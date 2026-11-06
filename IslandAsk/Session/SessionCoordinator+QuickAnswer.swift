//
//  SessionCoordinator+QuickAnswer.swift
//  IslandAsk
//
//  快速档请求的发起与提前发请求（M4 耗时优化）：
//  - 转录文字稳定 0.8 秒（SilenceDetector.transcriptSettled）就先用当时的文字问大模型，录音继续。
//  - 用户又开口、文字变了：取消这次提前请求；再稳定下来会重新发（每次会话最多 maxSpeculativeRequests 次）。
//  - 说完（stopListening）后最终转录和提前请求的问题一致（忽略标点空格）就直接用它，否则取消重发。
//  与 SPEC 第 4 节第 9 步的偏差：请求可能在 stopListening 之前就发出。
//

import Foundation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
    category: "coordinator"
)

extension SessionCoordinator {

    /// 每次会话最多提前发几次：说话中间停顿很多时，避免反复花调用。
    static let maxSpeculativeRequests = 3

    /// 创建并立即开始一次快速档请求：等截图压缩 → 等 OCR（有上限）→ 流式问大模型。
    func makeQuickAnswerRun(
        sessionID: UUID,
        question: String,
        speculative: Bool,
        jpegTask: Task<Data?, Never>?,
        screenTextTask: Task<String?, Never>?
    ) -> QuickAnswerRun {
        let run = QuickAnswerRun(sessionID: sessionID, question: question, speculative: speculative, startedAt: clock.now)
        run.task = Task { [weak self] in
            guard let self else { return .failure(LLMError.cancelled) }
            return await self.executeQuickAnswer(run, jpegTask: jpegTask, screenTextTask: screenTextTask)
        }
        return run
    }

    private func executeQuickAnswer(
        _ run: QuickAnswerRun,
        jpegTask: Task<Data?, Never>?,
        screenTextTask: Task<String?, Never>?
    ) async -> Result<LLMAnswer, any Error> {
        let sessionID = run.sessionID
        let startedAt = clock.now
        let imageJPEG = await jpegTask?.value
        let encodedAt = clock.now
        guard !Task.isCancelled else { return .failure(LLMError.cancelled) }
        let screenText = await awaitScreenText(screenTextTask, sessionID: sessionID)
        let llmStartedAt = clock.now
        run.jpegWaitMs = Self.milliseconds(encodedAt - startedAt)
        run.ocrWaitMs = Self.milliseconds(llmStartedAt - encodedAt)
        run.imageBytes = imageJPEG?.count
        run.llmStartedAt = llmStartedAt
        guard !Task.isCancelled else { return .failure(LLMError.cancelled) }

        logger.info(
            "quick answer request session=\(sessionID.uuidString, privacy: .public) speculative=\(run.speculative, privacy: .public) chars=\(run.question.count, privacy: .public) jpegWaitMs=\(run.jpegWaitMs ?? -1, privacy: .public) ocrWaitMs=\(run.ocrWaitMs ?? -1, privacy: .public)"
        )
        let result: Result<LLMAnswer, any Error>
        do {
            let provider = try OpenAICompatibleProvider.fromSettings()
            let answer = try await provider.ask(
                imageJPEG: imageJPEG,
                screenText: screenText,
                question: run.question,
                history: [],
                onSummary: { summary in
                    await run.deliverSummary(summary)
                }
            )
            result = .success(answer)
        } catch {
            result = .failure(error)
        }
        run.llmMs = Self.milliseconds(clock.now - llmStartedAt)
        return result
    }

    // MARK: - 提前发请求

    /// SilenceDetector 报告转录文字已稳定：用当时的文字先问。
    func speculate(sessionID: UUID, text: String) {
        guard currentSessionID == sessionID, !isStopping else { return }
        let normalized = QuickAnswerRun.normalize(text)
        guard !normalized.isEmpty else { return }
        if let run = speculativeRun, run.normalizedQuestion == normalized { return }
        guard speculativeRequestCount < Self.maxSpeculativeRequests else {
            logger.notice(
                "speculate skipped: limit reached session=\(sessionID.uuidString, privacy: .public) count=\(self.speculativeRequestCount, privacy: .public)"
            )
            return
        }
        cancelSpeculativeRun(reason: "superseded")
        speculativeRequestCount += 1
        speculativeRun = makeQuickAnswerRun(
            sessionID: sessionID,
            question: text,
            speculative: true,
            jpegTask: screenshotJPEGTask,
            screenTextTask: screenTextTask
        )
        logger.info(
            "speculate start session=\(sessionID.uuidString, privacy: .public) count=\(self.speculativeRequestCount, privacy: .public) chars=\(text.count, privacy: .public)"
        )
    }

    /// 转录文字变了（用户又开口）：和提前请求的问题不一样就取消。
    func cancelSpeculativeRunIfStale(transcript: String) {
        guard let run = speculativeRun, QuickAnswerRun.normalize(transcript) != run.normalizedQuestion else { return }
        cancelSpeculativeRun(reason: "transcript changed")
    }

    func cancelSpeculativeRun(reason: String) {
        guard let run = speculativeRun else { return }
        run.cancel()
        speculativeRun = nil
        logger.info(
            "speculate cancel session=\(run.sessionID.uuidString, privacy: .public) reason=\(reason, privacy: .public)"
        )
    }
}
