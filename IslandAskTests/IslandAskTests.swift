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
