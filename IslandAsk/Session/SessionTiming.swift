//
//  SessionTiming.swift
//  IslandAsk
//
//  一次提问各环节的耗时（毫秒），存进 AskSession.timingData，会话页的耗时卡片显示，同时写 timing 日志。
//  字段全部可选：失败的会话、旧版本没记到的环节就是 nil。字段名一旦发布不要改，方便前后对比。
//

import Foundation

/// 一次 HTTP 请求最后一次传输的各阶段耗时（URLSessionTaskMetrics）。复用连接时 DNS / 建连 / TLS 为 nil。
nonisolated struct NetworkTiming: Codable, Sendable, Equatable {
    var dnsMs: Int?
    var connectMs: Int?
    var tlsMs: Int?
    var uploadMs: Int?
    /// 上传完到收到第一个字节：基本就是模型处理时间。
    var waitFirstByteMs: Int?
    var downloadMs: Int?
    var totalMs: Int?
    var reused: Bool?
    var sentBytes: Int?
}

nonisolated struct SessionTiming: Codable, Sendable, Equatable {

    nonisolated enum StopTrigger: String, Codable, Sendable {
        case silence
        case button
        case maxDuration
    }

    /// 提前发的请求最后有没有用上。
    nonisolated enum Speculation: String, Codable, Sendable {
        /// 最终转录和提前请求的问题一致，直接用提前请求的结果。
        case hit
        /// 发过提前请求，但最终转录不一样，说完后重新发。
        case miss
    }

    // MARK: 提问

    /// Intent perform 开始 → 音频和转录都跑起来（含保存截图、启动灵动岛）。
    var pressToListeningMs: Int?
    // 「按键到开始听」的分段（M4）：
    /// Intent perform 开始 → SessionCoordinator.start 被调用（主要是保存截图）。
    var screenshotSaveMs: Int?
    /// 结束上一个会话和残留的灵动岛。
    var startEndPreviousMs: Int?
    /// Activity.request 启动灵动岛。
    var startActivityRequestMs: Int?
    /// 选好并准备转录引擎。
    var startTranscriptionPrepareMs: Int?
    /// 激活音频会话、启动录音。
    var startAudioMs: Int?
    /// 启动转录分析。
    var startTranscriptionActivateMs: Int?
    /// 开始听 → 结束录音。
    var listeningMs: Int?
    /// 最后一次转录文字变化 → 结束录音（静音判定的等待时间）。
    var endDetectionMs: Int?
    var stopTrigger: StopTrigger?
    /// 说话时的平滑音量最大值（dB）。和 endLevelDB 一起用来调提前请求的相对阈值。
    var speechLevelDB: Int?
    /// 结束录音时的平滑音量（dB），基本就是环境音。
    var endLevelDB: Int?

    // MARK: 回答（快速档，灵动岛链路）

    var transcriptFinishMs: Int?
    /// 采用的那次请求等截图压缩的时间（M4 起压缩在录音期间就开始，通常接近 0）。
    var jpegEncodeMs: Int?
    var imageBytes: Int?
    var ocrWaitMs: Int?
    /// 调用 ask 的总耗时（含重试），即完整回答生成完。
    var llmMs: Int?
    /// 发出请求 → 流式拿到完整 summary。
    var llmSummaryMs: Int?
    var attempts: Int?
    /// 最后一次请求的网络分段。
    var network: NetworkTiming?
    var activityUpdateMs: Int?
    /// 结束录音 → 灵动岛显示回答（或失败）。M4 起是显示摘要的时间，完整回答见 fullAnswerMs。
    var answerTotalMs: Int?
    /// 结束录音 → 完整回答生成完（写进数据库）。提前请求命中时可能很小。
    var fullAnswerMs: Int?
    var succeeded: Bool?
    /// 快速档请求失败的原因（LLMError.logDescription）。失败、或摘要已显示但完整回答没拿到（降级）时才有。
    var answerError: String?
    /// 提前请求的结果；本次没发过提前请求为 nil。
    var speculation: Speculation?
    /// 本次会话一共发了几次提前请求（含被取消的）。
    var speculativeRequests: Int?
    /// 命中时，用上的那次请求比结束录音早发了多久。
    var speculationLeadMs: Int?
    // 未命中时两段文字的差异（都是去掉标点空格后的字数，不记原文）：
    /// 提前请求时的问题字数。
    var missSpeculativeChars: Int?
    /// 最终转录字数。
    var missFinalChars: Int?
    /// 两者的编辑距离：1–2 多半是识别改了字，接近字数差且 missIsExtension 为 true 是停顿后补了话。
    var missEditDistance: Int?
    /// 最终转录以提前请求的问题开头（只是在后面补了话）。
    var missIsExtension: Bool?
    /// 回答之后截掉的录音末尾静音（不计入 answerTotalMs）；没截为 nil。
    var trimmedSilenceMs: Int?

    // MARK: 深度回答（会话页，从请求开始算起）

    var deepFirstReasoningMs: Int?
    var deepFirstContentMs: Int?
    var deepTotalMs: Int?
    var deepSucceeded: Bool?

    // MARK: - 编解码

    static func decode(_ data: Data?) -> SessionTiming? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(SessionTiming.self, from: data)
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    // MARK: - 日志 / 复制

    /// 一行 key=value，只含有值的字段。timing 日志和会话页「复制耗时」共用这一行。
    var logLine: String {
        var pairs: [(String, String)] = []
        func add(_ key: String, _ value: (some CustomStringConvertible)?) {
            if let value { pairs.append((key, value.description)) }
        }
        add("pressToListeningMs", pressToListeningMs)
        add("screenshotSaveMs", screenshotSaveMs)
        add("startEndPreviousMs", startEndPreviousMs)
        add("startActivityRequestMs", startActivityRequestMs)
        add("startTranscriptionPrepareMs", startTranscriptionPrepareMs)
        add("startAudioMs", startAudioMs)
        add("startTranscriptionActivateMs", startTranscriptionActivateMs)
        add("listeningMs", listeningMs)
        add("endDetectionMs", endDetectionMs)
        add("stopTrigger", stopTrigger?.rawValue)
        add("speechLevelDB", speechLevelDB)
        add("endLevelDB", endLevelDB)
        add("transcriptFinishMs", transcriptFinishMs)
        add("jpegEncodeMs", jpegEncodeMs)
        add("imageBytes", imageBytes)
        add("ocrWaitMs", ocrWaitMs)
        add("llmMs", llmMs)
        add("llmSummaryMs", llmSummaryMs)
        add("attempts", attempts)
        add("reused", network?.reused)
        add("dnsMs", network?.dnsMs)
        add("connectMs", network?.connectMs)
        add("tlsMs", network?.tlsMs)
        add("uploadMs", network?.uploadMs)
        add("waitFirstByteMs", network?.waitFirstByteMs)
        add("downloadMs", network?.downloadMs)
        add("sentBytes", network?.sentBytes)
        add("activityUpdateMs", activityUpdateMs)
        add("answerTotalMs", answerTotalMs)
        add("fullAnswerMs", fullAnswerMs)
        add("succeeded", succeeded)
        add("answerError", answerError.map { "\"\($0)\"" })
        add("speculation", speculation?.rawValue)
        add("speculativeRequests", speculativeRequests)
        add("speculationLeadMs", speculationLeadMs)
        add("missSpeculativeChars", missSpeculativeChars)
        add("missFinalChars", missFinalChars)
        add("missEditDistance", missEditDistance)
        add("missIsExtension", missIsExtension)
        add("trimmedSilenceMs", trimmedSilenceMs)
        add("deepFirstReasoningMs", deepFirstReasoningMs)
        add("deepFirstContentMs", deepFirstContentMs)
        add("deepTotalMs", deepTotalMs)
        add("deepSucceeded", deepSucceeded)
        return pairs.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
    }

    static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
