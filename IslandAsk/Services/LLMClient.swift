//
//  LLMClient.swift
//  IslandAsk
//
//  大模型调用（SPEC 第 6.9 节）。第一版只有 OpenAICompatibleProvider，默认接 DeepSeek：
//  - 模型 deepseek-flash（https://api-docs.deepseek.com/guides/vision ，2026-11 查询：当前支持图片的模型）。
//  - 图片只能放在 user 消息的 content 数组里，放 system/assistant 会 400。
//  - JSON 模式可能返回全空格内容，按可重试错误处理（https://api-docs.deepseek.com/guides/json_mode ）。
//  - deepseek-flash 默认开思考模式（high）。M3 真机日志：识图类问题思考就用完 max_tokens，finish_reason=length、
//    content 全空格，单次 16–18 秒，重试后超出后台时间被取消。所以显式关闭思考
//    （https://api-docs.deepseek.com/guides/thinking_mode ：{"thinking": {"type": "disabled"}}）。
//  - 两档回答：ask() 是快速档（不思考、JSON、30 秒），给灵动岛摘要；streamDeepAnswer() 是深度档
//    （开思考、流式 SSE、纯 Markdown），只在 App 前台的会话页和追问里用。
//    流式时思考在 delta.reasoning_content、正文在 delta.content；不带 tools 时历史里的 reasoning_content 会被忽略，不回传。
//
//  与 SPEC 的偏差：history 的元素类型是 LLMTurn 而不是 ChatMessage。ChatMessage 是 @Model，不是 Sendable，
//  不能传进 @concurrent 的 ask；调用方在主线程上用 ChatMessage.turn / AskSession.conversationTurns 转换。
//  配置（地址、模型、Key）每次请求从设置页读取：fromSettings()。
//

import Foundation
import os

nonisolated struct LLMAnswer: Codable, Sendable {
    let summary: String
    let answer: String
    /// 快速模型判断是否需要会话页再用深度思考回答一次；没返回时调用方按 true 处理。
    var needsDeep: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case summary
        case answer
        case needsDeep = "needs_deep"
    }
}

/// 发给大模型的一轮对话（ChatMessage 的值类型快照）。
nonisolated struct LLMTurn: Sendable {
    enum Role: String, Sendable {
        case user
        case assistant
    }

    let role: Role
    let content: String
}

/// 深度回答的流式片段。
nonisolated enum LLMStreamEvent: Sendable {
    case reasoning(String)
    case content(String)
}

nonisolated protocol LLMProvider: Sendable {
    var model: String { get }
    /// screenText：截图的 OCR 文字（M4），和截图一起放在第一条 user 消息里；nil 表示没有。
    @concurrent
    func ask(imageJPEG: Data?, screenText: String?, question: String, history: [LLMTurn]) async throws -> LLMAnswer
    /// 深度回答：开思考、流式返回。取消消费方的 Task（或停止迭代）会取消网络请求。
    func streamDeepAnswer(
        imageJPEG: Data?,
        screenText: String?,
        question: String,
        history: [LLMTurn]
    ) -> AsyncThrowingStream<LLMStreamEvent, any Error>
}

