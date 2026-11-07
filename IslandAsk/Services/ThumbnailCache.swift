//
//  ThumbnailCache.swift
//  IslandAsk
//
//  截图、封面图、网站图标的缩略图内存缓存。列表滚回来、从详情页返回时直接用解码好的图，
//  不再每次从磁盘按原图重新解码（全尺寸截图一张几 MB）。
//  键 = 文件路径 + 目标像素尺寸：截图从 PNG 转成 HEIC 后路径变了，自然用新键，不会显示旧图。
//  NSCache 线程安全，内存紧张时系统自动清掉。
//

import Foundation
import UIKit
import os

nonisolated final class ThumbnailCache: @unchecked Sendable {

    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        // 列表缩略图 48pt×64pt@3x 一张约 80KB（解码后），封面、详情页大图更大；按解码后字节数计成本。
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    private static func key(_ url: URL, maxPixelSize: Int) -> NSString {
        "\(url.path)|\(maxPixelSize)" as NSString
    }

    /// 只查缓存，不读盘：视图 body 里调用，命中就直接显示，滚动时不闪占位图。
    func cached(url: URL, maxPixelSize: Int) -> UIImage? {
        cache.object(forKey: Self.key(url, maxPixelSize: maxPixelSize))
    }

    /// 先查缓存，没有再在主线程之外解码并放进缓存。
    @concurrent
    func load(url: URL, maxPixelSize: Int) async -> UIImage? {
        let key = Self.key(url, maxPixelSize: maxPixelSize)
        if let hit = cache.object(forKey: key) { return hit }
        let state = PerformanceTrace.signposter.beginInterval("thumbnail.decode")
        let image = ScreenshotStore.thumbnail(url: url, maxPixelSize: maxPixelSize)
        PerformanceTrace.signposter.endInterval("thumbnail.decode", state)
        guard let image else { return nil }
        cache.setObject(image, forKey: key, cost: Self.cost(of: image))
        return image
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
