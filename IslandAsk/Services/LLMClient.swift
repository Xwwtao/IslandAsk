//
//  LLMClient.swift
//  IslandAsk
//
//  大模型调用（SPEC 第 6.9 节）。第一版只有 OpenAICompatibleProvider，默认接 DeepSeek：
//  - 模型 deepseek-flash（https://api-docs.deepseek.com/guides/vision ，2026-11 查询：当前支持图片的模型）。
//  - 图片只能放在 user 消息的 content 数组里，放 system/assistant 会 400。
//  - JSON 模式可能返回全空格内容，按可重试错误处理（https://api-docs.deepseek.com/guides/json_mode ）。
//
//  与 SPEC 的偏差：history 的元素类型 ChatMessage 是 M3 的 SwiftData 模型，M2 先用 LLMHistoryMessage 占位，
//  M2 始终传空数组。
//

import Foundation
import os

nonisolated struct LLMAnswer: Codable, Sendable {
    let summary: String
    let answer: String
}

/// 追问历史的占位类型，M3 换成 ChatMessage 或从它映射。
nonisolated struct LLMHistoryMessage: Sendable {
    let role: String
    let content: String
}

nonisolated protocol LLMProvider: Sendable {
    var model: String { get }
    @concurrent
    func ask(imageJPEG: Data?, question: String, history: [LLMHistoryMessage]) async throws -> LLMAnswer
}

nonisolated struct OpenAICompatibleProvider: LLMProvider {

    /// SPEC 6.9 的系统提示词原文。JSON 模式要求提示词里出现 "json" 并给出格式示例，这里两者都有。
    static let systemPrompt = """
        你是屏幕助手。用户会给你一张手机截图和一个口语化的问题（来自语音转写，可能有错别字）。请结合截图回答。
        只输出 JSON：{"summary": "...", "answer": "..."}
        summary：不超过 40 个汉字，直接给结论，不寒暄。
        answer：完整回答，可使用 Markdown。
        如果截图与问题无关或看不清，在 summary 中直接说明。
        """

    /// 灵动岛摘要硬上限（SPEC 第 6.10 节：summary 最多 40 字）。
    static let maxSummaryLength = 40

    let baseURL: URL
    let apiKey: String
    let model: String

    private let maxAttempts = 2
    private let session: URLSession

    init(baseURL: URL, apiKey: String, model: String, timeout: TimeInterval = 30) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    /// 原型阶段的默认配置：DeepSeek + 本地 Secrets.swift 里的 Key。M3 的设置页接管这些值。
    static func deepSeek() -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            baseURL: URL(string: "https://api.deepseek.com")!,
            apiKey: Secrets.deepSeekAPIKey,
            model: "deepseek-flash"
        )
    }

    @concurrent
    func ask(imageJPEG: Data?, question: String, history: [LLMHistoryMessage]) async throws -> LLMAnswer {
        let logger = Self.makeLogger()
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.error("ask aborted: API key is empty")
            throw LLMError.missingAPIKey
        }

        let body = try makeRequestBody(imageJPEG: imageJPEG, question: question, history: history)
        logger.info(
            "ask start model=\(model, privacy: .public) imageBytes=\(imageJPEG?.count ?? 0, privacy: .public) questionChars=\(question.count, privacy: .public) history=\(history.count, privacy: .public) bodyBytes=\(body.count, privacy: .public)"
        )

        var attempt = 1
        while true {
            do {
                let answer = try await performAttempt(body: body, attempt: attempt, logger: logger)
                logger.info("ask succeeded attempt=\(attempt, privacy: .public)")
                return answer
            } catch let error as LLMError where error.isRetryable && attempt < maxAttempts && !Task.isCancelled {
                logger.error(
                    "ask attempt=\(attempt, privacy: .public) failed, retrying: \(error.logDescription, privacy: .public)"
                )
                attempt += 1
            } catch let error as LLMError {
                logger.error(
                    "ask failed attempt=\(attempt, privacy: .public): \(error.logDescription, privacy: .public)"
                )
                throw error
            }
        }
    }

    // MARK: - 单次请求

    private func performAttempt(body: Data, attempt: Int, logger: Logger) async throws -> LLMAnswer {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        let startedAt = ContinuousClock.now
        logger.info("request attempt=\(attempt, privacy: .public) sending")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMError(transportError: error)
        }
        let elapsedMs = Self.milliseconds(ContinuousClock.now - startedAt)

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.badResponse("非 HTTP 响应")
        }
        logger.info(
            "response attempt=\(attempt, privacy: .public) status=\(http.statusCode, privacy: .public) bytes=\(data.count, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public)"
        )
        guard (200..<300).contains(http.statusCode) else {
            // 错误响应体只含错误说明，不含 Key，截一段方便排查。
            let snippet = String(decoding: data.prefix(300), as: UTF8.self)
            logger.error("http error body: \(snippet, privacy: .public)")
            throw LLMError.http(status: http.statusCode)
        }

        let completion: ChatCompletionResponse
        do {
            completion = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw LLMError.badResponse("响应结构解析失败：\(error.localizedDescription)")
        }
        if let usage = completion.usage {
            logger.info(
                "usage promptTokens=\(usage.promptTokens ?? -1, privacy: .public) completionTokens=\(usage.completionTokens ?? -1, privacy: .public)"
            )
        }
        let choice = completion.choices.first
        if let finishReason = choice?.finishReason, finishReason != "stop" {
            logger.error("unexpected finish_reason=\(finishReason, privacy: .public)")
        }
        guard let content = choice?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // JSON 模式下模型没产出合法 JSON 时，content 可能全是空格。
            throw LLMError.emptyContent
        }
        return try Self.parseAnswer(content, logger: logger)
    }

    // MARK: - 请求体

    private func makeRequestBody(
        imageJPEG: Data?,
        question: String,
        history: [LLMHistoryMessage]
    ) throws -> Data {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        var userContent: [[String: Any]] = [
            ["type": "text", "text": trimmedQuestion.isEmpty ? "请看这张截图。" : trimmedQuestion],
        ]
        if let imageJPEG {
            userContent.append([
                "type": "image_url",
                // detail=low 会缩到 512×512，中文小字看不清；high 保留原尺寸（我们已压到长边 1536）。
                "image_url": [
                    "url": "data:image/jpeg;base64,\(imageJPEG.base64EncodedString())",
                    "detail": "high",
                ],
            ])
        }

        var messages: [[String: Any]] = [["role": "system", "content": Self.systemPrompt]]
        messages += history.map { ["role": $0.role, "content": $0.content] }
        messages.append(["role": "user", "content": userContent])

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": false,
            "max_tokens": 2048,
            // TODO: 核对官方文档：DeepSeek 文档未说明 json_object 能否与图片输入同时使用，需真机确认；
            // 若返回 400，去掉这一项，依靠 parseAnswer 的代码块兜底解析。
            "response_format": ["type": "json_object"],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    // MARK: - 解析

    /// 去掉可能的 ```json 代码块包裹，只取第一个 { 到最后一个 } 之间的内容再解码。
    private static func parseAnswer(_ content: String, logger: Logger) throws -> LLMAnswer {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"),
              start < end else {
            throw LLMError.badResponse("内容里没有 JSON 对象")
        }
        let jsonText = content[start...end]
        let raw: LLMAnswer
        do {
            raw = try JSONDecoder().decode(LLMAnswer.self, from: Data(jsonText.utf8))
        } catch {
            throw LLMError.badResponse("JSON 字段解析失败：\(error.localizedDescription)")
        }

        var summary = raw.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = raw.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            throw LLMError.badResponse("summary 为空")
        }
        if summary.count > maxSummaryLength {
            logger.error("summary too long chars=\(summary.count, privacy: .public), truncating to \(maxSummaryLength, privacy: .public)")
            summary = String(summary.prefix(maxSummaryLength - 1)) + "…"
        }
        logger.info(
            "answer parsed summaryChars=\(summary.count, privacy: .public) answerChars=\(answer.count, privacy: .public)"
        )
        return LLMAnswer(summary: summary, answer: answer.isEmpty ? summary : answer)
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }

    private static func makeLogger() -> Logger {
        Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
            category: "llm"
        )
    }
}

