//
//  IslandAskApp.swift
//  IslandAsk
//
//  App 入口。启动时先过首次引导门禁：权限 + zh-CN 转录模型都就绪后，才显示会话列表。
//  M0 的 SessionListView 是临时验证界面，M3 会替换为 HistoryView。
//

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

    @State private var phase: LaunchPhase = .checking

    var body: some Scene {
        WindowGroup {
            Group {
                switch phase {
                case .checking:
                    ProgressView("正在检查权限…")
                        .task { await checkSetup() }
                case .onboarding:
                    OnboardingView {
                        logger.info("onboarding finished, showing session list")
                        phase = .ready
                    }
                case .ready:
                    SessionListView()
                }
            }
        }
    }

    private func checkSetup() async {
        let ready = await OnboardingView.isSetupComplete()
        logger.info("launch setup check complete ready=\(ready, privacy: .public)")
        phase = ready ? .ready : .onboarding
    }
}
