//
//  CardSearch.swift
//  IslandAsk
//
//  收藏库检索（M-C3，SPEC 第 6.14 节）：
//  - CardSearchQuery：本地文本包含匹配（拆词、#标签）。
//  - Card.searchableTexts：参与本地匹配的全部文字（含截图 OCR 文字）。
//  - NaturalLanguageSearch：自然语言搜索的触发判断、发给模型的候选列表、模型返回结果的解析。
//    候选用本地序号 1…N 代替卡片 UUID（省 token，模型也不会抄错 id），并带收藏日期和今天的日期，
//    让模型能理解「上个月」「上周」这类时间。
//  - AISearchModel：收藏库的 AI 搜索状态。只读数据库，只在前台用快速档调用。
//

import Foundation
import Observation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
    category: "llm"
)

// MARK: - 本地搜索

/// 收藏库搜索词。按空白拆成多个词，每个词都要匹配（AND）：
/// - 以 # 或 ＃ 开头的词只匹配标签（标签存的时候不带 #，界面上显示成 #标签），如「#漫威」。
/// - 其他词匹配标题、摘要、标签、附注、关键信息、OCR 文字、问答等全部文字。
/// 单独一个 # 忽略。匹配不区分大小写和全半角（localizedStandardContains）。
nonisolated struct CardSearchQuery: Equatable {

    struct Term: Equatable {
        let text: String
        let tagOnly: Bool
    }

    let terms: [Term]

    init(_ raw: String) {
        terms = raw
            .split(whereSeparator: \.isWhitespace)
            .compactMap { word in
                let tagOnly = word.first == "#" || word.first == "＃"
                let text = String(word.drop { $0 == "#" || $0 == "＃" })
                return text.isEmpty ? nil : Term(text: text, tagOnly: tagOnly)
            }
    }

    var isEmpty: Bool { terms.isEmpty }

    var hasTagTerm: Bool { terms.contains(where: \.tagOnly) }

    func matches(texts: [String], tags: [String]) -> Bool {
        terms.allSatisfy { term in
            let pool = term.tagOnly ? tags : texts
            return pool.contains { $0.localizedStandardContains(term.text) }
        }
    }
}

// MARK: - 关键字高亮

/// 搜索结果里把命中的关键字标出来。匹配规则和 localizedStandardContains 一致：不区分大小写、全半角、重音。
nonisolated enum SearchHighlighter {

    private static let options: String.CompareOptions = [.caseInsensitive, .widthInsensitive, .diacriticInsensitive]

    /// text 里所有命中任一关键字的位置（不重叠，按出现顺序）。
    static func ranges(of terms: [String], in text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        for term in terms where !term.isEmpty {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let found = text.range(of: term, options: options, range: searchStart..<text.endIndex, locale: .current) {
                if !result.contains(where: { $0.overlaps(found) }) {
                    result.append(found)
                }
                searchStart = found.upperBound
            }
        }
        return result.sorted { $0.lowerBound < $1.lowerBound }
    }

    static func contains(_ terms: [String], in text: String) -> Bool {
        !ranges(of: terms, in: text).isEmpty
    }

    /// 命中的关键字所在的一小段：前后各留 radius 个字，被截掉的一侧加「…」，换行压成空格。
    /// 用在关键字只出现在列表不显示的文字里（OCR、转录、回答、翻译等）时，告诉用户为什么搜到这张卡片。
    static func snippet(in texts: [String], terms: [String], radius: Int = 16) -> String? {
        for text in texts {
            let flat = text.replacingOccurrences(of: "\n", with: " ")
            guard let first = ranges(of: terms, in: flat).first else { continue }
            let start = flat.index(first.lowerBound, offsetBy: -radius, limitedBy: flat.startIndex) ?? flat.startIndex
            let end = flat.index(first.upperBound, offsetBy: radius * 2, limitedBy: flat.endIndex) ?? flat.endIndex
            var snippet = String(flat[start..<end]).trimmingCharacters(in: .whitespaces)
            if start > flat.startIndex { snippet = "…" + snippet }
            if end < flat.endIndex { snippet += "…" }
            return snippet
        }
        return nil
    }
}

