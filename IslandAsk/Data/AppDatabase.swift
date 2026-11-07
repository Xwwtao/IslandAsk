//
//  AppDatabase.swift
//  IslandAsk
//
//  共享的 SwiftData 容器：存在 App Group 容器里（SPEC 第 6.11 节）。
//  Intent 和 UI 都在主 App 进程，共用同一个 container 的 mainContext，UI 的 @Query 会实时刷新。
//

import Foundation
import SwiftData
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
    category: "coordinator"
)

@MainActor
enum AppDatabase {

    static let container: ModelContainer = makeContainer()

    static var context: ModelContext { container.mainContext }

    private static func makeContainer() -> ModelContainer {
        let schema = Schema([AskSession.self, ChatMessage.self, Card.self])
        // App Group 没配好时 groupContainer 会失败，退回默认位置，保证 App 能用。
        let configuration: ModelConfiguration
        if AppGroup.isContainerAvailable {
            // ModelConfiguration(schema:groupContainer:)：签名由编译器确认，M3 真机读写 App Group 库正常。
            configuration = ModelConfiguration(schema: schema, groupContainer: .identifier(AppGroup.identifier))
        } else {
            logger.error("database: app group unavailable, using default store location")
            configuration = ModelConfiguration(schema: schema)
        }
        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            logger.info("database opened url=\(configuration.url.path, privacy: .public)")
            return container
        } catch {
            logger.fault("database open failed error=\(error.localizedDescription, privacy: .public); using in-memory store")
            // 打不开就用内存库：本次运行可用但不落盘，日志里能看到原因。
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                return try ModelContainer(for: schema, configurations: [fallback])
            } catch {
                fatalError("in-memory database failed: \(error)")
            }
        }
    }

    static func fetchSession(id: UUID) -> AskSession? {
        var descriptor = FetchDescriptor<AskSession>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        do {
            return try context.fetch(descriptor).first
        } catch {
            logger.error(
                "database fetch failed session=\(id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    static func fetchCard(id: UUID) -> Card? {
        var descriptor = FetchDescriptor<Card>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        do {
            return try context.fetch(descriptor).first
        } catch {
            logger.error(
                "database fetch failed card=\(id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    static func fetchCards(ids: Set<UUID>) -> [Card] {
        guard !ids.isEmpty else { return [] }
        let idList = Array(ids)
        let descriptor = FetchDescriptor<Card>(predicate: #Predicate { idList.contains($0.id) })
        do {
            return try context.fetch(descriptor)
        } catch {
            logger.error(
                "database fetch failed cards=\(ids.count, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    /// 返回是否保存成功；大多数调用方只需要日志，忽略返回值。
    @discardableResult
    static func save(reason: String) -> Bool {
        // M-C3：保存前收集这次改动的卡片，保存成功后同步 Spotlight 索引（所有写库都经这里，不会漏）。
        let spotlightChanges = SpotlightIndexer.pendingCardChanges(in: context)
        do {
            try context.save()
            logger.info("database saved reason=\(reason, privacy: .public)")
            SpotlightIndexer.shared.enqueue(upserts: spotlightChanges.upserts, deletes: spotlightChanges.deletes)
            return true
        } catch {
            logger.error(
                "database save failed reason=\(reason, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}
