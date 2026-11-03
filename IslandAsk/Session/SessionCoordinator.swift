//
//  SessionCoordinator.swift
//  IslandAsk
//
//  调度中心：串起 Live Activity、实时转录、静音检测、m4a 录音和大模型回答（SPEC 第 4、6.4 节）。
//  是唯一更新 Live Activity 和数据库（AskSession / ChatMessage）的地方。
//
//  关键约定：
//  - 灵动岛「停止」按钮与静音检测都走 stopListening(sessionID:)，不做两套结束逻辑。
//  - 6 秒不开口走 cancel(sessionID:failure:)：failed 态 + AlertConfiguration，保活 3 秒后再结束。
//  - 转录更新节流：第一条立即推，之后每秒最多推一次（有 pending 时补一次尾部推送）。
//  - M2：stopListening 第一步先拿 beginBackgroundTask，再停采集 → thinking → 另起任务问大模型 →
//    answered / failed（带 AlertConfiguration）→ 最后才关音频会话、结束后台任务（SPEC 第 4 节第 9、10 步）。
//    answered / failed 的 Live Activity 不自动结束，等用户点关闭、开始下一次提问或打开 App。
//  - M3：每次状态转换同步写 AskSession（SPEC 第 6.4 节）；App 内追问 askFollowUp、失败重问 retryAnswer
//    只在前台使用，不碰灵动岛。大模型配置每次请求从设置页读取。
//  - M4：失败文案统一走 UserFacingFailure（灵动岛短原因 + errorHint，会话页补充说明 + 操作）；
//    起录前检查实时活动和麦克风/语音识别权限；录音期间并行跑 Vision 文字识别，问大模型前最多再等 1.5 秒。
//

import AVFAudio
import ActivityKit
import Foundation
import SwiftData
import UIKit
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
    category: "coordinator"
)

private let activityLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
    category: "activity"
)

@MainActor
final class SessionCoordinator {

    static let shared = SessionCoordinator()

    /// 灵动岛/锁屏里显示的转录末尾字数（UI 优化后展开态显示最新约 80 字，留余量取 100；SPEC 6.10 原为 60 字）。
    private static let maxTranscriptTailLength = 100
    /// 说完后最多再等 OCR 多久（SPEC 第 2 节：后台保活约 30 秒，快速档本身 30 秒超时，不能多占）。
    private static let screenTextWaitLimit: Duration = .milliseconds(1500)

    private let audioCapture = AudioCaptureService()
    private let clock = ContinuousClock()

    private var currentActivityID: String?
    private var currentState: AskActivityAttributes.ContentState?
    private var currentSessionID: UUID?
    private var currentScreenshotURL: URL?
    /// M4：录音期间并行跑的截图文字识别；stopListening 交给 runAnswer 等结果。
    private var screenTextTask: Task<String?, Never>?
    private var transcription: TranscriptionService?
    /// 静音检测需要拿到转录文字（以转录为主判断说完/没说话，SPEC 第 6.7 节）。
    private var silenceDetector: SilenceDetector?

    /// 已停止录音、正在等大模型回答的会话（thinking 阶段）。
    private var answeringSessionID: UUID?
    private var answerTask: Task<Void, Never>?
    private var answerBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    /// App 内正在追问或重问的会话：同一会话同时只允许一个请求。
    private var inAppRequestSessionIDs: Set<UUID> = []

    private var isStartingSession = false
    private var isStopping = false

    private var transcriptUpdateTask: Task<Void, Never>?
    private var pendingActivityPushTask: Task<Void, Never>?
    private var lastActivityPush: ContinuousClock.Instant?
    private var latestTranscriptTail = ""
    private var didLogFirstTranscriptUpdate = false

    private init() {}

    /// 正在启动、录音或等大模型回答：此时 UI 的预热/残留清理都不能碰音频会话和 Live Activity。
    var isSessionBusy: Bool {
        isStartingSession || currentSessionID != nil || answeringSessionID != nil
    }

    // MARK: - 开始

