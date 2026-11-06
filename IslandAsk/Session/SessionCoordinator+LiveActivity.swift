//
//  SessionCoordinator+LiveActivity.swift
//  IslandAsk
//
//  SessionCoordinator 的 Live Activity 部分：转录推送节流、更新 / 结束 activity、残留清理。
//  状态（currentActivityID、currentState、节流相关）仍存在 SessionCoordinator 主体里。
//

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

extension SessionCoordinator {

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

    func startTranscriptUpdates() {
        guard let transcription else { return }
        transcriptUpdateTask = Task { [weak self] in
            for await update in transcription.updates {
                guard let self else { return }
                self.handleTranscriptUpdate(update)
            }
        }
    }

    func handleTranscriptUpdate(_ update: TranscriptUpdate) {
        let display = update.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !display.isEmpty else { return }
        silenceDetector?.noteTranscript(display)
        if display != lastTranscriptText {
            lastTranscriptText = display
            lastTranscriptChangeAt = clock.now
            lastSpeechAudioSeconds = audioCapture.recordedSeconds
            // 用户又开口了：提前发的请求问的是旧文字，取消掉，等文字再稳定时重发。
            cancelSpeculativeRunIfStale(transcript: display)
        }

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
    func scheduleTranscriptPush() {
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

    func pushTranscriptTail() async {
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
    func updateCurrentActivity(
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
    func endAllActivities(reason: String) async {
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
    func scheduleActivityEnd(
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
    nonisolated static func findActivity(id: String) -> Activity<AskActivityAttributes>? {
        Activity<AskActivityAttributes>.activities.first { $0.id == id }
    }

    nonisolated static func activityIDs(sessionID: String) -> [String] {
        Activity<AskActivityAttributes>.activities
            .filter { $0.attributes.sessionID == sessionID }
            .map(\.id)
    }
}