nonisolated struct OpenAICompatibleProvider: LLMProvider {

    /// SPEC 6.9 的系统提示词原文，加了 needs_deep 一行（快速回答够用时会话页不自动深度思考）。
    /// JSON 模式要求提示词里出现 "json" 并给出格式示例，这里两者都有。
    static let systemPrompt = """
        你是屏幕助手。用户会给你一张手机截图和一个口语化的问题（来自语音转写，可能有错别字）。请结合截图回答。
        只输出 JSON：{"summary": "...", "answer": "...", "needs_deep": false}
        summary：不超过 80 个汉字，直接给结论，不寒暄。
        answer：完整回答，可使用 Markdown。
        needs_deep：true 或 false。answer 已经完整准确回答了问题时为 false；需要逐项识别图中多个细节、多步推理、你没有把握，或 answer 只是概要时为 true。
        如果截图与问题无关或看不清，在 summary 中直接说明。
        """

    /// 深度回答的系统提示词：直接输出 Markdown 正文，流式显示时不会露出 JSON。
    static let deepSystemPrompt = """
        你是屏幕助手。用户会给你一张手机截图和一个问题（首轮问题来自语音转写，可能有错别字）。请结合截图仔细分析后详细回答。
        直接输出回答正文，使用 Markdown（可用标题、列表、粗体），不要输出 JSON，不要寒暄。
        如果截图与问题无关或看不清，直接说明。
        """

    /// 深度回答专用 session：request 超时是两个数据包之间的最长间隔，思考期间也会持续收到 reasoning 片段；
    /// resource 超时是整次请求上限。
    private static let streamSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// 灵动岛摘要硬上限（UI 优化后展开态 bottom 整行最多 5 行，约 80 字；SPEC 6.10 原为 40 字）。
    static let maxSummaryLength = 80

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

    /// 按设置页的当前值构造：地址、模型来自 AppSettings，Key 来自 Keychain。每次请求都重新读，改完立即生效。
    static func fromSettings() throws -> OpenAICompatibleProvider {
        let logger = makeLogger()
        let baseURLString = AppSettings.baseURLString
        guard let baseURL = URL(string: baseURLString),
              let scheme = baseURL.scheme?.lowercased(), scheme == "https" || scheme == "http",
              baseURL.host() != nil else {
            logger.error("provider config invalid baseURL=\(baseURLString, privacy: .public)")
            throw LLMError.invalidBaseURL
        }
        let apiKey = KeychainStore.read() ?? ""
        logger.info(
            "provider config baseURL=\(baseURL.absoluteString, privacy: .public) model=\(AppSettings.model, privacy: .public) hasKey=\(!apiKey.isEmpty, privacy: .public)"
        )
        return OpenAICompatibleProvider(baseURL: baseURL, apiKey: apiKey, model: AppSettings.model)
    }

    @concurrent
    func ask(imageJPEG: Data?, screenText: String?, question: String, history: [LLMTurn]) async throws -> LLMAnswer {
        let logger = Self.makeLogger()
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.error("ask aborted: API key is empty")
            throw LLMError.missingAPIKey
        }

        let body = try makeRequestBody(imageJPEG: imageJPEG, screenText: screenText, question: question, history: history)
        logger.info(
            "ask start model=\(model, privacy: .public) imageBytes=\(imageJPEG?.count ?? 0, privacy: .public) screenTextChars=\(screenText?.count ?? 0, privacy: .public) questionChars=\(question.count, privacy: .public) history=\(history.count, privacy: .public) bodyBytes=\(body.count, privacy: .public)"
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

    // MARK: - 深度回答（流式）

    func streamDeepAnswer(
        imageJPEG: Data?,
        screenText: String?,
        question: String,
        history: [LLMTurn]
    ) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<LLMStreamEvent, any Error>.makeStream()
        let task = Task {
            do {
                try await runDeepStream(
                    imageJPEG: imageJPEG,
                    screenText: screenText,
                    question: question,
                    history: history,
                    continuation: continuation
                )
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func runDeepStream(
        imageJPEG: Data?,
        screenText: String?,
        question: String,
        history: [LLMTurn],
        continuation: AsyncThrowingStream<LLMStreamEvent, any Error>.Continuation
    ) async throws {
        let logger = Self.makeLogger()
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.error("stream aborted: API key is empty")
            throw LLMError.missingAPIKey
        }

        let body = try makeDeepRequestBody(
            imageJPEG: imageJPEG,
            screenText: screenText,
            question: question,
            history: history
        )
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        let startedAt = ContinuousClock.now
        logger.info(
            "stream start model=\(model, privacy: .public) imageBytes=\(imageJPEG?.count ?? 0, privacy: .public) screenTextChars=\(screenText?.count ?? 0, privacy: .public) questionChars=\(question.count, privacy: .public) history=\(history.count, privacy: .public) bodyBytes=\(body.count, privacy: .public)"
        )

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await Self.streamSession.bytes(for: request)
        } catch {
            let llmError = LLMError(transportError: error)
            logger.error("stream connect failed: \(llmError.logDescription, privacy: .public)")
            throw llmError
        }
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.badResponse("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            // 错误响应体只含错误说明，不含 Key，截一段方便排查。
            var snippet = Data()
            for try await byte in bytes {
                snippet.append(byte)
                if snippet.count >= 300 { break }
            }
            logger.error(
                "stream http error status=\(http.statusCode, privacy: .public) body=\(String(decoding: snippet, as: UTF8.self), privacy: .public)"
            )
            throw LLMError.http(status: http.statusCode)
        }

        var reasoningChars = 0
        var contentChars = 0
        var finishReason: String?
        let decoder = JSONDecoder()
        do {
            for try await line in bytes.lines {
                // SSE：只处理 data: 行；空行、注释行（: keep-alive）跳过。
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let chunk = try? decoder.decode(ChatCompletionChunk.self, from: Data(payload.utf8)) else {
                    logger.error("stream chunk decode failed head=\(String(payload.prefix(200)), privacy: .public)")
                    continue
                }
                guard let choice = chunk.choices.first else { continue }
                if let reasoning = choice.delta.reasoningContent, !reasoning.isEmpty {
                    if reasoningChars == 0 {
                        logger.info(
                            "stream first reasoning elapsedMs=\(Self.milliseconds(ContinuousClock.now - startedAt), privacy: .public)"
                        )
                    }
                    reasoningChars += reasoning.count
                    continuation.yield(.reasoning(reasoning))
                }
                if let content = choice.delta.content, !content.isEmpty {
                    if contentChars == 0 {
                        logger.info(
                            "stream first content elapsedMs=\(Self.milliseconds(ContinuousClock.now - startedAt), privacy: .public) reasoningChars=\(reasoningChars, privacy: .public)"
                        )
                    }
                    contentChars += content.count
                    continuation.yield(.content(content))
                }
                if let reason = choice.finishReason {
                    finishReason = reason
                }
            }
        } catch {
            let llmError = Task.isCancelled ? LLMError.cancelled : LLMError(transportError: error)
            logger.error(
                "stream interrupted reasoningChars=\(reasoningChars, privacy: .public) contentChars=\(contentChars, privacy: .public): \(llmError.logDescription, privacy: .public)"
            )
            throw llmError
        }
        if Task.isCancelled {
            logger.notice("stream cancelled contentChars=\(contentChars, privacy: .public)")
            throw LLMError.cancelled
        }

        let finish = finishReason ?? "nil"
        logger.info(
            "stream finished finish_reason=\(finish, privacy: .public) reasoningChars=\(reasoningChars, privacy: .public) contentChars=\(contentChars, privacy: .public) elapsedMs=\(Self.milliseconds(ContinuousClock.now - startedAt), privacy: .public)"
        )
        if finishReason == "length" {
            throw LLMError.truncated
        }
        guard contentChars > 0 else {
            logger.error("stream finished without content finish_reason=\(finish, privacy: .public)")
            throw LLMError.emptyContent
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
        let finishReason = choice?.finishReason ?? "nil"
        let content = choice?.message.content ?? ""
        let reasoningChars = choice?.message.reasoningContent?.count ?? 0
        logger.info(
            "completion finish_reason=\(finishReason, privacy: .public) contentChars=\(content.count, privacy: .public) reasoningChars=\(reasoningChars, privacy: .public)"
        )
        if finishReason == "length" {
            // 被 max_tokens 截断：同样的请求重试也会截断，直接报错，不浪费后台时间。
            logger.error(
                "truncated finish_reason=length contentChars=\(content.count, privacy: .public) reasoningChars=\(reasoningChars, privacy: .public) completionTokens=\(completion.usage?.completionTokens ?? -1, privacy: .public)"
            )
            throw LLMError.truncated
        }
        if finishReason != "stop" {
            logger.error("unexpected finish_reason=\(finishReason, privacy: .public)")
        }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // JSON 模式下模型没产出合法 JSON 时，content 可能全是空格。
            logger.error(
                "empty content finish_reason=\(finishReason, privacy: .public) rawChars=\(content.count, privacy: .public) reasoningChars=\(reasoningChars, privacy: .public)"
            )
            throw LLMError.emptyContent
        }
        do {
            return try Self.parseAnswer(content, logger: logger)
        } catch {
            // 回答内容不含 Key，打头尾各一段方便排查格式问题。
            logger.error(
                "parse failed head=\(String(content.prefix(200)), privacy: .public) tail=\(String(content.suffix(100)), privacy: .public)"
            )
            throw error
        }
    }

    // MARK: - 请求体

    private func makeRequestBody(
        imageJPEG: Data?,
        screenText: String?,
        question: String,
        history: [LLMTurn]
    ) throws -> Data {
        let messages = makeMessages(
            systemPrompt: Self.systemPrompt,
            imageJPEG: imageJPEG,
            screenText: screenText,
            question: question,
            history: history
        )
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": false,
            "max_tokens": 2048,
            "thinking": ["type": "disabled"],
            // TODO: 核对官方文档：DeepSeek 文档未说明 json_object 能否与图片输入同时使用，需真机确认；
            // 若返回 400，去掉这一项，依靠 parseAnswer 的代码块兜底解析。
            "response_format": ["type": "json_object"],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func makeDeepRequestBody(
        imageJPEG: Data?,
        screenText: String?,
        question: String,
        history: [LLMTurn]
    ) throws -> Data {
        let messages = makeMessages(
            systemPrompt: Self.deepSystemPrompt,
            imageJPEG: imageJPEG,
            screenText: screenText,
            question: question,
            history: history
        )
        // 不设 max_tokens：文档没给思考模式的上限，之前设 2048 时思考就把额度用完了。
        // TODO: 核对官方文档：思考模式不设 max_tokens 时的默认输出上限；流式 + 思考 + 图片输入的组合文档未写明，需真机确认。
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true,
            "thinking": ["type": "enabled"],
            "reasoning_effort": "high",
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func makeMessages(
        systemPrompt: String,
        imageJPEG: Data?,
        screenText: String?,
        question: String,
        history: [LLMTurn]
    ) -> [[String: Any]] {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let turns = history + [LLMTurn(role: .user, content: trimmedQuestion.isEmpty ? "请看这张截图。" : trimmedQuestion)]
        let trimmedScreenText = screenText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let screenText = trimmedScreenText?.isEmpty == false ? trimmedScreenText : nil

        // 截图和 OCR 文字挂在第一条 user 消息上：追问时它是首轮问题，沿用同一张截图（SPEC 6.12）。
        // DeepSeek 只接受 user 消息里的图片，放 system/assistant 会 400。
        let contextTurnIndex = imageJPEG == nil && screenText == nil ? nil : turns.firstIndex { $0.role == .user }

        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for (index, turn) in turns.enumerated() {
            if index == contextTurnIndex {
                var text = turn.content
                if let screenText {
                    // 放在问题后面并标明来源：模型以截图为准，OCR 只用来补小字。
                    text += "\n\n（以下是本机 OCR 从截图中识别出的文字，可能有错，仅供参考，以截图为准）\n\(screenText)"
                }
                var content: [[String: Any]] = [["type": "text", "text": text]]
                if let imageJPEG {
                    content.append([
                        "type": "image_url",
                        // detail=low 会缩到 512×512，中文小字看不清；high 保留原尺寸（我们已压到长边 1536）。
                        "image_url": [
                            "url": "data:image/jpeg;base64,\(imageJPEG.base64EncodedString())",
                            "detail": "high",
                        ],
                    ])
                }
                messages.append(["role": turn.role.rawValue, "content": content])
            } else {
                messages.append(["role": turn.role.rawValue, "content": turn.content])
            }
        }
        return messages
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
            "answer parsed summaryChars=\(summary.count, privacy: .public) answerChars=\(answer.count, privacy: .public) needsDeep=\(raw.needsDeep.map(String.init(describing:)) ?? "nil", privacy: .public)"
        )
        return LLMAnswer(summary: summary, answer: answer.isEmpty ? summary : answer, needsDeep: raw.needsDeep)
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
            let reasoningContent: String?

            enum CodingKeys: String, CodingKey {
                case content
                case reasoningContent = "reasoning_content"
            }
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

/// 流式响应的一个 chunk（只解需要的字段）。
nonisolated private struct ChatCompletionChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
            let reasoningContent: String?

            enum CodingKeys: String, CodingKey {
                case content
                case reasoningContent = "reasoning_content"
            }
        }
        let delta: Delta
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    let choices: [Choice]
}

// MARK: - 错误

/// errorDescription 是给灵动岛看的短文案；logDescription 带细节，只进日志。
nonisolated enum LLMError: LocalizedError, Sendable {
    case missingAPIKey
    case invalidBaseURL
    case timeout
    case offline
    case network(code: Int)
    case cancelled
    case http(status: Int)
    case emptyContent
    case truncated
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
        case .missingAPIKey, .invalidBaseURL, .cancelled, .truncated:
            return false
        }
    }

    /// 灵动岛第一行（≤12 字）。状态码按 DeepSeek 错误码文档归类：401 Key 错、402 余额不足、
    /// 400/422 参数错（模型名写错也是 400）、429 限流、5xx 服务端问题。
    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "未配置 API Key"
        case .invalidBaseURL:
            return "API 地址无效"
        case .timeout:
            return "网络超时"
        case .offline:
            return "网络不可用"
        case .network(let code):
            return "网络出错（\(code)）"
        case .cancelled:
            return "已取消"
        case .http(let status):
            switch status {
            case 401, 403: return "API Key 无效"
            case 402: return "账户余额不足"
            case 404: return "API 地址有误"
            case 429: return "请求太频繁"
            case 500..<600: return "服务繁忙（\(status)）"
            default: return "请求被拒绝（\(status)）"
            }
        case .emptyContent, .badResponse:
            return "回答格式异常"
        case .truncated:
            return "回答太长被截断"
        }
    }

    /// 会话页的补充说明：告诉用户下一步怎么做。
    var recoverySuggestion: String? {
        switch self {
        case .missingAPIKey:
            return "到设置里填写大模型的 API Key。"
        case .invalidBaseURL:
            return "到设置里检查 API 地址，需要以 https:// 开头。"
        case .timeout:
            return "网络较慢或服务繁忙，稍后重试。"
        case .offline:
            return "检查网络连接后重试。"
        case .network:
            return "网络连接出错，稍后重试。"
        case .cancelled:
            return nil
        case .http(let status):
            switch status {
            case 401, 403: return "API Key 不正确或已失效，到设置里重新填写。"
            case 402: return "大模型账户余额不足，充值后重试。"
            case 404: return "接口不存在，到设置里检查 API 地址。"
            case 429: return "请求太频繁，稍等片刻再试。"
            case 500..<600: return "大模型服务暂时不可用，稍后重试。"
            default: return "请求被服务拒绝，到设置里检查模型名和 API 地址。"
            }
        case .emptyContent, .badResponse:
            return "模型没有按格式返回，重试一般就能恢复。"
        case .truncated:
            return "回答超出长度上限，换个更具体的问题再试。"
        }
    }

    /// 需要用户改设置（Key、地址、模型）才能恢复：会话页显示「去设置」，灵动岛提示打开 App。
    var needsSettings: Bool {
        switch self {
        case .missingAPIKey, .invalidBaseURL:
            return true
        case .http(let status):
            return status == 401 || status == 403 || status == 404 || status == 400 || status == 422
        default:
            return false
        }
    }

    var logDescription: String {
        switch self {
        case .badResponse(let detail):
            return "badResponse: \(detail)"
        case .emptyContent:
            return "emptyContent"
        case .truncated:
            return "truncated"
        default:
            return errorDescription ?? "unknown"
        }
    }
}
