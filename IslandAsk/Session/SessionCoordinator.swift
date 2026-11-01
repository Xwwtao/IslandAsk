//
//  SessionCoordinator.swift
//  IslandAsk
//
//  调度中心：串起 Live Activity、实时转录、静音检测、m4a 录音和大模型回答（SPEC 第 4、6.4 节）。
//  是唯一更新 Live Activity 的地方。
//
//  关键约定：
//  - 灵动岛「停止」按钮与静音检测都走 stopListening(sessionID:)，不做两套结束逻辑。
//  - 6 秒不开口走 cancel(sessionID:reason:)：failed 态 + AlertConfiguration，保活 3 秒后再结束。
//  - 转录更新节流：第一条立即推，之后每秒最多推一次（有 pending 时补一次尾部推送）。
//  - M2：stopListening 第一步先拿 beginBackgroundTask，再停采集 → thinking → 另起任务问大模型 →
//    answered / failed（带 AlertConfiguration）→ 最后才关音频会话、结束后台任务（SPEC 第 4 节第 9、10 步）。
//    answered / failed 的 Live Activity 不自动结束，等用户点关闭、开始下一次提问或打开 App。
//

import ActivityKit
import Foundation
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

    /// 灵动岛/锁屏里显示的转录末尾字数（SPEC 第 6.10 节：最多 60 字）。
    private static let maxTranscriptTailLength = 60

    private let audioCapture = AudioCaptureService()
    private let llmProvider: any LLMProvider = OpenAICompatibleProvider.deepSeek()
    private let clock = ContinuousClock()

    private var currentActivityID: String?
    private var currentState: AskActivityAttributes.ContentState?
    private var currentSessionID: UUID?
    private var currentScreenshotURL: URL?
    private var transcription: TranscriptionService?
    /// 静音检测需要拿到转录文字（以转录为主判断说完/没说话，SPEC 第 6.7 节）。
    private var silenceDetector: SilenceDetector?

    /// 已停止录音、正在等大模型回答的会话（thinking 阶段）。
    private var answeringSessionID: UUID?
    private var answerTask: Task<Void, Never>?
    private var answerBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid

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
            throw SessionCoordinatorError.liveActivityStartFailed(
                "\(nsError.localizedDescription)（\(nsError.domain) \(nsError.code)）"
            )
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
            throw SessionCoordinatorError.transcriptionStartFailed(nsError.localizedDescription)
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
                    await SessionCoordinator.shared.cancel(sessionID: sessionID.uuidString, reason: "没听到")
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
            throw SessionCoordinatorError.audioStartFailed(
                "\(nsError.localizedDescription)（\(nsError.domain) \(nsError.code)）"
            )
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
            throw SessionCoordinatorError.transcriptionStartFailed(nsError.localizedDescription)
        }

        self.transcription = transcription
        silenceDetector = detector
        currentSessionID = sessionID
        currentScreenshotURL = screenshotURL
        latestTranscriptTail = ""
        lastActivityPush = nil
        didLogFirstTranscriptUpdate = false
        startTranscriptUpdates()
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

        do {
            try TranscriptStore.save(finalText, sessionID: trackedSessionID)
        } catch {
            logger.error(
                "transcript save failed session=\(trackedSessionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }

        let screenshotURL = currentScreenshotURL
        currentSessionID = nil
        currentScreenshotURL = nil
        latestTranscriptTail = ""
        lastActivityPush = nil

        let question = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            // 没识别到文字就不问大模型，按「没听到」提示后结束。
            logger.notice("stopListening: empty transcript session=\(trackedSessionID.uuidString, privacy: .public)")
            await presentFailureThenEnd(reason: "没听到", sessionID: trackedSessionID)
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
            await self?.runAnswer(sessionID: trackedSessionID, question: question, screenshotURL: screenshotURL)
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
    func cancel(sessionID: String, reason: String) async {
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
        currentSessionID = nil
        currentScreenshotURL = nil
        latestTranscriptTail = ""
        lastActivityPush = nil

        await presentFailureThenEnd(reason: reason, sessionID: trackedSessionID)
        logger.info("cancel finished session=\(trackedSessionID.uuidString, privacy: .public)")
    }

    /// failed 态 + AlertConfiguration 提示一下，关音频会话，3 秒后结束 Live Activity。
    /// 用于「没听到」这类不需要用户处理的失败；大模型失败会一直显示，见 runAnswer。
    private func presentFailureThenEnd(reason: String, sessionID: UUID) async {
        let failedState = AskActivityAttributes.ContentState(
            phase: .failed,
            transcriptTail: "",
            summary: nil,
            errorMessage: reason,
            startedAt: currentState?.startedAt ?? .now
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

    /// thinking 之后的后台流程：压缩截图 → 问大模型 → 存 .json → answered / failed → 关音频会话 → 结束后台任务。
    private func runAnswer(sessionID: UUID, question: String, screenshotURL: URL?) async {
        let startedAt = clock.now
        logger.notice(
            "answer start session=\(sessionID.uuidString, privacy: .public) backgroundTimeRemaining=\(UIApplication.shared.backgroundTimeRemaining, privacy: .public)"
        )

        var imageJPEG: Data?
        if let screenshotURL {
            do {
                imageJPEG = try await Self.makeUploadJPEG(url: screenshotURL, sessionID: sessionID)
            } catch {
                // 截图压缩失败不影响提问，只是不带图。
                logger.error(
                    "screenshot compress failed, asking without image session=\(sessionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }

        let outcome: Result<LLMAnswer, any Error>
        do {
            outcome = .success(try await llmProvider.ask(imageJPEG: imageJPEG, question: question, history: []))
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

        var result = SessionResult(
            sessionID: sessionID,
            createdAt: .now,
            question: question,
            status: .answered,
            summary: nil,
            answer: nil,
            errorMessage: nil,
            model: llmProvider.model,
            latencyMs: latencyMs
        )
        let finalState: AskActivityAttributes.ContentState
        let alertBody: String
        switch outcome {
        case .success(let answer):
            result.summary = answer.summary
            result.answer = answer.answer
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
            // 后台任务过期时请求被取消，对用户来说就是超时。
            let message: String
            if let llmError = error as? LLMError, case .cancelled = llmError {
                message = LLMError.timeout.errorDescription ?? "网络超时"
            } else {
                message = (error as? LLMError)?.errorDescription ?? error.localizedDescription
            }
            result.status = .failed
            result.errorMessage = message
            finalState = AskActivityAttributes.ContentState(
                phase: .failed,
                transcriptTail: currentState?.transcriptTail ?? "",
                summary: nil,
                errorMessage: message,
                startedAt: currentState?.startedAt ?? .now
            )
            alertBody = message
            logger.error(
                "answer failed session=\(sessionID.uuidString, privacy: .public) latencyMs=\(latencyMs, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }

        do {
            try AnswerStore.save(result)
        } catch {
            logger.error(
                "result save failed session=\(sessionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
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

    /// 截图解码和 JPEG 编码比较重，放到主线程之外。
    @concurrent
    private nonisolated static func makeUploadJPEG(url: URL, sessionID: UUID) async throws -> Data {
        try ScreenshotStore.jpegForUpload(url: url, sessionID: sessionID)
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
        currentSessionID = nil
        currentScreenshotURL = nil
        currentState = nil
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

enum SessionCoordinatorError: LocalizedError {
    case liveActivityStartFailed(String)
    case transcriptionStartFailed(String)
    case audioStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .liveActivityStartFailed(let message):
            return "启动灵动岛失败：\(message)"
        case .transcriptionStartFailed(let message):
            return "语音识别启动失败：\(message)"
        case .audioStartFailed(let message):
            return "开始录音失败：\(message)"
        }
    }
}
