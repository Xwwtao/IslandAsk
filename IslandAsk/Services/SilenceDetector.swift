//
//  SilenceDetector.swift
//  IslandAsk
//
//  静音检测（SPEC 第 6.7 节）：以转录文字为主、音量为辅。
//    - 转录出现第一个字：标记已开口
//    - 已开口后满足任一条件就触发 stopListening（和点停止按钮同一条路径）：
//        ① 转录文字连续 1.5 秒没变化（吵的环境靠这条：语音识别会过滤掉非人声噪音）
//        ② 音量连续 1.5 秒低于 -45 dB（安静环境靠这条，结束更快）
//    - 已开口后转录文字稳定 0.8 秒且音量比说话时低 12 dB 满 0.5 秒：发 transcriptSettled，调度器提前问大模型（不结束录音，同一段文字只发一次）
//    - 6 秒内没有任何转录文字：触发 cancel，灵动岛提示「没听到」
//    - 最长 60 秒：强制 stopListening
//
//  为什么不再只看音量：环境噪音持续高于阈值时，「说完」永远不成立、「没听到」也不触发（真机已复现）。
//
//  所有阈值集中放在 SilenceDetectionConfiguration，值来自设置页（AppSettings）；每次会话开始时取一次快照。
//  音频数据在音频线程上同步进来，转录文字从主线程进来，状态用锁保护；事件只发一次，由调度器决定走 stop 还是 cancel。
//

import AVFAudio
import Foundation
import os

// MARK: - 配置（全部阈值集中在这里；会话开始时从设置页读一次快照，音频线程不读 UserDefaults）

nonisolated struct SilenceDetectionConfiguration: Sendable {
    /// 音量辅助判断：RMS 高于该值（dB）算有声音，用于刷新「最后有声音的时刻」。
    var speechEndRMSDB: Float
    /// 已开口后，音量连续低于 speechEndRMSDB 多久算说完。
    var endSilenceDuration: Duration
    /// 已开口后，转录文字连续多久没变化算说完。
    var transcriptStableDuration: Duration
    /// 一直没有转录文字的超时。
    var noSpeechTimeout: Duration
    /// 最长录音时间。
    var maxRecordingDuration: Duration
    /// 提前发请求：已开口后转录文字连续多久没变化，就发一次 transcriptSettled（每段新文字只发一次，不结束录音）。
    /// nil 表示不提前发。
    var settledDuration: Duration? = nil
    /// 提前发请求还要求音量已经安静这么久：转录文字是一阵一阵出来的，人还在说话时文字也常有 0.8 秒不变
    /// （M4 真机：每次都在说话中途用光 3 次提前请求）。
    var settledQuietDuration: Duration = .zero
    /// 提前发请求的「安静」是相对的：平滑后的音量比说话时的音量低这么多 dB（或低于 speechEndRMSDB）就算安静。
    /// 用固定 -45 dB 时普通房间的环境音就超过阈值，提前请求一次都发不出来（M4 真机）。
    /// 只影响 transcriptSettled，不影响 SPEC 6.7 的说完判定。
    var settledRelativeDropDB: Float = 15

    /// 固定用 SPEC 第 6.7 节的默认值：UI 优化时去掉了设置页里的阈值调节（看起来太复杂）。
    static var current: SilenceDetectionConfiguration {
        current(hasScreenshot: false)
    }

    /// M-C1：有截图且开启「不说话就收藏」时，不开口的判定时间用设置页的值（默认 3 秒），超时后收藏；
    /// 否则仍是 6 秒，超时后取消。
    static func current(hasScreenshot: Bool) -> SilenceDetectionConfiguration {
        typealias Defaults = AppSettings.SilenceDefaults
        let noSpeechSeconds = collectsOnNoSpeech(hasScreenshot: hasScreenshot)
            ? AppSettings.collectNoSpeechSeconds
            : Defaults.noSpeechTimeoutSeconds
        return SilenceDetectionConfiguration(
            speechEndRMSDB: Float(Defaults.speechEndRMSDB),
            endSilenceDuration: .milliseconds(Int(Defaults.endSilenceSeconds * 1000)),
            transcriptStableDuration: .milliseconds(Int(Defaults.transcriptStableSeconds * 1000)),
            noSpeechTimeout: .milliseconds(Int(noSpeechSeconds * 1000)),
            maxRecordingDuration: .milliseconds(Int(Defaults.maxRecordingSeconds * 1000)),
            settledDuration: .milliseconds(Int(Defaults.speculativeStableSeconds * 1000)),
            settledQuietDuration: .milliseconds(Int(Defaults.speculativeQuietSeconds * 1000)),
            settledRelativeDropDB: Float(Defaults.speculativeRelativeDropDB)
        )
    }

    /// 不开口超时后是收藏还是取消：需要有截图，且设置里没关。
    static func collectsOnNoSpeech(hasScreenshot: Bool) -> Bool {
        hasScreenshot && AppSettings.noSpeechCollects
    }
}

