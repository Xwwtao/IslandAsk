//
//  SilenceDetector.swift
//  IslandAsk
//
//  静音检测（SPEC 第 6.7 节）：以转录文字为主、音量为辅。
//    - 转录出现第一个字：标记已开口
//    - 已开口后满足任一条件就触发 stopListening（和点停止按钮同一条路径）：
//        ① 转录文字连续 1.5 秒没变化（吵的环境靠这条：语音识别会过滤掉非人声噪音）
//        ② 音量连续 1.5 秒低于 -45 dB（安静环境靠这条，结束更快）
//    - 6 秒内没有任何转录文字：触发 cancel，灵动岛提示「没听到」
//    - 最长 60 秒：强制 stopListening
//
//  为什么不再只看音量：环境噪音持续高于阈值时，「说完」永远不成立、「没听到」也不触发（真机已复现）。
//
//  所有阈值集中放在 SilenceDetectionConfiguration，M3 设置页再接 UI（现在不拆设置项）。
//  音频数据在音频线程上同步进来，转录文字从主线程进来，状态用锁保护；事件只发一次，由调度器决定走 stop 还是 cancel。
//

import AVFAudio
import Foundation
import os

// MARK: - 配置（全部阈值集中在这里，M3 设置页直接读这里）

nonisolated enum SilenceDetectionConfiguration {
    /// 音量辅助判断：RMS 高于该值（dB）算有声音，用于刷新「最后有声音的时刻」。
    static let speechEndRMSDB: Float = -45
    /// 已开口后，音量连续低于 speechEndRMSDB 多久算说完。
    static let endSilenceDuration: Duration = .milliseconds(1500)
    /// 已开口后，转录文字连续多久没变化算说完。
    static let transcriptStableDuration: Duration = .milliseconds(1500)
    /// 一直没有转录文字的超时。
    static let noSpeechTimeout: Duration = .seconds(6)
    /// 最长录音时间。
    static let maxRecordingDuration: Duration = .seconds(60)
}

// MARK: - 事件

nonisolated enum SilenceDetectorEvent: Sendable {
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
    }

    private struct State {
        var startedAt: ContinuousClock.Instant?
        var lastVoiceAt: ContinuousClock.Instant?
        var lastTranscript = ""
        var lastTranscriptChangeAt: ContinuousClock.Instant?
        var hasSpoken = false
        var hasEmitted = false
    }

    private let clock = ContinuousClock()
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let onEvent: @MainActor @Sendable (SilenceDetectorEvent) -> Void

    init(onEvent: @escaping @MainActor @Sendable (SilenceDetectorEvent) -> Void) {
        self.onEvent = onEvent
    }

    /// 转录有更新时调用（任意线程）。text 为 finalized + volatile 的完整显示文字；
    /// 内容没变（例如 volatile 转成 finalized）不算变化。
    func noteTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = clock.now

        let isFirst = state.withLock { state -> Bool in
            guard !state.hasEmitted, trimmed != state.lastTranscript else { return false }
            let isFirst = !state.hasSpoken
            state.hasSpoken = true
            state.lastTranscript = trimmed
            state.lastTranscriptChangeAt = now
            // 文字在变说明还在说，同时刷新音量计时，避免转录延迟期间被音量条件提前截断。
            state.lastVoiceAt = now
            return isFirst
        }
        if isFirst {
            Self.makeLogger().notice("silence detector: speech started (first transcript)")
        }
    }

    /// 音频线程同步调用；只在触发事件那一次回调到主线程。
    func consume(buffer: AVAudioPCMBuffer) {
        let now = clock.now
        let levelDB = Self.rmsDB(of: buffer)

        let decision: (event: SilenceDetectorEvent, reason: Reason, sinceTextChange: Duration?)? = state.withLock { state in
            guard !state.hasEmitted else { return nil }

            if state.startedAt == nil {
                state.startedAt = now
                state.lastVoiceAt = now
            }
            if levelDB > SilenceDetectionConfiguration.speechEndRMSDB {
                state.lastVoiceAt = now
            }

            guard let startedAt = state.startedAt else { return nil }
            let sinceTextChange = state.lastTranscriptChangeAt.map { now - $0 }

            if state.hasSpoken {
                if let sinceTextChange, sinceTextChange >= SilenceDetectionConfiguration.transcriptStableDuration {
                    state.hasEmitted = true
                    return (.finishedSpeaking, .transcriptStable, sinceTextChange)
                }
                if let lastVoiceAt = state.lastVoiceAt,
                   now - lastVoiceAt >= SilenceDetectionConfiguration.endSilenceDuration {
                    state.hasEmitted = true
                    return (.finishedSpeaking, .quiet, sinceTextChange)
                }
            } else if now - startedAt >= SilenceDetectionConfiguration.noSpeechTimeout {
                state.hasEmitted = true
                return (.noSpeechTimeout, .noSpeech, sinceTextChange)
            }

            if now - startedAt >= SilenceDetectionConfiguration.maxRecordingDuration {
                state.hasEmitted = true
                return (.maxDurationReached, .maxDuration, sinceTextChange)
            }

            return nil
        }

        guard let decision else { return }
        let sinceTextChange = decision.sinceTextChange.map { "\($0)" } ?? "nil"
        Self.makeLogger().notice(
            "silence detector event=\(String(describing: decision.event), privacy: .public) reason=\(decision.reason.rawValue, privacy: .public) levelDB=\(levelDB, privacy: .public) sinceTextChange=\(sinceTextChange, privacy: .public)"
        )
        let onEvent = self.onEvent
        let event = decision.event
        Task { @MainActor in
            onEvent(event)
        }
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
