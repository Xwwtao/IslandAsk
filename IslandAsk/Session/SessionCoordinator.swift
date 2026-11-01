//
//  SessionCoordinator.swift
//  IslandAsk
//
//  M1 的调度中心：串起 Live Activity、实时转录、静音检测和 m4a 录音（SPEC 第 4、6.4 节）。
//  是唯一更新 Live Activity 的地方。
//
//  关键约定：
//  - 灵动岛「停止」按钮与静音检测都走 stopListening(sessionID:)，不做两套结束逻辑。
//  - 6 秒不开口走 cancel(sessionID:reason:)：failed 态 + AlertConfiguration，保活 3 秒后再结束。
//  - 转录更新节流：第一条立即推，之后每秒最多推一次（有 pending 时补一次尾部推送）。
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
    private let clock = ContinuousClock()

    private var currentActivityID: String?
    private var currentState: AskActivityAttributes.ContentState?
    private var currentSessionID: UUID?
    private var transcription: TranscriptionService?

    private var isStartingSession = false
    private var isStopping = false

    private var transcriptUpdateTask: Task<Void, Never>?
    private var pendingActivityPushTask: Task<Void, Never>?
    private var lastActivityPush: ContinuousClock.Instant?
    private var latestTranscriptTail = ""
    private var didLogFirstTranscriptUpdate = false

    private init() {}

    /// 正在启动或录音中：此时 UI 的预热/残留清理都不能碰音频会话和 Live Activity。
    var isSessionBusy: Bool {
        isStartingSession || currentSessionID != nil
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
        currentSessionID = sessionID
        latestTranscriptTail = ""
        lastActivityPush = nil
        didLogFirstTranscriptUpdate = false
        startTranscriptUpdates()
        logger.info("start succeeded session=\(sessionID.uuidString, privacy: .public)")
    }

    // MARK: - 停止

    /// 灵动岛「停止」按钮、静音检测（说完/超 60 秒）都走这里。
    /// 故意不依赖 currentSessionID 匹配：参数丢失、App 进程被重建时也要把录音和 Live Activity 收干净。
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

        // 关键顺序：先停采集但保留音频会话（保活）→ 取最终转录并落盘 → 结束 Live Activity → 关音频会话。
        // 反过来会在 activity.end(...) 完成前丢掉后台执行权，灵动岛就会残留（真机已复现）。
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

        do {
            try TranscriptStore.save(finalText, sessionID: trackedSessionID)
        } catch {
            logger.error(
                "transcript save failed session=\(trackedSessionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }

        currentSessionID = nil
        currentState = nil
        latestTranscriptTail = ""
        lastActivityPush = nil

        await endAllActivities(reason: "stop requested")
        await audioCapture.deactivateAudioSession()
        logger.info(
            "stopListening finished session=\(trackedSessionID.uuidString, privacy: .public) chars=\(finalText.count, privacy: .public)"
        )
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
        currentSessionID = nil
        latestTranscriptTail = ""
        lastActivityPush = nil

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
        await audioCapture.deactivateAudioSession()
        scheduleActivityEnd(activityID: activityID, after: .seconds(3), backgroundTaskID: backgroundTaskID)
        logger.info("cancel finished session=\(trackedSessionID.uuidString, privacy: .public)")
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
        currentSessionID = nil
        currentState = nil
        latestTranscriptTail = ""
        lastActivityPush = nil
        await endAllActivities(reason: "capture stopped unexpectedly")
        await audioCapture.deactivateAudioSession()
    }

    /// App 重新打开时收尾：如果当前没有在录音、却还有残留的 Live Activity
    /// （停止时进程被挂起导致 activity.end 没执行完），补一次结束。
    func endOrphanActivitiesIfNeeded() async {
        guard currentSessionID == nil, !isStartingSession else { return }

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
