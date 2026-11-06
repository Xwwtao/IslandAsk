//
//  SettingsView.swift
//  IslandAsk
//
//  设置页（SPEC 第 6.12 节，UI 优化后）：
//  - 顶部「状态」：一张总览卡（一切就绪 / 有 N 项需要处理）+ 检查清单，只有出问题的行才显示处理按钮。
//    后台录音准备、App Group 这类排查项收进「诊断信息」。
//  - 大模型：API 地址、Key（存 Keychain，提交或离开本页时保存）、模型名、截图文字识别开关。
//  - 语音识别：识别语言，切换前先在本页下载目标语言的模型，下载成功才生效（模型只能在前台下载）。
//  - 快捷指令：图文指引入口。
//  静音检测阈值已从设置页去掉，固定用默认值（SilenceDetectionConfiguration.current）。
//  所有设置下一次提问生效。
//

import AVFAudio
import SwiftUI
import UIKit
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
    category: "coordinator"
)

struct SettingsView: View {

    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    // 大模型
    @State private var baseURL = AppSettings.baseURLString
    @State private var model = AppSettings.model
    @State private var screenTextRecognition = AppSettings.screenTextRecognitionEnabled
    @State private var apiKey = ""
    @State private var savedAPIKey = ""
    @State private var apiKeyError: String?
    @FocusState private var apiKeyFocused: Bool

    // 识别语言
    @State private var language = AppSettings.recognitionLanguage
    @State private var isDownloadingModel = false
    @State private var downloadProgress = 0.0
    @State private var languageError: String?

    // 历史记录
    @State private var retentionDays = AppSettings.historyRetentionDays
    @State private var storageBytes: Int64?

    // 诊断
    @State private var showsTiming = AppSettings.showsTiming

    // 状态
    @State private var microphoneGranted = false
    @State private var speechRecognitionGranted = false
    @State private var speechModelStatus: SpeechModelStatus?
    @State private var liveActivitiesEnabled = false

