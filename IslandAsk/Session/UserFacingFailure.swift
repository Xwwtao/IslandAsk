//
//  UserFacingFailure.swift
//  IslandAsk
//
//  失败提示文案（M4）：把各种错误整理成灵动岛的「短原因 + 下一步」，以及会话页的补充说明和操作按钮。
//  原始错误码只进日志，不给用户看。由 SessionCoordinator 写进 AskSession / ContentState。
//

import Foundation

nonisolated struct UserFacingFailure: Sendable {

    /// 会话页失败卡片上的操作按钮。
    enum Action: String, Sendable {
        /// App 内设置页（API Key、地址、模型）。
        case appSettings
        /// 系统设置里本 App 的页面（麦克风、语音识别、实时活动）。
        case systemSettings
    }

    /// 灵动岛第一行 / 会话页标题，控制在 12 字左右。
    let message: String
    /// 灵动岛第二行：下一步做什么。
    let islandHint: String
    /// 会话页补充说明。
    let detail: String?
    let action: Action?

    static let retryHint = "按操作按钮再试一次"
    static let openAppHint = "打开 App 查看"

    static let noSpeech = UserFacingFailure(
        message: "没听到",
        islandHint: "按下操作按钮后直接说出问题",
        detail: "没有识别到说话内容。离麦克风近一点，或在设置里调整静音阈值。",
        action: nil
    )

    static let cancelled = UserFacingFailure(
        message: "已取消",
        islandHint: retryHint,
        detail: nil,
        action: nil
    )

    static let interrupted = UserFacingFailure(
        message: "录音被中断",
        islandHint: retryHint,
        detail: "录音时被来电、Siri 或其他 App 打断了。",
        action: nil
    )

    static let microphoneDenied = UserFacingFailure(
        message: "没有麦克风权限",
        islandHint: "打开 App 完成设置",
        detail: "到系统设置里允许 IslandAsk 使用麦克风。",
        action: .systemSettings
    )

    static let speechDenied = UserFacingFailure(
        message: "没有语音识别权限",
        islandHint: "打开 App 完成设置",
        detail: "到系统设置里允许 IslandAsk 使用语音识别。",
        action: .systemSettings
    )

    /// 快速档（灵动岛）失败。后台任务过期时请求被取消，对用户来说就是超时。
    static func answerFailure(for error: any Error) -> UserFacingFailure {
        var llmError = error as? LLMError
        if error is CancellationError {
            llmError = .timeout
        }
        if let current = llmError, case .cancelled = current {
            llmError = .timeout
        }
        guard let llmError else {
            return UserFacingFailure(
                message: "回答失败",
                islandHint: retryHint,
                detail: error.localizedDescription,
                action: nil
            )
        }
        // 余额不足重试也没用，但要去大模型平台充值，不是改 App 设置。
        let needsUserAction: Bool
        if case .http(status: 402) = llmError {
            needsUserAction = true
        } else {
            needsUserAction = llmError.needsSettings
        }
        return UserFacingFailure(
            message: llmError.errorDescription ?? "回答失败",
            islandHint: needsUserAction ? openAppHint : retryHint,
            detail: llmError.recoverySuggestion,
            action: llmError.needsSettings ? .appSettings : nil
        )
    }
}
