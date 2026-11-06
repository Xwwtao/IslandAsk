//
//  AskAboutScreenIntent.swift
//  IslandAsk
//
//  快捷指令 / Action Button 的入口 Intent。
//  只属于主 App target，保证 perform() 在主 App 进程内执行（SPEC 第 6.2 节）。
//

import AppIntents
import Foundation
import UniformTypeIdentifiers
import os

struct AskAboutScreenIntent: AppIntent, AudioRecordingIntent, LiveActivityIntent {

    static let title: LocalizedStringResource = "对屏幕提问"

    // 不打开 App、纯后台执行（SPEC 第 6.2 节要求「画面不跳转」）。
    // iOS 26 起 openAppWhenRun 已弃用，改用 supportedModes。
    static let supportedModes: IntentModes = .background

    // 为什么同时遵循 LiveActivityIntent：
    // ActivityKit 规定 App 在后台时不能调用 Activity.request，除非是在 LiveActivityIntent 的
    // perform() 里启动 Live Activity（Apple 文档：Activity.request(attributes:content:pushType:)
    // 的 Discussion、LiveActivityIntent 的 Overview）。否则会抛 "Target is not foreground"。
    // 而 AudioRecordingIntent 要求录音期间保持 Live Activity 活跃，两者必须配合使用。
    //
    // 注意：不要再把 supportedModes 改成 .foreground，否则会打开 App，违反「不跳转」。

    /// 快捷指令「截屏」动作的输出。没传截图时照常录音（SPEC 第 6.2 节）。
    @Parameter(title: "截图", supportedContentTypes: [.image])
    var screenshot: IntentFile?

    nonisolated func perform() async throws -> some IntentResult {
        let logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
            category: "intent"
        )
        let sessionID = UUID()
        let triggeredAt = ContinuousClock.now
        logger.info(
            "perform start session=\(sessionID.uuidString, privacy: .public) hasScreenshot=\(screenshot != nil, privacy: .public)"
        )

        do {
            let screenshotURL = try ScreenshotStore.save(screenshot, sessionID: sessionID)
            try await SessionCoordinator.shared.start(
                sessionID: sessionID,
                screenshotURL: screenshotURL,
                triggeredAt: triggeredAt
            )
            logger.info("perform succeeded session=\(sessionID.uuidString, privacy: .public)")
            return .result()
        } catch {
            let nsError = error as NSError
            logger.error(
                "perform failed session=\(sessionID.uuidString, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) error=\(nsError.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }
}
