//
//  SpotlightIndexer.swift
//  IslandAsk
//
//  Core Spotlight 索引（M-C3，SPEC 6.14）：系统搜索能搜到卡片，点开进入卡片详情。
//  - 每张卡片一条 CSSearchableItem：uniqueIdentifier = 卡片 id，标题、摘要、标签（关键词）、类型、缩略图。
//  - 收藏库「全部」里的卡片都索引（含没收藏的提问卡片）；按保留天数清掉时一起从索引删除。
//  - 同步入口只有一个：AppDatabase.save 在保存前收集这次插入、修改、删除的卡片，保存成功后交给这里。
//    合并 1 秒内的改动再写索引；缩略图生成和写索引在主线程之外。
//  - 第一次运行（或索引版本号变了）时，回到前台时全量重建一次，升级前的卡片也能搜到。
//  - 点开系统搜索结果：系统以 CSSearchableItemActionType 的 NSUserActivity 打开 App（不是 URL），
//    IslandAskApp 接住后走和 islandask://card/<id> 一样的路由。
//

import CoreSpotlight
import Foundation
import SwiftData
import UIKit
import UniformTypeIdentifiers
import os

nonisolated private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
    category: "coordinator"
)

/// 写索引用的卡片快照（值类型，可以离开主线程）。
nonisolated struct SpotlightCardSnapshot: Sendable {
    let id: UUID
    let title: String
    let summary: String?
    let tags: [String]
    let typeName: String
    let createdAt: Date
    /// 缩略图来源：截图 → 链接封面图 → 网站图标（相对 App Group 容器的路径，离开主线程后再拼成 URL）。
    let imageRelativePath: String?

    /// 在主线程上读卡片字段，尽量少碰关系和文件系统：
    /// 只存相对路径（拼绝对路径要查 App Group 容器），会话只在前面几项都为空时才读（读关系会触发数据库加载）。
    @MainActor
    init(card: Card) {
        id = card.id
        title = card.displayTitle
        summary = Self.firstNonEmpty(card.summary, card.note, card.sourceTitle)
            ?? Self.firstNonEmpty(card.session?.answer)
        tags = card.tags ?? []
        typeName = card.cardTypeValue.displayName
        createdAt = card.createdAt
        imageRelativePath = card.screenshotPath ?? card.coverPath ?? card.iconPath
    }

    private static func firstNonEmpty(_ texts: String?...) -> String? {
        texts.lazy.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }
}

@MainActor
final class SpotlightIndexer {

    static let shared = SpotlightIndexer()

    nonisolated static let domainIdentifier = "card"
    /// 改了索引内容的格式时加一，下次回到前台会全量重建。
    /// 2：重建改为延后、分批（真机测重建耗时时升级，已装 M-C3 的设备会再重建一次）。
    private static let indexVersion = 2
    private static let versionKey = "spotlight.indexVersion"
    private static let flushDelay: Duration = .seconds(1)
    /// 全量重建等启动、导入、整理这些事先做完，界面稳定了再开始。
    private static let rebuildDelay: Duration = .seconds(5)
    /// 每批在主线程上读的卡片数；批与批之间让出主线程。
    private static let rebuildBatchSize = 20

    private var pendingUpserts: Set<UUID> = []
    private var pendingDeletes: Set<UUID> = []
    private var flushTask: Task<Void, Never>?
    private var isRebuilding = false

    private init() {}

    // MARK: - 收集改动（AppDatabase.save 调用）

    /// 保存前调用：这次保存会插入、修改、删除的卡片 id。删除优先。
    /// TODO: 核对官方文档：ModelContext.insertedModelsArray / changedModelsArray / deletedModelsArray 在 save 前读取的语义。
    static func pendingCardChanges(in context: ModelContext) -> (upserts: Set<UUID>, deletes: Set<UUID>) {
        var upserts = Set<UUID>()
        var deletes = Set<UUID>()
        for model in context.insertedModelsArray + context.changedModelsArray {
            if let card = model as? Card {
                upserts.insert(card.id)
            }
        }
        for model in context.deletedModelsArray {
            if let card = model as? Card {
                deletes.insert(card.id)
            }
        }
        upserts.subtract(deletes)
        return (upserts, deletes)
    }

