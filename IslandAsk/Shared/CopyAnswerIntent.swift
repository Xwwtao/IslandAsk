//
//  CopyAnswerIntent.swift
//  IslandAsk
//
//  灵动岛 answered 状态的「复制」按钮：把完整回答复制到剪贴板，不用打开 App（M4）。
//  放在 Shared/，两个 target 都需要这个类型：widget 用来渲染按钮，系统在主 App 进程执行 perform()。
//

import AppIntents
import Foundation

#if !WIDGET_EXTENSION
import os
#endif

struct CopyAnswerIntent: LiveActivityIntent {

    static let title: LocalizedStringResource = "复制回答"

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
        logger.info("CopyAnswerIntent perform start session=\(sessionID, privacy: .public)")
        await SessionCoordinator.shared.copyAnswer(sessionID: sessionID)
        logger.info("CopyAnswerIntent perform finished session=\(sessionID, privacy: .public)")
        #endif
        return .result()
    }
}
