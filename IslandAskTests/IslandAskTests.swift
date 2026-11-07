//
//  IslandAskTests.swift
//  IslandAskTests
//
//  不依赖真机的纯逻辑：Markdown 解析与流式切分、识别提示词提取、大模型回答解析与错误分类、静音检测判定。
//

import Foundation
import Testing
import os
@testable import IslandAsk

// MARK: - Token 用量

struct TokenUsageTests {

    @Test func decodesUsageChunkWithDetails() throws {
        let json = #"{"choices":[],"usage":{"prompt_tokens":1200,"completion_tokens":300,"prompt_cache_hit_tokens":800,"completion_tokens_details":{"reasoning_tokens":250}}}"#
        let chunk = try JSONDecoder().decode(ChatCompletionChunk.self, from: Data(json.utf8))
        let usage = try #require(chunk.usage).tokenUsage
        #expect(usage == TokenUsage(promptTokens: 1200, completionTokens: 300, reasoningTokens: 250, cacheHitTokens: 800))
        #expect(usage.totalTokens == 1500)
    }

    @Test func decodesUsageChunkWithoutOptionalFields() throws {
        let json = #"{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5}}"#
        let chunk = try JSONDecoder().decode(ChatCompletionChunk.self, from: Data(json.utf8))
        let usage = try #require(chunk.usage).tokenUsage
        #expect(usage.reasoningTokens == nil)
        #expect(usage.cacheHitTokens == nil)
        #expect(usage.totalTokens == 15)
    }

    @Test func recordsRoundTripAndTotal() {
        let records = [
            TokenUsageRecord(kind: .quick, usage: TokenUsage(promptTokens: 100, completionTokens: 20), model: "m", createdAt: Date(timeIntervalSince1970: 0)),
            TokenUsageRecord(kind: .deep, usage: TokenUsage(promptTokens: 110, completionTokens: 500, reasoningTokens: 400), model: "m", createdAt: Date(timeIntervalSince1970: 1)),
        ]
        let decoded = TokenUsageRecord.decodeList(TokenUsageRecord.encodeList(records))
        #expect(decoded == records)
        #expect(decoded.totalTokens == 730)
        #expect(TokenUsageRecord.decodeList(nil).isEmpty)
    }

    @MainActor
    @Test func cancelledSpeculativeCountExcludesHit() {
        var timing = SessionTiming()
        timing.speculativeRequests = 3
        timing.speculation = .hit
        #expect(timing.cancelledSpeculativeRequests == 2)
        timing.speculation = .miss
        #expect(timing.cancelledSpeculativeRequests == 3)
        #expect(SessionTiming().cancelledSpeculativeRequests == 0)
    }
}

// MARK: - 链接安全

struct LinkSafetyTests {

    @Test func hidesLabelOnlyWhenTextIsTheSameHost() {
        #expect(LinkSafety.linkTextShowsHost("bank.com", host: "bank.com"))
        #expect(LinkSafety.linkTextShowsHost("https://www.bank.com/login", host: "bank.com"))
        #expect(LinkSafety.linkTextShowsHost("BANK.COM", host: "bank.com"))
    }

    @Test func showsLabelForLookalikeOrDescriptiveText() {
        // 文字包含真实域名的子串，但不是同一个域名。
        #expect(!LinkSafety.linkTextShowsHost("bank.com", host: "ank.com"))
        #expect(!LinkSafety.linkTextShowsHost("bank.com.evil.com", host: "bank.com"))
        #expect(!LinkSafety.linkTextShowsHost("点这里登录 bank.com", host: "bank.com"))
        #expect(!LinkSafety.linkTextShowsHost("官网", host: "bank.com"))
        // 用户信息骗局：人读是 bank.com，实际主机是 evil.com。
        #expect(!LinkSafety.linkTextShowsHost("bank.com@evil.com", host: "evil.com"))
        #expect(!LinkSafety.linkTextShowsHost("https://bank.com@evil.com/login", host: "evil.com"))
        #expect(!LinkSafety.linkTextShowsHost("ftp://bank.com", host: "bank.com"))
    }
}

// MARK: - Markdown

@MainActor
struct MarkdownBlockTests {

