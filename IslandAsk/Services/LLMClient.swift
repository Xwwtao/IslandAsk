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
//  - 两档回答：ask() 是快速档（不思考、JSON、30 秒；M4 起也走流式，summary 一完整就回调 onSummary），给灵动岛摘要；
//    streamDeepAnswer() 是深度档
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
    /// M-C1：模型判断的意图；无法识别时为 nil，调用方按 ask 处理。
    var intent: LLMIntent? = nil
    /// M-C1：卡片字段；模型没给时为 nil，卡片只用 summary / answer。
    var card: CardFields? = nil
    /// 不在 CodingKeys 里、不参与 JSON 解析：ask 成功后填入最后一次请求的网络耗时和请求次数（含重试）。
    var network: NetworkTiming? = nil
    var attempts: Int? = nil
    /// 同上，不参与 JSON 解析：流式最后一个 chunk 里的 token 用量（会话页 Token 卡片）。
    var usage: TokenUsage? = nil

    enum CodingKeys: String, CodingKey {
        case summary
        case answer
        case needsDeep = "needs_deep"
        case intent
        case card
    }
}

nonisolated extension LLMAnswer {
    /// 写在扩展里，保留 memberwise init。intent / card 解析失败不算格式错误，按缺失处理。
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decode(String.self, forKey: .summary)
        answer = (try? container.decodeIfPresent(String.self, forKey: .answer)) ?? ""
        needsDeep = try? container.decodeIfPresent(Bool.self, forKey: .needsDeep)
        intent = (try? container.decodeIfPresent(String.self, forKey: .intent))
            .flatMap { LLMIntent(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
        card = try? container.decodeIfPresent(CardFields.self, forKey: .card)
    }
}

/// M-C1：一次按键的意图（SPEC 第 4 节「分流与卡片」）。
nonisolated enum LLMIntent: String, Codable, Sendable {
    case ask
    case collect
    case both
}

/// 卡片里的一条关键信息（店名、地址、价格……）。
nonisolated struct KeyInfo: Codable, Sendable, Hashable {
    var label: String
    var value: String
}

/// M-C1：快速档顺带整理出的卡片字段（SPEC 6.9）。全部可选，单个字段类型不对时只丢这个字段。
nonisolated struct CardFields: Codable, Sendable {
    var title: String?
    var type: String?
    var tags: [String]?
    var keyInfo: [KeyInfo]?
    var note: String?
    var sourcePlatform: String?
    var sourceTitle: String?
    var translation: String?

    enum CodingKeys: String, CodingKey {
        case title
        case type
        case tags
        case keyInfo = "key_info"
        case note
        case sourcePlatform = "source_platform"
        case sourceTitle = "source_title"
        case translation
    }

    init(
        title: String? = nil,
        type: String? = nil,
        tags: [String]? = nil,
        keyInfo: [KeyInfo]? = nil,
        note: String? = nil,
        sourcePlatform: String? = nil,
        sourceTitle: String? = nil,
        translation: String? = nil
    ) {
        self.title = title
        self.type = type
        self.tags = tags
        self.keyInfo = keyInfo
        self.note = note
        self.sourcePlatform = sourcePlatform
        self.sourceTitle = sourceTitle
        self.translation = translation
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        type = try? container.decodeIfPresent(String.self, forKey: .type)
        tags = try? container.decodeIfPresent([String].self, forKey: .tags)
        // 逐条解：某一条缺 label / value 只丢那一条。
        keyInfo = (try? container.decodeIfPresent([LossyKeyInfo].self, forKey: .keyInfo))?.compactMap(\.value)
        note = try? container.decodeIfPresent(String.self, forKey: .note)
        sourcePlatform = try? container.decodeIfPresent(String.self, forKey: .sourcePlatform)
        sourceTitle = try? container.decodeIfPresent(String.self, forKey: .sourceTitle)
        translation = try? container.decodeIfPresent(String.self, forKey: .translation)
    }

    private struct LossyKeyInfo: Decodable {
        let value: KeyInfo?

        init(from decoder: any Decoder) throws {
            value = try? KeyInfo(from: decoder)
        }
    }

    static let maxTitleLength = 20
    static let maxTags = 4
    static let maxKeyInfo = 6
    static let maxTranslationLength = 600

    /// SPEC 6.9 的规范化：去空白、空串当 nil；title 截到 20 字，type 不在列表里按 other，tags 最多 4 个，
    /// key_info 最多 6 条，translation 超长截断。
    func normalized() -> CardFields {
        func clean(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, text.lowercased() != "null" else { return nil }
            return text
        }
        var result = CardFields()
        result.title = clean(title).map { String($0.prefix(Self.maxTitleLength)) }
        let rawType = clean(type)?.lowercased()
        result.type = rawType.flatMap(CardType.init(rawValue:))?.rawValue ?? CardType.other.rawValue
        var seenTags = Set<String>()
        result.tags = (tags ?? []).compactMap(clean).filter { seenTags.insert($0).inserted }.prefix(Self.maxTags).map { $0 }
        result.keyInfo = (keyInfo ?? []).compactMap { item in
            guard let label = clean(item.label), let value = clean(item.value) else { return nil }
            return KeyInfo(label: label, value: value)
        }.prefix(Self.maxKeyInfo).map { $0 }
        result.note = clean(note)
        result.sourcePlatform = clean(sourcePlatform)
        result.sourceTitle = clean(sourceTitle)
        result.translation = clean(translation).map { text in
            text.count > Self.maxTranslationLength ? String(text.prefix(Self.maxTranslationLength - 1)) + "…" : text
        }
        return result
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
    /// 流结束前的 token 用量（请求带 stream_options.include_usage 时才有）。
    case usage(TokenUsage)
}

nonisolated protocol LLMProvider: Sendable {
    var model: String { get }
    /// screenText：截图的 OCR 文字（M4），和截图一起放在第一条 user 消息里；nil 表示没有。
    /// intentHint（M-C1）：本地已确定的意图。collect = 用户没说话，按收藏整理；ask = 用户点了「改为提问」；nil = 由模型判断。
    /// onSummary：流式返回中 summary 字段一完整就回调一次（已截断到 maxSummaryLength），同时带上已经到达的 intent
    /// （提示词把 intent 排在 summary 前面），用来提前更新灵动岛。
    /// 回调过之后请求再失败不会重试（摘要已经给出去了），直接抛错，由调用方降级处理。
    @concurrent
    func ask(
        imageJPEG: Data?,
        screenText: String?,
        question: String,
        history: [LLMTurn],
        intentHint: LLMIntent?,
        onSummary: (@Sendable (String, LLMIntent?) async -> Void)?
    ) async throws -> LLMAnswer
    /// M-C2 链接收藏的快速档整理（SPEC 6.13）：不带图、不开思考、JSON 模式，intent 固定 collect。
    /// 输入是链接、网页标题、网页描述和分享时附带的文字，任何一项都可以为 nil（纯文字收藏时 url 为 nil）。
    /// allowRetry = false 时不重试：Intent 链路有总时长上限，重试一次就会超时。
    @concurrent
    func organizeLink(
        url: URL?,
        pageTitle: String?,
        pageDescription: String?,
        pageExcerpt: String?,
        sharedText: String?,
        coverJPEG: Data?,
        allowRetry: Bool
    ) async throws -> LLMAnswer
    /// 深度回答：开思考、流式返回。取消消费方的 Task（或停止迭代）会取消网络请求。
    func streamDeepAnswer(
        imageJPEG: Data?,
        screenText: String?,
        question: String,
        history: [LLMTurn]
    ) -> AsyncThrowingStream<LLMStreamEvent, any Error>
}

nonisolated struct OpenAICompatibleProvider: LLMProvider {

    /// SPEC 6.9 的系统提示词（M-C1：同时完成意图判断、回答和卡片整理）。summary 按代码的 80 字上限（SPEC 已同步）。
    /// JSON 模式要求提示词里出现 "json" 并给出格式示例，这里两者都有。intent 排在 summary 前面，流式提前取摘要时意图已经到了。
    static let systemPrompt = """
        你是屏幕助手兼收藏整理员。用户会给你一张手机截图和一句口语化的话（来自语音转写，可能有错别字，也可能为空）。
        先判断用户意图：
        - collect：用户要收藏、保存、记下这个内容（如「收藏」「存一下」「记一下」「以后看」），或者话为空；
        - ask：用户在提问；
        - both：既提问又要求收藏。
        只输出 JSON：
        {"intent": "ask", "summary": "...", "answer": "...", "needs_deep": false,
         "card": {"title": "...", "type": "article", "tags": ["..."], "key_info": [{"label": "...", "value": "..."}],
                  "note": null, "source_platform": null, "source_title": null, "translation": null}}
        summary：不超过 80 个汉字，显示在灵动岛。ask / both 时直接给结论，不寒暄；collect 时概括收藏了什么。
        answer：ask / both 时是完整回答，可使用 Markdown；collect 时是 2–4 句的内容摘要。
        needs_deep：true 或 false，只在 ask / both 时有意义，collect 时为 false。answer 已经完整准确回答了问题时为 false；需要逐项识别图中多个细节、多步推理、你没有把握，或 answer 只是概要时为 true。
        card.title：不超过 20 个汉字，概括截图内容本身（不是概括问题）。
        card.type：article / product / place / event / recipe / knowledge / media / chat / other 之一。
        card.tags：1–4 个中文短标签。
        card.key_info：截图里值得单独记下的信息，如店名、地址、价格、时间、书名、作者，最多 6 条；没有就给空数组。
        card.note：用户话里除收藏指令之外的附注（如「周末去」），没有时为 null。
        card.source_platform / card.source_title：根据界面特征判断截图来自哪个 App 或网站、原内容的标题；看不出来时为 null，不要猜。
        card.translation：截图主要内容不是中文时，给出中文翻译，最多 600 字，超出时只翻译开头并以「…」结尾；是中文时为 null。
        如果截图与问题无关或看不清，在 summary 中直接说明。
        """

    /// M-C2 链接卡片的系统提示词：字段和取值与 systemPrompt 一致，复用同一套解析和规范化。
    /// note 固定为 null：分享时附带的文字由 App 原样保存为附注，不让模型改写，避免丢掉用户的原文。
    static let linkSystemPrompt = """
        你是收藏整理员。用户从其他 App 分享了一个链接（或一段文字）到收藏夹。你会拿到链接地址、网页标题、网页描述、分享时附带的文字和网页正文摘录，其中任何一项都可能缺失；短链、需要登录的页面往往抓不到内容。
        有正文摘录时，以它为主写摘要和关键信息，忽略其中的导航、按钮、版权声明等无关文字。
        请据此整理成一张收藏卡片，只输出 JSON：
        {"intent": "collect", "summary": "...", "answer": "...", "needs_deep": false,
         "card": {"title": "...", "type": "article", "tags": ["..."], "key_info": [{"label": "...", "value": "..."}],
                  "note": null, "source_platform": null, "source_title": null, "translation": null}}
        intent 固定为 collect，needs_deep 固定为 false，card.note 固定为 null。
        summary：不超过 80 个汉字，概括收藏了什么。
        answer：2–4 句的内容摘要。信息很少时如实说明只知道标题或链接，不要编造内容。
        card.title：不超过 20 个汉字，概括内容本身；有网页标题时以它为准提炼。
        card.type：article / product / place / event / recipe / knowledge / media / chat / other 之一。
        card.tags：1–4 个中文短标签。
        card.key_info：值得单独记下的信息，如店名、地址、价格、时间、书名、作者，最多 6 条；没有就给空数组。
        card.source_platform：根据链接域名和标题判断内容来自哪个 App 或网站（如微信公众号、小红书、哔哩哔哩、知乎），看不出来时为 null，不要猜。
        card.source_title：原内容的标题，没有时为 null。
        card.translation：标题、描述或分享文字主要不是中文时，给出中文翻译，最多 600 字；是中文时为 null。
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

    /// 快速档共享一个 session：fromSettings() 每次都会构造新的 provider，session 也跟着新建的话，
    /// 连接无法复用，preconnect() 提前建好的连接也用不上。
    private static let quickSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    let baseURL: URL
    let apiKey: String
    let model: String

    private let maxAttempts = 2

    init(baseURL: URL, apiKey: String, model: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }

    /// 用户开口时就向 API 主机发一个不带 Key 的 HEAD，提前做完 DNS、TCP、TLS；说完后的正式请求复用这条连接。
    /// 返回什么状态码都无所谓，只记日志。效果看正式请求日志里的 reused=true。
    @concurrent
    static func preconnect() async {
        let logger = makeLogger()
        guard let baseURL = URL(string: AppSettings.baseURLString),
              baseURL.scheme?.lowercased() == "https" else {
            logger.info("preconnect skipped: baseURL not https")
            return
        }
        var request = URLRequest(url: baseURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        let startedAt = ContinuousClock.now
        do {
            let (_, response) = try await quickSession.data(for: request, delegate: TransactionMetricsLogger(label: "preconnect"))
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            logger.info(
                "preconnect finished status=\(status, privacy: .public) elapsedMs=\(milliseconds(ContinuousClock.now - startedAt), privacy: .public)"
            )
        } catch {
            logger.notice("preconnect failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 按设置页的当前值构造：地址、模型来自 AppSettings，Key 来自 Keychain。每次请求都重新读，改完立即生效。
    static func fromSettings() throws -> OpenAICompatibleProvider {
        let logger = makeLogger()
        let baseURLString = AppSettings.baseURLString
        // Key 放在请求头里，只允许 https；http 仅限本机地址（开发调试用），避免 Key 明文上网。
        guard let baseURL = URL(string: baseURLString),
              let host = baseURL.host()?.lowercased(),
              let scheme = baseURL.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && Self.loopbackHosts.contains(host)) else {
            logger.error("provider config invalid baseURL chars=\(baseURLString.count, privacy: .public) value=\(baseURLString, privacy: .private)")
            throw LLMError.invalidBaseURL
        }
        let apiKey = KeychainStore.read() ?? ""
        logger.info(
            "provider config baseURL=\(Self.redacted(baseURL), privacy: .public) model=\(AppSettings.model, privacy: .public) hasKey=\(!apiKey.isEmpty, privacy: .public)"
        )
        return OpenAICompatibleProvider(baseURL: baseURL, apiKey: apiKey, model: AppSettings.model)
    }

    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    /// 日志用：只留 scheme、host、端口、路径，去掉可能带凭据的 userinfo 和 query。
    private static func redacted(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "<unparsable>" }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "<unparsable>"
    }

    @concurrent
    func ask(
        imageJPEG: Data?,
        screenText: String?,
        question: String,
        history: [LLMTurn],
        intentHint: LLMIntent?,
        onSummary: (@Sendable (String, LLMIntent?) async -> Void)?
    ) async throws -> LLMAnswer {
        let logger = Self.makeLogger()
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.error("ask aborted: API key is empty")
            throw LLMError.missingAPIKey
        }

        let body = try makeRequestBody(
            imageJPEG: imageJPEG,
            screenText: screenText,
            question: question,
            history: history,
            intentHint: intentHint
        )
        logger.info(
            "ask start model=\(model, privacy: .public) intentHint=\(intentHint?.rawValue ?? "nil", privacy: .public) imageBytes=\(imageJPEG?.count ?? 0, privacy: .public) screenTextChars=\(screenText?.count ?? 0, privacy: .public) questionChars=\(question.count, privacy: .public) history=\(history.count, privacy: .public) bodyBytes=\(body.count, privacy: .public)"
        )
        return try await runQuickRequest(body: body, maxAttempts: maxAttempts, label: "ask", logger: logger, onSummary: onSummary)
    }

    @concurrent
    func organizeLink(
        url: URL?,
        pageTitle: String?,
        pageDescription: String?,
        pageExcerpt: String?,
        sharedText: String?,
        coverJPEG: Data?,
        allowRetry: Bool
    ) async throws -> LLMAnswer {
        let logger = Self.makeLogger()
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.error("organize link aborted: API key is empty")
            throw LLMError.missingAPIKey
        }
        let userText = Self.linkUserText(
            url: url,
            pageTitle: pageTitle,
            pageDescription: pageDescription,
            pageExcerpt: pageExcerpt,
            sharedText: sharedText
        )
        // 正文很少时调用方会带上封面图（M-C2 补充）：和截图一样放进 user 消息的 content 数组。
        let userContent: Any
        if let coverJPEG {
            userContent = [
                ["type": "text", "text": userText + "\n\n（附带一张网页的封面或首图。文字信息很少，内容主要在图里时，请据图整理摘要和关键信息。）"],
                [
                    "type": "image_url",
                    "image_url": ["url": "data:image/jpeg;base64,\(coverJPEG.base64EncodedString())", "detail": "high"],
                ],
            ] as [[String: Any]]
        } else {
            userContent = userText
        }
        let body = try makeQuickBody(messages: [
            ["role": "system", "content": Self.linkSystemPrompt],
            ["role": "user", "content": userContent],
        ])
        logger.info(
            "organize link start model=\(model, privacy: .public) host=\(url?.host() ?? "nil", privacy: .public) titleChars=\(pageTitle?.count ?? 0, privacy: .public) descriptionChars=\(pageDescription?.count ?? 0, privacy: .public) excerptChars=\(pageExcerpt?.count ?? 0, privacy: .public) sharedTextChars=\(sharedText?.count ?? 0, privacy: .public) coverBytes=\(coverJPEG?.count ?? 0, privacy: .public) allowRetry=\(allowRetry, privacy: .public) bodyBytes=\(body.count, privacy: .public)"
        )
        return try await runQuickRequest(
            body: body,
            maxAttempts: allowRetry ? maxAttempts : 1,
            label: "organize link",
            logger: logger,
            onSummary: nil
        )
    }

    /// 分享文字的上限：整篇文章粘进来时只取开头，避免请求过大、输出变慢。
    static let maxSharedTextLength = 2000

    /// 链接整理的 user 文字。缺失的项写明「无」，让模型知道是没抓到而不是空内容。
    static func linkUserText(
        url: URL?,
        pageTitle: String?,
        pageDescription: String?,
        pageExcerpt: String? = nil,
        sharedText: String?
    ) -> String {
        func value(_ text: String?) -> String {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return "无" }
            return text
        }
        let shared = sharedText.map { text in
            text.count > maxSharedTextLength ? String(text.prefix(maxSharedTextLength)) + "…" : text
        }
        return """
            链接：\(url?.absoluteString ?? "无")
            网页标题：\(value(pageTitle))
            网页描述：\(value(pageDescription))
            分享时附带的文字：\(value(shared))
            网页正文摘录（自动提取，可能夹杂导航、按钮文字）：
            \(value(pageExcerpt))
            """
    }

    /// 快速档请求循环：可重试的错误重试到 maxAttempts 次；摘要回调过之后不再重试。
    private func runQuickRequest(
        body: Data,
        maxAttempts: Int,
        label: String,
        logger: Logger,
        onSummary: (@Sendable (String, LLMIntent?) async -> Void)?
    ) async throws -> LLMAnswer {
        var attempt = 1
        let summaryDelivered = OSAllocatedUnfairLock(initialState: false)
        let deliverSummary: @Sendable (String, LLMIntent?) async -> Void = { summary, intent in
            summaryDelivered.withLock { $0 = true }
            await onSummary?(summary, intent)
        }
        while true {
            do {
                let metrics = TransactionMetricsLogger(label: "\(label) attempt=\(attempt)")
                var answer = try await performAttempt(
                    body: body,
                    attempt: attempt,
                    metrics: metrics,
                    logger: logger,
                    onSummary: deliverSummary
                )
                // 流式时系统可能在数据读完之后才回调 didFinishCollecting，稍等一下再取（不影响摘要显示）。
                answer.network = await metrics.waitForTiming(timeout: .milliseconds(300))
                answer.attempts = attempt
                logger.info("\(label, privacy: .public) succeeded attempt=\(attempt, privacy: .public)")
                return answer
            } catch let error as LLMError
                where error.isRetryable && attempt < maxAttempts && !Task.isCancelled
                && !summaryDelivered.withLock({ $0 }) {
                logger.error(
                    "\(label, privacy: .public) attempt=\(attempt, privacy: .public) failed, retrying: \(error.logDescription, privacy: .public)"
                )
                attempt += 1
            } catch let error as LLMError {
                logger.error(
                    "\(label, privacy: .public) failed attempt=\(attempt, privacy: .public): \(error.logDescription, privacy: .public)"
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
                    // 片段里可能有模型复述的屏幕内容，标 private（Xcode 连机调试时仍可见）。
                    logger.error("stream chunk decode failed chars=\(payload.count, privacy: .public) head=\(String(payload.prefix(200)), privacy: .private)")
                    continue
                }
                if let usage = chunk.usage {
                    let tokenUsage = usage.tokenUsage
                    logger.info(
                        "stream usage promptTokens=\(tokenUsage.promptTokens ?? -1, privacy: .public) completionTokens=\(tokenUsage.completionTokens ?? -1, privacy: .public) reasoningTokens=\(tokenUsage.reasoningTokens ?? -1, privacy: .public) cacheHitTokens=\(tokenUsage.cacheHitTokens ?? -1, privacy: .public)"
                    )
                    continuation.yield(.usage(tokenUsage))
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

    // MARK: - 单次请求（流式）

    /// 快速档也走 SSE：灵动岛只要 summary，它在 JSON 里排第一个，一完整就回调，不用等 answer 生成完。
    /// 内容累加到结束后再整体解析，失败处理和非流式时一致。
    private func performAttempt(
        body: Data,
        attempt: Int,
        metrics: TransactionMetricsLogger,
        logger: Logger,
        onSummary: @Sendable (String, LLMIntent?) async -> Void
    ) async throws -> LLMAnswer {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        let startedAt = ContinuousClock.now
        logger.info("request attempt=\(attempt, privacy: .public) sending stream")

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await Self.quickSession.bytes(for: request, delegate: metrics)
        } catch {
            throw LLMError(transportError: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.badResponse("非 HTTP 响应")
        }
        logger.info(
            "response attempt=\(attempt, privacy: .public) status=\(http.statusCode, privacy: .public) headersMs=\(Self.milliseconds(ContinuousClock.now - startedAt), privacy: .public)"
        )
        guard (200..<300).contains(http.statusCode) else {
            // 错误响应体只含错误说明，不含 Key，截一段方便排查。
            var snippet = Data()
            do {
                for try await byte in bytes {
                    snippet.append(byte)
                    if snippet.count >= 300 { break }
                }
            } catch {
                // 读错误体失败不影响按状态码报错。
            }
            logger.error("http error body: \(String(decoding: snippet, as: UTF8.self), privacy: .public)")
            throw LLMError.http(status: http.statusCode)
        }

        var content = ""
        var reasoningChars = 0
        var finishReason: String?
        var usage: ChatCompletionChunk.Usage?
        var summarySent = false
        var firstContentLogged = false
        let decoder = JSONDecoder()
        do {
            for try await line in bytes.lines {
                // SSE：只处理 data: 行；空行、注释行（: keep-alive）跳过。
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let chunk = try? decoder.decode(ChatCompletionChunk.self, from: Data(payload.utf8)) else {
                    logger.error("quick chunk decode failed chars=\(payload.count, privacy: .public) head=\(String(payload.prefix(200)), privacy: .private)")
                    continue
                }
                if let chunkUsage = chunk.usage {
                    usage = chunkUsage
                }
                guard let choice = chunk.choices.first else { continue }
                if let reasoning = choice.delta.reasoningContent {
                    reasoningChars += reasoning.count
                }
                if let delta = choice.delta.content, !delta.isEmpty {
                    if !firstContentLogged, !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        firstContentLogged = true
                        logger.info(
                            "quick stream first content elapsedMs=\(Self.milliseconds(ContinuousClock.now - startedAt), privacy: .public)"
                        )
                    }
                    content += delta
                    if !summarySent, let raw = Self.completedStringField("summary", in: content) {
                        let summary = Self.normalizedSummary(raw, logger: logger)
                        if !summary.isEmpty {
                            summarySent = true
                            let intent = Self.completedStringField("intent", in: content)
                                .flatMap { LLMIntent(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
                            logger.info(
                                "quick stream summary ready chars=\(summary.count, privacy: .public) intent=\(intent?.rawValue ?? "nil", privacy: .public) elapsedMs=\(Self.milliseconds(ContinuousClock.now - startedAt), privacy: .public)"
                            )
                            await onSummary(summary, intent)
                        }
                    }
                }
                if let reason = choice.finishReason {
                    finishReason = reason
                }
            }
        } catch {
            let llmError = Task.isCancelled ? LLMError.cancelled : LLMError(transportError: error)
            logger.error(
                "quick stream interrupted contentChars=\(content.count, privacy: .public) summarySent=\(summarySent, privacy: .public): \(llmError.logDescription, privacy: .public)"
            )
            throw llmError
        }
        if Task.isCancelled {
            logger.notice("quick stream cancelled contentChars=\(content.count, privacy: .public)")
            throw LLMError.cancelled
        }

        let finish = finishReason ?? "nil"
        logger.info(
            "quick stream finished finish_reason=\(finish, privacy: .public) contentChars=\(content.count, privacy: .public) reasoningChars=\(reasoningChars, privacy: .public) summarySent=\(summarySent, privacy: .public) elapsedMs=\(Self.milliseconds(ContinuousClock.now - startedAt), privacy: .public)"
        )
        if let usage {
            logger.info(
                "usage promptTokens=\(usage.promptTokens ?? -1, privacy: .public) completionTokens=\(usage.completionTokens ?? -1, privacy: .public)"
            )
        }
        if finishReason == "length" {
            // 被 max_tokens 截断：同样的请求重试也会截断，直接报错，不浪费后台时间。
            logger.error(
                "truncated finish_reason=length contentChars=\(content.count, privacy: .public) reasoningChars=\(reasoningChars, privacy: .public) completionTokens=\(usage?.completionTokens ?? -1, privacy: .public)"
            )
            throw LLMError.truncated
        }
        if finishReason != "stop" {
            logger.error("unexpected finish_reason=\(finish, privacy: .public)")
        }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // JSON 模式下模型没产出合法 JSON 时，content 可能全是空格。
            logger.error(
                "empty content finish_reason=\(finish, privacy: .public) rawChars=\(content.count, privacy: .public) reasoningChars=\(reasoningChars, privacy: .public)"
            )
            throw LLMError.emptyContent
        }
        do {
            var answer = try Self.parseAnswer(content, logger: logger)
            answer.usage = usage?.tokenUsage
            return answer
        } catch {
            // 回答可能复述屏幕内容，头尾片段标 private（Xcode 连机调试时仍可见），长度公开。
            logger.error(
                "parse failed chars=\(content.count, privacy: .public) head=\(String(content.prefix(200)), privacy: .private) tail=\(String(content.suffix(100)), privacy: .private)"
            )
            throw error
        }
    }

    // MARK: - 流式 JSON 里提前取字段

    /// 在还没收完的 JSON 文本里找顶层字符串字段 key 的值：值的结束引号已经到了才返回（已解码转义），否则 nil。
    /// 只做够用的扫描：跳过其它字符串字面量里出现的同名文字，不区分嵌套层级（快速档的 intent、summary 排在 card 对象前面，
    /// 先遇到的就是顶层字段）。
    static func completedStringField(_ key: String, in text: String) -> String? {
        let chars = Array(text.unicodeScalars)
        let keyScalars = Array(key.unicodeScalars)
        var index = 0

        /// 从 start（指向开引号）扫到对应的结束引号，返回结束引号的下标；没到就 nil。
        func closingQuote(from start: Int) -> Int? {
            var i = start + 1
            while i < chars.count {
                switch chars[i] {
                case "\\": i += 2
                case "\"": return i
                default: i += 1
                }
            }
            return nil
        }
        func skipWhitespace(_ i: inout Int) {
            while i < chars.count, CharacterSet.whitespacesAndNewlines.contains(chars[i]) { i += 1 }
        }

        while index < chars.count {
            guard chars[index] == "\"" else {
                index += 1
                continue
            }
            // 当前是一个字符串字面量的开头：整段跳过，内容正好是 key、后面跟冒号才算目标字段。
            guard let end = closingQuote(from: index) else { return nil }
            let isKey = Array(chars[(index + 1)..<end]) == keyScalars
            index = end + 1
            guard isKey else { continue }

            var i = index
            skipWhitespace(&i)
            guard i < chars.count else { return nil }
            guard chars[i] == ":" else { continue }
            i += 1
            skipWhitespace(&i)
            guard i < chars.count else { return nil }
            guard chars[i] == "\"" else { return nil }
            guard let valueEnd = closingQuote(from: i) else { return nil }
            var literal = String.UnicodeScalarView()
            literal.append(contentsOf: chars[i...valueEnd])
            return try? JSONDecoder().decode(String.self, from: Data(String(literal).utf8))
        }
        return nil
    }

    // MARK: - 请求体

    private func makeRequestBody(
        imageJPEG: Data?,
        screenText: String?,
        question: String,
        history: [LLMTurn],
        intentHint: LLMIntent?
    ) throws -> Data {
        let messages = makeMessages(
            systemPrompt: Self.systemPrompt,
            imageJPEG: imageJPEG,
            screenText: screenText,
            question: Self.quickQuestionText(question, intentHint: intentHint),
            history: history
        )
        return try makeQuickBody(messages: messages)
    }

    /// 快速档请求体（ask 和 organizeLink 共用）。
    private func makeQuickBody(messages: [[String: Any]]) throws -> Data {
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            // 与 SPEC 6.9 的偏差：快速档改为流式，summary 一完整就更新灵动岛（M4 耗时优化）。
            // M-C1：max_tokens 从 2048 上调到 3072，输出多了卡片字段和翻译。
            "stream": true,
            // 流式时最后一个 chunk 返回 usage（已真机确认）。
            "stream_options": ["include_usage": true],
            "max_tokens": 3072,
            "thinking": ["type": "disabled"],
            // TODO: 核对官方文档：DeepSeek 文档未说明 json_object 能否与图片输入、流式同时使用，需真机确认；
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
            // 最后一个 chunk 带 usage，会话页 Token 卡片用（与快速档同一参数）。
            "stream_options": ["include_usage": true],
            "thinking": ["type": "enabled"],
            "reasoning_effort": "high",
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// 没说话但要提问时（「改为提问」、深度回答）的默认问法。
    static let implicitQuestion = "请解释这张截图的主要内容。"

    /// 快速档 user 文字：把本地已确定的意图写进去。没说话时不再用占位句（模型会把占位句当成提问）。
    static func quickQuestionText(_ question: String, intentHint: LLMIntent?) -> String {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        switch intentHint {
        case .collect:
            let lead = "（用户没有说话。请按 intent = collect 整理这张截图。）"
            return trimmed.isEmpty ? lead : "\(trimmed)\n\n\(lead)"
        case .ask:
            let question = trimmed.isEmpty ? Self.implicitQuestion : trimmed
            return "\(question)\n\n（用户已确认这次是提问，intent 必须为 ask。）"
        case .both, nil:
            return trimmed.isEmpty ? "（用户没有说话。）" : trimmed
        }
    }

    private func makeMessages(
        systemPrompt: String,
        imageJPEG: Data?,
        screenText: String?,
        question: String,
        history: [LLMTurn]
    ) -> [[String: Any]] {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let turns = history + [LLMTurn(role: .user, content: trimmedQuestion.isEmpty ? Self.implicitQuestion : trimmedQuestion)]
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
                        // detail=low 会缩到 512×512，中文小字看不清；high 保留原尺寸（我们已压到长边 1280）。
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
    static func parseAnswer(_ content: String, logger: Logger) throws -> LLMAnswer {
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

        let summary = normalizedSummary(raw.summary, logger: logger)
        let answer = raw.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            throw LLMError.badResponse("summary 为空")
        }
        let card = raw.card?.normalized()
        logger.info(
            "answer parsed intent=\(raw.intent?.rawValue ?? "nil", privacy: .public) summaryChars=\(summary.count, privacy: .public) answerChars=\(answer.count, privacy: .public) needsDeep=\(raw.needsDeep.map(String.init(describing:)) ?? "nil", privacy: .public) hasCard=\(card != nil, privacy: .public) type=\(card?.type ?? "nil", privacy: .public) tags=\(card?.tags?.count ?? 0, privacy: .public) keyInfo=\(card?.keyInfo?.count ?? 0, privacy: .public) translationChars=\(card?.translation?.count ?? 0, privacy: .public)"
        )
        return LLMAnswer(
            summary: summary,
            answer: answer.isEmpty ? summary : answer,
            needsDeep: raw.needsDeep,
            intent: raw.intent,
            card: card
        )
    }

    /// 去首尾空白，超过 maxSummaryLength 截断加「…」。流式提前取到的 summary 和最终解析共用。
    static func normalizedSummary(_ raw: String, logger: Logger) -> String {
        let summary = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard summary.count > maxSummaryLength else { return summary }
        logger.error("summary too long chars=\(summary.count, privacy: .public), truncating to \(maxSummaryLength, privacy: .public)")
        return String(summary.prefix(maxSummaryLength - 1)) + "…"
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

// MARK: - 网络耗时

/// 单个请求的任务 delegate：请求结束时把最后一次传输（含重定向时只看最终那次）的各阶段耗时写进日志，
/// 用来判断慢在建连、上传还是等模型；结果同时存一份给调用方（会话页耗时卡片）。
/// 唯一的可变状态放在锁里，可以跨并发域传递。
nonisolated final class TransactionMetricsLogger: NSObject, URLSessionTaskDelegate, Sendable {

    private let label: String
    private let captured = OSAllocatedUnfairLock<NetworkTiming?>(initialState: nil)

    /// 请求结束后读取；系统在请求完成前回调 didFinishCollecting，拿不到时为 nil。
    var timing: NetworkTiming? {
        captured.withLock { $0 }
    }

    init(label: String) {
        self.label = label
    }

    /// 等系统交回分段耗时，最多等 timeout；超时返回 nil 并记日志。
    func waitForTiming(timeout: Duration) async -> NetworkTiming? {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let timing { return timing }
            guard ContinuousClock.now < deadline, !Task.isCancelled else { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk", category: "llm").notice(
            "metrics \(self.label, privacy: .public) not collected within \(String(describing: timeout), privacy: .public)"
        )
        return nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk", category: "llm")
        guard let transaction = metrics.transactionMetrics.last else {
            logger.info("metrics \(self.label, privacy: .public) no transaction")
            return
        }
        func ms(_ start: Date?, _ end: Date?) -> Int {
            guard let start, let end else { return -1 }
            return Int(end.timeIntervalSince(start) * 1000)
        }
        // -1 表示该阶段没发生（复用连接时 DNS / 建连 / TLS 都是 -1）。
        let dns = ms(transaction.domainLookupStartDate, transaction.domainLookupEndDate)
        let connect = ms(transaction.connectStartDate, transaction.connectEndDate)
        let tls = ms(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate)
        let upload = ms(transaction.requestStartDate, transaction.requestEndDate)
        let waitFirstByte = ms(transaction.requestEndDate, transaction.responseStartDate)
        let download = ms(transaction.responseStartDate, transaction.responseEndDate)
        let total = Int(metrics.taskInterval.duration * 1000)
        let timing = NetworkTiming(
            dnsMs: dns >= 0 ? dns : nil,
            connectMs: connect >= 0 ? connect : nil,
            tlsMs: tls >= 0 ? tls : nil,
            uploadMs: upload >= 0 ? upload : nil,
            waitFirstByteMs: waitFirstByte >= 0 ? waitFirstByte : nil,
            downloadMs: download >= 0 ? download : nil,
            totalMs: total,
            reused: transaction.isReusedConnection,
            sentBytes: Int(transaction.countOfRequestBodyBytesSent)
        )
        captured.withLock { $0 = timing }
        logger.info(
            "metrics \(self.label, privacy: .public) reused=\(transaction.isReusedConnection, privacy: .public) protocol=\(transaction.networkProtocolName ?? "nil", privacy: .public) dnsMs=\(dns, privacy: .public) connectMs=\(connect, privacy: .public) tlsMs=\(tls, privacy: .public) uploadMs=\(upload, privacy: .public) waitFirstByteMs=\(waitFirstByte, privacy: .public) downloadMs=\(download, privacy: .public) totalMs=\(total, privacy: .public) sentBytes=\(transaction.countOfRequestBodyBytesSent, privacy: .public)"
        )
    }
}

// MARK: - 响应结构（只解需要的字段）

/// 流式响应的一个 chunk（只解需要的字段）。
/// 不标 private：单元测试直接解码 usage chunk。
nonisolated struct ChatCompletionChunk: Decodable {
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

    /// 流式最后一个 chunk 返回（stream_options.include_usage），缓存命中和思考 token 已真机确认会返回；
    /// 字段仍保持可选，缺了只是卡片不显示对应一列。
    struct Usage: Decodable {
        struct CompletionDetails: Decodable {
            let reasoningTokens: Int?

            enum CodingKeys: String, CodingKey {
                case reasoningTokens = "reasoning_tokens"
            }
        }

        let promptTokens: Int?
        let completionTokens: Int?
        let promptCacheHitTokens: Int?
        let completionTokensDetails: CompletionDetails?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case promptCacheHitTokens = "prompt_cache_hit_tokens"
            case completionTokensDetails = "completion_tokens_details"
        }

        var tokenUsage: TokenUsage {
            TokenUsage(
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                reasoningTokens: completionTokensDetails?.reasoningTokens,
                cacheHitTokens: promptCacheHitTokens
            )
        }
    }

    let choices: [Choice]
    /// 只在带 stream_options.include_usage 的最后一个 chunk 里出现（此时 choices 为空）。
    let usage: Usage?
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