// MARK: - 响应结构（只解需要的字段）

nonisolated private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }
        let message: Message
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }

    let choices: [Choice]
    let usage: Usage?
}

// MARK: - 错误

/// errorDescription 是给灵动岛看的短文案；logDescription 带细节，只进日志。
nonisolated enum LLMError: LocalizedError, Sendable {
    case missingAPIKey
    case timeout
    case offline
    case network(code: Int)
    case cancelled
    case http(status: Int)
    case emptyContent
    case badResponse(String)

    init(transportError error: any Error) {
        guard let urlError = error as? URLError else {
            self = .network(code: (error as NSError).code)
            return
        }
        switch urlError.code {
        case .timedOut:
            self = .timeout
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
            self = .offline
        case .cancelled:
            self = .cancelled
        default:
            self = .network(code: urlError.errorCode)
        }
    }

    /// 只在可能是临时问题时重试（SPEC 6.9：失败重试 1 次）。Key 错、参数错重试也没用。
    var isRetryable: Bool {
        switch self {
        case .timeout, .offline, .network, .emptyContent, .badResponse:
            return true
        case .http(let status):
            return status == 429 || (500..<600).contains(status)
        case .missingAPIKey, .cancelled:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "未配置 API Key"
        case .timeout:
            return "网络超时"
        case .offline:
            return "网络不可用"
        case .network(let code):
            return "网络出错（\(code)）"
        case .cancelled:
            return "已取消"
        case .http(let status):
            return "服务出错（\(status)）"
        case .emptyContent, .badResponse:
            return "回答格式异常"
        }
    }

    var logDescription: String {
        switch self {
        case .badResponse(let detail):
            return "badResponse: \(detail)"
        case .emptyContent:
            return "emptyContent"
        default:
            return errorDescription ?? "unknown"
        }
    }
}
