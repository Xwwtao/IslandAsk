//
//  DismissAskIntent.swift
//  IslandAsk
//
//  灵动岛 answered / failed 状态右上角的「关闭」按钮：立即结束这个 Live Activity（SPEC 第 6.3 节）。
//  放在 Shared/，两个 target 都需要这个类型：widget 用来渲染按钮，系统在主 App 进程执行 perform()。
//

import AppIntents
import Foundation

#if !WIDGET_EXTENSION
import os
#endif

struct DismissAskIntent: LiveActivityIntent {

    static let title: LocalizedStringResource = "关闭回答"

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
        logger.info("DismissAskIntent perform start session=\(sessionID, privacy: .public)")
        await SessionCoordinator.shared.dismiss(sessionID: sessionID)
        logger.info("DismissAskIntent perform finished session=\(sessionID, privacy: .public)")
        #endif
        return .result()
    }
}
