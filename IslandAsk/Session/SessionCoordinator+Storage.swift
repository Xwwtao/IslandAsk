//
//  SessionCoordinator+Storage.swift
//  IslandAsk
//
//  性能优化：截图从 PNG 转成 HEIC，减少存储占用。
//  - 按键时照旧原样写 PNG（不拖慢灵动岛出现），回到前台延后几秒、低优先级分批转码，新旧截图都会转。
//  - 编码在主线程之外；改库在主线程，改之前再确认卡片不在进行中、路径还是原来那张 PNG。
//  - 顺序：写 HEIC → 改库并保存 → 删 PNG。保存失败就删掉 HEIC，原图不动；任何一步失败下次回前台再试。
//  - 正在录音或等回答时整轮停下，不和按键链路抢资源。
//

import Foundation
import SwiftData
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
    category: "coordinator"
)

extension SessionCoordinator {

    private static let compactionDelay: Duration = .seconds(8)
    private static let compactionPause: Duration = .milliseconds(200)

    /// 回到前台时调用；已经在跑就跳过。
    func scheduleScreenshotCompaction() {
        guard !isCompactingScreenshots else { return }
        isCompactingScreenshots = true
        Task(priority: .background) { [weak self] in
            try? await Task.sleep(for: Self.compactionDelay)
            await self?.compactScreenshots()
            self?.isCompactingScreenshots = false
        }
    }

    private func compactScreenshots() async {
        var descriptor = FetchDescriptor<Card>(predicate: #Predicate { $0.screenshotPath != nil })
        descriptor.propertiesToFetch = [\.id, \.screenshotPath]
        let targets: [(id: UUID, path: String)]
        do {
            targets = try AppDatabase.context.fetch(descriptor).compactMap { card in
                guard let path = card.screenshotPath, ScreenshotStore.isPNGPath(path) else { return nil }
                return (card.id, path)
            }
        } catch {
            logger.error("screenshot compaction failed: fetch error=\(error.localizedDescription, privacy: .public)")
            return
        }
        guard !targets.isEmpty else { return }

        let started = ContinuousClock.now
        logger.info("screenshot compaction start count=\(targets.count, privacy: .public)")
        var converted = 0
        var savedBytes = 0
        for target in targets {
            guard !isSessionBusy else {
                logger.info("screenshot compaction paused: session busy converted=\(converted, privacy: .public)")
                break
            }
            guard !isCardBusy(id: target.id), let pngURL = ScreenshotStore.url(forRelativePath: target.path) else { continue }

            let result = await Self.convertOffMain(pngURL: pngURL, sessionID: target.id)
            switch result {
            case .converted(let heicURL, let originalBytes, let heicBytes):
                if commitHEIC(cardID: target.id, pngPath: target.path, pngURL: pngURL, heicURL: heicURL) {
                    converted += 1
                    savedBytes += originalBytes - heicBytes
                }
            case .notSmaller, .failed:
                continue
            case .encoderUnavailable:
                logger.notice("screenshot compaction stopped: heic encoder unavailable")
                return
            }
            try? await Task.sleep(for: Self.compactionPause)
        }
        logger.info(
            "screenshot compaction finished converted=\(converted, privacy: .public)/\(targets.count, privacy: .public) savedBytes=\(savedBytes, privacy: .public) elapsedMs=\(PerformanceTrace.milliseconds(since: started), privacy: .public)"
        )
    }

    @concurrent
    nonisolated private static func convertOffMain(pngURL: URL, sessionID: UUID) async -> ScreenshotStore.HEICConversion {
        let state = PerformanceTrace.signposter.beginInterval("storage.heic")
        defer { PerformanceTrace.signposter.endInterval("storage.heic", state) }
        return ScreenshotStore.convertToHEIC(pngURL: pngURL, sessionID: sessionID)
    }

    /// 编码期间卡片可能被删除、开始追问或重新整理：都放弃这次转码，删掉新文件。
    private func commitHEIC(cardID: UUID, pngPath: String, pngURL: URL, heicURL: URL) -> Bool {
        func discard(_ reason: String) -> Bool {
            try? FileManager.default.removeItem(at: heicURL)
            logger.info("screenshot compaction skipped card=\(cardID.uuidString, privacy: .public) reason=\(reason, privacy: .public)")
            return false
        }
        guard !isCardBusy(id: cardID) else { return discard("busy") }
        guard let card = AppDatabase.fetchCard(id: cardID), !card.isGone else { return discard("card gone") }
        guard card.screenshotPath == pngPath else { return discard("path changed") }

        let heicPath = ScreenshotStore.relativePath(for: heicURL)
        card.screenshotPath = heicPath
        if let session = card.session, session.screenshotPath == pngPath {
            session.screenshotPath = heicPath
        }
        guard AppDatabase.save(reason: "screenshot compacted card=\(cardID.uuidString)") else {
            card.screenshotPath = pngPath
            if let session = card.session, session.screenshotPath == heicPath {
                session.screenshotPath = pngPath
            }
            return discard("save failed")
        }
        do {
            try FileManager.default.removeItem(at: pngURL)
        } catch {
            // 库已指向 HEIC：PNG 留在磁盘上只是多占空间，删卡片时 removeArtifacts 会一起删。
            logger.error(
                "screenshot compaction: remove png failed card=\(cardID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
        return true
    }
}
