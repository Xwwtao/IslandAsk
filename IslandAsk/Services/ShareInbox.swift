//
//  ShareInbox.swift
//  IslandAsk
//
//  分享 inbox（M-C2 阶段 2，SPEC 第 6.13 节）：Share Extension 把 {id, url, title, text, createdAt} 写成
//  App Group 里的 inbox/<id>.json；主 App 由 SessionCoordinator 导入建卡，写库成功后再删文件。
//  同时属于 IslandAsk 和 IslandAskShare 两个 target：只依赖 Foundation、os 和 AppGroup，不引用主 App 的类型。
//  拿不到 App Group 容器时直接抛错，不回退到别的目录（扩展的 Documents 主 App 读不到）。
//

import Foundation
import os

nonisolated struct ShareInboxItem: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    var url: String?
    /// 扩展里能拿到的标题（分享来源附带的标题或预览标题），可能为 nil。
    var title: String?
    /// 用户在确认面板里写的附注，或分享来的纯文字。
    var text: String?
    var createdAt: Date
}

nonisolated enum ShareInbox {

    static let directoryName = "inbox"

    private static let logger = Logger(subsystem: AppGroup.logSubsystem, category: "coordinator")

    static func directoryURL() throws -> URL {
        let directory = try AppGroup.requireSharedContainerURL().appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 扩展调用：原子写入一条。
    static func write(_ item: ShareInboxItem) throws {
        let fileURL = try directoryURL().appendingPathComponent("\(item.id.uuidString).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(item)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        logger.info(
            "inbox item written id=\(item.id.uuidString, privacy: .public) hasURL=\(item.url != nil, privacy: .public) textChars=\(item.text?.count ?? 0, privacy: .public)"
        )
    }

    /// 主 App 调用：读出全部条目（按创建时间排序）。解析失败的文件记日志后跳过，不删除，方便排查。
    static func readAll() -> [ShareInboxItem] {
        let directory: URL
        do {
            directory = try directoryURL()
        } catch {
            logger.error("inbox read failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
        } catch {
            logger.error("inbox list failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var items: [ShareInboxItem] = []
        for file in files {
            do {
                items.append(try decoder.decode(ShareInboxItem.self, from: Data(contentsOf: file)))
            } catch {
                logger.error(
                    "inbox item decode failed file=\(file.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return items.sorted { $0.createdAt < $1.createdAt }
    }

    /// 主 App 调用：卡片写库成功后删除对应文件。
    static func remove(id: UUID) {
        do {
            let fileURL = try directoryURL().appendingPathComponent("\(id.uuidString).json")
            try FileManager.default.removeItem(at: fileURL)
            logger.info("inbox item removed id=\(id.uuidString, privacy: .public)")
        } catch {
            logger.error("inbox item remove failed id=\(id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }
}
