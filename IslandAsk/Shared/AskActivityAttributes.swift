//
//  AskActivityAttributes.swift
//  IslandAsk
//
//  Live Activity 的共享数据结构。
//  放在 Shared/，同时属于 IslandAsk 和 IslandAskWidget 两个 target；字段按 SPEC 第 6.10 节定义。
//

import ActivityKit
import Foundation

/// 一次「对屏幕提问」会话的 Live Activity。
/// 固定不变的属性放在这里，随时间变化的状态放在 ContentState。
nonisolated struct AskActivityAttributes: ActivityAttributes {

    /// 会变化的状态。M0 只用到 phase 和 startedAt，其余字段先按 SPEC 定义好，M1/M2 直接使用。
    nonisolated struct ContentState: Codable, Hashable {

        nonisolated enum Phase: String, Codable {
            case listening
            case thinking
            case answered
            case failed
        }

        /// M-C1：这次按键是提问还是收藏，决定 thinking / answered 的展示。nil 按 ask。
        nonisolated enum Kind: String, Codable {
            case ask
            case collect
        }

        var phase: Phase
        var transcriptTail: String
        var summary: String?
        var errorMessage: String?
        var startedAt: Date
        /// M4：failed 态第二行的下一步提示；nil 时 widget 显示默认的「按操作按钮再试一次」。
        /// 可选且有默认值：旧版本推送的 state 解码不受影响，现有的 memberwise init 调用也不用改。
        var errorHint: String? = nil
        /// M4：answered 态点过「复制」后为 true，按钮显示对勾。可选，理由同 errorHint。
        var answerCopied: Bool? = nil
        /// M-C1 新增，全部可选，兼容旧的 Activity（SPEC 6.10）。
        var kind: Kind? = nil
        /// collect 时的卡片标题，最多 20 字。
        var cardTitle: String? = nil
        /// ask 回答后是否已点「收藏」。
        var isSaved: Bool? = nil
        /// 转录文字不为空时为 true，控制「改为提问」按钮。
        var canSwitchToAsk: Bool? = nil

        var isCollect: Bool { kind == .collect }
    }

    /// 会话 ID，与 App Group 容器 sessions/<sessionID>.png、<sessionID>.m4a 对应。
    var sessionID: String
}

// MARK: - 深链（SPEC 第 6.10 节：点击灵动岛跳到 islandask://session/<sessionID>）

nonisolated extension AskActivityAttributes {

    static let urlScheme = "islandask"
    static let sessionHost = "session"
    /// M-C1：islandask://card/<id>，供链接卡片和 Spotlight 使用（按键卡片与会话同 id）。
    static let cardHost = "card"

    static func sessionURL(sessionID: String) -> URL {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = sessionHost
        components.path = "/\(sessionID)"
        return components.url ?? URL(string: "\(urlScheme)://\(sessionHost)")!
    }

    /// 解析 islandask://session/<uuid> 和 islandask://card/<uuid>；不是本 App 的链接时返回 nil。
    static func sessionID(from url: URL) -> UUID? {
        guard url.scheme?.lowercased() == urlScheme,
              let host = url.host()?.lowercased(),
              host == sessionHost || host == cardHost else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
}
