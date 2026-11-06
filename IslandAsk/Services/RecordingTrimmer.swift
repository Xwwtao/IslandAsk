//
//  RecordingTrimmer.swift
//  IslandAsk
//
//  截掉录音末尾的静音（M4）：静音判定要等 1.5 秒以上才结束录音，点停止前也常有空白，回放时没用。
//  截取点 = 最后一次转录文字变化时已写入的录音时长 + 余量。文字变化比实际说话晚一点，所以不会截到最后一个字。
//  先导出到临时文件，成功后再替换原文件；任何一步失败都保留原录音。
//

import AVFoundation
import Foundation
import os

nonisolated enum RecordingTrimmer {

    /// 最后一次文字变化之后再保留多久。
    static let tailPadding: Double = 0.5
    /// 能截掉的部分短于这个值就不动文件（不值得重新编码一次）。
    static let minimumTrim: Double = 0.3

    /// 要保留的时长；不需要截时返回 nil。纯计算，单元测试直接调用。
    static func keepDuration(speechEndSeconds: Double?, recordedSeconds: Double) -> Double? {
        guard let speechEndSeconds, speechEndSeconds > 0, recordedSeconds > 0 else { return nil }
        let keep = min(speechEndSeconds + tailPadding, recordedSeconds)
        guard recordedSeconds - keep >= minimumTrim else { return nil }
        return keep
    }

    /// 把 fileURL 截成前 keepSeconds 秒，返回截掉的秒数；失败返回 nil（原文件不变）。
    @concurrent
    static func trimTail(fileURL: URL, keepSeconds: Double, sessionID: UUID) async -> Double? {
        let logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
            category: "audio"
        )
        let startedAt = ContinuousClock.now
        let asset = AVURLAsset(url: fileURL)
        let originalSeconds: Double
        do {
            originalSeconds = try await asset.load(.duration).seconds
        } catch {
            logger.error("trim skipped: load duration failed session=\(sessionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard originalSeconds - keepSeconds >= minimumTrim else {
            logger.info("trim skipped: nothing to trim session=\(sessionID.uuidString, privacy: .public) duration=\(originalSeconds, privacy: .public) keep=\(keepSeconds, privacy: .public)")
            return nil
        }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            logger.error("trim skipped: export session unavailable session=\(sessionID.uuidString, privacy: .public)")
            return nil
        }
        export.timeRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: keepSeconds, preferredTimescale: 600)
        )
        let tempURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(sessionID.uuidString)-trimmed")
            .appendingPathExtension("m4a")
        try? FileManager.default.removeItem(at: tempURL)
        do {
            // export(to:as:) 签名已对照 iPhoneOS SDK 的 AVFoundation.swiftinterface 核对。
            try await export.export(to: tempURL, as: .m4a)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            logger.error("trim failed session=\(sessionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
        let trimmed = originalSeconds - keepSeconds
        let elapsedMs = SessionTiming.milliseconds(ContinuousClock.now - startedAt)
        logger.info(
            "recording trimmed session=\(sessionID.uuidString, privacy: .public) original=\(originalSeconds, privacy: .public) kept=\(keepSeconds, privacy: .public) trimmed=\(trimmed, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public)"
        )
        return trimmed
    }
}
