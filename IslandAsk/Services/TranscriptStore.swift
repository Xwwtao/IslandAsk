//
//  TranscriptStore.swift
//  IslandAsk
//
//  最终转录文字的本地存储：与 m4a 同目录、同名的 .txt（Documents/sessions/<sessionID>.txt）。
//  M3 接 SwiftData 后由 AskSession.transcript 取代，这个文件届时删除。
//

import Foundation
import os

nonisolated enum TranscriptStore {

    nonisolated private static func makeLogger() -> Logger {
        Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
            category: "transcription"
        )
    }

    static func transcriptFileURL(sessionID: UUID) throws -> URL {
        try ScreenshotStore.sessionsDirectory()
            .appendingPathComponent(sessionID.uuidString)
            .appendingPathExtension("txt")
    }

    /// 保存最终转录；空文本也写文件（列表显示"没有识别到文字"），便于排查。
    @discardableResult
    static func save(_ text: String, sessionID: UUID) throws -> URL {
        let logger = makeLogger()
        let url = try transcriptFileURL(sessionID: sessionID)
        try text.write(to: url, atomically: true, encoding: .utf8)
        logger.info(
            "transcript saved session=\(sessionID.uuidString, privacy: .public) chars=\(text.count, privacy: .public)"
        )
        return url
    }

    static func load(sessionID: UUID) -> String? {
        guard let url = try? transcriptFileURL(sessionID: sessionID) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
