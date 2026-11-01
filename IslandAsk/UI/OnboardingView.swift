//
//  OnboardingView.swift
//  IslandAsk
//
//  首次引导（SPEC 第 6.1 / 6.12 节）：麦克风 → 语音识别 → zh-CN 转录模型（只在前台下载）→
//  实时活动开关检查 → 快捷指令设置指引。
//
//  模型状态是 unsupported 时允许继续，由 TranscriptionService 回退到系统语音识别（M1 第 2 步），
//  不能把用户永久卡在引导页。
//

import AVFAudio
import Observation
import Speech
import SwiftUI
import UIKit
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
    category: "coordinator"
)

struct OnboardingView: View {

    /// 引导完成后由 App 根视图切到主界面。
    var onComplete: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var model = OnboardingModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    permissionsCard
                    modelCard
                    liveActivityCard
                    shortcutCard
                    if let message = model.errorMessage {
                        errorCard(message)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .safeAreaInset(edge: .bottom) { footer }
            .navigationTitle("准备 IslandAsk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.refreshWhenForeground() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("重新检查")
                }
            }
            .task { await model.prepare() }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                Task { await model.refreshWhenForeground() }
            }
            .onChange(of: model.isDownloading) { _, downloading in
                // 模型下载要求 App 在前台，下载期间不要让屏幕自动锁屏。
                UIApplication.shared.isIdleTimerDisabled = downloading
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("开始使用 IslandAsk")
                    .font(.title3.bold())
                Text("完成下面几步后，按下 Action Button 就能在灵动岛里语音提问。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var permissionsCard: some View {
        card("权限") {
            VStack(alignment: .leading, spacing: 12) {
                permissionRow(
                    icon: "mic.fill",
                    title: "麦克风",
                    granted: model.microphoneGranted,
                    denied: model.microphoneStatus == .denied
                ) {
                    if model.microphoneStatus == .undetermined {
                        Button("授权") {
                            Task { await model.requestMicrophone() }
                        }
                        .font(.caption.weight(.semibold))
                    } else if model.microphoneStatus == .denied,
                              let url = PermissionManager.appSettingsURL {
                        Link("去设置", destination: url)
                            .font(.caption.weight(.semibold))
                    }
                }

                Divider()

                permissionRow(
                    icon: "waveform",
                    title: "语音识别",
                    granted: model.speechGranted,
                    denied: model.speechStatus == .denied || model.speechStatus == .restricted
                ) {
                    if model.speechStatus == .notDetermined {
                        Button("授权") {
                            Task { await model.requestSpeech() }
                        }
                        .font(.caption.weight(.semibold))
                    } else if (model.speechStatus == .denied || model.speechStatus == .restricted),
                              let url = PermissionManager.appSettingsURL {
                        Link("去设置", destination: url)
                            .font(.caption.weight(.semibold))
                    }
                }
            }
        }
    }

    private var modelCard: some View {
        card("转录模型（zh-CN）") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: model.modelIcon)
                        .foregroundStyle(model.modelStatusColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apple 语音转录模型")
                            .font(.subheadline.weight(.medium))
                        Text(model.modelStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if model.isDownloading {
                    ProgressView(value: model.downloadProgress)
                    Text("正在下载 \(Int((model.downloadProgress * 100).rounded()))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("下载只能在 App 前台进行，请保持当前页面打开。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if model.modelStatus == .needsDownload, model.modelChecked {
                    Button("下载模型") {
                        Task { await model.downloadModelIfNeeded() }
                    }
                    .font(.caption.weight(.semibold))
                    Text("未安装模型时无法使用 Apple 语音转录。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if model.modelStatus == .unsupported {
                    Text("当前设备/语言不支持 Apple 转录模型，将自动回退到系统语音识别（SFSpeechRecognizer）。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if !model.modelChecked {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text("正在检查模型…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var liveActivityCard: some View {
        card("实时活动") {
            HStack(spacing: 12) {
                Image(systemName: model.liveActivitiesEnabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(model.liveActivitiesEnabled ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("灵动岛显示")
                        .font(.subheadline.weight(.medium))
                    Text(
                        model.liveActivitiesEnabled
                            ? "已开启"
                            : "被关闭，触发时看不到灵动岛；请到系统设置里打开"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if !model.liveActivitiesEnabled, let url = PermissionManager.appSettingsURL {
                    Link("去设置", destination: url)
                        .font(.caption.weight(.semibold))
                }
            }
        }
    }

    private var shortcutCard: some View {
        card("快捷指令设置") {
            VStack(alignment: .leading, spacing: 8) {
                shortcutLine(1, "打开快捷指令 App，新建快捷指令，命名为「屏幕提问」。")
                shortcutLine(2, "添加动作「截屏」。")
                shortcutLine(3, "添加动作「对屏幕提问」，把「截图」参数设为上一步的「截屏」结果。")
                shortcutLine(4, "进入 设置 → 操作按钮 → 快捷指令，选择「屏幕提问」。")
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Button {
                logger.info("onboarding completed, entering session list")
                onComplete()
            } label: {
                Text("开始使用")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canContinue)

            Text(model.hintText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    // MARK: - Components

    private func card<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 14)
        )
    }

    private func permissionRow<Accessory: View>(
        icon: String,
        title: String,
        granted: Bool,
        denied: Bool,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : (denied ? "xmark.circle.fill" : "circle.dashed"))
                .foregroundStyle(granted ? Color.green : (denied ? Color.red : Color.orange))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(granted ? "已授权" : (denied ? "已拒绝，请在系统设置里打开" : "尚未授权"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            accessory()
        }
    }

    private func shortcutLine(_ index: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(index)")
                .font(.caption2.bold())
                .frame(width: 18, height: 18)
                .background(Color.secondary.opacity(0.15), in: Circle())
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                if model.modelStatus == .needsDownload || model.modelStatus == .downloading {
                    Button("重试下载") {
                        Task { await model.downloadModelIfNeeded() }
                    }
                    .font(.caption.weight(.semibold))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - 启动门禁

extension OnboardingView {

    /// App 启动时判断引导是否已完成：权限齐全，且模型已安装或该 locale 不受支持（允许回退）。
    static func isSetupComplete() async -> Bool {
        guard PermissionManager.microphoneStatus == .granted,
              PermissionManager.isSpeechRecognitionGranted else {
            return false
        }
        let status = await SpeechModelManager.status()
        return status == .installed || status == .unsupported
    }
}

// MARK: - OnboardingModel

@MainActor
@Observable
final class OnboardingModel {

    private(set) var microphoneStatus: AVAudioApplication.recordPermission = PermissionManager.microphoneStatus
    private(set) var speechStatus: SFSpeechRecognizerAuthorizationStatus = PermissionManager.speechRecognitionStatus
    private(set) var modelStatus: SpeechModelStatus = .needsDownload
    private(set) var modelChecked = false
    private(set) var isDownloading = false
    private(set) var downloadProgress = 0.0
    private(set) var errorMessage: String?
    private(set) var liveActivitiesEnabled = false

    private var didPrepare = false

    var microphoneGranted: Bool {
        microphoneStatus == .granted
    }

    var speechGranted: Bool {
        speechStatus == .authorized
    }

    var canContinue: Bool {
        microphoneGranted
            && speechGranted
            && !isDownloading
            && (modelStatus == .installed || modelStatus == .unsupported)
    }

    var hintText: String {
        if !microphoneGranted {
            return "请先授权麦克风"
        }
        if !speechGranted {
            return "请先授权语音识别"
        }
        if isDownloading {
            return "语音模型下载中，完成后即可开始"
        }
        switch modelStatus {
        case .needsDownload:
            return "请先下载语音模型"
        case .downloading:
            return "系统正在下载语音模型，请稍候"
        case .unsupported:
            return "模型不支持，将使用系统语音识别"
        case .installed:
            return "准备就绪，可以开始使用"
        }
    }

    var modelStatusText: String {
        switch modelStatus {
        case .installed:
            return "已安装"
        case .needsDownload:
            return "未安装"
        case .downloading:
            return "系统下载中"
        case .unsupported:
            return "不支持，使用系统语音识别"
        }
    }

    var modelIcon: String {
        switch modelStatus {
        case .installed:
            return "checkmark.circle.fill"
        case .needsDownload:
            return "arrow.down.circle"
        case .downloading:
            return "arrow.down.circle.dotted"
        case .unsupported:
            return "exclamationmark.triangle.fill"
        }
    }

    var modelStatusColor: Color {
        switch modelStatus {
        case .installed:
            return .green
        case .needsDownload:
            return .orange
        case .downloading:
            return .blue
        case .unsupported:
            return .orange
        }
    }

    // MARK: - Flow

    func prepare() async {
        guard !didPrepare else { return }
        didPrepare = true

        liveActivitiesEnabled = PermissionManager.areLiveActivitiesEnabled

        _ = await PermissionManager.requestMicrophoneIfNeeded()
        microphoneStatus = PermissionManager.microphoneStatus

        _ = await PermissionManager.requestSpeechRecognitionIfNeeded()
        speechStatus = PermissionManager.speechRecognitionStatus

        await refreshModelStatus(autoDownload: true)
    }

    func requestMicrophone() async {
        _ = await PermissionManager.requestMicrophoneIfNeeded()
        microphoneStatus = PermissionManager.microphoneStatus
    }

    func requestSpeech() async {
        _ = await PermissionManager.requestSpeechRecognitionIfNeeded()
        speechStatus = PermissionManager.speechRecognitionStatus
    }

    /// 从系统设置返回、或 App 回到前台时重新读状态；下载没完成就在前台继续。
    func refreshWhenForeground() async {
        microphoneStatus = PermissionManager.microphoneStatus
        speechStatus = PermissionManager.speechRecognitionStatus
        liveActivitiesEnabled = PermissionManager.areLiveActivitiesEnabled

        guard !isDownloading else { return }
        await refreshModelStatus(autoDownload: true)
    }

    func downloadModelIfNeeded() async {
        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        errorMessage = nil
        defer { isDownloading = false }

        logger.info("speech model download requested by onboarding")
        do {
            let installed = try await SpeechModelManager.ensureInstalled { [weak self] fraction in
                guard let self else { return }
                self.downloadProgress = min(max(fraction, 0), 1)
            }
            modelChecked = true
            if installed {
                modelStatus = .installed
                downloadProgress = 1
                logger.info("speech model ready")
            } else {
                modelStatus = await SpeechModelManager.status()
                if modelStatus == .needsDownload {
                    errorMessage = "模型没有安装成功，请重试下载。"
                }
            }
        } catch {
            modelStatus = await SpeechModelManager.status()
            errorMessage = "模型下载失败：\(error.localizedDescription)"
            logger.error("speech model download failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Private

    private func refreshModelStatus(autoDownload: Bool) async {
        let status = await SpeechModelManager.status()
        modelStatus = status
        modelChecked = true

        guard autoDownload, !isDownloading else { return }
        switch status {
        case .needsDownload, .downloading:
            await downloadModelIfNeeded()
        case .installed, .unsupported:
            break
        }
    }
}
