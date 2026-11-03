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
        let schema = Schema([AskSession.self, ChatMessage.self])
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

    static func save(reason: String) {
        do {
            try context.save()
            logger.info("database saved reason=\(reason, privacy: .public)")
        } catch {
            logger.error(
                "database save failed reason=\(reason, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
