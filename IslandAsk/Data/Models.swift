//
//  Models.swift
//  IslandAsk
//
//  SwiftData 模型（SPEC 第 6.11 节）。只有 SessionCoordinator 写入，UI 用 @Query 读。
//
//  与 SPEC 的偏差：
//  - 多一个 errorMessage：会话页显示失败原因、决定是否显示「重新提问」。
//  - screenshotPath 存相对 App Group 容器的路径（sessions/<id>.png），容器绝对路径在重装后会变。
//  - ChatMessage 有反向关系 session；messages 不保证顺序，显示时用 sortedMessages。
//  - M-C1：Card 比 SPEC 6.11 多一个 intent（ask / collect / both），详情页靠它决定显示问答还是收藏摘要。
//

import Foundation
import SwiftData

@Model
final class AskSession {

    enum Status: String {
        case listening
        case thinking
        case answered
        case failed
    }

    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var screenshotPath: String?
    var transcript: String
    var summary: String?
    var answer: String?
    /// listening / thinking / answered / failed，与 Status 一一对应。
    var status: String
    var errorMessage: String?
    /// M4：失败的补充说明（会话页显示）。
    var errorDetail: String?
    /// M4：失败卡片上的操作，UserFacingFailure.Action 的 rawValue（appSettings / systemSettings）。
    var errorAction: String?
    /// M4：截图的 Vision 文字识别结果，随截图一起发给大模型；深度回答、追问、重问复用。
    var ocrText: String?
    /// 会话页里用深度思考生成的长回答（流式）。灵动岛只用快速档的 summary / answer。
    var deepAnswer: String?
    var deepReasoning: String?
    var deepError: String?
    /// 快速模型判断是否需要深度回答；nil（旧会话 / 模型没返回）按需要处理。
    var needsDeepAnswer: Bool?
    /// M4：各环节耗时（SessionTiming 的 JSON），会话页耗时卡片显示。旧会话为 nil。
    var timingData: Data?
    /// 每次大模型调用的 token 用量（[TokenUsageRecord] 的 JSON），会话页 Token 卡片显示。旧会话为 nil。
    var tokenUsageData: Data?
    /// App 内追问记录（不含首轮问题和回答，那两项在 transcript / answer 里）。
    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.session)
    var messages: [ChatMessage] = []
    /// M-C1：这次按键产生的卡片（同 id）。关系的删除规则写在 Card.session 上。
    var card: Card?

    init(id: UUID, createdAt: Date = .now, screenshotPath: String?) {
        self.id = id
        self.createdAt = createdAt
        self.screenshotPath = screenshotPath
        self.transcript = ""
        self.status = Status.listening.rawValue
    }

    var statusValue: Status {
        get { Status(rawValue: status) ?? .failed }
        set { status = newValue.rawValue }
    }

    var errorActionValue: UserFacingFailure.Action? {
        errorAction.flatMap(UserFacingFailure.Action.init(rawValue:))
    }

    /// 只给 SessionCoordinator 调用：转为 failed 并写入提示文案。卡片同时记为整理失败（M-C1），可在收藏库里重新整理。
    func markFailed(_ failure: UserFacingFailure) {
        statusValue = .failed
        card?.organizeStatus = Card.OrganizeStatus.failed.rawValue
        errorMessage = failure.message
        errorDetail = failure.detail
        errorAction = failure.action?.rawValue
    }

    func clearFailure() {
        errorMessage = nil
        errorDetail = nil
        errorAction = nil
    }

    var sortedMessages: [ChatMessage] {
        messages.sorted { $0.createdAt < $1.createdAt }
    }

    var screenshotURL: URL? {
        screenshotPath.flatMap { ScreenshotStore.url(forRelativePath: $0) }
    }

    var timing: SessionTiming? {
        SessionTiming.decode(timingData)
    }

    var tokenUsages: [TokenUsageRecord] {
        TokenUsageRecord.decodeList(tokenUsageData)
    }

    /// 发给大模型的首轮问题：没说话但已改为提问（M-C1「改为提问」）时，用固定的问法代替空转录。
    var effectiveQuestion: String {
        let question = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return question.isEmpty ? OpenAICompatibleProvider.implicitQuestion : question
    }

    /// 发给大模型的上下文：首轮问题 + 首轮回答 + 已有追问（SPEC 6.12：追问沿用同一张截图和上下文）。
    var conversationTurns: [LLMTurn] {
        var turns: [LLMTurn] = []
        let firstAnswer = deepAnswer ?? answer
        // 没说话的会话只要有回答，也补上默认问法，保证上下文以 user 开头。
        if firstAnswer?.isEmpty == false || !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            turns.append(LLMTurn(role: .user, content: effectiveQuestion))
        }
        if let firstAnswer, !firstAnswer.isEmpty {
            turns.append(LLMTurn(role: .assistant, content: firstAnswer))
        }
        turns += sortedMessages.compactMap(\.turn)
        return turns
    }
}

@Model
final class ChatMessage {
    var role: String
    var content: String
    var createdAt: Date
    /// assistant 消息的思考过程（深度思考模式）。
    var reasoning: String?
    var session: AskSession?