    /// 按 SPEC 第 4 节第 5 步的顺序：
    /// 结束上一个 Live Activity → 启动新 Live Activity（phase = listening）→ 启动转录 → 激活音频会话并开始录音。
    func start(sessionID: UUID, screenshotURL: URL?) async throws {
        guard !isStartingSession else {
            logger.error("start ignored: another session is starting session=\(sessionID.uuidString, privacy: .public)")
            return
        }
        isStartingSession = true
        defer { isStartingSession = false }

        // 同一时间只允许一个会话：新会话开始前先把上一个收干净（SPEC 第 6.4 节）。
        // 上一个还在等回答：直接放弃，结果不再更新灵动岛；音频会话马上会被新会话重新激活，这里不关。
        if answeringSessionID != nil {
            abandonAnswering(reason: "new session started")
        }
        if let existingSessionID = currentSessionID {
            logger.notice(
                "start: stopping previous session previous=\(existingSessionID.uuidString, privacy: .public)"
            )
            await stopListening(sessionID: existingSessionID.uuidString)
        }

        logger.info(
            "start session=\(sessionID.uuidString, privacy: .public) hasScreenshot=\(screenshotURL != nil, privacy: .public)"
        )
        await endAllActivities(reason: "before new session")

        // 实时活动被关闭时 Activity.request 只会抛一个看不懂的错误，提前给快捷指令一句能照着做的话。
        guard PermissionManager.areLiveActivitiesEnabled else {
            logger.error("start aborted: live activities disabled session=\(sessionID.uuidString, privacy: .public)")
            throw SessionCoordinatorError.liveActivitiesDisabled
        }

        let state = AskActivityAttributes.ContentState(
            phase: .listening,
            transcriptTail: "",
            summary: nil,
            errorMessage: nil,
            startedAt: .now
        )

        do {
            let content = ActivityContent(state: state, staleDate: nil)
            let activity = try Activity.request(
                attributes: AskActivityAttributes(sessionID: sessionID.uuidString),
                content: content,
                pushType: nil
            )
            currentActivityID = activity.id
            currentState = state
            activityLogger.info("live activity started id=\(activity.id, privacy: .public)")
        } catch {
            let nsError = error as NSError
            logger.error(
                "live activity request failed session=\(sessionID.uuidString, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) error=\(nsError.localizedDescription, privacy: .public)"
            )
            throw SessionCoordinatorError.liveActivityStartFailed
        }

        // Intent 里不能弹授权框（SPEC 第 2 节）。没授权时音频/转录会报底层错误码，
        // 这里先在灵动岛上说清楚原因，再给快捷指令抛一句人话。
        if let missing = Self.missingPermission() {
            logger.error(
                "start aborted: permission missing session=\(sessionID.uuidString, privacy: .public) failure=\(missing.failure.message, privacy: .public)"
            )
            await presentFailureThenEnd(missing.failure, sessionID: sessionID)
            throw missing.error
        }

        // 先选好转录引擎（SpeechAnalyzer 只准备、不启动分析），再启动 M0 验证过的音频链路；
        // 音频跑起来之后才 activate 转录，避免模型启动与 AVAudioEngine 起 IO 互相影响。
        let transcription = TranscriptionService()
        do {
            let engine = try await transcription.prepare(locale: SpeechModelManager.locale)
            logger.info(
                "session=\(sessionID.uuidString, privacy: .public) transcription engine=\(engine.rawValue, privacy: .public)"
            )
        } catch {
            let nsError = error as NSError
            logger.error(
                "transcription start failed session=\(sessionID.uuidString, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) error=\(nsError.localizedDescription, privacy: .public)"
            )
            await endAllActivities(reason: "transcription start failed")
            throw SessionCoordinatorError.transcriptionStartFailed
        }

        // 静音检测只负责发事件；结束动作统一回调度器，和停止按钮同一条路径。
        let detector = SilenceDetector { event in
            switch event {
            case .finishedSpeaking, .maxDurationReached:
                Task {
                    await SessionCoordinator.shared.stopListening(sessionID: sessionID.uuidString)
                }
            case .noSpeechTimeout:
                Task {
                    await SessionCoordinator.shared.cancel(sessionID: sessionID.uuidString, failure: .noSpeech)
                }
            }
        }

        do {
            let audioURL = try AudioCaptureService.audioFileURL(sessionID: sessionID)
            try await audioCapture.start(
                sessionID: sessionID,
                fileURL: audioURL,
                consumers: [transcription, detector]
            )
        } catch {
            let nsError = error as NSError
            logger.error(
                "audio start failed session=\(sessionID.uuidString, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) error=\(nsError.localizedDescription, privacy: .public)"
            )
            await transcription.cancel()
            await endAllActivities(reason: "audio start failed")
            throw SessionCoordinatorError.audioStartFailed
        }

        // 音频已在跑，现在才真正启动转录分析；失败要把已经开始的录音和 activity 收干净。
        do {
            try await transcription.activate()
        } catch {
            let nsError = error as NSError
            logger.error(
                "transcription activate failed session=\(sessionID.uuidString, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) error=\(nsError.localizedDescription, privacy: .public)"
            )
            audioCapture.stopCaptureKeepingSessionActive()
            await transcription.cancel()
            await endAllActivities(reason: "transcription activate failed")
            await audioCapture.deactivateAudioSession()
            throw SessionCoordinatorError.transcriptionStartFailed
        }

        // SPEC 第 4 节第 5.5 步：写入 AskSession（status = listening）。
        let session = AskSession(
            id: sessionID,
            screenshotPath: screenshotURL.map(ScreenshotStore.relativePath(for:))
        )
        AppDatabase.context.insert(session)
        AppDatabase.save(reason: "session inserted listening")

        self.transcription = transcription
        silenceDetector = detector
        currentSessionID = sessionID
        currentScreenshotURL = screenshotURL
        latestTranscriptTail = ""
        lastActivityPush = nil
        didLogFirstTranscriptUpdate = false
        startTranscriptUpdates()
        startScreenTextRecognition(sessionID: sessionID, screenshotURL: screenshotURL)
        logger.info("start succeeded session=\(sessionID.uuidString, privacy: .public)")
    }

    // MARK: - 停止

