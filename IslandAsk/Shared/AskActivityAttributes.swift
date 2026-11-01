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

        var phase: Phase
        var transcriptTail: String
        var summary: String?
        var errorMessage: String?
        var startedAt: Date
    }

    /// 会话 ID，与 Documents/sessions/<sessionID>.png、<sessionID>.m4a 对应。
    var sessionID: String
}
