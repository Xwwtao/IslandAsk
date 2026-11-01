//
//  SessionListView.swift
//  IslandAsk
//
//  M1 的临时验证界面：权限状态 + 会话列表（截图缩略图、最终转录文字、录音播放）。
//  这是给真机验证用的，M3 会替换成 HistoryView / SessionDetailView，届时整个文件删除。
//

import AVFAudio
import SwiftUI
import UIKit
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
    category: "audio"
)

struct SessionListView: View {

    private struct SessionArtifact: Identifiable, Hashable {
        let id: UUID
        let screenshotURL: URL?
        let audioURL: URL?
        let transcript: String?
        let result: SessionResult?
        let createdAt: Date
    }

    @Environment(\.scenePhase) private var scenePhase

    @State private var sessions: [SessionArtifact] = []
    @State private var player: AVAudioPlayer?
    @State private var playingSessionID: UUID?
    @State private var microphoneGranted = false
    @State private var speechRecognitionGranted = false
    @State private var speechModelStatus: SpeechModelStatus?
    @State private var liveActivitiesEnabled = false
    @State private var audioSessionPrimed = false
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            List {
                permissionSection
                triggerSection
                sessionsSection
            }
            .navigationTitle("IslandAsk")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        reloadSessions()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("刷新会话列表")
                }
            }
            .task {
                await refreshAll()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                Task { await refreshAll() }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var permissionSection: some View {
        Section("权限") {
            HStack {
                Label("麦克风", systemImage: microphoneGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(microphoneGranted ? Color.green : Color.red)
                Spacer()
                Text(microphoneGranted ? "已授权" : "未授权")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Label(
                    "语音识别",
                    systemImage: speechRecognitionGranted ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .foregroundStyle(speechRecognitionGranted ? Color.green : Color.red)
                Spacer()
                Text(speechRecognitionGranted ? "已授权" : "未授权")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Label("转录模型", systemImage: speechModelStatusIcon)
                    .foregroundStyle(speechModelStatusColor)
                Spacer()
                Text(speechModelStatusText)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Label("实时活动", systemImage: liveActivitiesEnabled ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(liveActivitiesEnabled ? Color.green : Color.red)
                Spacer()
                Text(liveActivitiesEnabled ? "已开启" : "被关闭")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Label("后台录音准备", systemImage: audioSessionPrimed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(audioSessionPrimed ? Color.green : Color.orange)
                Spacer()
                Text(audioSessionPrimed ? "已就绪" : "未就绪")
                    .foregroundStyle(.secondary)
            }
            if (!microphoneGranted || !speechRecognitionGranted || !liveActivitiesEnabled),
               let settingsURL = PermissionManager.appSettingsURL {
                Link("去系统设置里修改", destination: settingsURL)
            }
        }
    }

    @ViewBuilder
    private var triggerSection: some View {
        Section("怎么触发") {
            Text("在快捷指令 App 新建快捷指令：先放「截屏」，再放「IslandAsk → 对屏幕提问」，把「截图」参数设为上一步的截屏结果；最后到 设置 → 操作按钮 → 快捷指令 里选中它。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("触发前请先打开本 App 一次：上面的「后台录音准备」变成「已就绪」后再切到别的 App 触发。这是系统允许后台录音的前置条件。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var sessionsSection: some View {
        Section("会话") {
            if let loadError {
                Text(loadError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if sessions.isEmpty {
                Text("还没有会话。触发一次「屏幕提问」快捷指令试试。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sessions) { session in
                    sessionRow(session)
                }
            }
        }
    }

    private func sessionRow(_ session: SessionArtifact) -> some View {
        HStack(spacing: 12) {
            thumbnail(for: session)
            VStack(alignment: .leading, spacing: 3) {
                transcriptView(for: session)
                resultView(for: session)
                Text("\(session.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(session.audioURL == nil ? "无录音" : "已录音")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                togglePlayback(for: session)
            } label: {
                Image(systemName: playingSessionID == session.id ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(session.audioURL == nil)
            .accessibilityLabel(playingSessionID == session.id ? "停止播放" : "播放录音")
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func transcriptView(for session: SessionArtifact) -> some View {
        if let transcript = session.transcript?.trimmingCharacters(in: .whitespacesAndNewlines),
           !transcript.isEmpty {
            Text(transcript)
                .font(.subheadline)
                .lineLimit(2)
        } else {
            Text("没有识别到文字")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    /// M2 的大模型结果（.json）。M3 换成会话页里的完整回答。
    @ViewBuilder
    private func resultView(for session: SessionArtifact) -> some View {
        if let result = session.result {
            switch result.status {
            case .answered:
                Text(result.summary ?? "")
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .lineLimit(3)
            case .failed:
                Text("回答失败：\(result.errorMessage ?? "未知错误")")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private func thumbnail(for session: SessionArtifact) -> some View {
        if let url = session.screenshotURL, let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 56, height: 56)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
        }
    }

    // MARK: - Data

    private var speechModelStatusText: String {
        switch speechModelStatus {
        case .installed:
            return "已安装"
        case .needsDownload:
            return "未安装"
        case .downloading:
            return "下载中"
        case .unsupported:
            return "不支持（用系统识别）"
        case nil:
            return "检查中"
        }
    }

    private var speechModelStatusIcon: String {
        switch speechModelStatus {
        case .installed:
            return "checkmark.circle.fill"
        case .needsDownload:
            return "xmark.circle.fill"
        case .downloading:
            return "arrow.down.circle"
        case .unsupported:
            return "exclamationmark.triangle.fill"
        case nil:
            return "circle.dashed"
        }
    }

    private var speechModelStatusColor: Color {
        switch speechModelStatus {
        case .installed:
            return .green
        case .needsDownload:
            return .red
        case .downloading, .unsupported:
            return .orange
        case nil:
            return .secondary
        }
    }

    private func refreshAll() async {
        // 后台被拉起时不要动音频会话和 Live Activity，避免打断刚启动的录音。
        guard scenePhase == .active else { return }

        let coordinator = SessionCoordinator.shared
        microphoneGranted = await PermissionManager.requestMicrophoneIfNeeded()
        speechRecognitionGranted = PermissionManager.isSpeechRecognitionGranted
        speechModelStatus = await SpeechModelManager.status()
        liveActivitiesEnabled = PermissionManager.areLiveActivitiesEnabled

        if microphoneGranted, !coordinator.isSessionBusy {
            // 前台预热：后台起录要求本 App 在前台成功激活过一次录音会话。
            audioSessionPrimed = await AudioCaptureService.primeAudioSessionInForeground()
        } else if coordinator.isSessionBusy {
            audioSessionPrimed = true
        } else {
            audioSessionPrimed = false
        }

        // App 回到前台时先检查异常态，再补一次残留清理。
        await coordinator.recoverUnexpectedStoppedSessionIfNeeded()
        await coordinator.endOrphanActivitiesIfNeeded()
        reloadSessions()
    }

    private func reloadSessions() {
        do {
            sessions = try Self.loadArtifacts()
            loadError = nil
            logger.info("sessions reloaded count=\(sessions.count, privacy: .public)")
        } catch {
            sessions = []
            loadError = error.localizedDescription
            logger.error("sessions reload failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// M0 直接从 Documents/sessions/ 目录重建列表，不依赖数据库（SwiftData 在 M3 才上）。
    private static func loadArtifacts() throws -> [SessionArtifact] {
        let directory = try ScreenshotStore.sessionsDirectory()
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )

        var screenshotURLs: [UUID: URL] = [:]
        var audioURLs: [UUID: URL] = [:]
        var transcriptURLs: [UUID: URL] = [:]
        for url in urls {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            switch url.pathExtension.lowercased() {
            case "png":
                screenshotURLs[id] = url
            case "m4a":
                audioURLs[id] = url
            case "txt":
                transcriptURLs[id] = url
            default:
                break
            }
        }

        let ids = Set(screenshotURLs.keys)
            .union(audioURLs.keys)
            .union(transcriptURLs.keys)
        let artifacts: [SessionArtifact] = ids.compactMap { id in
            let representativeURL = audioURLs[id] ?? screenshotURLs[id] ?? transcriptURLs[id]
            var createdAt = Date.distantPast
            if let representativeURL,
               let values = try? representativeURL.resourceValues(forKeys: [.creationDateKey]),
               let creationDate = values.creationDate {
                createdAt = creationDate
            }
            let transcript = transcriptURLs[id].flatMap { url in
                try? String(contentsOf: url, encoding: .utf8)
            }
            return SessionArtifact(
                id: id,
                screenshotURL: screenshotURLs[id],
                audioURL: audioURLs[id],
                transcript: transcript,
                result: AnswerStore.load(sessionID: id),
                createdAt: createdAt
            )
        }
        return artifacts.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Playback

    private func togglePlayback(for session: SessionArtifact) {
        if playingSessionID == session.id {
            stopPlayback()
            return
        }
        guard let url = session.audioURL else { return }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default)
            try audioSession.setActive(true)

            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            guard player.play() else {
                logger.error("playback did not start session=\(session.id.uuidString, privacy: .public)")
                return
            }
            self.player = player
            playingSessionID = session.id
            logger.info("playback started session=\(session.id.uuidString, privacy: .public)")
        } catch {
            logger.error(
                "playback failed session=\(session.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            stopPlayback()
        }
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        playingSessionID = nil
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            logger.info("playback stopped")
        } catch {
            logger.error("playback session deactivate failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