    /// 灵动岛「停止」按钮、静音检测（说完/超 60 秒）都走这里。
    /// 故意不依赖 currentSessionID 匹配：参数丢失、App 进程被重建时也要把录音和 Live Activity 收干净。
    /// 进入 thinking 后另起任务问大模型、立即返回：StopAskIntent.perform() 会 await 这里，不能让它等回答。
    func stopListening(sessionID: String) async {
        guard !isStopping else {
            logger.error("stopListening ignored: stop already in progress session=\(sessionID, privacy: .public)")
            return
        }
        isStopping = true
        defer { isStopping = false }

        let trackedSessionID = currentSessionID
        let current = trackedSessionID?.uuidString ?? "nil"
        logger.info(
            "stopListening requested session=\(sessionID, privacy: .public) current=\(current, privacy: .public)"
        )

        guard let trackedSessionID else {
            // 已经在等回答（例如停止按钮被重复点击）：不能把 thinking 的灵动岛和音频会话收掉。
            if let answering = answeringSessionID {
                logger.notice(
                    "stopListening ignored: session=\(answering.uuidString, privacy: .public) already answering"
                )
                return
            }
            logger.error("stopListening with no active session; cleaning up leftover activity")
            await endAllActivities(reason: "stop with no session")
            await audioCapture.deactivateAudioSession()
            return
        }
        if trackedSessionID.uuidString != sessionID {
            logger.error(
                "stopListening session mismatch current=\(current, privacy: .public) requested=\(sessionID, privacy: .public)"
            )
        }

        // 第一步先拿后台任务：停掉引擎后进程不再算「在录音」，要靠它撑到回答返回（SPEC 第 4 节第 9 步）。
        beginAnswerBackgroundTask(sessionID: trackedSessionID)

        // 先停采集但保留音频会话（保活）→ 取最终转录并落盘 → thinking → 等回答 → 最后才关音频会话。
        audioCapture.stopCaptureKeepingSessionActive()
        transcriptUpdateTask?.cancel()
        transcriptUpdateTask = nil
        pendingActivityPushTask?.cancel()
        pendingActivityPushTask = nil

        let finalText: String
        if let transcription {
            finalText = await transcription.finish()
        } else {
            finalText = ""
        }
        self.transcription = nil
        silenceDetector = nil

        let question = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        updateSession(trackedSessionID, reason: question.isEmpty ? "empty transcript" : "thinking") { session in
            session.transcript = question
            if question.isEmpty {
                session.markFailed(.noSpeech)
            } else {
                session.statusValue = .thinking
            }
        }

        let screenshotURL = currentScreenshotURL
        let screenTextTask = self.screenTextTask
        self.screenTextTask = nil
        currentSessionID = nil
        currentScreenshotURL = nil
        latestTranscriptTail = ""
        lastActivityPush = nil

        guard !question.isEmpty else {
            screenTextTask?.cancel()
            // 没识别到文字就不问大模型，按「没听到」提示后结束。
            logger.notice("stopListening: empty transcript session=\(trackedSessionID.uuidString, privacy: .public)")
            await presentFailureThenEnd(.noSpeech, sessionID: trackedSessionID)
            endAnswerBackgroundTask(reason: "empty transcript")
            return
        }

        answeringSessionID = trackedSessionID
        let thinkingState = AskActivityAttributes.ContentState(
            phase: .thinking,
            transcriptTail: String(question.suffix(Self.maxTranscriptTailLength)),
            summary: nil,
            errorMessage: nil,
            startedAt: currentState?.startedAt ?? .now
        )
        await updateCurrentActivity(thinkingState, alert: nil)
        logger.info(
            "thinking session=\(trackedSessionID.uuidString, privacy: .public) chars=\(question.count, privacy: .public) hasScreenshot=\(screenshotURL != nil, privacy: .public)"
        )

        answerTask = Task { [weak self] in
            await self?.runAnswer(
                sessionID: trackedSessionID,
                question: question,
                screenshotURL: screenshotURL,
                screenTextTask: screenTextTask
            )
        }
    }

