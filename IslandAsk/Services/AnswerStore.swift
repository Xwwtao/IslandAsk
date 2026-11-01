//
//  AnswerStore.swift
//  IslandAsk
//
//  大模型结果的本地存储：与 m4a 同目录、同名的 .json（Documents/sessions/<sessionID>.json）。
//  成功、失败都写，便于真机排查。M3 接 SwiftData 后由 AskSession 取代，这个文件届时删除。
//

import Foundation
import os

nonisolated struct SessionResult: Codable, Hashable, Sendable {
    enum Status: String, Codable, Hashable, Sendable {
        case answered
        case failed
    }

    var sessionID: UUID
    var createdAt: Date
    var question: String
    var status: Status
    var summary: String?
    var answer: String?
    var errorMessage: String?
    var model: String
    var latencyMs: Int
}

nonisolated enum AnswerStore {

    nonisolated private static func makeLogger() -> Logger {
        Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
            category: "llm"
        )
    }

    static func resultFileURL(sessionID: UUID) throws -> URL {
        try ScreenshotStore.sessionsDirectory()
            .appendingPathComponent(sessionID.uuidString)
            .appendingPathExtension("json")
    }

    @discardableResult
    static func save(_ result: SessionResult) throws -> URL {
        let logger = makeLogger()
        let url = try resultFileURL(sessionID: result.sessionID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(result).write(to: url, options: .atomic)
        logger.info(
            "result saved session=\(result.sessionID.uuidString, privacy: .public) status=\(result.status.rawValue, privacy: .public)"
        )
        return url
    }

    static func load(sessionID: UUID) -> SessionResult? {
        guard let url = try? resultFileURL(sessionID: sessionID),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SessionResult.self, from: data)
    }
}
