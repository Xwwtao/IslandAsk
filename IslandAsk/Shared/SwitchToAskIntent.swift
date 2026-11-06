//
//  SwitchToAskIntent.swift
//  IslandAsk
//
//  灵动岛收藏后的「改为提问」按钮（M-C1，SPEC 第 6.3 节）：用同一张截图和转录文字、强制 intent = ask 重跑快速档。
//  放在 Shared/，两个 target 都需要这个类型：widget 用来渲染按钮，系统在主 App 进程执行 perform()。
//

import AppIntents
import Foundation

#if !WIDGET_EXTENSION
import os
#endif

struct SwitchToAskIntent: LiveActivityIntent {

    static let title: LocalizedStringResource = "改为提问"

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
        logger.info("SwitchToAskIntent perform start session=\(sessionID, privacy: .public)")
        // 等快速档跑完再返回：perform 期间系统给的执行时间也算在保活里。
        // TODO: 核对官方文档：LiveActivityIntent 在 App 已无音频会话时，perform 能得到多少后台执行时间。
        await SessionCoordinator.shared.switchToAsk(sessionID: sessionID)
        logger.info("SwitchToAskIntent perform finished session=\(sessionID, privacy: .public)")
        #endif
        return .result()
    }
}