    /// 灵动岛 answered / failed 的关闭按钮（DismissAskIntent）。
    func dismiss(sessionID: String) async {
        logger.info("dismiss requested session=\(sessionID, privacy: .public)")

        // 正常不会在 thinking 时点到关闭；万一点到了，放弃这次回答并把保活收干净。
        if let answering = answeringSessionID, answering.uuidString == sessionID {
            abandonAnswering(reason: "dismissed")
            await audioCapture.deactivateAudioSession()
        }

        // Activity 非 Sendable：先只取 id，再按 id 逐个取新引用去 end（与 scheduleActivityEnd 同一做法）。
        let activityIDs = Self.activityIDs(sessionID: sessionID)
        guard !activityIDs.isEmpty else {
            activityLogger.error("dismiss: no live activity for session=\(sessionID, privacy: .public)")
            return
        }
        activityLogger.info("dismissing \(activityIDs.count, privacy: .public) live activity(ies)")
        if let currentActivityID, activityIDs.contains(currentActivityID) {
            self.currentActivityID = nil
            currentState = nil
        }
        for activityID in activityIDs {
            if let activity = Self.findActivity(id: activityID) {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// 没说话/出错：failed 态提示一下再结束。用后台任务保住这 3 秒，音频会话可以尽早关。
    func cancel(sessionID: String, failure: UserFacingFailure) async {
        let reason = failure.message
        guard !isStopping else {
            logger.error("cancel ignored: stop already in progress session=\(sessionID, privacy: .public)")
            return
        }
        isStopping = true
        defer { isStopping = false }

        guard let trackedSessionID = currentSessionID else {
            if let answering = answeringSessionID {
                logger.notice(
                    "cancel ignored: session=\(answering.uuidString, privacy: .public) already answering"
                )
                return
            }
            logger.error("cancel with no active session; cleaning up leftover activity")
            await endAllActivities(reason: "cancel with no session")
            await audioCapture.deactivateAudioSession()
            return
        }
        logger.info(
            "cancel requested session=\(trackedSessionID.uuidString, privacy: .public) reason=\(reason, privacy: .public)"
        )

        audioCapture.stopCaptureKeepingSessionActive()
        transcriptUpdateTask?.cancel()
        transcriptUpdateTask = nil
        pendingActivityPushTask?.cancel()
        pendingActivityPushTask = nil

        if let transcription {
            await transcription.cancel()
        }
        self.transcription = nil
        silenceDetector = nil
        screenTextTask?.cancel()
        screenTextTask = nil
        currentSessionID = nil
        currentScreenshotURL = nil
        latestTranscriptTail = ""
        lastActivityPush = nil

        updateSession(trackedSessionID, reason: "cancelled") { session in
            session.markFailed(failure)
        }
        await presentFailureThenEnd(failure, sessionID: trackedSessionID)
        logger.info("cancel finished session=\(trackedSessionID.uuidString, privacy: .public)")
    }

    /// failed 态 + AlertConfiguration 提示一下，关音频会话，3 秒后结束 Live Activity。
    /// 用于「没听到」这类不需要用户处理的失败；大模型失败会一直显示，见 runAnswer。
    private func presentFailureThenEnd(_ failure: UserFacingFailure, sessionID: UUID) async {
        let reason = failure.message
        let failedState = AskActivityAttributes.ContentState(
            phase: .failed,
            transcriptTail: "",
            summary: nil,
            errorMessage: reason,
            startedAt: currentState?.startedAt ?? .now,
            errorHint: failure.islandHint
        )
        currentState = failedState

        guard let activityID = currentActivityID, let activity = Self.findActivity(id: activityID) else {
            currentActivityID = nil
            await audioCapture.deactivateAudioSession()
            return
        }

        // 先拿后台保活，再 update + 关音频会话；3 秒后真正 end（dismissalPolicy 只影响锁屏，不影响灵动岛）。
        let backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "islandask.failedActivity")
        await activity.update(
            ActivityContent(state: failedState, staleDate: nil),
            alertConfiguration: AlertConfiguration(
                title: "IslandAsk",
                body: LocalizedStringResource(stringLiteral: reason),
                sound: .default
            )
        )
        activityLogger.info(
            "failed state shown session=\(sessionID.uuidString, privacy: .public) reason=\(reason, privacy: .public)"
        )
        await audioCapture.deactivateAudioSession()
        scheduleActivityEnd(activityID: activityID, after: .seconds(3), backgroundTaskID: backgroundTaskID)
    }

    // MARK: - 大模型回答

    /// thinking 之后的后台流程：压缩截图 → 问大模型 → 写 AskSession → answered / failed → 关音频会话 → 结束后台任务。
    private func runAnswer(
        sessionID: UUID,
        question: String,
        screenshotURL: URL?,
        screenTextTask: Task<String?, Never>?
    ) async {
        let startedAt = clock.now
        logger.notice(
            "answer start session=\(sessionID.uuidString, privacy: .public) backgroundTimeRemaining=\(UIApplication.shared.backgroundTimeRemaining, privacy: .public)"
        )

        let imageJPEG = await Self.uploadJPEGIfPossible(url: screenshotURL, sessionID: sessionID)
        let screenText = await awaitScreenText(screenTextTask, sessionID: sessionID)

        let outcome: Result<LLMAnswer, any Error>
        do {
            let provider = try OpenAICompatibleProvider.fromSettings()
            outcome = .success(
                try await provider.ask(imageJPEG: imageJPEG, screenText: screenText, question: question, history: [])
            )
        } catch {
            outcome = .failure(error)
        }
        let latencyMs = Self.milliseconds(clock.now - startedAt)

        // 被新会话或关闭按钮放弃了：结果只记日志，不再碰灵动岛、音频会话和后台任务（放弃方已经收尾）。
        guard answeringSessionID == sessionID else {
            logger.notice(
                "answer discarded: session=\(sessionID.uuidString, privacy: .public) superseded latencyMs=\(latencyMs, privacy: .public)"
            )
            return
        }

        let finalState: AskActivityAttributes.ContentState
        let alertBody: String
        switch outcome {
        case .success(let answer):
            updateSession(sessionID, reason: "answered") { session in
                session.summary = answer.summary
                session.answer = answer.answer
                session.needsDeepAnswer = answer.needsDeep ?? true
                session.clearFailure()
                session.statusValue = .answered
            }
            finalState = AskActivityAttributes.ContentState(
                phase: .answered,
                transcriptTail: currentState?.transcriptTail ?? "",
                summary: answer.summary,
                errorMessage: nil,
                startedAt: currentState?.startedAt ?? .now
            )
            alertBody = answer.summary
            logger.info(
                "answered session=\(sessionID.uuidString, privacy: .public) latencyMs=\(latencyMs, privacy: .public)"
            )
        case .failure(let error):
            // 后台任务过期时请求被取消，对用户来说就是超时（answerFailure 里处理）。
            let failure = UserFacingFailure.answerFailure(for: error)
            updateSession(sessionID, reason: "answer failed") { session in
                session.markFailed(failure)
            }
            finalState = AskActivityAttributes.ContentState(
                phase: .failed,
                transcriptTail: currentState?.transcriptTail ?? "",
                summary: nil,
                errorMessage: failure.message,
                startedAt: currentState?.startedAt ?? .now,
                errorHint: failure.islandHint
            )
            alertBody = failure.message
            logger.error(
                "answer failed session=\(sessionID.uuidString, privacy: .public) latencyMs=\(latencyMs, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }

        // SPEC 第 4 节第 10 步：带 AlertConfiguration 更新 → 停用音频会话 → endBackgroundTask。
        // TODO: 核对官方文档：确认 App 在后台时带 AlertConfiguration 的 update 会让灵动岛自动展开（M1 的 failed 已用过，answered 需真机再确认）。
        await updateCurrentActivity(
            finalState,
            alert: AlertConfiguration(
                title: "IslandAsk",
                body: LocalizedStringResource(stringLiteral: alertBody),
                sound: .default
            )
        )
        answeringSessionID = nil
        answerTask = nil
        await audioCapture.deactivateAudioSession()
        endAnswerBackgroundTask(reason: "answer finished")
    }

    /// 放弃正在等的回答（新会话开始 / 用户关闭）。不关音频会话：调用方按需处理。
    private func abandonAnswering(reason: String) {
        let answering = answeringSessionID?.uuidString ?? "nil"
        logger.notice(
            "abandon answering session=\(answering, privacy: .public) reason=\(reason, privacy: .public)"
        )
        if let answering = answeringSessionID {
            updateSession(answering, reason: "abandoned") { session in
                session.markFailed(.cancelled)
            }
        }
        answeringSessionID = nil
        answerTask?.cancel()
        answerTask = nil
        endAnswerBackgroundTask(reason: reason)
    }

    private func beginAnswerBackgroundTask(sessionID: UUID) {
        endAnswerBackgroundTask(reason: "replaced by new background task")
        answerBackgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "islandask.llm") {
            // 系统在主线程回调过期处理；必须在这里同步结束后台任务，否则进程会被杀。
            MainActor.assumeIsolated {
                SessionCoordinator.shared.handleAnswerBackgroundTaskExpired()
            }
        }
        if answerBackgroundTaskID == .invalid {
            logger.error("background task unavailable session=\(sessionID.uuidString, privacy: .public)")
        } else {
            logger.notice(
                "background task began session=\(sessionID.uuidString, privacy: .public) remaining=\(UIApplication.shared.backgroundTimeRemaining, privacy: .public)"
            )
        }
    }

    /// 后台时间用完：取消请求（runAnswer 会把它当超时显示 failed），并立即结束后台任务。
    private func handleAnswerBackgroundTaskExpired() {
        let answering = answeringSessionID?.uuidString ?? "nil"
        logger.error("background task expired answering=\(answering, privacy: .public); cancelling LLM request")
        answerTask?.cancel()
        endAnswerBackgroundTask(reason: "expired")
    }

    private func endAnswerBackgroundTask(reason: String) {
        guard answerBackgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(answerBackgroundTaskID)
        answerBackgroundTaskID = .invalid
        logger.info("background task ended reason=\(reason, privacy: .public)")
    }

    /// 截图解码和 JPEG 编码比较重，放到主线程之外。压缩失败不影响提问，只是不带图。
    @concurrent
    private nonisolated static func uploadJPEGIfPossible(url: URL?, sessionID: UUID) async -> Data? {
        guard let url else { return nil }
        do {
            return try ScreenshotStore.jpegForUpload(url: url, sessionID: sessionID)
        } catch {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk", category: "coordinator").error(
                "screenshot compress failed, asking without image session=\(sessionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    // MARK: - 截图文字识别（M4）

    /// 录音一开始就并行识别截图文字：用户说话的几秒足够跑完，问大模型时基本不用再等。
    private func startScreenTextRecognition(sessionID: UUID, screenshotURL: URL?) {
        screenTextTask?.cancel()
        screenTextTask = nil
        guard let screenshotURL else { return }
        guard AppSettings.screenTextRecognitionEnabled else {
            logger.info("ocr skipped: disabled in settings session=\(sessionID.uuidString, privacy: .public)")
            return
        }
        screenTextTask = Task {
            await TextRecognizer.recognize(imageURL: screenshotURL, sessionID: sessionID)
        }
    }

    /// 问大模型前最多再等 screenTextWaitLimit；没识别完就先不带文字问，识别完再补写进库，供深度回答和追问使用。
    private func awaitScreenText(_ task: Task<String?, Never>?, sessionID: UUID) async -> String? {
        guard let task else { return nil }
        enum Wait: Sendable {
            case finished(String?)
            case timedOut
        }
        let waitStartedAt = clock.now
        let limit = Self.screenTextWaitLimit
        let result = await withTaskGroup(of: Wait.self) { group in
            group.addTask { .finished(await task.value) }
            group.addTask {
                try? await Task.sleep(for: limit)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
        let waitedMs = Self.milliseconds(clock.now - waitStartedAt)
        switch result {
        case .finished(let text):
            logger.info(
                "ocr ready session=\(sessionID.uuidString, privacy: .public) chars=\(text?.count ?? 0, privacy: .public) waitedMs=\(waitedMs, privacy: .public)"
            )
            if let text {
                updateSession(sessionID, reason: "ocr text saved") { $0.ocrText = text }
            }
            return text
        case .timedOut:
            logger.notice(
                "ocr not ready, asking without it session=\(sessionID.uuidString, privacy: .public) waitedMs=\(waitedMs, privacy: .public)"
            )
            Task { [weak self] in
                guard let text = await task.value else { return }
                self?.updateSession(sessionID, reason: "ocr text saved late") { $0.ocrText = text }
            }
            return nil
        }
    }

    /// App 内请求（深度回答、追问、重问）用的 OCR 文字：已有就复用；没有（旧会话 / 当时没识别完）就现在识别并写库。
    /// 设置里关掉后一律不带。
    private func screenTextForInAppRequest(sessionID: UUID) async -> String? {
        guard AppSettings.screenTextRecognitionEnabled,
              let session = AppDatabase.fetchSession(id: sessionID) else { return nil }
        if let stored = session.ocrText {
            return stored
        }
        guard let screenshotURL = session.screenshotURL else { return nil }
        let text = await TextRecognizer.recognize(imageURL: screenshotURL, sessionID: sessionID)
        if let text {
            updateSession(sessionID, reason: "ocr text saved in app") { $0.ocrText = text }
        }
        return text
    }

    /// 起录前的权限检查：Intent 里不能弹授权框，没授权就只能提示用户回 App 处理。
    private static func missingPermission() -> (failure: UserFacingFailure, error: SessionCoordinatorError)? {
        if PermissionManager.microphoneStatus != .granted {
            return (.microphoneDenied, .microphoneNotAuthorized)
        }
        if !PermissionManager.isSpeechRecognitionGranted {
            return (.speechDenied, .speechNotAuthorized)
        }
        return nil
    }

    // MARK: - 数据库

    /// 所有 AskSession 的修改都走这里（SPEC 第 6.4 节：任何状态转换都同步写入数据库）。
    private func updateSession(_ id: UUID, reason: String, _ mutate: (AskSession) -> Void) {
        guard let session = AppDatabase.fetchSession(id: id) else {
            logger.error(
                "session update skipped: not found session=\(id.uuidString, privacy: .public) reason=\(reason, privacy: .public)"
            )
            return
        }
        mutate(session)
        AppDatabase.save(reason: "\(reason) session=\(id.uuidString)")
    }

    // MARK: - App 内深度回答 / 追问 / 重问 / 深链

    /// 会话页的深度回答：开思考、流式，结果写进 deepAnswer / deepReasoning。
    /// 只在快速回答已到达、还没有深度回答、没有其它请求进行时开始；流由协调器持有，离开会话页也继续。
    func startDeepAnswer(sessionID: UUID) {
        guard let session = AppDatabase.fetchSession(id: sessionID) else {
            logger.error("deep answer skipped: session not found session=\(sessionID.uuidString, privacy: .public)")
            return
        }
        let question = session.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard session.statusValue == .answered, session.deepAnswer == nil, !question.isEmpty else {
            logger.info(
                "deep answer skipped session=\(sessionID.uuidString, privacy: .public) status=\(session.status, privacy: .public) hasDeep=\(session.deepAnswer != nil, privacy: .public)"
            )
            return
        }
        guard inAppRequestSessionIDs.insert(sessionID).inserted else {
            logger.notice("deep answer skipped: request in flight session=\(sessionID.uuidString, privacy: .public)")
            return
        }

        let screenshotURL = session.screenshotURL
        session.deepError = nil
        AppDatabase.save(reason: "deep answer start session=\(sessionID.uuidString)")
        logger.info("deep answer start session=\(sessionID.uuidString, privacy: .public)")

        let reply = StreamingReplyStore.shared.begin(sessionID: sessionID, kind: .deepAnswer)
        let work = Task {
            let screenText = await SessionCoordinator.shared.screenTextForInAppRequest(sessionID: sessionID)
            try await Self.consumeDeepStream(
                into: reply,
                sessionID: sessionID,
                screenshotURL: screenshotURL,
                screenText: screenText,
                question: question,
                history: []
            )
        }
        // 用户切走 App 时还有约 30 秒；用完就取消，下次打开会话页重新生成。
        let backgroundToken = BackgroundTaskToken(name: "islandask.deepAnswer") { work.cancel() }

        Task { [weak self] in
            let result = await work.result
            backgroundToken.end()
            self?.finishDeepAnswer(sessionID: sessionID, reply: reply, result: result)
        }
    }

    private func finishDeepAnswer(sessionID: UUID, reply: StreamingReply, result: Result<Void, any Error>) {
        defer {
            inAppRequestSessionIDs.remove(sessionID)
            StreamingReplyStore.shared.end(sessionID: sessionID)
        }
        reply.flush()
        switch result {
        case .success:
            updateSession(sessionID, reason: "deep answer finished") { session in
                session.deepAnswer = reply.content
                session.deepReasoning = reply.reasoning.isEmpty ? nil : reply.reasoning
                session.deepError = nil
            }
            logger.info(
                "deep answer succeeded session=\(sessionID.uuidString, privacy: .public) contentChars=\(reply.content.count, privacy: .public) reasoningChars=\(reply.reasoning.count, privacy: .public)"
            )
        case .failure(let error):
            let message = Self.deepFailureMessage(for: error)
            updateSession(sessionID, reason: "deep answer failed") { session in
                session.deepError = message
            }
            logger.error(
                "deep answer failed session=\(sessionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// 会话页底部的追问（SPEC 第 6.12 节）：沿用同一张截图和上下文（首轮问题 + 回答 + 已有追问），深度思考 + 流式。
    /// 失败时撤回这条 user 消息并抛错，UI 把文字放回输入框。
    func askFollowUp(sessionID: UUID, text: String) async throws {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        guard let session = AppDatabase.fetchSession(id: sessionID) else {
            logger.error("follow-up failed: session not found session=\(sessionID.uuidString, privacy: .public)")
            throw SessionCoordinatorError.sessionNotFound
        }
        guard inAppRequestSessionIDs.insert(sessionID).inserted else {
            logger.notice("follow-up ignored: request in flight session=\(sessionID.uuidString, privacy: .public)")
            return
        }
        defer {
            inAppRequestSessionIDs.remove(sessionID)
            StreamingReplyStore.shared.end(sessionID: sessionID)
        }

        let history = session.conversationTurns
        let screenshotURL = session.screenshotURL
        let userMessage = ChatMessage(role: .user, content: question)
        session.messages.append(userMessage)
        AppDatabase.save(reason: "follow-up user message session=\(sessionID.uuidString)")
        logger.info(
            "follow-up start session=\(sessionID.uuidString, privacy: .public) chars=\(question.count, privacy: .public) history=\(history.count, privacy: .public)"
        )

        let reply = StreamingReplyStore.shared.begin(sessionID: sessionID, kind: .followUp)
        let work = Task {
            let screenText = await SessionCoordinator.shared.screenTextForInAppRequest(sessionID: sessionID)
            try await Self.consumeDeepStream(
                into: reply,
                sessionID: sessionID,
                screenshotURL: screenshotURL,
                screenText: screenText,
                question: question,
                history: history
            )
        }
        // 用户在等回答时切走 App，后台时间用完就取消请求。
        let backgroundToken = BackgroundTaskToken(name: "islandask.followUp") { work.cancel() }
        defer { backgroundToken.end() }

        do {
            try await work.value
            reply.flush()
            session.messages.append(
                ChatMessage(
                    role: .assistant,
                    content: reply.content,
                    reasoning: reply.reasoning.isEmpty ? nil : reply.reasoning
                )
            )
            AppDatabase.save(reason: "follow-up answered session=\(sessionID.uuidString)")
            logger.info(
                "follow-up succeeded session=\(sessionID.uuidString, privacy: .public) contentChars=\(reply.content.count, privacy: .public) reasoningChars=\(reply.reasoning.count, privacy: .public)"
            )
        } catch {
            logger.error(
                "follow-up failed session=\(sessionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            AppDatabase.context.delete(userMessage)
            AppDatabase.save(reason: "follow-up rollback session=\(sessionID.uuidString)")
            throw SessionCoordinatorError.followUpFailed(Self.deepFailureMessage(for: error))
        }
    }

    /// 深度回答和追问共用：压缩截图 → 开流 → 片段写进 reply。在主线程迭代，reply 是主线程对象。
    private static func consumeDeepStream(
        into reply: StreamingReply,
        sessionID: UUID,
        screenshotURL: URL?,
        screenText: String?,
        question: String,
        history: [LLMTurn]
    ) async throws {
        let imageJPEG = await uploadJPEGIfPossible(url: screenshotURL, sessionID: sessionID)
        let provider = try OpenAICompatibleProvider.fromSettings()
        let stream = provider.streamDeepAnswer(
            imageJPEG: imageJPEG,
            screenText: screenText,
            question: question,
            history: history
        )
        for try await event in stream {
            reply.append(event)
        }
        try Task.checkCancellation()
    }

    /// 深度档被取消通常是切到后台时间用完，提示用户回来重新生成。
    private static func deepFailureMessage(for error: any Error) -> String {
        if error is CancellationError {
            return "切到后台后被中断"
        }
        if let llmError = error as? LLMError, case .cancelled = llmError {
            return "切到后台后被中断"
        }
        return (error as? LLMError)?.errorDescription ?? error.localizedDescription
    }

    /// 失败会话在 App 内重新提问（SPEC 第 8 节：断网或 API 超时，App 内可重试）。只更新数据库，不碰灵动岛。
    func retryAnswer(sessionID: UUID) async {
        guard let session = AppDatabase.fetchSession(id: sessionID) else {
            logger.error("retry failed: session not found session=\(sessionID.uuidString, privacy: .public)")
            return
        }
        let question = session.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, session.statusValue == .failed, answeringSessionID != sessionID else {
            logger.notice(
                "retry ignored session=\(sessionID.uuidString, privacy: .public) status=\(session.status, privacy: .public) chars=\(question.count, privacy: .public)"
            )
            return
        }
        guard inAppRequestSessionIDs.insert(sessionID).inserted else {
            logger.notice("retry ignored: request in flight session=\(sessionID.uuidString, privacy: .public)")
            return
        }
        defer { inAppRequestSessionIDs.remove(sessionID) }

        let screenshotURL = session.screenshotURL
        session.statusValue = .thinking
        session.clearFailure()
        AppDatabase.save(reason: "retry thinking session=\(sessionID.uuidString)")
        logger.info("retry start session=\(sessionID.uuidString, privacy: .public)")

        let backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "islandask.retry")
        defer {
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
            }
        }

        do {
            let imageJPEG = await Self.uploadJPEGIfPossible(url: screenshotURL, sessionID: sessionID)
            let screenText = await screenTextForInAppRequest(sessionID: sessionID)
            let provider = try OpenAICompatibleProvider.fromSettings()
            let answer = try await provider.ask(
                imageJPEG: imageJPEG,
                screenText: screenText,
                question: question,
                history: []
            )
            session.summary = answer.summary
            session.answer = answer.answer
            session.needsDeepAnswer = answer.needsDeep ?? true
            session.statusValue = .answered
            AppDatabase.save(reason: "retry answered session=\(sessionID.uuidString)")
            logger.info("retry succeeded session=\(sessionID.uuidString, privacy: .public)")
        } catch {
            session.markFailed(.answerFailure(for: error))
            AppDatabase.save(reason: "retry failed session=\(sessionID.uuidString)")
            logger.error(
                "retry failed session=\(sessionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// 历史列表左滑删除：删数据库记录（追问级联删除）和截图、录音文件。进行中的会话不允许删。
    func deleteSession(id: UUID) {
        guard currentSessionID != id, answeringSessionID != id, !inAppRequestSessionIDs.contains(id) else {
            logger.notice("delete ignored: session in progress session=\(id.uuidString, privacy: .public)")
            return
        }
        guard let session = AppDatabase.fetchSession(id: id) else {
            logger.error("delete failed: session not found session=\(id.uuidString, privacy: .public)")
            return
        }
        AppDatabase.context.delete(session)
        AppDatabase.save(reason: "session deleted session=\(id.uuidString)")
        ScreenshotStore.removeArtifacts(sessionID: id)
    }

    func isInAppRequestInFlight(sessionID: UUID) -> Bool {
        inAppRequestSessionIDs.contains(sessionID)
    }

    /// 点灵动岛经深链进入会话页（SPEC 第 4 节第 11 步）：结束这个 Live Activity。
    /// 还在录音或等回答时不结束，让灵动岛继续显示进度。
    func openedSession(id: UUID) async {
        guard currentSessionID != id, answeringSessionID != id else {
            activityLogger.info("opened session=\(id.uuidString, privacy: .public) still in progress; keeping live activity")
            return
        }
        guard !Self.activityIDs(sessionID: id.uuidString).isEmpty else {
            activityLogger.info("opened session=\(id.uuidString, privacy: .public) has no live activity")
            return
        }
        await dismiss(sessionID: id.uuidString)
    }

    private nonisolated static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }

    // MARK: - 异常回收

    /// 异常态回收：调度器以为还在录音，但采集其实已经停了（例如被系统中断）。
    /// 把残留的 Live Activity 结束掉，避免灵动岛一直停在「正在听」。
    func recoverUnexpectedStoppedSessionIfNeeded() async {
        guard let sessionID = currentSessionID else { return }
        guard !audioCapture.isCapturing else { return }

        logger.error(
            "recover: capture stopped but session=\(sessionID.uuidString, privacy: .public) still tracked"
        )
        transcriptUpdateTask?.cancel()
        transcriptUpdateTask = nil
        pendingActivityPushTask?.cancel()
        pendingActivityPushTask = nil
        if let transcription {
            await transcription.cancel()
        }
        transcription = nil
        silenceDetector = nil
        screenTextTask?.cancel()
        screenTextTask = nil
        currentSessionID = nil
        currentScreenshotURL = nil
        currentState = nil
        updateSession(sessionID, reason: "recovered") { session in
            session.markFailed(.interrupted)
        }
        latestTranscriptTail = ""
        lastActivityPush = nil
        await endAllActivities(reason: "capture stopped unexpectedly")
        await audioCapture.deactivateAudioSession()
    }

    /// App 重新打开时收尾：如果当前没有在录音、也没在等回答，却还有残留的 Live Activity
    /// （停止时进程被挂起导致 activity.end 没执行完），补一次结束。
    /// answered / failed 的灵动岛也在这里结束，对应 SPEC 6.10「打开 App 查看后结束」。
    func endOrphanActivitiesIfNeeded() async {
        guard currentSessionID == nil, answeringSessionID == nil, !isStartingSession else { return }

        let activities = Activity<AskActivityAttributes>.activities
        guard !activities.isEmpty else { return }

        activityLogger.info("cleaning up \(activities.count, privacy: .public) orphan live activity(ies)")
        for activity in activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        currentActivityID = nil
    }

    // MARK: - 转录 → Live Activity

    private func startTranscriptUpdates() {
        guard let transcription else { return }
        transcriptUpdateTask = Task { [weak self] in
            for await update in transcription.updates {
                guard let self else { return }
                self.handleTranscriptUpdate(update)
            }
        }
    }

    private func handleTranscriptUpdate(_ update: TranscriptUpdate) {
        let display = update.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !display.isEmpty else { return }
        silenceDetector?.noteTranscript(display)

        if !didLogFirstTranscriptUpdate {
            didLogFirstTranscriptUpdate = true
            logger.info("first transcript update chars=\(display.count, privacy: .public)")
        }

        let tail = String(display.suffix(Self.maxTranscriptTailLength))
        latestTranscriptTail = tail
        guard tail != currentState?.transcriptTail else { return }
        scheduleTranscriptPush()
    }

    /// 节流：距上次推送满 1 秒就立即推，否则排一个 trailing 任务补推最新内容。
    private func scheduleTranscriptPush() {
        guard pendingActivityPushTask == nil else { return }

        let now = clock.now
        var delay = Duration.zero
        if let lastActivityPush, now - lastActivityPush < .seconds(1) {
            delay = .seconds(1) - (now - lastActivityPush)
        }

        pendingActivityPushTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard let self, !Task.isCancelled else { return }
            await self.pushTranscriptTail()
        }
    }

    private func pushTranscriptTail() async {
        pendingActivityPushTask = nil
        guard let activityID = currentActivityID,
              let activity = Self.findActivity(id: activityID),
              var state = currentState else { return }

        let tail = latestTranscriptTail
        guard !tail.isEmpty, tail != state.transcriptTail else { return }

        state.transcriptTail = tail
        currentState = state
        lastActivityPush = clock.now
        activityLogger.info("transcript tail pushed chars=\(tail.count, privacy: .public)")
        await activity.update(ActivityContent(state: state, staleDate: nil))

        // 推送期间又来了新文字：补一次（仍受 1 秒节流约束）。
        if latestTranscriptTail != state.transcriptTail {
            scheduleTranscriptPush()
        }
    }

    // MARK: - 收尾工具

    /// 更新当前 Live Activity 并同步 currentState；activity 已不存在时只记日志。
    private func updateCurrentActivity(
        _ state: AskActivityAttributes.ContentState,
        alert: AlertConfiguration?
    ) async {
        currentState = state
        guard let activityID = currentActivityID, let activity = Self.findActivity(id: activityID) else {
            activityLogger.error("update skipped: no live activity phase=\(state.phase.rawValue, privacy: .public)")
            return
        }
        let content = ActivityContent(state: state, staleDate: nil)
        if let alert {
            await activity.update(content, alertConfiguration: alert)
        } else {
            await activity.update(content)
        }
        activityLogger.info(
            "live activity updated phase=\(state.phase.rawValue, privacy: .public) alert=\(alert != nil, privacy: .public)"
        )
    }

    /// 结束当前所有本类型的 Live Activity（App 被重启过也能清干净）。
    private func endAllActivities(reason: String) async {
        pendingActivityPushTask?.cancel()
        pendingActivityPushTask = nil
        transcriptUpdateTask?.cancel()
        transcriptUpdateTask = nil

        let activities = Activity<AskActivityAttributes>.activities
        guard !activities.isEmpty else {
            currentActivityID = nil
            return
        }

        activityLogger.info(
            "ending \(activities.count, privacy: .public) live activity(ies) reason=\(reason, privacy: .public)"
        )
        for activity in activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        currentActivityID = nil
    }

    /// failed 态展示一会儿再结束；期间用后台任务保活（音频会话可能已经关了）。
    private func scheduleActivityEnd(
        activityID: String,
        after duration: Duration,
        backgroundTaskID: UIBackgroundTaskIdentifier
    ) {
        Task { [weak self] in
            try? await Task.sleep(for: duration)
            if let activity = Self.findActivity(id: activityID) {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            if let self, self.currentActivityID == activityID {
                self.currentActivityID = nil
                self.currentState = nil
            }
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
            }
        }
    }

    /// Activity 不是 Sendable，不长期持有；需要时按 id 从 ActivityKit 里取一个新的引用。
    private nonisolated static func findActivity(id: String) -> Activity<AskActivityAttributes>? {
        Activity<AskActivityAttributes>.activities.first { $0.id == id }
    }

    private nonisolated static func activityIDs(sessionID: String) -> [String] {
        Activity<AskActivityAttributes>.activities
            .filter { $0.attributes.sessionID == sessionID }
            .map(\.id)
    }
}

/// errorDescription 会显示在快捷指令的错误提示里，写成用户能照着做的话；原始错误码只进日志。
enum SessionCoordinatorError: LocalizedError {
    case liveActivitiesDisabled
    case microphoneNotAuthorized
    case speechNotAuthorized
    case liveActivityStartFailed
    case transcriptionStartFailed
    case audioStartFailed
    case sessionNotFound
    case followUpFailed(String)

    var errorDescription: String? {
        switch self {
        case .liveActivitiesDisabled:
            return "灵动岛（实时活动）已关闭。请到 设置 → IslandAsk 打开「实时活动」后再试。"
        case .microphoneNotAuthorized:
            return "IslandAsk 没有麦克风权限。请打开 IslandAsk 完成授权后再试。"
        case .speechNotAuthorized:
            return "IslandAsk 没有语音识别权限。请打开 IslandAsk 完成授权后再试。"
        case .liveActivityStartFailed:
            return "灵动岛没能启动，请稍后再试。"
        case .transcriptionStartFailed:
            return "语音识别没能启动。请打开 IslandAsk 检查语音模型是否已下载。"
        case .audioStartFailed:
            return "麦克风没能启动，可能正被通话或其他 App 占用，请稍后再试。"
        case .sessionNotFound:
            return "找不到这条会话"
        case .followUpFailed(let message):
            return "追问失败：\(message)"
        }
    }
}