    /// 保存成功后调用：记下改动，1 秒后统一写索引（期间的改动合并到同一次）。
    func enqueue(upserts: Set<UUID>, deletes: Set<UUID>) {
        guard !upserts.isEmpty || !deletes.isEmpty else { return }
        pendingDeletes.formUnion(deletes)
        pendingUpserts.subtract(deletes)
        pendingUpserts.formUnion(upserts.subtracting(deletes))
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flushDelay)
            await self?.flush()
        }
    }

    private func flush() async {
        flushTask = nil
        let upsertIDs = pendingUpserts
        var deleteIDs = pendingDeletes
        pendingUpserts = []
        pendingDeletes = []

        let cards = AppDatabase.fetchCards(ids: upsertIDs)
        let snapshots = cards.filter { !$0.isGone }.map(SpotlightCardSnapshot.init(card:))
        // 改动之后又被删掉的卡片（批量删除、过期清理）：库里已经找不到，按删除处理。
        deleteIDs.formUnion(upsertIDs.subtracting(snapshots.map(\.id)))

        await Self.write(snapshots: snapshots, deleteIDs: deleteIDs, reason: "sync")
    }

    // MARK: - 全量重建

    /// 回到前台时调用：索引版本号落后（第一次运行 M-C3，或改了索引格式）就删掉旧索引、重建全部卡片。
    /// 不阻塞调用方：延后几秒、低优先级在后台做；主线程上只分批读卡片字段，生成缩略图和写索引都在主线程之外。
    func scheduleRebuildIfNeeded() {
        let stored = UserDefaults.standard.integer(forKey: Self.versionKey)
        guard stored < Self.indexVersion, !isRebuilding else { return }
        isRebuilding = true
        logger.info(
            "spotlight rebuild scheduled fromVersion=\(stored, privacy: .public) toVersion=\(Self.indexVersion, privacy: .public)"
        )
        Task(priority: .background) { [weak self] in
            try? await Task.sleep(for: Self.rebuildDelay)
            await self?.rebuild()
        }
    }

    private func rebuild() async {
        defer { isRebuilding = false }
        let startedAt = ContinuousClock.now
        var mainThreadTime = Duration.zero

        let fetchStartedAt = ContinuousClock.now
        let cards: [Card]
        do {
            cards = try AppDatabase.context.fetch(FetchDescriptor<Card>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
        } catch {
            logger.error("spotlight rebuild failed: fetch error=\(error.localizedDescription, privacy: .public)")
            return
        }
        mainThreadTime += ContinuousClock.now - fetchStartedAt
        logger.info("spotlight rebuild start cards=\(cards.count, privacy: .public)")

        guard await Self.deleteAllItems() else { return }

        var indexed = 0
        var offset = 0
        while offset < cards.count {
            let batch = cards[offset..<min(offset + Self.rebuildBatchSize, cards.count)]
            offset += batch.count
            let batchStartedAt = ContinuousClock.now
            let snapshots = batch.filter { !$0.isGone }.map(SpotlightCardSnapshot.init(card:))
            mainThreadTime += ContinuousClock.now - batchStartedAt
            guard await Self.indexBatch(snapshots) else {
                logger.error("spotlight rebuild stopped at offset=\(offset, privacy: .public); will retry next foreground")
                return
            }
            indexed += snapshots.count
            await Task.yield()
        }
        UserDefaults.standard.set(Self.indexVersion, forKey: Self.versionKey)
        logger.info(
            "spotlight rebuild succeeded cards=\(indexed, privacy: .public) mainThreadMs=\(SessionCoordinator.milliseconds(mainThreadTime), privacy: .public) totalMs=\(SessionCoordinator.milliseconds(ContinuousClock.now - startedAt), privacy: .public)"
        )
    }

    // MARK: - 写索引（主线程之外）

    @concurrent
    private nonisolated static func deleteAllItems() async -> Bool {
        do {
            // TODO: 核对官方文档：deleteSearchableItems(withDomainIdentifiers:) 的 async 版本签名。
            try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domainIdentifier])
            return true
        } catch {
            logger.error("spotlight rebuild: delete old items failed error=\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// 生成缩略图、写索引：都在主线程之外。
    @concurrent
    private nonisolated static func indexBatch(_ snapshots: [SpotlightCardSnapshot]) async -> Bool {
        guard !snapshots.isEmpty else { return true }
        do {
            try await CSSearchableIndex.default().indexSearchableItems(snapshots.map(makeItem))
            return true
        } catch {
            logger.error(
                "spotlight rebuild: index batch failed count=\(snapshots.count, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    @concurrent
    private nonisolated static func write(snapshots: [SpotlightCardSnapshot], deleteIDs: Set<UUID>, reason: String) async {
        let index = CSSearchableIndex.default()
        if !deleteIDs.isEmpty {
            do {
                // TODO: 核对官方文档：deleteSearchableItems(withIdentifiers:) 的 async 版本签名。
                try await index.deleteSearchableItems(withIdentifiers: deleteIDs.map(\.uuidString))
                logger.info("spotlight items deleted count=\(deleteIDs.count, privacy: .public) reason=\(reason, privacy: .public)")
            } catch {
                logger.error(
                    "spotlight delete failed count=\(deleteIDs.count, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
        guard !snapshots.isEmpty else { return }
        let items = snapshots.map(makeItem)
        do {
            // TODO: 核对官方文档：indexSearchableItems(_:) 的 async 版本签名。
            try await index.indexSearchableItems(items)
            logger.info("spotlight items indexed count=\(items.count, privacy: .public) reason=\(reason, privacy: .public)")
        } catch {
            logger.error(
                "spotlight index failed count=\(items.count, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// 缩略图长边（像素）。系统搜索结果的图很小，压小一点省索引空间。
    private nonisolated static let thumbnailPixelSize = 240

    private nonisolated static func makeItem(_ snapshot: SpotlightCardSnapshot) -> CSSearchableItem {
        // TODO: 核对官方文档：CSSearchableItemAttributeSet(contentType:) 用 .content 是否合适，thumbnailData 的尺寸建议。
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = snapshot.title
        attributes.displayName = snapshot.title
        attributes.contentDescription = snapshot.summary
        attributes.keywords = snapshot.tags + [snapshot.typeName]
        attributes.contentCreationDate = snapshot.createdAt
        if let imageURL = snapshot.imageRelativePath.flatMap(ScreenshotStore.url(forRelativePath:)) {
            attributes.thumbnailData = ScreenshotStore.thumbnail(url: imageURL, maxPixelSize: thumbnailPixelSize)?
                .jpegData(compressionQuality: 0.7)
        }
        let item = CSSearchableItem(
            uniqueIdentifier: snapshot.id.uuidString,
            domainIdentifier: domainIdentifier,
            attributeSet: attributes
        )
        // 默认会在一段时间后过期；收藏的卡片不该从系统搜索里自己消失，删除时再移除。
        item.expirationDate = .distantFuture
        return item
    }

    // MARK: - 点开搜索结果

    /// 系统搜索结果打开 App 时的卡片 id。
    /// TODO: 核对官方文档：CSSearchableItemActivityIdentifier 在 userInfo 里的取值方式。
    nonisolated static func cardID(from activity: NSUserActivity) -> UUID? {
        guard activity.activityType == CSSearchableItemActionType,
              let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return nil }
        return UUID(uuidString: identifier)
    }
}