    init(role: LLMTurn.Role, content: String, reasoning: String? = nil, createdAt: Date = .now) {
        self.role = role.rawValue
        self.content = content
        self.reasoning = reasoning
        self.createdAt = createdAt
    }

    var isUser: Bool { role == LLMTurn.Role.user.rawValue }

    /// @Model 不是 Sendable，传给 @concurrent 的 LLMProvider 前在主线程上转成值类型。
    var turn: LLMTurn? {
        LLMTurn.Role(rawValue: role).map { LLMTurn(role: $0, content: content) }
    }
}

// MARK: - 卡片（M-C1，SPEC 第 6.11 节）

/// 收藏库里唯一的「东西」。按键产生的卡片与 AskSession 同 id；分享得到的卡片（M-C2）没有会话。
@Model
final class Card {

    enum Origin: String {
        case press
        case share
    }

    enum OrganizeStatus: String {
        case pending
        case done
        case failed
    }

    @Attribute(.unique) var id: UUID
    var createdAt: Date
    /// press（按键）/ share（分享，M-C2）。
    var origin: String
    /// nil 按 false：提问产生的卡片默认不进收藏。
    var isSaved: Bool?
    /// pending / done / failed。
    var organizeStatus: String?
    /// ask / collect / both（LLMIntent 的 rawValue）；nil 按 ask。
    var intent: String?
    var title: String?
    var summary: String?
    /// 与 CardFields.type 相同的取值（CardType）。
    var cardType: String?
    var tags: [String]?
    /// [KeyInfo] 的 JSON。
    var keyInfoData: Data?
    /// 收藏时的语音附注，或分享时填写的文字。
    var note: String?
    var translation: String?
    /// 与 AskSession 指向同一个文件（相对 App Group 容器的路径）。
    var screenshotPath: String?
    var sourceURL: String?
    /// shared / guessed / confirmed。
    var sourceURLState: String?
    var sourcePlatform: String?
    var sourceTitle: String?
    /// 删除卡片时级联删除会话；会话的追问再由 AskSession.messages 级联删除。
    @Relationship(deleteRule: .cascade, inverse: \AskSession.card)
    var session: AskSession?

    init(id: UUID, createdAt: Date = .now, origin: Origin, screenshotPath: String?) {
        self.id = id
        self.createdAt = createdAt
        self.origin = origin.rawValue
        self.screenshotPath = screenshotPath
        self.organizeStatus = OrganizeStatus.pending.rawValue
    }

    var isSavedValue: Bool { isSaved ?? false }

    var organizeStatusValue: OrganizeStatus {
        organizeStatus.flatMap(OrganizeStatus.init(rawValue:)) ?? .done
    }

    var intentValue: LLMIntent {
        intent.flatMap(LLMIntent.init(rawValue:)) ?? .ask
    }

    var cardTypeValue: CardType {
        cardType.flatMap(CardType.init(rawValue:)) ?? .other
    }

    var keyInfo: [KeyInfo] {
        guard let keyInfoData else { return [] }
        return (try? JSONDecoder().decode([KeyInfo].self, from: keyInfoData)) ?? []
    }

    var screenshotURL: URL? {
        screenshotPath.flatMap { ScreenshotStore.url(forRelativePath: $0) }
    }

    /// 列表和灵动岛显示的标题：没有标题时用摘要，再没有用转录文字。
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let summary, !summary.isEmpty { return String(summary.prefix(Self.maxTitleLength)) }
        let transcript = session?.transcript.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !transcript.isEmpty { return String(transcript.prefix(Self.maxTitleLength)) }
        return "未命名卡片"
    }

    static let maxTitleLength = 20

    /// 已被删除（含已保存的删除）。List 删行动画期间 SwiftUI 还会用旧对象重算一次行的 body，
    /// 这时读任何持久化字段都会触发 SwiftData 断言、App 闪退，所以持有 Card 的视图先判断这个。
    /// modelContext / isDeleted 不是持久化字段，删除后读取是安全的。
    var isGone: Bool { isDeleted || modelContext == nil }
}

/// 卡片类型（SPEC 6.9 card.type 的取值）。
nonisolated enum CardType: String, CaseIterable, Identifiable, Sendable {
    case article
    case product
    case place
    case event
    case recipe
    case knowledge
    case media
    case chat
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .article: return "文章"
        case .product: return "商品"
        case .place: return "地点"
        case .event: return "活动"
        case .recipe: return "菜谱"
        case .knowledge: return "知识"
        case .media: return "影音"
        case .chat: return "聊天"
        case .other: return "其他"
        }
    }

    var systemImage: String {
        switch self {
        case .article: return "doc.text"
        case .product: return "bag"
        case .place: return "mappin.and.ellipse"
        case .event: return "calendar"
        case .recipe: return "fork.knife"
        case .knowledge: return "lightbulb"
        case .media: return "play.rectangle"
        case .chat: return "bubble.left.and.bubble.right"
        case .other: return "square.grid.2x2"
        }
    }
}