    @Test func parsesHeadingListAndCode() {
        let blocks = MarkdownBlock.parse("# 标题\n\n- 第一项\n2. 第二项\n\n```\nlet a = 1\n```")
        #expect(blocks == [
            .heading(level: 1, text: "标题"),
            .listItem(marker: "•", indent: 0, text: "第一项"),
            .listItem(marker: "2.", indent: 0, text: "第二项"),
            .code("let a = 1"),
        ])
    }

    @Test func streamingSplitWithoutBlankLineKeepsEverythingInTail() {
        let split = MarkdownBlock.streamingSplit("第一段还没写完")
        #expect(split.stable == "")
        #expect(split.tail == "第一段还没写完")
    }

    @Test func streamingSplitCutsAtLastBlankLine() {
        let markdown = "第一段\n\n第二段\n\n第三段写到一半"
        let split = MarkdownBlock.streamingSplit(markdown)
        #expect(split.stable == "第一段\n\n第二段\n\n")
        #expect(split.tail == "第三段写到一半")
        #expect(split.stable + split.tail == markdown)
    }

    @Test func streamingSplitIgnoresBlankLinesInsideOpenCodeFence() {
        let markdown = "说明\n\n```\nlet a = 1\n\nlet b = 2"
        let split = MarkdownBlock.streamingSplit(markdown)
        #expect(split.stable == "说明\n\n")
        #expect(split.tail == "```\nlet a = 1\n\nlet b = 2")
    }
}

// MARK: - 识别提示词

struct ContextualTermsTests {

    @Test func extractsEnglishWordsAndShortChineseLines() {
        let text = "设置\n使用 SwiftUI 和 iOS 26 开发\n这是一行很长很长的中文正文内容不应该整句加入\nXcode."
        let terms = TextRecognizer.contextualTerms(from: text)
        #expect(terms == ["设置", "SwiftUI", "iOS", "Xcode"])
    }

    @Test func deduplicatesCaseInsensitively() {
        let terms = TextRecognizer.contextualTerms(from: "GitHub\ngithub\nGITHUB")
        #expect(terms == ["GitHub"])
    }

    @Test func capsTermCount() {
        let text = (0..<300).map { "word\($0)" }.joined(separator: " ")
        #expect(TextRecognizer.contextualTerms(from: text).count == TextRecognizer.maxContextualTerms)
    }
}

// MARK: - 大模型回答

struct LLMAnswerParsingTests {

    private let logger = Logger(subsystem: "IslandAskTests", category: "llm")

    @Test func parsesJSONWrappedInCodeFence() throws {
        let content = "```json\n{\"summary\": \"结论\", \"answer\": \"完整回答\", \"needs_deep\": true}\n```"
        let answer = try OpenAICompatibleProvider.parseAnswer(content, logger: logger)
        #expect(answer.summary == "结论")
        #expect(answer.answer == "完整回答")
        #expect(answer.needsDeep == true)
    }

