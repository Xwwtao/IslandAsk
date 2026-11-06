//
//  TokenUsage.swift
//  IslandAsk
//
//  每次大模型调用的 token 用量：会话页 Token 卡片显示，估算费用、对比快速档和深度档用。
//  存在 AskSession.tokenUsageData（[TokenUsageRecord] 的 JSON），只有 SessionCoordinator 追加。
//  被取消的提前请求拿不到 usage，不在这里，卡片另外按 SessionTiming 里的次数提示。
//

import Foundation

/// 一次调用的用量，字段都可选：服务商不返回的就不显示。
nonisolated struct TokenUsage: Codable, Sendable, Equatable {
    var promptTokens: Int?
    var completionTokens: Int?
    /// 输出里属于思考过程的部分（已包含在 completionTokens 里）。
    var reasoningTokens: Int?
    /// 输入里命中服务端缓存的部分（已包含在 promptTokens 里）。
    var cacheHitTokens: Int?

    var totalTokens: Int {
        (promptTokens ?? 0) + (completionTokens ?? 0)
    }
}

nonisolated struct TokenUsageRecord: Codable, Sendable, Equatable {

    enum Kind: String, Codable, Sendable {
        /// 灵动岛快速回答（含提前请求命中的那一次）。
        case quick
        /// 会话页「重新提问」（快速档）。
        case retry
        /// 会话页深度回答。
        case deep
        /// 会话页追问（深度档）。
        case followUp

        var displayName: String {
            switch self {
            case .quick: return "快速回答"
            case .retry: return "重新提问"
            case .deep: return "深度回答"
            case .followUp: return "追问"
            }
        }
    }

    var kind: Kind
    var usage: TokenUsage
    var model: String
    var createdAt: Date

    static func decodeList(_ data: Data?) -> [TokenUsageRecord] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([TokenUsageRecord].self, from: data)) ?? []
    }

    static func encodeList(_ records: [TokenUsageRecord]) -> Data? {
        try? JSONEncoder().encode(records)
    }

    /// 复制用的一行文本，和日志风格一致。
    var logLine: String {
        var parts = ["kind=\(kind.rawValue)", "model=\(model)"]
        if let prompt = usage.promptTokens { parts.append("prompt=\(prompt)") }
        if let cached = usage.cacheHitTokens { parts.append("cacheHit=\(cached)") }
        if let completion = usage.completionTokens { parts.append("completion=\(completion)") }
        if let reasoning = usage.reasoningTokens { parts.append("reasoning=\(reasoning)") }
        parts.append("total=\(usage.totalTokens)")
        return parts.joined(separator: " ")
    }
}

extension Array where Element == TokenUsageRecord {
    nonisolated var totalTokens: Int {
        reduce(0) { $0 + $1.usage.totalTokens }
    }
}
