//
//  TextRecognizer.swift
//  IslandAsk
//
//  截图文字识别增强（SPEC 第 6.8 节可选增强，M4）：用 Vision 提取截图里的文字，
//  作为补充上下文和截图一起发给大模型，提高中文小字的识别准确率。
//  SessionCoordinator 在录音开始时就并行识别，问大模型前最多再等一小会儿，不拖慢灵动岛。
//
//  API：iOS 18 起的 Swift Vision（RecognizeTextRequest / RecognizedTextObservation），
//  成员已对照 iPhoneOS SDK 的 Vision.swiftinterface 核对。
//

import CoreGraphics
import Foundation
import Vision
import os

nonisolated enum TextRecognizer {

    /// 发给大模型的 OCR 文字上限：截图文字通常几百字，超长时只留前面的部分，避免请求体和 token 膨胀。
    static let maxCharacters = 1500
    /// 置信度太低的行多半是图标、装饰字，丢掉。
    private static let minimumConfidence: Float = 0.3

    private static func makeLogger() -> Logger {
        Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
            category: "ocr"
        )
    }

    /// 识别截图文字，按从上到下、从左到右拼接。失败或没有文字时返回 nil（不影响提问）。
    @concurrent
    static func recognize(imageURL: URL, sessionID: UUID) async -> String? {
        let logger = makeLogger()
        let startedAt = ContinuousClock.now
        logger.info("ocr start session=\(sessionID.uuidString, privacy: .public)")

        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = [Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "en-US")]
        request.usesLanguageCorrection = true

        let observations: [RecognizedTextObservation]
        do {
            observations = try await request.perform(on: imageURL)
        } catch {
            logger.error(
                "ocr failed session=\(sessionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        // Vision 的归一化坐标原点在左下角：maxY 越大越靠上。按约 1% 屏高分行，行内按 x 排序。
        let lines = observations
            .compactMap { observation -> (row: Int, x: CGFloat, text: String)? in
                guard let candidate = observation.topCandidates(1).first,
                      candidate.confidence >= minimumConfidence else { return nil }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let rect = observation.boundingBox.cgRect
                return (Int(((1 - rect.maxY) * 100).rounded()), rect.minX, text)
            }
            .sorted { ($0.row, $0.x) < ($1.row, $1.x) }
            .map(\.text)

        var text = lines.joined(separator: "\n")
        let elapsedMs = Self.milliseconds(ContinuousClock.now - startedAt)
        guard !text.isEmpty else {
            logger.info("ocr finished: no text session=\(sessionID.uuidString, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public)")
            return nil
        }
        if text.count > maxCharacters {
            text = String(text.prefix(maxCharacters)) + "…"
        }
        logger.info(
            "ocr succeeded session=\(sessionID.uuidString, privacy: .public) observations=\(observations.count, privacy: .public) lines=\(lines.count, privacy: .public) chars=\(text.count, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public)"
        )
        return text
    }

    /// 识别提示词上限：给太多会稀释效果，也拖慢设置。
    static let maxContextualTerms = 100

    /// 从 OCR 文字里挑识别提示词，按出现顺序去重：
    /// - 英文 / 字母数字词（≥2 字符）：产品名、术语、代码符号，最容易被语音识别成同音中文；
    /// - 2–8 字的短中文行：标题、人名、按钮文字。长句不拆（没有分词，整句做提示没有意义）。
    static func contextualTerms(from text: String) -> [String] {
        var terms: [String] = []
        var seen = Set<String>()
        func add(_ term: String) {
            guard terms.count < maxContextualTerms, seen.insert(term.lowercased()).inserted else { return }
            terms.append(term)
        }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let isShortChineseLine = (2...8).contains(line.count)
                && line.unicodeScalars.allSatisfy { $0.properties.isIdeographic }
            if isShortChineseLine {
                add(line)
            }
            for match in line.matches(of: /[A-Za-z][A-Za-z0-9.+#_\-]+/) {
                let word = String(match.output).trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
                if word.count >= 2 {
                    add(word)
                }
            }
            if terms.count >= maxContextualTerms { break }
        }
        return terms
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
