//
//  StopAskIntent.swift
//  IslandAsk
//
//  灵动岛展开态的「停止」按钮。
//  放在 Shared/，两个 target 都需要这个类型：widget 用来渲染按钮，系统在主 App 进程执行 perform()。
//

import AppIntents
import Foundation

#if !WIDGET_EXTENSION
import os
#endif

struct StopAskIntent: LiveActivityIntent {

    static let title: LocalizedStringResource = "结束提问"

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
        logger.info("StopAskIntent perform start session=\(sessionID, privacy: .public)")
        await SessionCoordinator.shared.stopListening(sessionID: sessionID)
        logger.info("StopAskIntent perform finished session=\(sessionID, privacy: .public)")
        #endif
        return .result()
    }
}
