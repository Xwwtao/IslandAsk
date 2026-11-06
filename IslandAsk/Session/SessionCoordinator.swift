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
//    起录前检查实时活动和麦克风/语音识别权限；录音期间并行跑 Vision 文字识别和截图压缩，问大模型前最多再等 OCR 1.5 秒。
//  - M4 耗时优化：快速档流式，摘要一到就显示；转录稳定 0.8 秒先发请求（SessionCoordinator+QuickAnswer.swift）。
//  - 文件拆分：本文件是会话主流程；Live Activity 推送与清理在 SessionCoordinator+LiveActivity.swift，
//    App 内深度回答 / 追问 / 重问在 SessionCoordinator+InApp.swift。
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
    static let maxTranscriptTailLength = 100
    /// 说完后最多再等 OCR 多久（SPEC 第 2 节：后台保活约 30 秒，快速档本身 30 秒超时，不能多占）。
    private static let screenTextWaitLimit: Duration = .milliseconds(1500)

    // 下面这些状态不标 private：SessionCoordinator+LiveActivity.swift / +InApp.swift 两个扩展文件要用。
    // 只应在 SessionCoordinator 及其扩展里读写。
    let audioCapture = AudioCaptureService()
    let clock = ContinuousClock()

    var currentActivityID: String?
    var currentState: AskActivityAttributes.ContentState?
    var currentSessionID: UUID?
    private var currentScreenshotURL: URL?
    /// M4：录音期间并行跑的截图文字识别；快速档请求（含提前请求）等它的结果。
    var screenTextTask: Task<String?, Never>?
    /// M4：录音期间就开始压缩截图，说完后不用再等 JPEG 编码。
    var screenshotJPEGTask: Task<Data?, Never>?
    /// M4：录音中提前发的快速档请求（见 SessionCoordinator+QuickAnswer.swift）。
    var speculativeRun: QuickAnswerRun?
    var speculativeRequestCount = 0
    var transcription: TranscriptionService?
    /// 静音检测需要拿到转录文字（以转录为主判断说完/没说话，SPEC 第 6.7 节）。
    var silenceDetector: SilenceDetector?

    /// 已停止录音、正在等大模型回答的会话（thinking 阶段）。
    var answeringSessionID: UUID?
    private var answerTask: Task<Void, Never>?
    private var answerBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    /// App 内正在追问或重问的会话：同一会话同时只允许一个请求。
    var inAppRequestSessionIDs: Set<UUID> = []

    var isStartingSession = false
    var isStopping = false

    var transcriptUpdateTask: Task<Void, Never>?
    var pendingActivityPushTask: Task<Void, Never>?
    var lastActivityPush: ContinuousClock.Instant?
    var latestTranscriptTail = ""
    var didLogFirstTranscriptUpdate = false

    // 耗时采集（SessionTiming）：录音开始时间、最后一次转录文字变化的时间和文字、本次会话已采到的耗时。
    var listeningStartedAt: ContinuousClock.Instant?
    var lastTranscriptChangeAt: ContinuousClock.Instant?
    var lastTranscriptText = ""
    var pendingTiming = SessionTiming()
    /// 最后一次转录文字变化时已写进录音文件的时长：截掉录音末尾静音的依据。
    var lastSpeechAudioSeconds: Double?

    private init() {}

    /// 正在启动、录音或等大模型回答：此时 UI 的预热/残留清理都不能碰音频会话和 Live Activity。
    var isSessionBusy: Bool {
        isStartingSession || currentSessionID != nil || answeringSessionID != nil
    }

    // MARK: - 开始

    /// 按 SPEC 第 4 节第 5 步的顺序：
    /// 结束上一个 Live Activity → 启动新 Live Activity（phase = listening）→ 启动转录 → 激活音频会话并开始录音。
    /// triggeredAt：Intent perform 开始的时间，用来算「按键到开始听」。
    func start(sessionID: UUID, screenshotURL: URL?, triggeredAt: ContinuousClock.Instant = .now) async throws {
        guard !isStartingSession else {
            logger.error("start ignored: another session is starting session=\(sessionID.uuidString, privacy: .public)")
            return
        }
        isStartingSession = true
        defer { isStartingSession = false }
        // 「按键到开始听」分段计时（SessionTiming.screenshotSaveMs 等）。
        let startCalledAt = clock.now

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
        let previousEndedAt = clock.now

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
        let activityRequestedAt = clock.now

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
        let transcriptionPreparedAt = clock.now

        // 静音检测只负责发事件；结束动作统一回调度器，和停止按钮同一条路径。
        let detector = SilenceDetector { event in
            switch event {
            case .transcriptSettled(let text):
                SessionCoordinator.shared.speculate(sessionID: sessionID, text: text)
            case .finishedSpeaking:
                Task {
                    await SessionCoordinator.shared.stopListening(sessionID: sessionID.uuidString, trigger: .silence)
                }
            case .maxDurationReached:
                Task {
                    await SessionCoordinator.shared.stopListening(sessionID: sessionID.uuidString, trigger: .maxDuration)
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
        let audioStartedAt = clock.now

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
        let listeningAt = clock.now
        listeningStartedAt = listeningAt
        lastTranscriptChangeAt = nil
        lastSpeechAudioSeconds = nil
        lastTranscriptText = ""
        var timing = SessionTiming(pressToListeningMs: SessionTiming.milliseconds(listeningAt - triggeredAt))
        timing.screenshotSaveMs = SessionTiming.milliseconds(startCalledAt - triggeredAt)
        timing.startEndPreviousMs = SessionTiming.milliseconds(previousEndedAt - startCalledAt)
        timing.startActivityRequestMs = SessionTiming.milliseconds(activityRequestedAt - previousEndedAt)
        timing.startTranscriptionPrepareMs = SessionTiming.milliseconds(transcriptionPreparedAt - activityRequestedAt)
        timing.startAudioMs = SessionTiming.milliseconds(audioStartedAt - transcriptionPreparedAt)
        timing.startTranscriptionActivateMs = SessionTiming.milliseconds(listeningAt - audioStartedAt)
        pendingTiming = timing
        logger.info(
            "start steps session=\(sessionID.uuidString, privacy: .public) \(timing.logLine, privacy: .public)"
        )
        speculativeRun = nil
        speculativeRequestCount = 0
        startTranscriptUpdates()
        startScreenTextRecognition(sessionID: sessionID, screenshotURL: screenshotURL)
        screenshotJPEGTask = screenshotURL.map { url in
            Task { await Self.uploadJPEGIfPossible(url: url, sessionID: sessionID) }
        }
        Task { await OpenAICompatibleProvider.preconnect() }
        logger.info("start succeeded session=\(sessionID.uuidString, privacy: .public)")
    }

    // MARK: - 停止

    /// 灵动岛「停止」按钮、静音检测（说完/超 60 秒）都走这里。
    /// 故意不依赖 currentSessionID 匹配：参数丢失、App 进程被重建时也要把录音和 Live Activity 收干净。
    /// 进入 thinking 后另起任务问大模型、立即返回：StopAskIntent.perform() 会 await 这里，不能让它等回答。
    /// trigger：结束方式，只用于耗时记录；停止按钮（StopAskIntent）和新会话顶掉旧会话都按 .button。
    func stopListening(sessionID: String, trigger: SessionTiming.StopTrigger = .button) async {
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
        let stopStartedAt = clock.now
        var timing = pendingTiming
        timing.stopTrigger = trigger
        if let listeningStartedAt {
            timing.listeningMs = SessionTiming.milliseconds(stopStartedAt - listeningStartedAt)
        }
        if let lastTranscriptChangeAt {
            timing.endDetectionMs = SessionTiming.milliseconds(stopStartedAt - lastTranscriptChangeAt)
        }
        let speechEndSeconds = lastSpeechAudioSeconds
        listeningStartedAt = nil
        lastTranscriptChangeAt = nil
        lastSpeechAudioSeconds = nil
        lastTranscriptText = ""
        pendingTiming = SessionTiming()

        // 先停采集但保留音频会话（保活）→ 取最终转录并落盘 → thinking → 等回答 → 最后才关音频会话。
        audioCapture.stopCaptureKeepingSessionActive()
        let recordingKeepSeconds = RecordingTrimmer.keepDuration(
            speechEndSeconds: speechEndSeconds,
            recordedSeconds: audioCapture.recordedSeconds
        )
        transcriptUpdateTask?.cancel()
        transcriptUpdateTask = nil
        pendingActivityPushTask?.cancel()
        pendingActivityPushTask = nil

        let finalText: String
        if let transcription {
            let finishStartedAt = clock.now
            finalText = await transcription.finish()
            timing.transcriptFinishMs = SessionTiming.milliseconds(clock.now - finishStartedAt)
        } else {
            finalText = ""
        }
        if let levels = silenceDetector?.levelSnapshot() {
            timing.speechLevelDB = levels.speechDB.map { Int($0.rounded()) }
            timing.endLevelDB = levels.currentDB.map { Int($0.rounded()) }
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

        let screenTextTask = self.screenTextTask
        self.screenTextTask = nil
        let jpegTask = screenshotJPEGTask
        screenshotJPEGTask = nil
        let speculative = speculativeRun
        speculativeRun = nil
        let speculativeCount = speculativeRequestCount
        speculativeRequestCount = 0
        currentSessionID = nil
        currentScreenshotURL = nil
        latestTranscriptTail = ""
        lastActivityPush = nil

        guard !question.isEmpty else {
            speculative?.cancel()
            screenTextTask?.cancel()
            jpegTask?.cancel()
            // 没识别到文字就不问大模型，按「没听到」提示后结束。
            logger.notice("stopListening: empty transcript session=\(trackedSessionID.uuidString, privacy: .public)")
            await presentFailureThenEnd(.noSpeech, sessionID: trackedSessionID)
            endAnswerBackgroundTask(reason: "empty transcript")
            return
        }

        // 提前请求的问题和最终转录一致（忽略标点空格）就直接用它，否则取消、用最终转录重发。
        let run: QuickAnswerRun
        if let speculative, speculative.normalizedQuestion == QuickAnswerRun.normalize(question) {
            run = speculative
            timing.speculation = .hit
            timing.speculationLeadMs = Self.milliseconds(stopStartedAt - speculative.startedAt)
            logger.info(
                "speculate hit session=\(trackedSessionID.uuidString, privacy: .public) leadMs=\(timing.speculationLeadMs ?? -1, privacy: .public) summaryReady=\(speculative.summary != nil, privacy: .public)"
            )
        } else {
            if let speculative {
                speculative.cancel()
                timing.speculation = .miss
                let finalNormalized = QuickAnswerRun.normalize(question)
                let distance = QuickAnswerRun.editDistance(speculative.normalizedQuestion, finalNormalized)
                timing.missSpeculativeChars = speculative.normalizedQuestion.count
                timing.missFinalChars = finalNormalized.count
                timing.missEditDistance = distance
                timing.missIsExtension = finalNormalized.hasPrefix(speculative.normalizedQuestion)
                logger.info(
                    "speculate miss session=\(trackedSessionID.uuidString, privacy: .public) speculativeChars=\(speculative.normalizedQuestion.count, privacy: .public) finalChars=\(finalNormalized.count, privacy: .public) editDistance=\(distance, privacy: .public) isExtension=\(timing.missIsExtension ?? false, privacy: .public)"
                )
            }
            // 先发请求，thinking 的灵动岛更新在 runAnswer 里做，不占请求的时间。
            run = makeQuickAnswerRun(
                sessionID: trackedSessionID,
                question: question,
                speculative: false,
                jpegTask: jpegTask,
                screenTextTask: screenTextTask
            )
        }
        if speculativeCount > 0 {
            timing.speculativeRequests = speculativeCount
        }

        answeringSessionID = trackedSessionID
        answerTask = Task { [weak self] in
            await self?.runAnswer(
                sessionID: trackedSessionID,
                question: question,
                run: run,
                stopStartedAt: stopStartedAt,
                timing: timing,
                recordingKeepSeconds: recordingKeepSeconds
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

    /// 灵动岛 answered 态的「复制」按钮（CopyAnswerIntent）：复制完整回答（没有就复制摘要），按钮变成对勾。
    func copyAnswer(sessionID: String) async {
        guard let id = UUID(uuidString: sessionID), let session = AppDatabase.fetchSession(id: id) else {
            logger.error("copy answer failed: session not found session=\(sessionID, privacy: .public)")
            return
        }
        let text = session.answer ?? session.summary ?? ""
        guard !text.isEmpty else {
            logger.error("copy answer failed: no answer text session=\(sessionID, privacy: .public)")
            return
        }
        // TODO: 核对官方文档：App 在后台（由 LiveActivityIntent 唤起）时写 UIPasteboard 是否生效，需真机验证。
        UIPasteboard.general.string = text
        logger.info("answer copied session=\(sessionID, privacy: .public) chars=\(text.count, privacy: .public)")

        for activityID in Self.activityIDs(sessionID: sessionID) {
            guard let activity = Self.findActivity(id: activityID) else { continue }
            var state = activity.content.state
            guard state.phase == .answered else { continue }
            state.answerCopied = true
            if activityID == currentActivityID {
                currentState = state
            }
            await activity.update(ActivityContent(state: state, staleDate: nil))
            activityLogger.info("live activity updated answerCopied=true")
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
        screenshotJPEGTask?.cancel()
        screenshotJPEGTask = nil
        cancelSpeculativeRun(reason: "session ended")
        speculativeRequestCount = 0
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

    /// 说完之后的后台流程：thinking（摘要还没到时）→ 摘要一到就 answered + Alert → 等完整回答写 AskSession →
    /// 关音频会话 → 结束后台任务。请求本身在 run 里已经开始跑（可能是录音中提前发的）。
    private func runAnswer(
        sessionID: UUID,
        question: String,
        run: QuickAnswerRun,
        stopStartedAt: ContinuousClock.Instant,
        timing: SessionTiming,
        recordingKeepSeconds: Double?
    ) async {
        logger.notice(
            "answer start session=\(sessionID.uuidString, privacy: .public) speculative=\(run.speculative, privacy: .public) backgroundTimeRemaining=\(UIApplication.shared.backgroundTimeRemaining, privacy: .public)"
        )
        guard let requestTask = run.task else {
            logger.error("answer aborted: run has no task session=\(sessionID.uuidString, privacy: .public)")
            return
        }

        // 摘要还没到才显示 thinking；提前请求命中且摘要已到时直接跳到 answered。
        if run.summary == nil {
            let thinkingState = AskActivityAttributes.ContentState(
                phase: .thinking,
                transcriptTail: String(question.suffix(Self.maxTranscriptTailLength)),
                summary: nil,
                errorMessage: nil,
                startedAt: currentState?.startedAt ?? .now
            )
            await updateCurrentActivity(thinkingState, alert: nil)
            logger.info(
                "thinking session=\(sessionID.uuidString, privacy: .public) chars=\(question.count, privacy: .public)"
            )
        }

        // 采用这次请求：摘要到了（或已经到了）就推到灵动岛。
        run.summaryHandler = { [weak self, weak run] summary in
            guard let self, let run else { return }
            run.summaryShowTask = Task { await self.showSummary(summary, sessionID: sessionID, run: run) }
        }
        if let summary = run.summary {
            run.summaryShowTask = Task { await self.showSummary(summary, sessionID: sessionID, run: run) }
        }

        // 放弃回答 / 后台时间用完会取消 answerTask，这里连带取消请求。
        let outcome = await withTaskCancellationHandler {
            await requestTask.value
        } onCancel: {
            requestTask.cancel()
        }
        await run.summaryShowTask?.value
        let fullAnswerAt = clock.now
        let latencyMs = Self.milliseconds(fullAnswerAt - stopStartedAt)

        // 被新会话或关闭按钮放弃了：结果只记日志，不再碰灵动岛、音频会话和后台任务（放弃方已经收尾）。
        guard answeringSessionID == sessionID else {
            logger.notice(
                "answer discarded: session=\(sessionID.uuidString, privacy: .public) superseded latencyMs=\(latencyMs, privacy: .public)"
            )
            return
        }

        var succeeded = true
        var answerError: String?
        var finalShownAt: ContinuousClock.Instant?
        var finalActivityMs: Int?
        switch outcome {
        case .success(let answer):
            updateSession(sessionID, reason: "answered") { session in
                session.summary = answer.summary
                session.answer = answer.answer
                session.needsDeepAnswer = answer.needsDeep ?? true
                session.clearFailure()
                session.statusValue = .answered
            }
            logger.info(
                "answered session=\(sessionID.uuidString, privacy: .public) latencyMs=\(latencyMs, privacy: .public) summaryShownEarly=\(run.summaryShownAt != nil, privacy: .public)"
            )
            // 兜底：流式里没提前拿到摘要（模型把 summary 放在后面等），现在补显示。
            if run.summaryShownAt == nil {
                let activityStartedAt = clock.now
                await updateCurrentActivity(answeredState(summary: answer.summary), alert: alert(body: answer.summary))
                finalShownAt = clock.now
                finalActivityMs = Self.milliseconds(clock.now - activityStartedAt)
            }
        case .failure(let error):
            answerError = (error as? LLMError)?.logDescription ?? "\((error as NSError).domain) \((error as NSError).code)"
            if let summary = run.summary, run.summaryShownAt != nil {
                // 摘要已经在灵动岛上了，完整回答没拿到：用摘要当回答，会话页再做深度回答。
                updateSession(sessionID, reason: "answered degraded") { session in
                    session.summary = summary
                    session.answer = summary
                    session.needsDeepAnswer = true
                    session.clearFailure()
                    session.statusValue = .answered
                }
                logger.notice(
                    "answer degraded to summary session=\(sessionID.uuidString, privacy: .public) latencyMs=\(latencyMs, privacy: .public) error=\(answerError ?? "nil", privacy: .public)"
                )
            } else {
                succeeded = false
                // 后台任务过期时请求被取消，对用户来说就是超时（answerFailure 里处理）。
                let failure = UserFacingFailure.answerFailure(for: error)
                updateSession(sessionID, reason: "answer failed") { session in
                    session.markFailed(failure)
                }
                let failedState = AskActivityAttributes.ContentState(
                    phase: .failed,
                    transcriptTail: currentState?.transcriptTail ?? "",
                    summary: nil,
                    errorMessage: failure.message,
                    startedAt: currentState?.startedAt ?? .now,
                    errorHint: failure.islandHint
                )
                logger.error(
                    "answer failed session=\(sessionID.uuidString, privacy: .public) latencyMs=\(latencyMs, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                let activityStartedAt = clock.now
                await updateCurrentActivity(failedState, alert: alert(body: failure.message))
                finalShownAt = clock.now
                finalActivityMs = Self.milliseconds(clock.now - activityStartedAt)
            }
        }

        // 汇总各环节耗时：写库给会话页耗时卡片，同一行写 timing 日志。网络各阶段另有 llm 分类的 metrics 日志。
        var timing = timing
        let answer = try? outcome.get()
        timing.succeeded = succeeded
        timing.answerError = answerError
        timing.jpegEncodeMs = run.jpegWaitMs
        timing.imageBytes = run.imageBytes
        timing.ocrWaitMs = run.ocrWaitMs
        timing.llmMs = run.llmMs
        timing.llmSummaryMs = run.llmSummaryMs
        timing.attempts = answer?.attempts
        timing.network = answer?.network
        timing.activityUpdateMs = run.activityUpdateMs ?? finalActivityMs
        if let shownAt = run.summaryShownAt ?? finalShownAt {
            timing.answerTotalMs = Self.milliseconds(shownAt - stopStartedAt)
        }
        timing.fullAnswerMs = latencyMs
        // 灵动岛已经显示回答，再截录音末尾静音：不占用户等回答的时间。还在后台任务和音频会话保活范围内。
        if let recordingKeepSeconds, let audioURL = try? AudioCaptureService.audioFileURL(sessionID: sessionID) {
            let trimmed = await RecordingTrimmer.trimTail(
                fileURL: audioURL,
                keepSeconds: recordingKeepSeconds,
                sessionID: sessionID
            )
            timing.trimmedSilenceMs = trimmed.map { Int($0 * 1000) }
        }
        updateSession(sessionID, reason: "timing saved") { $0.timingData = timing.encoded() }
        appendTokenUsage(sessionID: sessionID, kind: .quick, usage: answer?.usage, model: nil)
        logger.info("timing session=\(sessionID.uuidString, privacy: .public) \(timing.logLine, privacy: .public)")
        answeringSessionID = nil
        answerTask = nil
        await audioCapture.deactivateAudioSession()
        endAnswerBackgroundTask(reason: "answer finished")
    }

    /// 流式摘要一到：写进库（状态仍是 thinking，完整回答到了才转 answered），灵动岛切 answered 并展开提示。
    private func showSummary(_ summary: String, sessionID: UUID, run: QuickAnswerRun) async {
        guard answeringSessionID == sessionID, run.summaryShownAt == nil else { return }
        updateSession(sessionID, reason: "summary ready") { $0.summary = summary }
        let activityStartedAt = clock.now
        await updateCurrentActivity(answeredState(summary: summary), alert: alert(body: summary))
        run.summaryShownAt = clock.now
        run.activityUpdateMs = Self.milliseconds(clock.now - activityStartedAt)
        logger.info(
            "summary shown session=\(sessionID.uuidString, privacy: .public) chars=\(summary.count, privacy: .public) llmSummaryMs=\(run.llmSummaryMs ?? -1, privacy: .public)"
        )
    }

    private func answeredState(summary: String) -> AskActivityAttributes.ContentState {
        AskActivityAttributes.ContentState(
            phase: .answered,
            transcriptTail: currentState?.transcriptTail ?? "",
            summary: summary,
            errorMessage: nil,
            startedAt: currentState?.startedAt ?? .now
        )
    }

    // SPEC 第 4 节第 10 步：带 AlertConfiguration 更新 → 停用音频会话 → endBackgroundTask。
    // TODO: 核对官方文档：确认 App 在后台时带 AlertConfiguration 的 update 会让灵动岛自动展开（M1 的 failed 已用过，answered 需真机再确认）。
    private func alert(body: String) -> AlertConfiguration {
        AlertConfiguration(
            title: "IslandAsk",
            body: LocalizedStringResource(stringLiteral: body),
            sound: .default
        )
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
    nonisolated static func uploadJPEGIfPossible(url: URL?, sessionID: UUID) async -> Data? {
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
        let task = Task {
            await TextRecognizer.recognize(imageURL: screenshotURL, sessionID: sessionID)
        }
        screenTextTask = task
        // OCR 在用户还在说话时完成，就把屏幕上的词交给转录当提示词。
        Task { [weak self] in
            guard let text = await task.value else { return }
            await self?.applyRecognitionHints(from: text, sessionID: sessionID)
        }
    }

    private func applyRecognitionHints(from screenText: String, sessionID: UUID) async {
        guard currentSessionID == sessionID, let transcription else {
            logger.info("recognition hints skipped: listening already ended session=\(sessionID.uuidString, privacy: .public)")
            return
        }
        let terms = TextRecognizer.contextualTerms(from: screenText)
        logger.info(
            "recognition hints session=\(sessionID.uuidString, privacy: .public) terms=\(terms.count, privacy: .public)"
        )
        await transcription.updateContext(terms: terms)
    }

    /// 问大模型前最多再等 screenTextWaitLimit；没识别完就先不带文字问，识别完再补写进库，供深度回答和追问使用。
    func awaitScreenText(_ task: Task<String?, Never>?, sessionID: UUID) async -> String? {
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
    func updateSession(_ id: UUID, reason: String, _ mutate: (AskSession) -> Void) {
        guard let session = AppDatabase.fetchSession(id: id) else {
            logger.error(
                "session update skipped: not found session=\(id.uuidString, privacy: .public) reason=\(reason, privacy: .public)"
            )
            return
        }
        mutate(session)
        AppDatabase.save(reason: "\(reason) session=\(id.uuidString)")
    }

    /// 按设置页的保留天数删除旧会话（连同截图、录音）。App 回到前台、改保留天数时调用；进行中的会话由 deleteSession 跳过。
    func purgeExpiredSessions() {
        let days = AppSettings.historyRetentionDays
        guard days > 0 else { return }
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) else { return }
        let descriptor = FetchDescriptor<AskSession>(predicate: #Predicate { $0.createdAt < cutoff })
        let expired: [AskSession]
        do {
            expired = try AppDatabase.context.fetch(descriptor)
        } catch {
            logger.error("purge failed: fetch error=\(error.localizedDescription, privacy: .public)")
            return
        }
        guard !expired.isEmpty else { return }
        let ids = expired.map(\.id)
        logger.info("purging expired sessions count=\(ids.count, privacy: .public) retentionDays=\(days, privacy: .public)")
        for id in ids {
            deleteSession(id: id)
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

    nonisolated static func milliseconds(_ duration: Duration) -> Int {
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
        screenshotJPEGTask?.cancel()
        screenshotJPEGTask = nil
        cancelSpeculativeRun(reason: "session ended")
        speculativeRequestCount = 0
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
