//
//  SaveCardIntent.swift
//  IslandAsk
//
//  灵动岛提问回答后的「收藏」按钮（M-C1，SPEC 第 6.3 节）：把这次的卡片加入收藏，按钮变成不可点的「已收藏」。
//  放在 Shared/，两个 target 都需要这个类型：widget 用来渲染按钮，系统在主 App 进程执行 perform()。
//

import AppIntents
import Foundation

#if !WIDGET_EXTENSION
import os
#endif

struct SaveCardIntent: LiveActivityIntent {

    static let title: LocalizedStringResource = "收藏"

    @Parameter(title: "会话")
    var sessionID: String

    init() {}

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    nonisolated func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        let logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
            category: "intent"
        )
        logger.info("SaveCardIntent perform start session=\(sessionID, privacy: .public)")
        await SessionCoordinator.shared.saveCard(sessionID: sessionID)
        logger.info("SaveCardIntent perform finished session=\(sessionID, privacy: .public)")
        #endif
        return .result()
    }
}
