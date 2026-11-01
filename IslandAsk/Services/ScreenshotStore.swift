//
//  ScreenshotStore.swift
//  IslandAsk
//
//  M0 版截图存储：先存 App 自己的 Documents/sessions/（暂时没有 App Group）。
//  M2/M3 开启 App Group 后把路径切到 group 容器，对外接口不变（SPEC 第 6.8 / 第 4 节第 4 步）。
//

import AppIntents
import Foundation
import UIKit
import os

nonisolated enum ScreenshotStore {

    /// 这个类型的方法要在非隔离的 Intent perform 里调用，所以 logger 用局部创建。
    private static func makeLogger() -> Logger {
        Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
            category: "intent"
        )
    }

    /// 会话产物目录：Documents/sessions/。调用方负责创建，这里保证存在。
    static func sessionsDirectory() throws -> URL {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw ScreenshotStoreError.documentsDirectoryUnavailable
        }
        let directory = documents.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func imageFileURL(sessionID: UUID) throws -> URL {
        try sessionsDirectory()
            .appendingPathComponent(sessionID.uuidString)
            .appendingPathExtension("png")
    }

    /// 保存快捷指令传进来的截图；没有截图时返回 nil，调用方照常录音。
    /// 返回 nil 与抛错不同：没有截图是正常路径，解码失败/写入失败才算失败。
    static func save(_ screenshot: IntentFile?, sessionID: UUID) throws -> URL? {
        let logger = makeLogger()
        guard let screenshot else {
            logger.info("no screenshot provided session=\(sessionID.uuidString, privacy: .public)")
            return nil
        }

        let data = screenshot.data
        guard !data.isEmpty else {
            logger.error("screenshot data is empty session=\(sessionID.uuidString, privacy: .public)")
            throw ScreenshotStoreError.invalidImageData
        }

        let url = try imageFileURL(sessionID: sessionID)

        // 快捷指令的「截屏」输出通常已经是 PNG：直接落盘，跳过 UIImage 解码 + PNG 重新编码，
        // 避免大截图在启动 Live Activity 之前占用上百毫秒。
        if isPNG(data) {
            try data.write(to: url, options: .atomic)
            logger.info(
                "screenshot saved (passthrough png) session=\(sessionID.uuidString, privacy: .public) bytes=\(data.count, privacy: .public)"
            )
            return url
        }

        guard let image = UIImage(data: data), let pngData = image.pngData() else {
            logger.error(
                "screenshot decode failed session=\(sessionID.uuidString, privacy: .public) bytes=\(data.count, privacy: .public)"
            )
            throw ScreenshotStoreError.invalidImageData
        }
        try pngData.write(to: url, options: .atomic)
        logger.info("screenshot saved (re-encoded png) session=\(sessionID.uuidString, privacy: .public) bytes=\(pngData.count, privacy: .public)")
        return url
    }

    /// 检查 PNG 文件头，能透写就透写。
    private static func isPNG(_ data: Data) -> Bool {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= signature.count else { return false }
        return Array(data.prefix(signature.count)) == signature
    }
}

enum ScreenshotStoreError: LocalizedError {
    case documentsDirectoryUnavailable
    case invalidImageData

    var errorDescription: String? {
        switch self {
        case .documentsDirectoryUnavailable:
            return "找不到 App 的 Documents 目录"
        case .invalidImageData:
            return "截图数据无法解码为图片"
        }
    }
}