// MARK: - 事件

nonisolated enum SilenceDetectorEvent: Sendable, Equatable {
    /// 转录文字已稳定 settledDuration：调度器据此提前问大模型，录音继续。
    case transcriptSettled(String)
    case finishedSpeaking
    case noSpeechTimeout
    case maxDurationReached
}

// MARK: - SilenceDetector

nonisolated final class SilenceDetector: AudioBufferConsumer, @unchecked Sendable {

    /// 触发原因，只用于日志，方便真机调参。
    private enum Reason: String {
        case transcriptStable
        case quiet
        case noSpeech
        case maxDuration
        case settled
    }

    private struct State {
        var startedAt: ContinuousClock.Instant?
        var lastVoiceAt: ContinuousClock.Instant?
        var lastTranscript = ""
        var lastTranscriptChangeAt: ContinuousClock.Instant?
        var hasSpoken = false
        var hasEmitted = false
        /// 最后一次发出 transcriptSettled 时的文字：同一段文字只发一次。
        var lastSettledTranscript: String?
        /// 平滑后的音量（dB，指数滑动平均），避免字与字之间的短暂停顿被当成安静。
        var smoothedLevelDB: Float?
        /// 说话音量：平滑音量的最大值。
        var speechLevelDB: Float?
        /// 最后一次「相对说话音量还算响」的时刻（转录文字变化也会刷新）。
        var lastRelativeVoiceAt: ContinuousClock.Instant?
    }

    /// 平滑系数：每个 buffer（约 20–100 ms）向新值靠近的比例。
    private static let levelSmoothing: Float = 0.2

    private let clock = ContinuousClock()
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let configuration: SilenceDetectionConfiguration
    private let onEvent: @MainActor @Sendable (SilenceDetectorEvent) -> Void

    init(
        configuration: SilenceDetectionConfiguration = .current,
        onEvent: @escaping @MainActor @Sendable (SilenceDetectorEvent) -> Void
    ) {
        self.configuration = configuration
        self.onEvent = onEvent
        Self.makeLogger().info(
            "silence detector config rmsDB=\(configuration.speechEndRMSDB, privacy: .public) endSilence=\(String(describing: configuration.endSilenceDuration), privacy: .public) stable=\(String(describing: configuration.transcriptStableDuration), privacy: .public) noSpeech=\(String(describing: configuration.noSpeechTimeout), privacy: .public) max=\(String(describing: configuration.maxRecordingDuration), privacy: .public)"
        )
    }

    /// 转录有更新时调用（任意线程）。text 为 finalized + volatile 的完整显示文字；
    /// 内容没变（例如 volatile 转成 finalized）不算变化。
    func noteTranscript(_ text: String) {
        noteTranscript(text, at: clock.now)
    }

    /// 同上，时间由调用方给出（单元测试用）。
    func noteTranscript(_ text: String, at now: ContinuousClock.Instant) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let isFirst = state.withLock { state -> Bool in
            guard !state.hasEmitted, trimmed != state.lastTranscript else { return false }
            let isFirst = !state.hasSpoken
            state.hasSpoken = true
            state.lastTranscript = trimmed
            state.lastTranscriptChangeAt = now
            // 文字在变说明还在说，同时刷新音量计时，避免转录延迟期间被音量条件提前截断。
            state.lastVoiceAt = now
            state.lastRelativeVoiceAt = now
            return isFirst
        }
        if isFirst {
            Self.makeLogger().notice("silence detector: speech started (first transcript)")
        }
    }

    /// 当前的说话音量和平滑音量（dB），写进耗时记录用来调相对阈值。
    func levelSnapshot() -> (speechDB: Float?, currentDB: Float?) {
        state.withLock { ($0.speechLevelDB, $0.smoothedLevelDB) }
    }

    /// 音频线程同步调用；只在触发事件那一次回调到主线程。
    func consume(buffer: AVAudioPCMBuffer) {
        guard let event = evaluate(levelDB: Self.rmsDB(of: buffer), at: clock.now) else { return }
        let onEvent = self.onEvent
        Task { @MainActor in
            onEvent(event)
        }
    }

    /// 判定逻辑：每个音频 buffer 调用一次，返回本次触发的事件（只会返回一次）。
    /// 时间和音量由调用方给出，单元测试可以直接驱动。
    func evaluate(levelDB: Float, at now: ContinuousClock.Instant) -> SilenceDetectorEvent? {
        let configuration = self.configuration

        let decision: (event: SilenceDetectorEvent, reason: Reason, sinceTextChange: Duration?)? = state.withLock { state in
            guard !state.hasEmitted else { return nil }

            if state.startedAt == nil {
                state.startedAt = now
                state.lastVoiceAt = now
            }
            if levelDB > configuration.speechEndRMSDB {
                state.lastVoiceAt = now
            }
            let smoothed = state.smoothedLevelDB.map { $0 + (levelDB - $0) * Self.levelSmoothing } ?? levelDB
            state.smoothedLevelDB = smoothed
            let speechLevel = max(state.speechLevelDB ?? smoothed, smoothed)
            state.speechLevelDB = speechLevel
            if smoothed > configuration.speechEndRMSDB, smoothed > speechLevel - configuration.settledRelativeDropDB {
                state.lastRelativeVoiceAt = now
            }

            guard let startedAt = state.startedAt else { return nil }
            let sinceTextChange = state.lastTranscriptChangeAt.map { now - $0 }

            if state.hasSpoken {
                if let sinceTextChange, sinceTextChange >= configuration.transcriptStableDuration {
                    state.hasEmitted = true
                    return (.finishedSpeaking, .transcriptStable, sinceTextChange)
                }
                if let lastVoiceAt = state.lastVoiceAt,
                   now - lastVoiceAt >= configuration.endSilenceDuration {
                    state.hasEmitted = true
                    return (.finishedSpeaking, .quiet, sinceTextChange)
                }
            } else if now - startedAt >= configuration.noSpeechTimeout {
                state.hasEmitted = true
                return (.noSpeechTimeout, .noSpeech, sinceTextChange)
            }

            if now - startedAt >= configuration.maxRecordingDuration {
                state.hasEmitted = true
                return (.maxDurationReached, .maxDuration, sinceTextChange)
            }

            // 说完判定之前的「差不多说完了」：不设 hasEmitted，录音继续，文字再变还能再发。
            if state.hasSpoken,
               let settled = configuration.settledDuration,
               let sinceTextChange, sinceTextChange >= settled,
               let lastRelativeVoiceAt = state.lastRelativeVoiceAt,
               now - lastRelativeVoiceAt >= configuration.settledQuietDuration,
               state.lastSettledTranscript != state.lastTranscript {
                state.lastSettledTranscript = state.lastTranscript
                return (.transcriptSettled(state.lastTranscript), .settled, sinceTextChange)
            }

            return nil
        }

        guard let decision else { return nil }
        let sinceTextChange = decision.sinceTextChange.map { "\($0)" } ?? "nil"
        // transcriptSettled 带着转录文字，日志里只记原因，不打印文字。
        let eventName: String
        if case .transcriptSettled = decision.event {
            eventName = "transcriptSettled"
        } else {
            eventName = String(describing: decision.event)
        }
        Self.makeLogger().notice(
            "silence detector event=\(eventName, privacy: .public) reason=\(decision.reason.rawValue, privacy: .public) levelDB=\(levelDB, privacy: .public) sinceTextChange=\(sinceTextChange, privacy: .public)"
        )
        return decision.event
    }

    private static func makeLogger() -> Logger {
        Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
            category: "audio"
        )
    }

    // MARK: - RMS

    /// 输入节点 tap 出来的是 Float32；其它格式按静音处理（避免误触发录音结束）。
    private static func rmsDB(of buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let data = buffer.floatChannelData else {
            return -160
        }
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0, channelCount > 0 else { return -160 }

        var sum: Float = 0
        for channel in 0..<channelCount {
            let samples = data[channel]
            for index in 0..<frameLength {
                let value = samples[index]
                sum += value * value
            }
        }
        let meanSquare = sum / Float(frameLength * channelCount)
        return 10 * log10f(meanSquare + 1e-12)
    }
}
