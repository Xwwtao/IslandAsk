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
    /// App 内追问记录（不含首轮问题和回答，那两项在 transcript / answer 里）。
    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.session)
    var messages: [ChatMessage] = []

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

    /// 只给 SessionCoordinator 调用：转为 failed 并写入提示文案。
    func markFailed(_ failure: UserFacingFailure) {
        statusValue = .failed
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

    /// 发给大模型的上下文：首轮问题 + 首轮回答 + 已有追问（SPEC 6.12：追问沿用同一张截图和上下文）。
    var conversationTurns: [LLMTurn] {
        var turns: [LLMTurn] = []
        let question = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !question.isEmpty {
            turns.append(LLMTurn(role: .user, content: question))
        }
        if let firstAnswer = deepAnswer ?? answer, !firstAnswer.isEmpty {
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
