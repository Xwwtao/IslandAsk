//
//  TranscriptionService.swift
//  IslandAsk
//
//  实时转录（SPEC 第 6.6 节）。引擎回退链：
//    1. SpeechAnalyzer + SpeechTranscriber（zh-CN，开 volatileResults）
//    2. SFSpeechRecognizer 端侧识别（supportsOnDeviceRecognition == true）
//    3. SFSpeechRecognizer 联网识别（端侧不支持且当前可用）
//  每次选择和回退原因都写 transcription 日志，启动时日志里能看到实际引擎。
//
//  线程模型：AudioCaptureService 的 tap 在音频线程上同步调用 consume(buffer:)，
//  这里当场把 buffer 转换/拷贝成 AnalyzerInput 或 append 给 SFSpeechRecognizer，
//  不把非 Sendable 的 AVAudioPCMBuffer 跨线程传递；可变的显示文字用锁保护。
//

import AVFAudio
import Foundation
import Speech
import os

// MARK: - 对外数据结构

nonisolated struct TranscriptUpdate: Sendable {
    let finalizedText: String
    let volatileText: String

    /// 灵动岛/列表显示用：已确定文字 + 当前临时文字。
    var displayText: String {
        finalizedText + volatileText
    }
}

nonisolated enum TranscriptionEngine: String, Sendable {
    case speechAnalyzer = "speech-analyzer"
    case sfSpeechOnDevice = "sf-speech-ondevice"
    case sfSpeechOnline = "sf-speech-online"
}

// MARK: - TranscriptionService

