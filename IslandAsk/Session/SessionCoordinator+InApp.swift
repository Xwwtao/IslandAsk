//
//  SessionCoordinator+InApp.swift
//  IslandAsk
//
//  SessionCoordinator 的 App 内部分（只在前台使用，不碰灵动岛）：深度回答、追问、失败重问、深链进入会话页。
//  仍是 SessionCoordinator 的方法，守住「只有 SessionCoordinator 写 SwiftData」的约定。
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

    func finishDeepAnswer(sessionID: UUID, reply: StreamingReply, result: Result<Void, any Error>) {
        defer {
            inAppRequestSessionIDs.remove(sessionID)
            StreamingReplyStore.shared.end(sessionID: sessionID)
        }
        reply.flush()
        recordDeepTiming(sessionID: sessionID, reply: reply, succeeded: (try? result.get()) != nil)
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

    /// 深度回答的三个耗时合并进已有的 timingData（旧会话没有就新建），同时写 deep timing 日志。
    private func recordDeepTiming(sessionID: UUID, reply: StreamingReply, succeeded: Bool) {
        let started = reply.startedInstant
        updateSession(sessionID, reason: "deep timing saved") { session in
            var timing = session.timing ?? SessionTiming()
            timing.deepFirstReasoningMs = reply.firstReasoningAt.map { SessionTiming.milliseconds($0 - started) }
            timing.deepFirstContentMs = reply.firstContentAt.map { SessionTiming.milliseconds($0 - started) }
            timing.deepTotalMs = SessionTiming.milliseconds(.now - started)
            timing.deepSucceeded = succeeded
            session.timingData = timing.encoded()
            logger.info("deep timing session=\(sessionID.uuidString, privacy: .public) \(timing.logLine, privacy: .public)")
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
    static func consumeDeepStream(
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
    static func deepFailureMessage(for error: any Error) -> String {
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
                history: [],
                onSummary: nil
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

    /// App 内请求（深度回答、追问、重问）用的 OCR 文字：已有就复用；没有（旧会话 / 当时没识别完）就现在识别并写库。
    /// 设置里关掉后一律不带。
    func screenTextForInAppRequest(sessionID: UUID) async -> String? {
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
}
