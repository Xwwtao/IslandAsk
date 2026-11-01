//
//  SessionCoordinator.swift
//  IslandAsk
//
//  M0 的调度中心：串起 Live Activity 和录音。是唯一能启动/结束 Live Activity 的地方（SPEC 第 4、6.4 节）。
//

import ActivityKit
import Foundation
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

    private let audioCapture = AudioCaptureService()
    private var currentActivity: Activity<AskActivityAttributes>?
    private var currentSessionID: UUID?
    private var isStartingSession = false

    private init() {}

    /// 正在启动或录音中：此时 UI 的预热/残留清理都不能碰音频会话和 Live Activity。
    var isSessionBusy: Bool {
        isStartingSession || currentSessionID != nil
    }

    /// 按 SPEC 第 4 节第 5 步的顺序：
    /// 结束上一个 Live Activity → 启动新 Live Activity（phase = listening）→ 激活音频会话并开始录音。
    /// 注意：AudioRecordingIntent 要求录音期间保持 Live Activity 活跃，所以顺序不能反。
    func start(sessionID: UUID, screenshotURL: URL?) async throws {
        logger.info(
            "start session=\(sessionID.uuidString, privacy: .public) hasScreenshot=\(screenshotURL != nil, privacy: .public)"
        )
        isStartingSession = true
        defer { isStartingSession = false }

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
            currentActivity = activity
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

        do {
            let audioURL = try AudioCaptureService.audioFileURL(sessionID: sessionID)
            try await audioCapture.start(sessionID: sessionID, fileURL: audioURL)
            currentSessionID = sessionID
            logger.info("start succeeded session=\(sessionID.uuidString, privacy: .public)")
        } catch {
            let nsError = error as NSError
            logger.error(
                "audio start failed session=\(sessionID.uuidString, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) error=\(nsError.localizedDescription, privacy: .public)"
            )
            currentSessionID = nil
            await endAllActivities(reason: "audio start failed")
            throw SessionCoordinatorError.audioStartFailed(
                "\(nsError.localizedDescription)（\(nsError.domain) \(nsError.code)）"
            )
        }
    }

    /// 灵动岛「停止」按钮或（M1 之后）静音检测触发。
    /// 故意不依赖 currentSessionID 匹配：参数丢失、App 进程被重建时也要把录音和 Live Activity 收干净。
    func stopListening(sessionID: String) async {
        let current = currentSessionID?.uuidString ?? "nil"
        logger.info(
            "stopListening requested session=\(sessionID, privacy: .public) current=\(current, privacy: .public)"
        )

        if let activeID = currentSessionID, activeID.uuidString != sessionID {
            logger.error(
                "stopListening session mismatch current=\(current, privacy: .public) requested=\(sessionID, privacy: .public)"
            )
        }

        // 关键顺序：先停采集但保留音频会话（保活），等 Live Activity 真正结束之后再关闭会话。
        // 反过来会在 activity.end(...) 完成前丢掉后台执行权，灵动岛就会残留（真机已复现）。
        audioCapture.stopCaptureKeepingSessionActive()
        currentSessionID = nil
        await endAllActivities(reason: "stop requested")
        await audioCapture.deactivateAudioSession()
        logger.info("stopListening finished session=\(sessionID, privacy: .public)")
    }

    /// 异常态回收：调度器以为还在录音，但采集其实已经停了（例如被系统中断）。
    /// 把残留的 Live Activity 结束掉，避免灵动岛一直停在「录音中」。
    func recoverUnexpectedStoppedSessionIfNeeded() async {
        guard let currentSessionID else { return }
        guard !audioCapture.isCapturing else { return }

        logger.error(
            "recover: capture stopped but session=\(currentSessionID.uuidString, privacy: .public) still tracked"
        )
        self.currentSessionID = nil
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
        currentActivity = nil
    }

    /// 结束当前所有本类型的 Live Activity（App 被重启过也能清干净）。
    private func endAllActivities(reason: String) async {
        let activities = Activity<AskActivityAttributes>.activities
        guard !activities.isEmpty else { return }

        activityLogger.info(
            "ending \(activities.count, privacy: .public) live activity(ies) reason=\(reason, privacy: .public)"
        )
        for activity in activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        currentActivity = nil
    }
}

enum SessionCoordinatorError: LocalizedError {
    case liveActivityStartFailed(String)
    case audioStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .liveActivityStartFailed(let message):
            return "启动灵动岛失败：\(message)"
        case .audioStartFailed(let message):
            return "开始录音失败：\(message)"
        }
    }
}