nonisolated final class TranscriptionService: AudioBufferConsumer, @unchecked Sendable {

    private struct State {
        var finalizedText = ""
        var volatileText = ""
        var analyzerResultsFinished = false
        var sfSpeechResultsFinished = false
        var didLogFirstResult = false
    }

    /// 供 SessionCoordinator 订阅；消费慢时只保留最近的更新。
    let updates: AsyncStream<TranscriptUpdate>
    private let updatesContinuation: AsyncStream<TranscriptUpdate>.Continuation

    private(set) var engine: TranscriptionEngine?

    // SpeechAnalyzer 链路
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var analyzerInputStream: AsyncStream<AnalyzerInput>?
    private var converter: AVAudioConverter?
    private var analyzerResultsTask: Task<Void, Never>?

    // SFSpeechRecognizer 回退链路
    private var sfRecognizer: SFSpeechRecognizer?
    private var sfRequest: SFSpeechAudioBufferRecognitionRequest?
    private var sfTask: SFSpeechRecognitionTask?

    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {
        (updates, updatesContinuation) = AsyncStream<TranscriptUpdate>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
    }

    deinit {
        inputBuilder?.finish()
        analyzerResultsTask?.cancel()
        sfTask?.cancel()
        updatesContinuation.finish()
    }

    // MARK: - Start

    // MARK: - 准备 / 激活

    /// 第 1 步：选引擎、建好管道（SpeechAnalyzer 只准备不 start）。
    /// 真正的分析在音频采集起来之后由 `activate()` 启动（先起 M0 验证过的音频链路，再跑模型）。
    @MainActor
    func prepare(locale: Locale) async throws -> TranscriptionEngine {
        let logger = Self.makeLogger()
        guard PermissionManager.isSpeechRecognitionGranted else {
            logger.error("transcription prepare failed reason=speech-permission-not-granted")
            throw TranscriptionError.permissionDenied
        }

        if let analyzerEngine = await prepareSpeechAnalyzer(locale: locale) {
            engine = analyzerEngine
            logger.info(
                "transcription engine selected engine=\(analyzerEngine.rawValue, privacy: .public) locale=\(locale.identifier, privacy: .public)"
            )
            return analyzerEngine
        }

        let sfEngine = try startSFSpeech(locale: locale)
        engine = sfEngine
        logger.info(
            "transcription engine selected engine=\(sfEngine.rawValue, privacy: .public) locale=\(locale.identifier, privacy: .public) reason=fallback"
        )
        return sfEngine
    }

    /// 第 2 步：音频采集已经启动，开始真正跑转录。
    /// SpeechAnalyzer 的输入流在 prepare 阶段就建好；启动前 tap 已经 yield 的 buffer 会先排在 AsyncStream 里。
    func activate() async throws {
        guard let analyzer, let analyzerInputStream else {
            return
        }
        do {
            // 用 detached task 调 start：避免继承调用方（MainActor）的执行器上下文。
            try await Task.detached {
                try await analyzer.start(inputSequence: analyzerInputStream)
            }.value
            Self.makeLogger().info("speech analyzer activated")
        } catch {
            Self.makeLogger().error(
                "speech analyzer activate failed: \(error.localizedDescription, privacy: .public)"
            )
            await cleanupSpeechAnalyzer()
            throw error
        }
    }

    /// 第 1 级：SpeechAnalyzer + SpeechTranscriber。失败只记录原因并返回 nil，由调用方回退。
    private func prepareSpeechAnalyzer(locale: Locale) async -> TranscriptionEngine? {
        let logger = Self.makeLogger()

        // reportingOptions 对应 Apple 的 progressiveTranscription 预设：
        // - volatileResults：随时给出临时结果
        // - fastResults：用更小的 context window 降低结果延迟（不加这个，首条结果可能等到整段说完才出来）
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )

        guard await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil else {
            logger.notice("speech analyzer unavailable reason=locale-unsupported engine=speech-analyzer")
            return nil
        }

        let assetStatus = await AssetInventory.status(forModules: [transcriber])
        guard assetStatus == .installed else {
            logger.notice(
                "speech analyzer unavailable reason=model-not-installed status=\(String(describing: assetStatus), privacy: .public) engine=speech-analyzer"
            )
            return nil
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            logger.notice("speech analyzer unavailable reason=no-compatible-audio-format engine=speech-analyzer")
            return nil
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (inputSequence, builder) = AsyncStream<AnalyzerInput>.makeStream()
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.inputBuilder = builder
        self.analyzerFormat = format

        // 结果消费放在 detached task 里：不要继承 MainActor 隔离，避免 Speech 的结果回调/迭代
        // 与主线程执行器断言互相踩（Swift 6 运行时 dispatch_assert_queue_fail）。
        analyzerResultsTask = Task.detached { [weak self] in
            do {
                for try await result in transcriber.results {
                    // 先取出 Sendable 的值，避免把非 Sendable 的 result 带进锁闭包。
                    let text = String(result.text.characters)
                    let isFinal = result.isFinal
                    self?.applyAnalyzerResult(text: text, isFinal: isFinal)
                }
                self?.markAnalyzerResultsFinished()
            } catch {
                Self.makeLogger().error("speech analyzer results failed: \(error.localizedDescription, privacy: .public)")
                self?.markAnalyzerResultsFinished()
            }
        }

        self.analyzerInputStream = inputSequence
        logger.info("speech analyzer prepared format=\(format.description, privacy: .public)")
        return .speechAnalyzer
    }

    /// 第 2/3 级：SFSpeechRecognizer。端侧可用优先，否则联网。
    private func startSFSpeech(locale: Locale) throws -> TranscriptionEngine {
        let logger = Self.makeLogger()

        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            logger.error("sf speech unavailable reason=locale-not-supported")
            throw TranscriptionError.localeNotSupported
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true

        let selectedEngine: TranscriptionEngine
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
            selectedEngine = .sfSpeechOnDevice
            logger.info("sf speech using on-device recognition")
        } else {
            request.requiresOnDeviceRecognition = false
            guard recognizer.isAvailable else {
                logger.error("sf speech unavailable reason=no-on-device-and-service-unavailable")
                throw TranscriptionError.engineUnavailable("SFSpeechRecognizer 当前不可用")
            }
            selectedEngine = .sfSpeechOnline
            logger.info("sf speech falling back to online recognition reason=on-device-unsupported")
        }

        self.sfRecognizer = recognizer
        self.sfRequest = request
        self.sfTask = recognizer.recognitionTask(
            with: request,
            resultHandler: Self.makeSFSpeechResultHandler(service: self)
        )
        return selectedEngine
    }

    /// 同样必须在 nonisolated 上下文创建并标 @Sendable：SFSpeechRecognizer 在任意队列回调，
    /// 继承 @MainActor 的闭包会在运行时命中 dispatch_assert_queue_fail。
    private nonisolated static func makeSFSpeechResultHandler(
        service: TranscriptionService
    ) -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        return { [weak service] result, error in
            if let result {
                // 先取出 Sendable 的值，再进锁；不要把非 Sendable 的 result 带进锁闭包。
                let text = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                service?.applySFSpeechResult(text: text, isFinal: isFinal)
                if isFinal {
                    service?.markSFSpeechResultsFinished()
                }
            }
            if let error {
                Self.makeLogger().error("sf speech task failed: \(error.localizedDescription, privacy: .public)")
                service?.markSFSpeechResultsFinished()
            }
        }
    }

    // MARK: - 音频线程入口

    /// AudioCaptureService 的 tap 在音频线程同步调用。buffer 只在本次回调内有效，
    /// 因此这里当场转换/拷贝后交给异步链路。
    func consume(buffer: AVAudioPCMBuffer) {
        if let builder = inputBuilder, let format = analyzerFormat {
            if let converted = convertBuffer(buffer, to: format) {
                builder.yield(AnalyzerInput(buffer: converted))
            }
        }
        sfRequest?.append(buffer)
    }

    // MARK: - 结束

    /// 停止并返回最终文字。调用前调度器已停掉音频采集，不会再有新 buffer。
    func finish() async -> String {
        let logger = Self.makeLogger()

        if sfRequest != nil {
            sfRequest?.endAudio()
            await waitForSFSpeechResults(timeout: .milliseconds(1500))
            sfTask?.cancel()
        } else if let analyzer {
            inputBuilder?.finish()
            do {
                try await Task.detached {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                }.value
            } catch {
                logger.error("speech analyzer finalize failed: \(error.localizedDescription, privacy: .public)")
            }
            await waitForAnalyzerResults(timeout: .milliseconds(2000))
            analyzerResultsTask?.cancel()
        }

        let text = currentText().trimmingCharacters(in: .whitespacesAndNewlines)
        logger.info(
            "transcription finished engine=\(self.engine?.rawValue ?? "nil", privacy: .public) chars=\(text.count, privacy: .public)"
        )
        updatesContinuation.finish()
        return text
    }

    /// 没说话/出错时取消：不等最终结果，只做清理。
    func cancel() async {
        Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
            category: "transcription"
        ).info("transcription cancel engine=\(self.engine?.rawValue ?? "nil", privacy: .public)")

        inputBuilder?.finish()
        if let analyzer {
            await Task.detached {
                await analyzer.cancelAndFinishNow()
            }.value
        }
        analyzerResultsTask?.cancel()
        sfRequest?.endAudio()
        sfTask?.cancel()
        state.withLock {
            $0.finalizedText = ""
            $0.volatileText = ""
        }
        updatesContinuation.finish()
    }

    // MARK: - 结果处理

    private func applyAnalyzerResult(text: String, isFinal: Bool) {
        let (snapshot, isFirstResult) = state.withLock { state -> (State, Bool) in
            let isFirst = !state.didLogFirstResult
            if isFirst {
                state.didLogFirstResult = true
            }
            if isFinal {
                state.finalizedText += text
                state.volatileText = ""
            } else {
                state.volatileText = text
            }
            return (state, isFirst)
        }
        if isFirstResult {
            Self.makeLogger().info(
                "first speech analyzer result isFinal=\(isFinal, privacy: .public) chars=\(text.count, privacy: .public)"
            )
        }
        emit(snapshot)
    }

    private func applySFSpeechResult(text: String, isFinal: Bool) {
        let snapshot = state.withLock { state in
            if isFinal {
                state.finalizedText = text
                state.volatileText = ""
            } else {
                state.volatileText = text
            }
            return state
        }
        emit(snapshot)
    }

    private func emit(_ snapshot: State) {
        updatesContinuation.yield(
            TranscriptUpdate(
                finalizedText: snapshot.finalizedText,
                volatileText: snapshot.volatileText
            )
        )
    }

    private func markAnalyzerResultsFinished() {
        state.withLock { $0.analyzerResultsFinished = true }
    }

    private func markSFSpeechResultsFinished() {
        state.withLock { $0.sfSpeechResultsFinished = true }
    }

    func currentText() -> String {
        state.withLock { $0.finalizedText + $0.volatileText }
    }

    // MARK: - 音频转换

    /// AVAudioConverter 只在音频线程使用（consume 内），不跨线程共享。
    private func convertBuffer(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format {
            return copyBuffer(buffer)
        }

        if converter == nil || converter?.outputFormat != format || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            // 官方示例：牺牲第一帧质量，避免时间戳漂移。
            converter?.primeMethod = .none
        }
        guard let converter else {
            Self.makeLogger().error("audio converter creation failed")
            return nil
        }

        let sampleRateRatio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let frameCapacity = AVAudioFrameCount((Double(buffer.frameLength) * sampleRateRatio).rounded(.up))
        guard frameCapacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: frameCapacity) else {
            return nil
        }

        var processed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            defer { processed = true }
            inputStatus.pointee = processed ? .noDataNow : .haveData
            return processed ? nil : buffer
        }

        guard status != .error else {
            Self.makeLogger().error(
                "audio conversion failed: \(conversionError?.localizedDescription ?? "unknown", privacy: .public)"
            )
            return nil
        }
        return output
    }

    /// 输入输出格式相同时不能直接交出 tap 的 buffer（回调返回后可能失效），拷一份。
    private func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0, channelCount > 0 else { return copy }

        if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
            for channel in 0..<channelCount {
                destination[channel].update(from: source[channel], count: frameLength)
            }
            return copy
        }
        if let source = buffer.int16ChannelData, let destination = copy.int16ChannelData {
            for channel in 0..<channelCount {
                destination[channel].update(from: source[channel], count: frameLength)
            }
            return copy
        }
        return nil
    }

    // MARK: - 收尾等待

    private func waitForAnalyzerResults(timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if state.withLock({ $0.analyzerResultsFinished }) { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func waitForSFSpeechResults(timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if state.withLock({ $0.sfSpeechResultsFinished }) { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func cleanupSpeechAnalyzer() async {
        inputBuilder?.finish()
        if let analyzer {
            await Task.detached {
                await analyzer.cancelAndFinishNow()
            }.value
        }
        analyzerResultsTask?.cancel()
        transcriber = nil
        analyzer = nil
        inputBuilder = nil
        analyzerFormat = nil
        analyzerInputStream = nil
        converter = nil
    }

    private static func makeLogger() -> Logger {
        Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
            category: "transcription"
        )
    }
}

// MARK: - Errors

nonisolated enum TranscriptionError: LocalizedError {
    case permissionDenied
    case localeNotSupported
    case engineUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "没有语音识别权限，请到设置里打开"
        case .localeNotSupported:
            return "zh-CN 语音识别不可用"
        case .engineUnavailable(let message):
            return "语音识别暂不可用：\(message)"
        }
    }
}
