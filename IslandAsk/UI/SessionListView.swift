//
//  SessionListView.swift
//  IslandAsk
//
//  M0 的临时验证界面：权限状态 + 会话列表（截图缩略图、录音播放）。
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
        let createdAt: Date
    }

    @Environment(\.scenePhase) private var scenePhase

    @State private var sessions: [SessionArtifact] = []
    @State private var player: AVAudioPlayer?
    @State private var playingSessionID: UUID?
    @State private var microphoneGranted = false
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
            if (!microphoneGranted || !liveActivitiesEnabled), let settingsURL = PermissionManager.appSettingsURL {
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
            VStack(alignment: .leading, spacing: 2) {
                Text(session.id.uuidString.prefix(8))
                    .font(.headline)
                Text(session.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(session.audioURL == nil ? "没有录音" : "已录音")
                    .font(.caption2)
                    .foregroundStyle(session.audioURL == nil ? Color.red : Color.green)
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

    private func refreshAll() async {
        // 后台被拉起时不要动音频会话和 Live Activity，避免打断刚启动的录音。
        guard scenePhase == .active else { return }

        let coordinator = SessionCoordinator.shared
        microphoneGranted = await PermissionManager.requestMicrophoneIfNeeded()
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
        for url in urls {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            switch url.pathExtension.lowercased() {
            case "png":
                screenshotURLs[id] = url
            case "m4a":
                audioURLs[id] = url
            default:
                break
            }
        }

        let ids = Set(screenshotURLs.keys).union(audioURLs.keys)
        let artifacts: [SessionArtifact] = ids.compactMap { id in
            let representativeURL = audioURLs[id] ?? screenshotURLs[id]
            var createdAt = Date.distantPast
            if let representativeURL,
               let values = try? representativeURL.resourceValues(forKeys: [.creationDateKey]),
               let creationDate = values.creationDate {
                createdAt = creationDate
            }
            return SessionArtifact(
                id: id,
                screenshotURL: screenshotURLs[id],
                audioURL: audioURLs[id],
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