    @Test func emptyAnswerFallsBackToSummary() throws {
        let answer = try OpenAICompatibleProvider.parseAnswer(#"{"summary": "结论", "answer": " "}"#, logger: logger)
        #expect(answer.answer == "结论")
        #expect(answer.needsDeep == nil)
    }

    @Test func truncatesLongSummary() throws {
        let long = String(repeating: "长", count: 120)
        let answer = try OpenAICompatibleProvider.parseAnswer(#"{"summary": "\#(long)", "answer": "a"}"#, logger: logger)
        #expect(answer.summary.count == OpenAICompatibleProvider.maxSummaryLength)
        #expect(answer.summary.hasSuffix("…"))
    }

    @Test func rejectsContentWithoutJSON() {
        #expect(throws: LLMError.self) {
            try OpenAICompatibleProvider.parseAnswer("抱歉，我无法回答", logger: logger)
        }
    }

    // MARK: M-C1 意图与卡片字段

    @Test func parsesIntentAndCardFields() throws {
        let content = #"""
        {"intent": "both", "summary": "一家咖啡店", "answer": "详细", "needs_deep": false,
         "card": {"title": "街角咖啡", "type": "place", "tags": ["咖啡", "探店"],
                  "key_info": [{"label": "地址", "value": "中山路 1 号"}],
                  "note": "周末去", "source_platform": "小红书", "source_title": null, "translation": null}}
        """#
        let answer = try OpenAICompatibleProvider.parseAnswer(content, logger: logger)
        #expect(answer.intent == .both)
        let card = try #require(answer.card)
        #expect(card.title == "街角咖啡")
        #expect(card.type == "place")
        #expect(card.tags == ["咖啡", "探店"])
        #expect(card.keyInfo == [KeyInfo(label: "地址", value: "中山路 1 号")])
        #expect(card.note == "周末去")
        #expect(card.sourcePlatform == "小红书")
        #expect(card.sourceTitle == nil)
        #expect(card.translation == nil)
    }

    @Test func parsesWithoutCardOrIntent() throws {
        let answer = try OpenAICompatibleProvider.parseAnswer(#"{"summary": "结论", "answer": "回答"}"#, logger: logger)
        #expect(answer.intent == nil)
        #expect(answer.card == nil)
    }

    @Test func unknownIntentAndMalformedCardBecomeNil() throws {
        let answer = try OpenAICompatibleProvider.parseAnswer(
            #"{"intent": "save", "summary": "结论", "answer": "回答", "card": "oops"}"#,
            logger: logger
        )
        #expect(answer.intent == nil)
        #expect(answer.card == nil)
    }

    @Test func intentIsCaseInsensitive() throws {
        let answer = try OpenAICompatibleProvider.parseAnswer(#"{"intent": " Collect ", "summary": "s", "answer": "a"}"#, logger: logger)
        #expect(answer.intent == .collect)
    }

    @Test func normalizesCardFields() throws {
        let longTitle = String(repeating: "题", count: 30)
        let content = #"""
        {"summary": "s", "answer": "a", "card": {"title": "\#(longTitle)", "type": "Recipe2",
         "tags": ["a", " ", "b", "a", "c", "d", "e"],
         "key_info": [{"label": "1", "value": "x"}, {"label": "", "value": "y"}, {"value": "no label"},
                      {"label": "2", "value": "x"}, {"label": "3", "value": "x"}, {"label": "4", "value": "x"},
                      {"label": "5", "value": "x"}, {"label": "6", "value": "x"}, {"label": "7", "value": "x"}],
         "note": "  ", "tags_extra": 1, "translation": 42}}
        """#
        let answer = try OpenAICompatibleProvider.parseAnswer(content, logger: logger)
        let card = try #require(answer.card)
        #expect(card.title?.count == CardFields.maxTitleLength)
        #expect(card.type == CardType.other.rawValue)
        #expect(card.tags == ["a", "b", "c", "d"])
        #expect(card.keyInfo?.count == CardFields.maxKeyInfo)
        #expect(card.keyInfo?.first == KeyInfo(label: "1", value: "x"))
        #expect(card.note == nil)
        #expect(card.translation == nil)
    }

    @Test func truncatesLongTranslation() {
        let fields = CardFields(translation: String(repeating: "译", count: 700)).normalized()
        #expect(fields.translation?.count == CardFields.maxTranslationLength)
        #expect(fields.translation?.hasSuffix("…") == true)
    }

    @Test func quickQuestionTextCarriesIntentHint() {
        #expect(OpenAICompatibleProvider.quickQuestionText("  ", intentHint: .collect).contains("collect"))
        #expect(OpenAICompatibleProvider.quickQuestionText("", intentHint: .ask).hasPrefix(OpenAICompatibleProvider.implicitQuestion))
        #expect(OpenAICompatibleProvider.quickQuestionText("这是什么", intentHint: .ask).hasPrefix("这是什么"))
        #expect(OpenAICompatibleProvider.quickQuestionText(" 这是什么 ", intentHint: nil) == "这是什么")
    }

    @Test func intentFieldIsReadBeforeSummaryCompletes() {
        let partial = #"{"intent": "collect", "summary": "收藏了一篇"#
        #expect(OpenAICompatibleProvider.completedStringField("intent", in: partial) == "collect")
        #expect(OpenAICompatibleProvider.completedStringField("summary", in: partial) == nil)
    }

    @Test func classifiesRetryableErrors() {
        #expect(LLMError.http(status: 429).isRetryable)
        #expect(LLMError.http(status: 503).isRetryable)
        #expect(!LLMError.http(status: 401).isRetryable)
        #expect(!LLMError.truncated.isRetryable)
        #expect(LLMError(transportError: URLError(.timedOut)).isRetryable)
        if case .offline = LLMError(transportError: URLError(.notConnectedToInternet)) {} else {
            Issue.record("notConnectedToInternet 应归为 offline")
        }
    }
}

// MARK: - 流式 JSON 里提前取 summary

struct CompletedStringFieldTests {

    @Test func returnsNilUntilClosingQuoteArrives() {
        #expect(OpenAICompatibleProvider.completedStringField("summary", in: #"{"summ"#) == nil)
        #expect(OpenAICompatibleProvider.completedStringField("summary", in: #"{"summary": "#) == nil)
        #expect(OpenAICompatibleProvider.completedStringField("summary", in: #"{"summary": "明天有"#) == nil)
        #expect(OpenAICompatibleProvider.completedStringField("summary", in: #"{"summary": "明天有雨""#) == "明天有雨")
    }

    @Test func decodesEscapes() {
        let text = #"{"summary": "他说\"好\"\n然后\\走了", "answer": "#
        #expect(OpenAICompatibleProvider.completedStringField("summary", in: text) == "他说\"好\"\n然后\\走了")
    }

    @Test func findsKeyAfterOtherFields() {
        let text = #"{"answer": "提到 \"summary\": \"假的\"", "summary": "真的", "needs"#
        #expect(OpenAICompatibleProvider.completedStringField("summary", in: text) == "真的")
    }

    @Test func ignoresSameTextAsValue() {
        // 值里恰好是 "summary"、后面不是冒号：不算 key。
        let text = #"{"answer": "summary", "summary": "结论"}"#
        #expect(OpenAICompatibleProvider.completedStringField("summary", in: text) == "结论")
    }
}

// MARK: - 提前请求的问题比较

struct QuickAnswerRunNormalizeTests {

    @Test func ignoresPunctuationAndSpaces() {
        #expect(QuickAnswerRun.normalize("这个雨还要下到什么时候 ？") == QuickAnswerRun.normalize("这个雨还要下到什么时候？"))
        #expect(QuickAnswerRun.normalize("你好，世界。") == "你好世界")
        #expect(QuickAnswerRun.normalize("明天下雨吗") != QuickAnswerRun.normalize("明天下雨吗要带伞吗"))
    }

    @Test func editDistanceCountsCharacters() {
        #expect(QuickAnswerRun.editDistance("明天下雨吗", "明天下雨吗") == 0)
        #expect(QuickAnswerRun.editDistance("想信的速度", "相信的速度") == 1)
        #expect(QuickAnswerRun.editDistance("明天下雨吗", "明天下雨吗要带伞吗") == 4)
        #expect(QuickAnswerRun.editDistance("", "你好") == 2)
    }
}

// MARK: - 静音检测

struct SilenceDetectorTests {

    private let configuration = SilenceDetectionConfiguration(
        speechEndRMSDB: -45,
        endSilenceDuration: .milliseconds(1500),
        transcriptStableDuration: .milliseconds(1500),
        noSpeechTimeout: .seconds(6),
        maxRecordingDuration: .seconds(60)
    )
    private let loud: Float = -20
    private let quiet: Float = -60

    private func makeDetector() -> SilenceDetector {
        SilenceDetector(configuration: configuration) { _ in }
    }

    @Test func noSpeechTimesOutAfterSixSeconds() {
        let detector = makeDetector()
        let start = ContinuousClock.now
        #expect(detector.evaluate(levelDB: loud, at: start) == nil)
        #expect(detector.evaluate(levelDB: loud, at: start + .milliseconds(5900)) == nil)
        #expect(detector.evaluate(levelDB: loud, at: start + .seconds(6)) == .noSpeechTimeout)
    }

    @Test func noisyRoomFinishesWhenTranscriptStopsChanging() {
        let detector = makeDetector()
        let start = ContinuousClock.now
        _ = detector.evaluate(levelDB: loud, at: start)
        detector.noteTranscript("你好", at: start + .seconds(1))
        detector.noteTranscript("你好世界", at: start + .seconds(2))
        // 环境一直很吵：音量条件永远不成立，只能靠文字稳定。
        #expect(detector.evaluate(levelDB: loud, at: start + .milliseconds(3400)) == nil)
        #expect(detector.evaluate(levelDB: loud, at: start + .milliseconds(3500)) == .finishedSpeaking)
    }

    @Test func quietRoomFinishesOnePointFiveSecondsAfterLastTextChange() {
        let detector = makeDetector()
        let start = ContinuousClock.now
        _ = detector.evaluate(levelDB: loud, at: start)
        detector.noteTranscript("你好", at: start + .seconds(1))
        // 每次文字变化都会刷新音量计时，所以安静环境也是在最后一次文字变化 1.5 秒后结束。
        detector.noteTranscript("你好呀", at: start + .milliseconds(2000))
        #expect(detector.evaluate(levelDB: quiet, at: start + .milliseconds(3400)) == nil)
        detector.noteTranscript("你好呀朋友", at: start + .milliseconds(3000))
        #expect(detector.evaluate(levelDB: quiet, at: start + .milliseconds(4400)) == nil)
        #expect(detector.evaluate(levelDB: quiet, at: start + .milliseconds(4500)) == .finishedSpeaking)
    }

    @Test func emitsOnlyOnce() {
        let detector = makeDetector()
        let start = ContinuousClock.now
        _ = detector.evaluate(levelDB: loud, at: start)
        #expect(detector.evaluate(levelDB: loud, at: start + .seconds(6)) == .noSpeechTimeout)
        #expect(detector.evaluate(levelDB: loud, at: start + .seconds(7)) == nil)
    }

    @Test func maxDurationStopsLongSpeech() {
        let detector = makeDetector()
        let start = ContinuousClock.now
        _ = detector.evaluate(levelDB: loud, at: start)
        var event: SilenceDetectorEvent?
        // 每秒都有新文字、一直很吵：只有 60 秒上限能结束。
        for second in 1...60 {
            detector.noteTranscript("第\(second)句", at: start + .seconds(second))
            event = detector.evaluate(levelDB: loud, at: start + .seconds(second))
            if event != nil { break }
        }
        #expect(event == .maxDurationReached)
    }

    @Test func settledFiresOncePerTranscript() {
        var configuration = self.configuration
        configuration.settledDuration = .milliseconds(800)
        let detector = SilenceDetector(configuration: configuration) { _ in }
        let start = ContinuousClock.now
        _ = detector.evaluate(levelDB: loud, at: start)
        detector.noteTranscript("明天下雨吗", at: start + .seconds(1))
        #expect(detector.evaluate(levelDB: loud, at: start + .milliseconds(1700)) == nil)
        #expect(detector.evaluate(levelDB: loud, at: start + .milliseconds(1800)) == .transcriptSettled("明天下雨吗"))
        // 同一段文字不再发；说完判定照常。
        #expect(detector.evaluate(levelDB: loud, at: start + .milliseconds(2000)) == nil)
        // 又开口：新文字稳定后再发一次。
        detector.noteTranscript("明天下雨吗要带伞吗", at: start + .milliseconds(2100))
        #expect(detector.evaluate(levelDB: loud, at: start + .milliseconds(2900)) == .transcriptSettled("明天下雨吗要带伞吗"))
        #expect(detector.evaluate(levelDB: loud, at: start + .milliseconds(3600)) == .finishedSpeaking)
    }

    @Test func settledWaitsForQuietAudio() throws {
        var configuration = self.configuration
        configuration.settledDuration = .milliseconds(800)
        configuration.settledQuietDuration = .milliseconds(500)
        let detector = SilenceDetector(configuration: configuration) { _ in }
        let start = ContinuousClock.now
        _ = detector.evaluate(levelDB: loud, at: start)
        detector.noteTranscript("明天下雨吗", at: start + .seconds(1))
        // 文字已稳定 0.8 秒，但还在出声（转录跟不上）：不提前发。
        #expect(detector.evaluate(levelDB: loud, at: start + .milliseconds(1800)) == nil)
        #expect(detector.evaluate(levelDB: loud, at: start + .milliseconds(1900)) == nil)
        // 之后每 20 ms 一个安静 buffer：平滑音量要几个 buffer 才降下来，再满 0.5 秒才发。
        var time = start + .milliseconds(1900)
        var firedAt: ContinuousClock.Instant?
        while firedAt == nil, time < start + .milliseconds(3300) {
            time += .milliseconds(20)
            if detector.evaluate(levelDB: quiet, at: time) == .transcriptSettled("明天下雨吗") {
                firedAt = time
            }
        }
        let fired = try #require(firedAt)
        #expect(fired - (start + .milliseconds(1900)) >= .milliseconds(500))
        #expect(fired - (start + .milliseconds(1900)) <= .milliseconds(800))
    }

    @Test func settledUsesLevelRelativeToSpeech() {
        var configuration = self.configuration
        configuration.settledDuration = .milliseconds(800)
        configuration.settledQuietDuration = .milliseconds(500)
        configuration.settledRelativeDropDB = 15
        let detector = SilenceDetector(configuration: configuration) { _ in }
        let start = ContinuousClock.now
        // 说话约 -20 dB；之后环境音 -40 dB：高于固定的 -45 dB，但比说话低 20 dB，算安静。
        var time = start
        for _ in 0..<20 {
            _ = detector.evaluate(levelDB: loud, at: time)
            time += .milliseconds(50)
        }
        detector.noteTranscript("明天下雨吗", at: time)
        var event: SilenceDetectorEvent?
        while event == nil, time < start + .seconds(5) {
            time += .milliseconds(50)
            event = detector.evaluate(levelDB: -40, at: time)
        }
        #expect(event == .transcriptSettled("明天下雨吗"))
        #expect(time - (start + .seconds(1)) < .milliseconds(1500))
        let levels = detector.levelSnapshot()
        #expect((levels.speechDB ?? -160) > -21)
        #expect((levels.currentDB ?? 0) < -35)
    }
}

// MARK: - 耗时记录

struct SessionTimingTests {

    @Test func roundTripsThroughJSON() {
        var timing = SessionTiming(pressToListeningMs: 420, stopTrigger: .silence)
        timing.network = NetworkTiming(tlsMs: 180, waitFirstByteMs: 2100, reused: false)
        timing.answerTotalMs = 3300
        #expect(SessionTiming.decode(timing.encoded()) == timing)
    }

    @Test func decodeToleratesMissingAndGarbageData() {
        #expect(SessionTiming.decode(nil) == nil)
        #expect(SessionTiming.decode(Data("not json".utf8)) == nil)
        // 旧版本只记了部分字段：其余字段为 nil，不报错。
        #expect(SessionTiming.decode(Data(#"{"llmMs": 900}"#.utf8))?.llmMs == 900)
    }

    @Test func logLineListsOnlyRecordedFieldsInOrder() {
        var timing = SessionTiming(listeningMs: 3000, stopTrigger: .button)
        timing.network = NetworkTiming(dnsMs: 12, reused: true)
        timing.succeeded = true
        #expect(timing.logLine == "listeningMs=3000 stopTrigger=button reused=true dnsMs=12 succeeded=true")
    }

    @Test func formatsMilliseconds() {
        #expect(TimingCard.format(850) == "850 毫秒")
        #expect(TimingCard.format(3250) == "3.2 秒")
    }
}

// MARK: - 录音末尾静音

struct RecordingTrimmerTests {

    @Test func keepsSpeechPlusPadding() {
        #expect(RecordingTrimmer.keepDuration(speechEndSeconds: 3.0, recordedSeconds: 5.0) == 3.5)
    }

    @Test func skipsWhenTrimIsTooShort() {
        // 只能截掉 0.2 秒：不值得重新编码。
        #expect(RecordingTrimmer.keepDuration(speechEndSeconds: 3.0, recordedSeconds: 3.7) == nil)
    }

    @Test func skipsWithoutSpeech() {
        #expect(RecordingTrimmer.keepDuration(speechEndSeconds: nil, recordedSeconds: 5.0) == nil)
        #expect(RecordingTrimmer.keepDuration(speechEndSeconds: 0, recordedSeconds: 5.0) == nil)
    }

    @Test func neverKeepsMoreThanRecorded() {
        #expect(RecordingTrimmer.keepDuration(speechEndSeconds: 4.9, recordedSeconds: 5.0) == nil)
    }
}

// MARK: - 链接收藏（M-C2）

struct SharedLinkInputTests {

    @Test func dropsURLFromNoteWhenSameInputPassedTwice() {
        let url = URL(string: "https://example.com/a?b=1")!
        let input = SessionCoordinator.resolveSharedInput(url: url, text: "https://example.com/a?b=1")
        #expect(input.url == url)
        #expect(input.note == nil)
    }

    @Test func extractsFirstLinkFromText() {
        let input = SessionCoordinator.resolveSharedInput(url: nil, text: "【周末去的咖啡店】 https://xhslink.com/abc 复制打开")
        #expect(input.url?.host() == "xhslink.com")
        #expect(input.note == "【周末去的咖啡店】  复制打开")
    }

    @Test func keepsPlainTextWithoutLink() {
        let input = SessionCoordinator.resolveSharedInput(url: nil, text: "  记一下：周三交房租  ")
        #expect(input.url == nil)
        #expect(input.note == "记一下：周三交房租")
    }

    @Test func ignoresNonHTTPURLButKeepsItInNote() {
        let url = URL(string: "file:///tmp/a.txt")!
        let input = SessionCoordinator.resolveSharedInput(url: url, text: nil)
        #expect(input.url == nil)
        #expect(input.note == "file:///tmp/a.txt")
    }

    @Test func emptyInputHasNothing() {
        let input = SessionCoordinator.resolveSharedInput(url: nil, text: "   ")
        #expect(input.url == nil)
        #expect(input.note == nil)
    }

    @Test func classifiesOrganizeErrors() {
        #expect(SessionCoordinator.isDeferrableOrganizeError(LLMError.offline))
        #expect(SessionCoordinator.isDeferrableOrganizeError(LLMError.timeout))
        #expect(SessionCoordinator.isDeferrableOrganizeError(LLMError.http(status: 503)))
        #expect(SessionCoordinator.isDeferrableOrganizeError(LLMError.http(status: 429)))
        #expect(!SessionCoordinator.isDeferrableOrganizeError(LLMError.http(status: 401)))
        #expect(!SessionCoordinator.isDeferrableOrganizeError(LLMError.missingAPIKey))
        #expect(!SessionCoordinator.isDeferrableOrganizeError(LLMError.badResponse("x")))
        #expect(!SessionCoordinator.isDeferrableOrganizeError(LLMError.truncated))
    }
}

struct LinkMetadataParsingTests {

    @Test func parsesOpenGraphInAnyAttributeOrder() {
        let html = """
            <html><head>
            <title> 备用 &amp; 标题 </title>
            <meta content="一家&quot;安静&quot;的咖啡店" property="og:description">
            <meta property='og:title' content='小巷咖啡 &#x2615;'>
            </head><body></body></html>
            """
        let meta = LinkMetadataFetcher.parsePageMeta(html)
        #expect(meta.ogTitle == "小巷咖啡 ☕")
        #expect(meta.htmlTitle == "备用 & 标题")
        #expect(meta.description == "一家\"安静\"的咖啡店")
    }

    @Test func fallsBackToMetaDescription() {
        let html = #"<head><META NAME="description" CONTENT="普通描述"></head>"#
        let meta = LinkMetadataFetcher.parsePageMeta(html)
        #expect(meta.ogTitle == nil)
        #expect(meta.description == "普通描述")
    }

    @Test func onlyHTTPLinksAreFetchable() {
        #expect(LinkMetadataFetcher.isFetchable(URL(string: "https://a.com")!))
        #expect(LinkMetadataFetcher.isFetchable(URL(string: "http://a.com/x")!))
        #expect(!LinkMetadataFetcher.isFetchable(URL(string: "weixin://dl/x")!))
        #expect(!LinkMetadataFetcher.isFetchable(URL(string: "file:///a")!))
    }
}

struct PromotionalTextTests {

    @Test func cleansXiaohongshuShareText() {
        let text = "【周末去的咖啡店 - 小王 | 小红书 - 你的生活指南】 😆 AbCdEf123 😆 http://xhslink.com/a/x1Y2，复制本条信息，打开【小红书】App查看精彩内容！"
        let input = SessionCoordinator.resolveSharedInput(url: nil, text: text)
        #expect(input.url?.host() == "xhslink.com")
        #expect(input.note == "周末去的咖啡店 - 小王")
    }

    @Test func cleansNewerXiaohongshuFormat() {
        let text = "超好吃的番茄牛腩 http://xhslink.com/o/abc 复制后打开【小红书】查看笔记！"
        let input = SessionCoordinator.resolveSharedInput(url: nil, text: text)
        #expect(input.note == "超好吃的番茄牛腩")
    }

    @Test func linkOnlyLeavesNoNote() {
        let input = SessionCoordinator.resolveSharedInput(url: nil, text: "http://xhslink.com/o/abc 复制后打开【小红书】查看笔记！")
        #expect(input.url != nil)
        #expect(input.note == nil)
    }

    @Test func keepsUnrecognizedText() {
        #expect(SessionCoordinator.cleanPromotionalText("周末去，记得带伞") == "周末去，记得带伞")
        #expect(SessionCoordinator.cleanPromotionalText("【第一】和【第二】") == "【第一】和【第二】")
    }
}

struct LinkExcerptAndImageTests {

    @Test func extractsWeChatArticleBody() {
        let paragraph = String(repeating: "第二艘国产大型邮轮今天在上海出坞，", count: 4)
        let html = """
            <html><head><script>var msg_cdn_url = "https://mmbiz.qpic.cn/cover.jpg";</script></head>
            <body><nav>首页 关于</nav><div class="rich_media_content" id="js_content">
            <p>\(paragraph)</p><script>track()</script><p>全长 341 米。</p></div></body></html>
            """
        let meta = LinkMetadataFetcher.parsePageMeta(html, baseURL: URL(string: "https://mp.weixin.qq.com/s/abc"))
        let excerpt = meta.excerpt ?? ""
        #expect(excerpt.hasPrefix("第二艘国产大型邮轮"))
        #expect(excerpt.contains("全长 341 米。"))
        #expect(!excerpt.contains("track()"))
        #expect(!excerpt.contains("首页"))
        #expect(meta.imageURL?.absoluteString == "https://mmbiz.qpic.cn/cover.jpg")
    }

    @Test func shortBodyIsNotAnExcerpt() {
        #expect(LinkMetadataFetcher.extractExcerpt(from: "<body><p>请在微信客户端打开链接</p></body>") == nil)
    }

    @Test func excerptIsCappedAt3000() {
        let html = "<article><p>" + String(repeating: "字", count: 5000) + "</p></article>"
        #expect(LinkMetadataFetcher.extractExcerpt(from: html)?.count == 3000)
    }

    @Test func resolvesRelativeImageAndIconURLs() {
        let html = """
            <head><meta property="og:image" content="/img/cover.png">
            <link rel="icon" href="favicon-32.png"><link rel="apple-touch-icon" href="//cdn.example.com/touch.png"></head>
            """
        let meta = LinkMetadataFetcher.parsePageMeta(html, baseURL: URL(string: "https://example.com/post/1"))
        #expect(meta.imageURL?.absoluteString == "https://example.com/img/cover.png")
        #expect(meta.iconURL?.absoluteString == "https://cdn.example.com/touch.png")
    }

    @Test func dropsDataURIImages() {
        #expect(LinkMetadataFetcher.resolveWebURL("data:image/png;base64,AAAA", baseURL: URL(string: "https://a.com")) == nil)
    }
}

struct LinkBlockingTests {

    @Test func detectsBlockedResponses() {
        #expect(LinkMetadataFetcher.isBlocked(status: 403, finalURL: URL(string: "https://www.zhihu.com/question/1")))
        #expect(LinkMetadataFetcher.isBlocked(status: 567, finalURL: URL(string: "https://www.coolapk.com/feed/1")))
        #expect(LinkMetadataFetcher.isBlocked(
            status: 200,
            finalURL: URL(string: "https://visitor.passport.weibo.cn/visitor/visitor?entry=sinawap")
        ))
        #expect(!LinkMetadataFetcher.isBlocked(status: 200, finalURL: URL(string: "https://example.com/passport-renewal-guide")))
        #expect(!LinkMetadataFetcher.isBlocked(status: 404, finalURL: URL(string: "https://example.com/gone")))
    }

    @Test func stripsSiteSuffixFromTitle() {
        #expect(LinkMetadataFetcher.stripSiteSuffix("上海！复联总部大楼已亮灯！！ - rednote") == "上海！复联总部大楼已亮灯！！")
        #expect(LinkMetadataFetcher.stripSiteSuffix("普通标题") == "普通标题")
        #expect(LinkMetadataFetcher.stripSiteSuffix(" - rednote") == " - rednote")
    }

    @Test func thinTextNeedsCoverImage() {
        var metadata = LinkMetadata(title: "笔记", description: "#漫威 #钢铁侠")
        #expect(SessionCoordinator.isTextThin(metadata))
        // 小红书页面提取出的几百字评论和推荐仍算文字很少。
        metadata.excerpt = String(repeating: "评论", count: 180)
        #expect(SessionCoordinator.isTextThin(metadata))
        metadata.excerpt = String(repeating: "正文", count: 300)
        #expect(!SessionCoordinator.isTextThin(metadata))
        metadata.excerpt = nil
        metadata.description = String(repeating: "描", count: 120)
        #expect(!SessionCoordinator.isTextThin(metadata))
    }
}

struct CardSearchQueryTests {

    private let texts = ["上海！复联总部大楼已亮灯", "漫威新片宣传", "漫威", "钢铁侠"]
    private let tags = ["漫威", "钢铁侠"]

    @Test func hashTermMatchesTags() {
        #expect(CardSearchQuery("#漫威").matches(texts: texts, tags: tags))
        #expect(CardSearchQuery("＃钢铁侠").matches(texts: texts, tags: tags))
        #expect(!CardSearchQuery("#上海").matches(texts: texts, tags: tags))
    }

    @Test func plainTermMatchesAllText() {
        #expect(CardSearchQuery("上海").matches(texts: texts, tags: tags))
        #expect(CardSearchQuery("漫威").matches(texts: texts, tags: tags))
    }

    @Test func allTermsMustMatch() {
        #expect(CardSearchQuery("#漫威 上海").matches(texts: texts, tags: tags))
        #expect(!CardSearchQuery("#漫威 北京").matches(texts: texts, tags: tags))
    }

    @Test func loneHashIsIgnored() {
        #expect(CardSearchQuery("#").isEmpty)
        #expect(CardSearchQuery("  #  ").isEmpty)
        #expect(CardSearchQuery("##漫威").terms == [.init(text: "漫威", tagOnly: true)])
    }
}

struct NetworkAddressPolicyTests {

    @Test func flagsPrivateAndLocalHosts() {
        for host in ["192.168.1.1", "10.0.0.5", "172.20.3.4", "127.0.0.1", "169.254.169.254", "100.64.0.1",
                     "0.0.0.0", "localhost", "printer.local", "router", "[::1]", "fe80::1", "fd12::3", "::ffff:192.168.0.1"] {
            #expect(NetworkAddressPolicy.isPrivateHost(host), "\(host)")
        }
    }

    @Test func allowsPublicHosts() {
        for host in ["mmbiz.qpic.cn", "sns-i11.rednotecdn.com", "8.8.8.8", "172.32.0.1", "2001:4860::8888", "example.com"] {
            #expect(!NetworkAddressPolicy.isPrivateHost(host), "\(host)")
        }
    }

    @Test func dropsPageDeclaredPrivateImageURLs() {
        let base = URL(string: "https://evil.example.com/post")
        #expect(LinkMetadataFetcher.resolveWebURL("http://192.168.1.1/reset", baseURL: base) == nil)
        #expect(LinkMetadataFetcher.resolveWebURL("http://localhost:8080/x.png", baseURL: base) == nil)
        #expect(LinkMetadataFetcher.resolveWebURL("https://cdn.example.com/a.png", baseURL: base) != nil)
        // 用户自己分享的就是内网页面时，同一主机的图片可以取。
        let lanBase = URL(string: "http://192.168.1.10/wiki")
        #expect(LinkMetadataFetcher.resolveWebURL("/logo.png", baseURL: lanBase) != nil)
    }
}

struct PrivateRedirectTests {

    @Test func blocksRedirectIntoPrivateNetwork() {
        let toLAN = URLRequest(url: URL(string: "http://192.168.1.1/admin")!)
        #expect(PrivateRedirectBlocker.allowedRedirect(toLAN, originalHost: "cdn.example.com") == nil)
        let toPublic = URLRequest(url: URL(string: "https://img.example.com/a.jpg")!)
        #expect(PrivateRedirectBlocker.allowedRedirect(toPublic, originalHost: "cdn.example.com") != nil)
        let sameLANHost = URLRequest(url: URL(string: "http://192.168.1.10/b.png")!)
        #expect(PrivateRedirectBlocker.allowedRedirect(sameLANHost, originalHost: "192.168.1.10") != nil)
    }
}
