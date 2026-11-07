//
//  SaveLinkIntent.swift
//  IslandAsk
//
//  链接收藏阶段 1（M-C2，SPEC 第 6.13 节）：快捷指令「在共享表单中显示」接收 URL 和文本，调用本 Intent。
//  只属于主 App target。流程：立即建卡落库 → 抓网页元数据 → 快速档整理 → 写回卡片 → 返回 dialog。
//  整个流程最多等约 15 秒；超时就先返回「已收藏，回到 App 后整理」，请求在后台继续跑，跑不完回前台再补。
//
//  与 SPEC 的偏差：SPEC 写的是 openAppWhenRun = false；iOS 26 起它已弃用，和 AskAboutScreenIntent 一样改用
//  supportedModes = .background（不打开 App）。
//

import AppIntents
import Foundation
import os

struct SaveLinkIntent: AppIntent {

    static let title: LocalizedStringResource = "收藏到 IslandAsk"
    static let description = IntentDescription("把分享的链接或文字存为收藏卡片，自动整理标题、摘要和标签。")

    static let supportedModes: IntentModes = .background

    @Parameter(title: "链接")
    var url: URL?

    @Parameter(title: "附注")
    var text: String?

    // TODO: 核对官方文档：后台 App Intent 的最长运行时间（快捷指令等待 dialog 的上限），真机看 15 秒的预算是否够、会不会被系统提前结束。
    nonisolated func perform() async throws -> some IntentResult & ProvidesDialog {
        let logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
            category: "intent"
        )
        let startedAt = ContinuousClock.now
        logger.info(
            "save link perform start hasURL=\(url != nil, privacy: .public) scheme=\(url?.scheme ?? "nil", privacy: .public) textChars=\(text?.count ?? 0, privacy: .public)"
        )
        let result = await SessionCoordinator.shared.saveSharedLink(url: url, text: text)
        let elapsedMs = SessionCoordinator.milliseconds(ContinuousClock.now - startedAt)
        switch result {
        case .empty:
            logger.notice("save link perform finished: empty input elapsedMs=\(elapsedMs, privacy: .public)")
            return .result(dialog: "没有收到链接或文字，未收藏。")
        case .saveFailed:
            logger.error("save link perform failed: database save error elapsedMs=\(elapsedMs, privacy: .public)")
            return .result(dialog: "收藏失败，请打开 IslandAsk 后再试。")
        case .organized(let title):
            logger.info("save link perform succeeded organized=true elapsedMs=\(elapsedMs, privacy: .public)")
            return .result(dialog: "已收藏：\(title)")
        case .savedPending(let title):
            logger.info("save link perform succeeded organized=false elapsedMs=\(elapsedMs, privacy: .public)")
            return .result(dialog: "已收藏：\(title)。回到 App 后整理。")
        }
    }
}
