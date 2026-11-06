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

/// 音频 buffer 的消费方（转录、静音检测）。
/// 约定：在音频线程上同步调用，实现方必须当场处理完或拷贝出需要的数据，
/// 不能把非 Sendable 的 AVAudioPCMBuffer 带到别的线程/任务里。
nonisolated protocol AudioBufferConsumer: Sendable {
    nonisolated func consume(buffer: AVAudioPCMBuffer)
}

@MainActor
final class AudioCaptureService {

    private var engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var tapInstalled = false
    private var isRunning = false
    /// 已写进 m4a 的帧数（音频线程累加）和文件采样率：换算成「录音文件里的第几秒」，用来截掉末尾静音。
    private let writtenFrames = OSAllocatedUnfairLock<Int64>(initialState: 0)
    private var fileSampleRate: Double = 0

    /// 当前已写进录音文件的时长（秒）。和文件时间轴一一对应，不受起录耗时影响。
    var recordedSeconds: Double {
        guard fileSampleRate > 0 else { return 0 }
        return Double(writtenFrames.withLock { $0 }) / fileSampleRate
    }

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
    /// tap 里的 buffer 同时分发给 consumers（转录服务、静音检测），M0 的 m4a 录音保留。
    /// 顺序按 SPEC 第 4 节第 5 步；调用方（Intent perform）会 await 到真正开始录音才返回，
    /// 不会缩短 AudioRecordingIntent 的授权窗口。
    func start(
        sessionID: UUID,
        fileURL: URL,
        consumers: [any AudioBufferConsumer] = []
    ) async throws {
        guard !isRunning else {
            logger.error("start ignored: audio capture already running")
            return
        }
        logger.info(
            "start requested session=\(sessionID.uuidString, privacy: .public) consumers=\(consumers.count, privacy: .public)"
        )

        // 每次会话用新的 AVAudioEngine：上一次 start 失败后 Engine 可能停在半初始化状态，
        // 复用会让下一次 start 继续失败；另外对已有 tap 的 inputNode 再 installTap 会直接崩溃
        // （AVAEInternal.h: required condition is false: nullptr == Tap()）。
        removeTapIfNeeded()
        engine.stop()
        engine = AVAudioEngine()

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

        // 后台起 IO 偶尔太快会把音频子系统顶出 'what'；给路由一点稳定时间。
        try? await Task.sleep(for: .milliseconds(120))

        do {
            let inputFormat = try await waitForInputFormat()
            let fileSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: inputFormat.sampleRate,
                AVNumberOfChannelsKey: inputFormat.channelCount,
            ]
            let file = try AVAudioFile(forWriting: fileURL, settings: fileSettings)
            audioFile = file
            writtenFrames.withLock { $0 = 0 }
            fileSampleRate = inputFormat.sampleRate
            try installTap(format: inputFormat, file: file, consumers: consumers)
            try await startEngineRetrying(file: file, consumers: consumers)
            isRunning = true
            logger.info("engine started file=\(fileURL.lastPathComponent, privacy: .public)")
        } catch {
            logger.error("start failed \(Self.describe(error), privacy: .public)")
            stopCaptureKeepingSessionActive()
            engine = AVAudioEngine()
            await deactivateAudioSession()
            throw error
        }
    }

    private func currentInputFormat() throws -> AVAudioFormat {
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.invalidInputFormat
        }
        return format
    }

    /// 后台起录时 inputNode 的格式偶尔会短暂是 0 Hz（音频路由还没就绪），轮询等一下再装 tap。
    private func waitForInputFormat(timeout: Duration = .seconds(2)) async throws -> AVAudioFormat {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let format = try? currentInputFormat() {
                return format
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        logger.error("input format stayed invalid after waiting \(timeout, privacy: .public)")
        throw AudioCaptureError.invalidInputFormat
    }

    private func installTap(
        format: AVAudioFormat,
        file: AVAudioFile,
        consumers: [any AudioBufferConsumer]
    ) throws {
        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: format,
            block: Self.makeTapBlock(file: file, writtenFrames: writtenFrames, consumers: consumers)
        )
        tapInstalled = true
        logger.info(
            "audio tap installed bufferSize=1024 consumers=\(consumers.count, privacy: .public)"
        )
    }

    /// 必须在 nonisolated 上下文创建 tap 闭包并显式标 @Sendable：
    /// AVAudioEngine 在实时音频线程回调，如果闭包继承了调用方（@MainActor 类方法）的隔离，
    /// Swift 6 运行时会命中 swift_task_isCurrentExecutor -> dispatch_assert_queue_fail 直接崩溃。
    private nonisolated static func makeTapBlock(
        file: AVAudioFile,
        writtenFrames: OSAllocatedUnfairLock<Int64>,
        consumers: [any AudioBufferConsumer]
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        // 音频回调线程里不碰 actor 状态，只用局部常量；写失败时打日志，避免静默丢数据。
        let writeLogger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
            category: "audio"
        )
        let firstBufferFlag = OSAllocatedUnfairLock(initialState: false)
        return { buffer, _ in
            let isFirstBuffer = firstBufferFlag.withLock { logged -> Bool in
                if logged { return false }
                logged = true
                return true
            }
            if isFirstBuffer {
                writeLogger.info(
                    "first audio buffer received frames=\(buffer.frameLength, privacy: .public) format=\(buffer.format.description, privacy: .public)"
                )
            }
            do {
                try file.write(from: buffer)
                let frames = Int64(buffer.frameLength)
                writtenFrames.withLock { $0 += frames }
            } catch {
                writeLogger.error("audio buffer write failed: \(error.localizedDescription, privacy: .public)")
            }
            // 同一份 buffer 分发给转录和静音检测；实现方在音频线程内当场消费。
            for consumer in consumers {
                consumer.consume(buffer: buffer)
            }
        }
    }

    /// 停止采集，但**保持音频会话激活**。
    /// 音频会话是 App 在后台唯一的保活来源：结束 Live Activity 之前必须留着它，
    /// 否则进程可能在 `activity.end(...)` 完成前被系统挂起，灵动岛就会残留（真机已复现）。
    func stopCaptureKeepingSessionActive() {
        logger.info(
            "stop capture requested (session kept active) isRunning=\(self.isRunning, privacy: .public) tapInstalled=\(self.tapInstalled, privacy: .public)"
        )
        // 即使 isRunning == false（例如 engine.start 抛错后），也必须把已经装上的 tap 移除，
        // 否则下一次 installTap 会触发 AVAudioEngine 的 Tap 断言直接崩溃（真机已复现）。
        removeTapIfNeeded()
        if isRunning {
            engine.stop()
        }
        isRunning = false
        audioFile = nil
        logger.info("capture stopped, audio session still active")
    }

    private func removeTapIfNeeded() {
        guard tapInstalled else { return }
        logger.info("removing audio tap from input node")
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    /// 启动引擎。后台起录偶尔会返回 'what'（2003329396，AVAudioSession unspecified）：
    /// 换一个新的 AVAudioEngine、重新激活会话后重试一次，仍失败再交给调用方收尾。
    private func startEngineRetrying(
        file: AVAudioFile,
        consumers: [any AudioBufferConsumer]
    ) async throws {
        engine.prepare()
        do {
            try engine.start()
            return
        } catch {
            logger.error(
                "engine start attempt=1 failed \(Self.describe(error), privacy: .public); retrying once"
            )
        }

        // 第一次失败后 Engine 可能已经处于坏状态，重建一个更稳。
        removeTapIfNeeded()
        engine.stop()
        engine = AVAudioEngine()

        try? await Task.sleep(for: .milliseconds(300))

        // 关键：重试时绝对不要 setActive(false)。后台这次会话一旦 deactivate，再激活会报
        // '!pla'（AVAudioSessionErrorCodeCannotStartPlaying），录音就彻底起不来了（真机已复现）。
        // setActive(true) 是幂等的，会话还激活时重复调用安全。
        do {
            try await Self.runOffMain {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)
            }
        } catch {
            logger.error("retry: keep session active failed \(Self.describe(error), privacy: .public)")
        }
        try? await Task.sleep(for: .milliseconds(200))

        do {
            let retryFormat = try await waitForInputFormat()
            try installTap(format: retryFormat, file: file, consumers: consumers)
            engine.prepare()
            try engine.start()
            logger.info(
                "engine started after retry format=\(retryFormat.description, privacy: .public)"
            )
        } catch {
            logger.error(
                "engine start attempt=2 failed \(Self.describe(error), privacy: .public)"
            )
            throw error
        }
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
    nonisolated private static func runOffMain(_ work: @escaping @Sendable () throws -> Void) async throws {
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
        guard nsError.domain == NSOSStatusErrorDomain
            || nsError.domain == "com.apple.coreaudio.avfaudio" else { return "" }
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