    var body: some View {
        Form {
            statusSection
            llmSection
            languageSection
            historySection
            privacySection
            shortcutSection
            diagnosticsSection
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let stored = KeychainStore.read() ?? ""
            apiKey = stored
            savedAPIKey = stored
            await refreshStatus()
            storageBytes = await ScreenshotStore.sessionsDirectoryByteCount()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await refreshStatus() }
        }
        .onChange(of: isDownloadingModel) { _, downloading in
            // 模型下载要求 App 在前台，下载期间不要自动锁屏。
            UIApplication.shared.isIdleTimerDisabled = downloading
        }
        .onDisappear {
            saveAPIKeyIfChanged()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: - 状态

    private var checkItems: [StatusCheckItem] {
        let modelOK = speechModelStatus == .installed || speechModelStatus == .unsupported
        let hasKey = !savedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return [
            StatusCheckItem(
                id: "mic", title: "麦克风", systemName: "mic.fill", color: .red,
                detail: microphoneGranted ? "已授权" : "未授权",
                fix: microphoneGranted ? nil : .systemSettings
            ),
            StatusCheckItem(
                id: "speech", title: "语音识别", systemName: "waveform", color: .orange,
                detail: speechRecognitionGranted ? "已授权" : "未授权",
                fix: speechRecognitionGranted ? nil : .systemSettings
            ),
            StatusCheckItem(
                id: "model", title: "转录模型", systemName: "arrow.down.circle.fill", color: .indigo,
                detail: speechModelStatusText,
                fix: modelOK || speechModelStatus == nil || speechModelStatus == .downloading ? nil : .downloadModel
            ),
            StatusCheckItem(
                id: "activity", title: "实时活动", systemName: "platter.filled.top.iphone", color: .green,
                detail: liveActivitiesEnabled ? "已开启" : "被关闭",
                fix: liveActivitiesEnabled ? nil : .systemSettings
            ),
            StatusCheckItem(
                id: "key", title: "API Key", systemName: "key.horizontal.fill", color: .gray,
                detail: hasKey ? "已填写" : "未填写",
                fix: hasKey ? nil : .fillAPIKey
            ),
        ]
    }

    /// 顶部一行总结 + 两列方块；正常的方块只展示，需要处理的方块点了直接修复。
    private var statusSection: some View {
        let items = checkItems
        let problems = items.filter { $0.fix != nil }.count
        return Section {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: problems == 0 ? "checkmark.seal.fill" : "exclamationmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(problems == 0 ? Color.green : Color.orange)
                        .symbolEffect(.bounce, value: problems)
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(problems == 0 ? "一切就绪" : "有 \(problems) 项需要处理")
                            .font(.headline)
                        if problems == 0 {
                            Text("按下操作按钮，就能对屏幕提问。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .cardStyle(tint: problems == 0 ? .green : .orange)
                .accessibilityElement(children: .combine)

                // 需要处理的排在前面；单数时最后一块占满整行，不留空位。
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    ForEach(tileRows(items), id: \.first?.id) { row in
                        GridRow {
                            ForEach(row) { item in
                                statusTile(item)
                                    .gridCellColumns(row.count == 1 ? 2 : 1)
                            }
                        }
                    }
                }
            }
            .animation(Theme.Motion.quick, value: problems)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } header: {
            Text("状态")
        }
    }

    private func statusTile(_ item: StatusCheckItem) -> some View {
        StatusTile(
            item: item,
            progress: item.fix == .downloadModel && isDownloadingModel ? downloadProgress : nil
        ) {
            if let fix = item.fix { perform(fix) }
        }
    }

    /// 两个一行；需要处理的项排在前面。
    private func tileRows(_ items: [StatusCheckItem]) -> [[StatusCheckItem]] {
        let sorted = items.filter { $0.fix != nil } + items.filter { $0.fix == nil }
        return stride(from: 0, to: sorted.count, by: 2).map { Array(sorted[$0..<min($0 + 2, sorted.count)]) }
    }

    private func perform(_ fix: StatusCheckItem.Fix) {
        switch fix {
        case .systemSettings:
            if let url = PermissionManager.appSettingsURL { openURL(url) }
        case .downloadModel:
            Task { await switchLanguage(to: language, force: true) }
        case .fillAPIKey:
            apiKeyFocused = true
        }
    }

    private var speechModelStatusText: String {
        switch speechModelStatus {
        case .installed: return "已安装"
        case .needsDownload: return "未安装"
        case .downloading: return "下载中"
        case .unsupported: return "使用系统识别"
        case nil: return "检查中"
        }
    }

    private func refreshStatus() async {
        microphoneGranted = PermissionManager.microphoneStatus == .granted
        speechRecognitionGranted = PermissionManager.isSpeechRecognitionGranted
        liveActivitiesEnabled = PermissionManager.areLiveActivitiesEnabled
        speechModelStatus = await SpeechModelManager.status()
    }

    // MARK: - 大模型

    private var llmSection: some View {
        Section {
            LabeledContent {
                TextField(AppSettings.defaultBaseURL, text: $baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .onChange(of: baseURL) { _, value in AppSettings.baseURLString = value }
            } label: {
                SettingsLabel("地址", systemName: "network", color: .blue)
            }
            LabeledContent {
                SecureField("未填写", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .focused($apiKeyFocused)
                    .onSubmit { saveAPIKeyIfChanged() }
            } label: {
                SettingsLabel("API Key", systemName: "key.horizontal.fill", color: .gray)
            }
            LabeledContent {
                TextField(AppSettings.defaultModel, text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .onChange(of: model) { _, value in AppSettings.model = value }
            } label: {
                SettingsLabel("模型", systemName: "cpu", color: .purple)
            }
            if apiKey != savedAPIKey {
                Button("保存 API Key", systemImage: "checkmark.circle") { saveAPIKeyIfChanged() }
                    .bold()
            }
            Toggle(isOn: $screenTextRecognition) {
                SettingsLabel("截图文字识别增强", systemName: "text.viewfinder", color: .teal)
            }
            .onChange(of: screenTextRecognition) { _, value in AppSettings.screenTextRecognitionEnabled = value }
        } header: {
            Text("大模型")
        } footer: {
            if let apiKeyError {
                Text(apiKeyError).foregroundStyle(.red)
            } else {
                Text("兼容 OpenAI /chat/completions 接口，模型须支持图片输入。Key 只保存在本机钥匙串。文字识别增强会在本机识别截图里的文字，和截图一起发送，小字更准。")
            }
        }
    }

    private func saveAPIKeyIfChanged() {
        guard apiKey != savedAPIKey else { return }
        do {
            try KeychainStore.write(apiKey)
            savedAPIKey = apiKey
            apiKeyError = nil
            logger.info("settings: api key saved hasKey=\(!apiKey.isEmpty, privacy: .public)")
        } catch {
            apiKeyError = error.localizedDescription
            logger.error("settings: api key save failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 识别语言

    private var languageSection: some View {
        Section {
            Picker(selection: Binding(
                get: { language },
                set: { newValue in
                    guard newValue != language else { return }
                    Task { await switchLanguage(to: newValue) }
                }
            )) {
                ForEach(AppSettings.RecognitionLanguage.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            } label: {
                SettingsLabel("识别语言", systemName: "globe", color: .blue)
            }
            .disabled(isDownloadingModel || SessionCoordinator.shared.isSessionBusy)

            if isDownloadingModel {
                ProgressView(value: downloadProgress) {
                    Text("正在下载语音模型… \(Int(downloadProgress * 100))%")
                        .font(.footnote)
                        .monospacedDigit()
                }
            }
        } header: {
            Text("语音识别")
        } footer: {
            if let languageError {
                Text(languageError).foregroundStyle(.red)
            } else {
                Text("切换语言时会先下载对应的语音模型，请保持 App 在前台。")
            }
        }
    }

    /// force：状态区「下载」按钮用，当前语言的模型缺失时重新下载。
    private func switchLanguage(to target: AppSettings.RecognitionLanguage, force: Bool = false) async {
        languageError = nil
        logger.info(
            "settings: switch language requested target=\(target.rawValue, privacy: .public) force=\(force, privacy: .public)"
        )

        let status = await SpeechModelManager.status(locale: target.locale)
        switch status {
        case .installed, .unsupported:
            // unsupported 时 TranscriptionService 会回退系统语音识别，允许切换。
            apply(target)
            return
        case .needsDownload, .downloading:
            break
        }

        isDownloadingModel = true
        downloadProgress = 0
        defer { isDownloadingModel = false }
        do {
            // TODO: 核对官方文档：确认 AssetInventory 可在当前识别语言之外为另一 locale 下载模型。
            let installed = try await SpeechModelManager.ensureInstalled(locale: target.locale) { fraction in
                downloadProgress = min(max(fraction, 0), 1)
            }
            if installed {
                apply(target)
            } else {
                languageError = "这个语言暂不支持，已保持原设置。"
                logger.notice("settings: language unsupported target=\(target.rawValue, privacy: .public)")
            }
        } catch {
            languageError = "模型下载失败：\(error.localizedDescription)"
            logger.error(
                "settings: language model download failed target=\(target.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func apply(_ target: AppSettings.RecognitionLanguage) {
        AppSettings.recognitionLanguage = target
        language = target
        logger.info("settings: language applied target=\(target.rawValue, privacy: .public)")
        Task { speechModelStatus = await SpeechModelManager.status() }
    }

    // MARK: - 历史记录

    private var historySection: some View {
        Section {
            Picker(selection: $retentionDays) {
                ForEach(AppSettings.historyRetentionOptions, id: \.self) { days in
                    Text(days == 0 ? "永久" : "\(days) 天").tag(days)
                }
            } label: {
                SettingsLabel("保留时长", systemName: "clock.arrow.circlepath", color: .brown)
            }
            .onChange(of: retentionDays) { _, value in
                AppSettings.historyRetentionDays = value
                logger.info("settings: history retention changed days=\(value, privacy: .public)")
                SessionCoordinator.shared.purgeExpiredSessions()
                Task { storageBytes = await ScreenshotStore.sessionsDirectoryByteCount() }
            }
            LabeledContent {
                Text(storageBytes.map { $0.formatted(.byteCount(style: .file)) } ?? "—")
                    .monospacedDigit()
            } label: {
                SettingsLabel("截图与录音占用", systemName: "internaldrive", color: .gray)
            }
        } header: {
            Text("历史记录")
        } footer: {
            Text("超过保留时长的会话，连同截图和录音，会在打开 App 时自动删除。")
        }
    }

    // MARK: - 数据去向

    private var privacySection: some View {
        Section {
            LabeledContent {
                Text(llmHost)
                    .foregroundStyle(.secondary)
            } label: {
                SettingsLabel("发送到", systemName: "paperplane.fill", color: .blue)
            }
        } header: {
            Text("数据去向")
        } footer: {
            Text("每次提问时，截图、语音转出的问题文字，以及（开启文字识别增强时）截图里识别出的文字，会发送到上面的大模型服务。截图、录音和历史记录只保存在本机；语音转文字优先在本机完成，设备不支持本机识别时会用 Apple 的联网识别。")
        }
    }

    private var llmHost: String {
        URL(string: baseURL)?.host() ?? "未配置"
    }

    // MARK: - 快捷指令

    private var shortcutSection: some View {
        Section {
            // 重装 App 或换机后快捷指令需要重新添加，入口放在这里。
            NavigationLink {
                ScrollView {
                    ShortcutGuideView()
                        .padding(20)
                }
                .background(Theme.Colors.pageBackground)
                .navigationTitle("快捷指令设置")
                .navigationBarTitleDisplayMode(.inline)
            } label: {
                SettingsLabel("快捷指令与操作按钮", systemName: "square.2.layers.3d", color: .pink)
            }
        } header: {
            Text("快捷指令")
        }
    }

    // MARK: - 诊断

    private var diagnosticsSection: some View {
        Section {
            DisclosureGroup("诊断信息") {
                diagnosticRow("后台录音准备", ok: appState.audioSessionPrimed, okText: "已就绪", badText: "未就绪")
                diagnosticRow("App Group", ok: AppGroup.isContainerAvailable, okText: "已配置", badText: "未配置")
                LabeledContent("识别语言", value: AppSettings.recognitionLanguage.displayName)
                LabeledContent("模型", value: AppSettings.model)
                Toggle("会话页显示耗时和 Token", isOn: $showsTiming)
                    .onChange(of: showsTiming) { _, value in AppSettings.showsTiming = value }
            }
            .font(.subheadline)
        } footer: {
            Text("真机排查用：后台录音准备在每次回到前台时检查。")
        }
    }

    private func diagnosticRow(_ title: String, ok: Bool, okText: String, badText: String) -> some View {
        LabeledContent(title) {
            Label(ok ? okText : badText, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(ok ? Color.green : Color.red)
        }
    }
}
