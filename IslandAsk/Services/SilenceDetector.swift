//
//  SilenceDetector.swift
//  IslandAsk
//
//  静音检测（SPEC 第 6.7 节）：
//    - 音量 RMS 高于 -40 dB：标记已开口
//    - 已开口后连续 1.5 秒低于 -45 dB：触发 stopListening（和点停止按钮同一条路径）
//    - 6 秒内未开口：触发 cancel，灵动岛提示「没听到」
//    - 最长 60 秒：强制 stopListening
//
//  所有阈值集中放在 SilenceDetectionConfiguration，M3 设置页再接 UI（现在不拆设置项）。
//  本类在音频线程上同步跑，状态用锁保护，事件只发一次，由调度器决定走 stop 还是 cancel。
//

import AVFAudio
import Foundation
import os

// MARK: - 配置（全部阈值集中在这里，M3 设置页直接读这里）

nonisolated enum SilenceDetectionConfiguration {
    /// 开始说话的判定：RMS 高于该值（dB）。
    static let speechStartRMSDB: Float = -40
    /// 说完的判定：RMS 低于该值（dB）持续 endSilenceDuration。
    static let speechEndRMSDB: Float = -45
    /// 已开口后，连续静音多久算说完。
    static let endSilenceDuration: Duration = .milliseconds(1500)
    /// 一直不开口的超时。
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

    private struct State {
        var startedAt: ContinuousClock.Instant?
        var lastVoiceAt: ContinuousClock.Instant?
        var hasSpoken = false
        var hasEmitted = false
    }

    private let clock = ContinuousClock()
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let onEvent: @MainActor @Sendable (SilenceDetectorEvent) -> Void

    init(onEvent: @escaping @MainActor @Sendable (SilenceDetectorEvent) -> Void) {
        self.onEvent = onEvent
    }

    /// 音频线程同步调用；只在触发事件那一次回调到主线程。
    func consume(buffer: AVAudioPCMBuffer) {
        let now = clock.now
        let levelDB = Self.rmsDB(of: buffer)

        let event: SilenceDetectorEvent? = state.withLock { state in
            guard !state.hasEmitted else { return nil }

            if state.startedAt == nil {
                state.startedAt = now
                state.lastVoiceAt = now
            }

            if levelDB > SilenceDetectionConfiguration.speechStartRMSDB {
                state.hasSpoken = true
            }
            if state.hasSpoken, levelDB > SilenceDetectionConfiguration.speechEndRMSDB {
                state.lastVoiceAt = now
            }

            guard let startedAt = state.startedAt else { return nil }

            if state.hasSpoken,
               let lastVoiceAt = state.lastVoiceAt,
               now - lastVoiceAt >= SilenceDetectionConfiguration.endSilenceDuration {
                state.hasEmitted = true
                return .finishedSpeaking
            }

            if !state.hasSpoken, now - startedAt >= SilenceDetectionConfiguration.noSpeechTimeout {
                state.hasEmitted = true
                return .noSpeechTimeout
            }

            if now - startedAt >= SilenceDetectionConfiguration.maxRecordingDuration {
                state.hasEmitted = true
                return .maxDurationReached
            }

            return nil
        }

        guard let event else { return }
        Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
            category: "audio"
        ).info(
            "silence detector event=\(String(describing: event), privacy: .public) levelDB=\(levelDB, privacy: .public)"
        )
        Task { @MainActor in
            onEvent(event)
        }
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
