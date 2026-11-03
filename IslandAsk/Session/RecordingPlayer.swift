//
//  RecordingPlayer.swift
//  IslandAsk
//
//  会话页播放原始录音（SPEC 第 6.12 节：便于排查转录问题）。从 M1 验证界面迁来。
//  正在录音或等回答时不改音频会话，避免打断后台录音链路。
//

import AVFAudio
import Foundation
import Observation
import os

private let audioLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
    category: "audio"
)

@MainActor
@Observable
final class RecordingPlayer {

    private(set) var hasRecording = false
    private(set) var isPlaying = false

    private var url: URL?
    private var player: AVAudioPlayer?
    private var finishTask: Task<Void, Never>?

    func load(sessionID: UUID) {
        guard let url = try? AudioCaptureService.audioFileURL(sessionID: sessionID) else { return }
        self.url = url
        hasRecording = FileManager.default.fileExists(atPath: url.path)
    }

    func toggle() {
        isPlaying ? stop() : play()
    }

    private func play() {
        guard let url else { return }
        // 正在录音或等回答时不能改音频会话类别，否则会打断后台录音链路。
        guard !SessionCoordinator.shared.isSessionBusy else {
            audioLogger.notice("playback skipped: session busy")
            return
        }
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default)
            try audioSession.setActive(true)

            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            guard player.play() else {
                audioLogger.error("playback did not start url=\(url.lastPathComponent, privacy: .public)")
                return
            }
            self.player = player
            isPlaying = true
            audioLogger.info("playback started url=\(url.lastPathComponent, privacy: .public)")

            // 播完自动复位按钮状态。
            let duration = player.duration
            finishTask?.cancel()
            finishTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration + 0.2))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        } catch {
            audioLogger.error("playback failed error=\(error.localizedDescription, privacy: .public)")
            stop()
        }
    }

    func stop() {
        finishTask?.cancel()
        finishTask = nil
        guard player != nil || isPlaying else { return }
        player?.stop()
        player = nil
        isPlaying = false
        guard !SessionCoordinator.shared.isSessionBusy else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioLogger.info("playback stopped")
        } catch {
            audioLogger.error("playback session deactivate failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
