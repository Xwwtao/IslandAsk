//
//  AppGroup.swift
//  IslandAsk
//
//  App Group 容器（SPEC 第 5 节）：截图、录音、SwiftData 数据库都放这里，方便以后 widget 读取。
//  两个 target 都要在 Signing & Capabilities 里开启同一个 App Group。
//

import Foundation
import os

nonisolated enum AppGroup {

    static let identifier = "group.com.wentao.islandask"

    private static func makeLogger() -> Logger {
        Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
            category: "coordinator"
        )
    }

    /// App Group 容器根目录。没配好 entitlement 时拿不到：打 error 日志并回退到 Documents，
    /// 让 App 仍可用（真机排查时看日志里的 "app group container unavailable"）。
    static func containerURL() throws -> URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return url
        }
        makeLogger().error(
            "app group container unavailable id=\(identifier, privacy: .public); falling back to Documents"
        )
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw ScreenshotStoreError.documentsDirectoryUnavailable
        }
        return documents
    }

    static var isContainerAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) != nil
    }
}
