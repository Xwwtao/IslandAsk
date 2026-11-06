//
//  QuickAnswerRun.swift
//  IslandAsk
//
//  一次快速档请求（灵动岛链路）的状态：可能是录音中提前发的（speculative），也可能是说完后发的。
//  请求在创建时就开始跑；summary 流式先到时先存着，调度器「采用」这次请求后设 summaryHandler 才会显示到灵动岛。
//  只在主线程读写；请求本身在 OpenAICompatibleProvider.ask（@concurrent）里跑。
//

import Foundation

@MainActor
final class QuickAnswerRun {

    let sessionID: UUID
    /// 发给大模型的问题（提前请求时是当时的转录文字）。
    let question: String
    /// 去掉空白和标点后的问题：和最终转录比较，判断提前请求能不能用。
    let normalizedQuestion: String
    let speculative: Bool
    /// M-C1：本地已确定的意图（没说话 = collect），透传给大模型。
    let intentHint: LLMIntent?
    let startedAt: ContinuousClock.Instant

    /// 创建后立即由调度器设置。
    var task: Task<Result<LLMAnswer, any Error>, Never>?

    private(set) var summary: String?
    /// M-C1：summary 到达时模型已经给出的 intent（提示词把 intent 排在 summary 前面）。
    private(set) var summaryIntent: LLMIntent?
    private(set) var summaryAt: ContinuousClock.Instant?
    /// 采用后才设置：summary 到了就回调（已经到了的话调度器会立即补一次）。
    var summaryHandler: ((String) -> Void)?
    /// 正在把 summary 推到灵动岛的任务：收尾前要等它，避免和最终状态的更新交错。
    var summaryShowTask: Task<Void, Never>?
    var summaryShownAt: ContinuousClock.Instant?

    // 耗时（毫秒），runAnswer 汇总进 SessionTiming。
    var jpegWaitMs: Int?
    var ocrWaitMs: Int?
    var imageBytes: Int?
    var llmStartedAt: ContinuousClock.Instant?
    var llmMs: Int?
    var activityUpdateMs: Int?

    init(
        sessionID: UUID,
        question: String,
        speculative: Bool,
        intentHint: LLMIntent? = nil,
        startedAt: ContinuousClock.Instant
    ) {
        self.sessionID = sessionID
        self.question = question
        self.normalizedQuestion = Self.normalize(question)
        self.speculative = speculative
        self.intentHint = intentHint
        self.startedAt = startedAt
    }

    var llmSummaryMs: Int? {
        guard let summaryAt, let llmStartedAt else { return nil }
        return SessionTiming.milliseconds(summaryAt - llmStartedAt)
    }

    func deliverSummary(_ summary: String, intent: LLMIntent?) {
        guard self.summary == nil else { return }
        self.summary = summary
        summaryIntent = intent
        summaryAt = .now
        summaryHandler?(summary)
    }

    func cancel() {
        task?.cancel()
    }

    /// 两段文字的编辑距离（按字符，插入 / 删除 / 替换各算 1）。未命中时记进耗时，判断差的是改字还是补话。
    nonisolated static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// 只保留文字本身：临时结果转成最终结果时常见的差别是标点和空格，这些不影响问题含义。
    nonisolated static func normalize(_ text: String) -> String {
        let dropped = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        return String(String.UnicodeScalarView(text.unicodeScalars.filter { !dropped.contains($0) }))
    }
}