extension Card {
    /// 本地搜索匹配的全部文字（SPEC 6.14：标题、摘要、标签、附注、OCR 文字、转录文字、翻译、关键信息），另含来源和问答。
    var searchableTexts: [String] {
        var texts = [title, summary, note, translation, sourceTitle, sourcePlatform, sourceURL]
            .compactMap { $0 }
        texts += tags ?? []
        texts += keyInfo.flatMap { [$0.label, $0.value] }
        if let session {
            texts += [session.transcript, session.answer, session.deepAnswer, session.ocrText].compactMap { $0 }
        }
        return texts
    }

    /// 列表行里不显示、但参与搜索的文字，按用户最可能想看的顺序排：附注、关键信息、转录、回答、OCR、翻译、来源。
    var hiddenSearchTexts: [String] {
        var texts = [note].compactMap { $0 }
        texts += keyInfo.map { "\($0.label)：\($0.value)" }
        if let session {
            // 快速回答和深度回答都参与搜索，片段也都要能取到（之前有深度回答时漏了快速回答）。
            texts += [session.transcript, session.answer, session.deepAnswer, session.ocrText].compactMap { $0 }
        }
        texts += [translation, sourceTitle, sourcePlatform, sourceURL].compactMap { $0 }
        return texts.filter { !$0.isEmpty }
    }
}

// MARK: - 自然语言搜索

/// 发给模型的一张候选卡片（值类型，可以跨 actor 传给 LLMProvider）。
nonisolated struct CardSearchCandidate: Sendable, Equatable {
    /// 本地序号，从 1 开始；模型返回序号，本地再换回卡片。
    let index: Int
    let cardID: UUID
    let createdAt: Date
    let type: String
    let title: String
    let tags: [String]
    let summaryLead: String
}

