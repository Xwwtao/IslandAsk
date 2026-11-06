//
//  IslandAskApp.swift
//  IslandAsk
//
//  App 入口。启动时先过首次引导门禁：权限 + 转录模型都就绪后，才显示历史列表。
//  处理 islandask://session/<id> 深链（SPEC 第 4 节第 11 步）：打开对应会话页并结束它的 Live Activity。
//  回到前台时做后台起录的前置准备：预热录音会话、回收异常态、清理残留 Live Activity。
//

import SwiftData
import SwiftUI
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
    category: "coordinator"
)

@main
struct IslandAskApp: App {

    private enum LaunchPhase {
        case checking
        case onboarding
        case ready
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var phase: LaunchPhase = .checking
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            Group {
                switch phase {
                case .checking:
                    ProgressView("正在检查权限…")
                        .task { await checkSetup() }
                case .onboarding:
                    OnboardingView {
                        logger.info("onboarding finished, showing history")
                        phase = .ready
                    }
                case .ready:
                    HistoryView()
                }
            }
            .environment(appState)
            .onOpenURL { url in
                handleOpenURL(url)
            }
            .onChange(of: phase) { _, newPhase in
                guard newPhase == .ready else { return }
                if let pending = appState.pendingSessionID {
                    appState.pendingSessionID = nil
                    openSession(pending)
                }
                Task { await prepareForegroundIfNeeded() }
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                Task { await prepareForegroundIfNeeded() }
            }
        }
        .modelContainer(AppDatabase.container)
    }

    private func checkSetup() async {
        let ready = await OnboardingView.isSetupComplete()
        logger.info("launch setup check complete ready=\(ready, privacy: .public)")
        phase = ready ? .ready : .onboarding
    }

    // MARK: - 深链

    private func handleOpenURL(_ url: URL) {
        guard let sessionID = AskActivityAttributes.sessionID(from: url) else {
            logger.error("deep link ignored: unrecognized url=\(url.absoluteString, privacy: .public)")
            return
        }
        logger.info("deep link received session=\(sessionID.uuidString, privacy: .public)")
        guard phase == .ready else {
            // 引导没完成时先暂存，进入主界面后再打开。
            appState.pendingSessionID = sessionID
            logger.info("deep link deferred until setup completes session=\(sessionID.uuidString, privacy: .public)")
            return
        }
        openSession(sessionID)
    }

    private func openSession(_ sessionID: UUID) {
        appState.openSession(sessionID)
        Task { await SessionCoordinator.shared.openedSession(id: sessionID) }
    }

    // MARK: - 前台准备

    /// 后台被拉起（Intent）时 scenePhase 不是 active：不要动音频会话和 Live Activity，避免打断刚启动的录音。
    private func prepareForegroundIfNeeded() async {
        guard phase == .ready, scenePhase == .active else { return }

        let coordinator = SessionCoordinator.shared
        let microphoneGranted = await PermissionManager.requestMicrophoneIfNeeded()
        if microphoneGranted, !coordinator.isSessionBusy {
            // 前台预热：后台起录要求本 App 在前台成功激活过一次录音会话。
            appState.audioSessionPrimed = await AudioCaptureService.primeAudioSessionInForeground()
        } else {
            appState.audioSessionPrimed = coordinator.isSessionBusy
        }

        // 先检查异常态，再补一次残留清理（answered / failed 的灵动岛在打开 App 时结束，SPEC 6.10）。
        await coordinator.recoverUnexpectedStoppedSessionIfNeeded()
        await coordinator.endOrphanActivitiesIfNeeded()
        coordinator.purgeExpiredSessions()
    }
}
