//
//  LinkImageStore.swift
//  IslandAsk
//
//  链接卡片的封面图和网站图标（M-C2 补充，SPEC 第 6.13 节）：下载、缩小、存进 App Group 的 sessions/ 目录，
//  和截图放在一起：sessions/<cardID>-cover.jpg、sessions/<cardID>-icon.png。数据库只存相对路径。
//  - 下载最多 3MB、8 秒，必须能被 ImageIO 解码（SVG 解不了，就当没有图标）。
//  - 封面长边缩到 600px 存 JPEG（质量 0.75）；图标缩到 128px 存 PNG（保留透明）。
//  - 删除卡片时由 ScreenshotStore.removeArtifacts 一起删。
//  只下载网站自己声明的图片（og:image、icon），不内置任何 App 的图标素材。日志 category：link。
//

import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

nonisolated enum LinkImageStore {

    enum Kind: String, Sendable {
        case cover
        case icon

        var fileSuffix: String {
            switch self {
            case .cover: return "-cover.jpg"
            case .icon: return "-icon.png"
            }
        }

        var maxPixelSize: Int {
            switch self {
            case .cover: return 600
            case .icon: return 128
            }
        }
    }

    static let maxDownloadBytes = 3 * 1024 * 1024
    static let downloadTimeout: TimeInterval = 8

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
        category: "link"
    )

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = downloadTimeout
        configuration.timeoutIntervalForResource = downloadTimeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    static func fileName(cardID: UUID, kind: Kind) -> String {
        cardID.uuidString + kind.fileSuffix
    }

    /// 下载并缩小，返回要写盘的数据；任何一步失败返回 nil（只记日志）。
    @concurrent
    /// maxPixelSize 为 nil 时按 kind 的尺寸；发给模型识图时传更大的值（M-C2 补充）。
    static func download(_ url: URL, kind: Kind, maxPixelSize: Int? = nil) async -> Data? {
        guard LinkMetadataFetcher.isFetchable(url) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(LinkMetadataFetcher.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("image/*,*/*;q=0.5", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                logger.notice(
                    "image download http error kind=\(kind.rawValue, privacy: .public) host=\(url.host() ?? "", privacy: .public) status=\((response as? HTTPURLResponse)?.statusCode ?? -1, privacy: .public)"
                )
                return nil
            }
            // expectedContentLength 未知时是 -1，只在明确超限时提前放弃。
            if http.expectedContentLength > Int64(maxDownloadBytes) {
                logger.notice("image download skipped: too large kind=\(kind.rawValue, privacy: .public) bytes=\(http.expectedContentLength, privacy: .public)")
                return nil
            }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxDownloadBytes {
                    logger.notice("image download aborted: too large kind=\(kind.rawValue, privacy: .public)")
                    return nil
                }
            }
            guard let output = downsample(data, kind: kind, maxPixelSize: maxPixelSize) else {
                logger.notice(
                    "image decode failed kind=\(kind.rawValue, privacy: .public) host=\(url.host() ?? "", privacy: .public) bytes=\(data.count, privacy: .public)"
                )
                return nil
            }
            logger.info(
                "image downloaded kind=\(kind.rawValue, privacy: .public) host=\(url.host() ?? "", privacy: .public) bytes=\(data.count, privacy: .public) storedBytes=\(output.count, privacy: .public)"
            )
            return output
        } catch {
            logger.notice(
                "image download failed kind=\(kind.rawValue, privacy: .public) host=\(url.host() ?? "", privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// 写进 sessions/ 目录，返回相对 App Group 容器的路径。
    static func save(_ data: Data, cardID: UUID, kind: Kind) throws -> String {
        let url = try ScreenshotStore.sessionsDirectory().appendingPathComponent(fileName(cardID: cardID, kind: kind))
        try data.write(to: url, options: .atomic)
        return ScreenshotStore.relativePath(for: url)
    }

    /// ImageIO 缩略图：长边不超过 kind.maxPixelSize，按 EXIF 方向转正。封面 JPEG，图标 PNG。
    static func downsample(_ data: Data, kind: Kind, maxPixelSize: Int? = nil) -> Data? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize ?? kind.maxPixelSize,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        // 1×1 的跟踪像素、过小的占位图不当封面。
        if kind == .cover, image.width < 80 || image.height < 80 { return nil }

        let output = NSMutableData()
        let type = (kind == .cover ? UTType.jpeg : UTType.png).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { return nil }
        let properties = (kind == .cover ? [kCGImageDestinationLossyCompressionQuality: 0.75] : [:]) as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