nonisolated enum NaturalLanguageSearch {

    /// SPEC 6.14：只发最近 200 张。
    static let maxCandidates = 200
    /// 模型最多返回的卡片数。
    static let maxResults = 10
    /// 摘要首句的长度上限。
    static let maxSummaryLeadLength = 40

    /// 回车时是否自动用 AI 搜索：本地没匹配到，或输入像一句话（不含 #标签，中文至少 6 个字，或至少 3 个词）。
    static func shouldAutoRun(query: String, localResultCount: Int) -> Bool {
        let parsed = CardSearchQuery(query)
        guard !parsed.isEmpty else { return false }
        return localResultCount == 0 || looksLikeSentence(query)
    }

    static func looksLikeSentence(_ query: String) -> Bool {
        let parsed = CardSearchQuery(query)
        guard !parsed.isEmpty, !parsed.hasTagTerm else { return false }
        let letters = query.filter { !$0.isWhitespace }
        let hasCJK = letters.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        return hasCJK ? letters.count >= 6 : parsed.terms.count >= 3
    }

    /// 摘要的第一句（到第一个句末标点或换行），超长截断。
    static func summaryLead(_ summary: String?) -> String {
        let text = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let terminators: Set<Character> = ["。", "！", "？", "!", "?", "\n", "；", ";"]
        var lead = ""
        for character in text {
            if terminators.contains(character) { break }
            lead.append(character)
        }
        lead = lead.trimmingCharacters(in: .whitespaces)
        guard lead.count > maxSummaryLeadLength else { return lead }
        return String(lead.prefix(maxSummaryLeadLength)) + "…"
    }

    private static func dayString(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// 今天的日期和星期，写进 user 消息，让模型换算「上个月」「上周」。
    static func todayText(_ today: Date, calendar: Calendar = .current) -> String {
        let weekdays = ["日", "一", "二", "三", "四", "五", "六"]
        let weekday = calendar.component(.weekday, from: today)
        return "\(dayString(today, calendar: calendar))（星期\(weekdays[(weekday - 1) % 7])）"
    }

    /// 一行一张卡片：序号 | 收藏日期 | 类型 | 标题 | 标签 | 摘要首句。字段里的 | 和换行换掉，避免打乱格式。
    static func candidateLines(_ candidates: [CardSearchCandidate], calendar: Calendar = .current) -> String {
        func clean(_ text: String) -> String {
            text.replacingOccurrences(of: "|", with: "/")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        return candidates.map { candidate in
            let tags = candidate.tags.map { "#\(clean($0))" }.joined(separator: " ")
            return [
                String(candidate.index),
                dayString(candidate.createdAt, calendar: calendar),
                clean(candidate.type),
                clean(candidate.title),
                tags.isEmpty ? "无" : tags,
                candidate.summaryLead.isEmpty ? "无" : clean(candidate.summaryLead),
            ].joined(separator: " | ")
        }
        .joined(separator: "\n")
    }

    /// 解析模型返回的 {"ids": [3, 17]}：去掉代码块包裹；序号可以是数字或数字字符串；
    /// 越界、重复的丢掉，最多 maxResults 个，保持模型给的顺序（相关度从高到低）。
    static func parseIndices(_ content: String, candidateCount: Int) throws -> [Int] {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"),
              start < end else {
            throw LLMError.badResponse("内容里没有 JSON 对象")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(content[start...end].utf8))
        } catch {
            throw LLMError.badResponse("JSON 解析失败：\(error.localizedDescription)")
        }
        guard let dictionary = object as? [String: Any] else {
            throw LLMError.badResponse("JSON 不是对象")
        }
        guard let raw = dictionary["ids"] else {
            throw LLMError.badResponse("缺少 ids 字段")
        }
        guard let list = raw as? [Any] else {
            throw LLMError.badResponse("ids 不是数组")
        }
        var seen = Set<Int>()
        var result: [Int] = []
        for item in list {
            let value: Int?
            if let number = item as? Int {
                value = number
            } else if let text = item as? String {
                value = Int(text.trimmingCharacters(in: .whitespaces))
            } else {
                value = nil
            }
            guard let value, (1...max(candidateCount, 1)).contains(value), candidateCount > 0,
                  seen.insert(value).inserted else { continue }
            result.append(value)
            if result.count == maxResults { break }
        }
        return result
    }
}

// MARK: - AI 搜索状态

/// 收藏库的 AI 搜索。搜索词变了就作废旧结果（取消进行中的请求）；结果只保存卡片 id，显示时再从 @Query 里取。
@MainActor
@Observable
final class AISearchModel {

    enum Phase: Equatable {
        case idle
        case searching
        case results([UUID])
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// 当前结果（或进行中的请求）对应的搜索词。
    private(set) var query = ""

    @ObservationIgnored private var task: Task<Void, Never>?

    /// 结果是否属于这个搜索词（搜索框改了字就不再显示旧结果）。
    func isCurrent(for text: String) -> Bool {
        phase != .idle && query == text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func reset() {
        task?.cancel()
        task = nil
        phase = .idle
        query = ""
    }

    /// cards：当前分段和类型筛选下的卡片（按时间倒序），取前 200 张作为候选。
    func search(_ text: String, in cards: [Card]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            reset()
            return
        }
        if query == trimmed, phase == .searching { return }
        task?.cancel()
        query = trimmed

        let candidates = cards.prefix(NaturalLanguageSearch.maxCandidates).enumerated().map { offset, card in
            CardSearchCandidate(
                index: offset + 1,
                cardID: card.id,
                createdAt: card.createdAt,
                type: card.cardTypeValue.displayName,
                title: card.displayTitle,
                tags: card.tags ?? [],
                summaryLead: NaturalLanguageSearch.summaryLead(card.summary ?? card.session?.answer)
            )
        }
        guard !candidates.isEmpty else {
            phase = .results([])
            return
        }
        phase = .searching
        logger.info(
            "ai search start queryChars=\(trimmed.count, privacy: .public) candidates=\(candidates.count, privacy: .public)"
        )
        let startedAt = ContinuousClock.now
        task = Task { [weak self] in
            let result: Result<[Int], any Error>
            do {
                let provider = try OpenAICompatibleProvider.fromSettings()
                result = .success(try await provider.searchCards(query: trimmed, candidates: candidates, today: .now))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled, let self, self.query == trimmed else {
                logger.info("ai search result dropped: query changed or cancelled")
                return
            }
            let elapsedMs = SessionCoordinator.milliseconds(ContinuousClock.now - startedAt)
            switch result {
            case .success(let indices):
                let ids = indices.map { candidates[$0 - 1].cardID }
                self.phase = .results(ids)
                logger.info(
                    "ai search succeeded results=\(ids.count, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public)"
                )
            case .failure(let error):
                let message = (error as? LLMError)?.errorDescription ?? error.localizedDescription
                self.phase = .failed(message)
                logger.error(
                    "ai search failed elapsedMs=\(elapsedMs, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
