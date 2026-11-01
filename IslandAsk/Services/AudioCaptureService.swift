//
//  AudioCaptureService.swift
//  IslandAsk
//
//  M0 只负责把麦克风数据写成 Documents/sessions/<sessionID>.m4a，用来验证确实录到了声音。
//  M1 会在这里把 tap 出来的 buffer 同时分发给转录服务和静音检测器（SPEC 第 6.5 节）。
//
//  真机踩出来的约束（都写在这里，避免以后改回去）：
//  1. 后台激活的 session 必须可混音（.mixWithOthers），否则系统按
//     AVAudioSession.ErrorCode.cannotInterruptOthers（FourCC '!int'）拒绝激活。
//     .mixWithOthers 只能配合 .playAndRecord / .playback / .multiRoute，所以用 .playAndRecord。
//  2. 首次录音会话要在前台成功激活过一次；App 在前台时用 primeAudioSessionInForeground() 预热。
//  3. AVAudioSession 的同步配置/激活不能在主线程做（系统日志 AVAudioSession_iOS.mm:978 会警告，
//     冷启动首次会卡住 UI 和停止按钮），统一走 runOffMain 在后台线程执行。
//

import AVFAudio
import Foundation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
    category: "audio"
)

@MainActor
final class AudioCaptureService {

    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var tapInstalled = false
    private var isRunning = false

    /// 采集是否真的在跑（供调度器识别「会话还在但采集已经停了」的异常态）。
    var isCapturing: Bool {
        isRunning
    }

    static func audioFileURL(sessionID: UUID) throws -> URL {
        try ScreenshotStore.sessionsDirectory()
            .appendingPathComponent(sessionID.uuidString)
            .appendingPathExtension("m4a")
    }

    /// App 在前台且麦克风已授权时调用：成功激活录音会话再立刻释放。
    /// 这是真机上「后台起录」的前置条件；用 .mixWithOthers 激活不会打断用户正在播放的音乐。
    @discardableResult
    static func primeAudioSessionInForeground() async -> Bool {
        do {
            try await runOffMain {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)
                try session.setActive(false, options: .notifyOthersOnDeactivation)
            }
            logger.info("audio session primed in foreground")
            return true
        } catch {
            logger.error("audio session prime failed \(describe(error), privacy: .public)")
            return false
        }
    }

    /// 配置并激活音频会话（后台线程）→ 安装 tap 并写入 m4a → 启动引擎。
    /// 顺序按 SPEC 第 4 节第 5 步；调用方（Intent perform）会 await 到真正开始录音才返回，
    /// 不会缩短 AudioRecordingIntent 的授权窗口。
    func start(sessionID: UUID, fileURL: URL) async throws {
        guard !isRunning else {
            logger.error("start ignored: audio capture already running")
            return
        }
        logger.info("start requested session=\(sessionID.uuidString, privacy: .public)")

        do {
            try await Self.runOffMain {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)
            }
            logger.info("audio category configured + session activated (off main thread)")
        } catch {
            logger.error("session configure/activate failed \(Self.describe(error), privacy: .public)")
            throw error
        }

        do {
            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                logger.error(
                    "invalid input format sampleRate=\(inputFormat.sampleRate, privacy: .public) channels=\(inputFormat.channelCount, privacy: .public)"
                )
                throw AudioCaptureError.invalidInputFormat
            }

            let fileSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: inputFormat.sampleRate,
                AVNumberOfChannelsKey: inputFormat.channelCount,
            ]
            let file = try AVAudioFile(forWriting: fileURL, settings: fileSettings)
            audioFile = file

            // 音频回调线程里不碰 self，只用局部常量；写失败时打日志，避免静默丢数据。
            let writeLogger = Logger(
                subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
                category: "audio"
            )
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
                do {
                    try file.write(from: buffer)
                } catch {
                    writeLogger.error("audio buffer write failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            tapInstalled = true
            logger.info("audio tap installed bufferSize=1024")

            engine.prepare()
            try engine.start()
            isRunning = true
            logger.info("engine started file=\(fileURL.lastPathComponent, privacy: .public)")
        } catch {
            logger.error("start failed \(Self.describe(error), privacy: .public)")
            stopCaptureKeepingSessionActive()
            await deactivateAudioSession()
            throw error
        }
    }

    /// 停止采集，但**保持音频会话激活**。
    /// 音频会话是 App 在后台唯一的保活来源：结束 Live Activity 之前必须留着它，
    /// 否则进程可能在 `activity.end(...)` 完成前被系统挂起，灵动岛就会残留（真机已复现）。
    func stopCaptureKeepingSessionActive() {
        logger.info("stop capture requested (session kept active)")
        guard isRunning else {
            logger.error("stop capture ignored: audio capture not running")
            return
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        audioFile = nil
        isRunning = false
        logger.info("capture stopped, audio session still active")
    }

    /// 停止链路的最后一步：关闭音频会话（后台线程）。调用前应确保 Live Activity 已经结束。
    func deactivateAudioSession() async {
        do {
            try await Self.runOffMain {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
            logger.info("audio session deactivated")
        } catch {
            logger.error("audio session deactivate failed \(Self.describe(error), privacy: .public)")
        }
    }

    /// 把 AVAudioSession 的同步配置/激活挪到后台线程。
    /// 系统日志：AVAudioSession_iOS.mm:978 "This method can lead to UI unresponsiveness if called on
    /// the main thread"；冷启动第一次触发时，主线程被它占住会导致停止按钮无响应、App 卡住。
    private static func runOffMain(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try work()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 把错误整理成带 domain/code 的日志；OSStatus 错误额外解出 FourCC（如 '!int'），方便真机排查。
    private static func describe(_ error: any Error) -> String {
        let nsError = error as NSError
        return "domain=\(nsError.domain) code=\(nsError.code)\(fourCCDetail(for: nsError)) error=\(nsError.localizedDescription)"
    }

    private static func fourCCDetail(for nsError: NSError) -> String {
        guard nsError.domain == NSOSStatusErrorDomain else { return "" }
        let value = UInt32(bitPattern: Int32(truncatingIfNeeded: nsError.code))
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return "" }
        return " fourCC='\(String(decoding: bytes, as: UTF8.self))'"
    }
}

enum AudioCaptureError: LocalizedError {
    case invalidInputFormat

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat:
            return "麦克风输入格式不可用"
        }
    }
}
