//
//  ScreenshotStore.swift
//  IslandAsk
//
//  截图存储：App Group 容器的 sessions/<sessionID>.png（SPEC 第 6.8 / 第 4 节第 4 步）。
//  录音 m4a 也放在同一目录。数据库里只存相对容器的路径（relativePath），用 url(forRelativePath:) 还原。
//  性能优化：按键时仍原样写 PNG（不在启动灵动岛前编码），会话结束后由 SessionCoordinator+Storage 在后台转成
//  sessions/<sessionID>.heic（全尺寸，体积约为 PNG 的一成到两成），转好后改库里的路径再删 PNG。
//  读截图的地方（缩略图、上传压缩、OCR、大图）都按路径用 ImageIO / Vision / UIImage 读，两种格式都能读。
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

    static let sessionsDirectoryName = "sessions"

    /// 会话产物目录：<App Group 容器>/sessions/。调用方负责创建，这里保证存在。
    static func sessionsDirectory() throws -> URL {
        let directory = try AppGroup.containerURL()
            .appendingPathComponent(sessionsDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 存进数据库的截图路径（相对 App Group 容器）。
    static func relativePath(for url: URL) -> String {
        "\(sessionsDirectoryName)/\(url.lastPathComponent)"
    }

    static func url(forRelativePath path: String) -> URL? {
        try? AppGroup.containerURL().appendingPathComponent(path)
    }

    /// 设置页显示用：sessions 目录（截图 + 录音）在磁盘上的占用字节数。读不到返回 nil。
    @concurrent
    static func sessionsDirectoryByteCount() async -> Int64? {
        guard let directory = try? sessionsDirectory() else { return nil }
        return allocatedByteCount(in: directory)
    }

    /// FileManager.DirectoryEnumerator 不能在 async 上下文里迭代，单独放一个同步函数。
    private static func allocatedByteCount(in directory: URL) -> Int64? {
        guard let enumerator = FileManager.default.enumerator(
                  at: directory,
                  includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
              ) else { return nil }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0
            total += Int64(size)
        }
        return total
    }

    /// 删除会话时一并删除截图和录音（历史列表左滑删除）。
    static func removeArtifacts(sessionID: UUID) {
        let logger = makeLogger()
        guard let directory = try? sessionsDirectory() else { return }
        // 截图、录音，以及 M-C2 补充的链接封面图和网站图标。
        let fileNames = ["\(sessionID.uuidString).png", "\(sessionID.uuidString).heic", "\(sessionID.uuidString).m4a"]
            + [LinkImageStore.Kind.cover, .icon].map { LinkImageStore.fileName(cardID: sessionID, kind: $0) }
        for fileName in fileNames {
            let url = directory.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                logger.info("artifact removed session=\(sessionID.uuidString, privacy: .public) file=\(fileName, privacy: .public)")
            } catch {
                logger.error(
                    "artifact remove failed session=\(sessionID.uuidString, privacy: .public) file=\(fileName, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
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

    /// 发给大模型前的压缩（SPEC 第 6.8 节；M4 耗时优化把长边从 1536 降到 1280，减少图片 token）：长边缩到 1280 px（小图不放大），转 JPEG（质量 0.75）。
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

    // MARK: - 转 HEIC（性能优化：存储）

    static func heicFileURL(sessionID: UUID) throws -> URL {
        try sessionsDirectory()
            .appendingPathComponent(sessionID.uuidString)
            .appendingPathExtension("heic")
    }

    static func isPNGPath(_ relativePath: String) -> Bool {
        relativePath.lowercased().hasSuffix(".png")
    }

    enum HEICConversion: Equatable {
        /// 写好了 HEIC 文件；原 PNG 还在，由调用方改库成功后再删。
        case converted(url: URL, originalBytes: Int, heicBytes: Int)
        /// HEIC 不比原图小（极少见，比如纯色小图）：不转，保留 PNG。
        case notSmaller
        /// 本机不支持 HEIC 编码（模拟器、旧设备）：整轮停止。
        case encoderUnavailable
        case failed
    }

    /// 把 PNG 截图转成同尺寸 HEIC。只写新文件，不动原文件、不碰数据库。调用方应在主线程之外执行。
    static func convertToHEIC(pngURL: URL, sessionID: UUID) -> HEICConversion {
        let logger = makeLogger()
        guard let source = CGImageSourceCreateWithURL(pngURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            logger.error("heic convert: open source failed session=\(sessionID.uuidString, privacy: .public)")
            return .failed
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            logger.error("heic convert: encoder unavailable session=\(sessionID.uuidString, privacy: .public)")
            return .encoderUnavailable
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: heicQuality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            logger.error("heic convert: finalize failed session=\(sessionID.uuidString, privacy: .public)")
            return .failed
        }
        let heic = output as Data
        let originalBytes = (try? pngURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard originalBytes == 0 || heic.count < originalBytes else {
            logger.info(
                "heic convert skipped: not smaller session=\(sessionID.uuidString, privacy: .public) png=\(originalBytes, privacy: .public) heic=\(heic.count, privacy: .public)"
            )
            return .notSmaller
        }
        do {
            let url = try heicFileURL(sessionID: sessionID)
            try heic.write(to: url, options: .atomic)
            return .converted(url: url, originalBytes: originalBytes, heicBytes: heic.count)
        } catch {
            logger.error(
                "heic convert: write failed session=\(sessionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return .failed
        }
    }

    /// 截图里多是文字，0.8 放大看也没有明显的压缩痕迹，OCR 和发给模型的 1280px JPEG 不受影响。
    private static let heicQuality = 0.8

    /// 列表缩略图：按目标尺寸解码，不解整张原图。调用方应在主线程之外执行。
    static func thumbnail(url: URL, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    private static let uploadMaxPixelSize = 1280
    private static let uploadJPEGQuality = 0.75

    /// 检查 PNG 文件头，能透写就透写。
    private static func isPNG(_ data: Data) -> Bool {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= signature.count else { return false }
        return Array(data.prefix(signature.count)) == signature
    }
}

enum ScreenshotStoreError: LocalizedError {
    case invalidImageData
    case jpegEncodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidImageData:
            return "截图数据无法解码为图片"
        case .jpegEncodingFailed:
            return "截图压缩失败"
        }
    }
}
