//
//  ScreenshotStore.swift
//  IslandAsk
//
//  M0 版截图存储：先存 App 自己的 Documents/sessions/（暂时没有 App Group）。
//  M2/M3 开启 App Group 后把路径切到 group 容器，对外接口不变（SPEC 第 6.8 / 第 4 节第 4 步）。
//

import AppIntents
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
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

    /// 发给大模型前的压缩（SPEC 第 6.8 节）：长边缩到 1536 px（小图不放大），转 JPEG（质量 0.75）。
    /// 用 ImageIO 直接按目标尺寸解码，不把整张原图解成 UIImage，省内存；调用方应在主线程之外执行。
    static func jpegForUpload(url: URL, sessionID: UUID) throws -> Data {
        let logger = makeLogger()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            logger.error("upload jpeg: open source failed session=\(sessionID.uuidString, privacy: .public)")
            throw ScreenshotStoreError.invalidImageData
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: uploadMaxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            logger.error("upload jpeg: downscale failed session=\(sessionID.uuidString, privacy: .public)")
            throw ScreenshotStoreError.invalidImageData
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            logger.error("upload jpeg: create destination failed session=\(sessionID.uuidString, privacy: .public)")
            throw ScreenshotStoreError.jpegEncodingFailed
        }
        let encodeOptions: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: uploadJPEGQuality]
        CGImageDestinationAddImage(destination, image, encodeOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            logger.error("upload jpeg: finalize failed session=\(sessionID.uuidString, privacy: .public)")
            throw ScreenshotStoreError.jpegEncodingFailed
        }

        let data = output as Data
        logger.info(
            "upload jpeg ready session=\(sessionID.uuidString, privacy: .public) size=\(image.width, privacy: .public)x\(image.height, privacy: .public) bytes=\(data.count, privacy: .public)"
        )
        return data
    }

    private static let uploadMaxPixelSize = 1536
    private static let uploadJPEGQuality = 0.75

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
    case jpegEncodingFailed

    var errorDescription: String? {
        switch self {
        case .documentsDirectoryUnavailable:
            return "找不到 App 的 Documents 目录"
        case .invalidImageData:
            return "截图数据无法解码为图片"
        case .jpegEncodingFailed:
            return "截图压缩失败"
        }
    }
}
