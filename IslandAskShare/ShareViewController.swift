//
//  ShareViewController.swift
//  IslandAskShare
//
//  链接收藏阶段 2（M-C2，SPEC 第 6.13 节）：分享菜单里的「收藏到 IslandAsk」确认面板。
//  - 只有一个面板：标题预览、可选的附注输入框、「收藏」按钮。
//  - 只把 {id, url, title, text, createdAt} 写进 App Group 的 inbox/<id>.json（ShareInbox）。
//    不发网络请求、不调大模型、不写 SwiftData：扩展内存和运行时间受限，被系统强杀时也不丢数据。
//  - 主 App 回到前台（或下次 Intent 运行）时由 SessionCoordinator 导入建卡、整理。
//  类名与 MainInterface.storyboard 里的 customClass 一致，storyboard 不用改。
//  日志 subsystem 用主 App 的 id（AppGroup.logSubsystem），category 用 link。
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os

private let logger = Logger(subsystem: AppGroup.logSubsystem, category: "link")

final class ShareViewController: UIViewController {

    private let model = SharePanelModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        model.onCancel = { [weak self] in self?.cancel() }
        model.onFinish = { [weak self] in self?.finish() }

        let host = UIHostingController(rootView: SharePanelView(model: model))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        logger.info("share extension opened items=\(items.count, privacy: .public)")
        Task { await model.load(from: items) }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func cancel() {
        logger.info("share extension cancelled")
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }
}

// MARK: - 数据

@MainActor
@Observable
final class SharePanelModel {

    enum Phase: Equatable {
        case loading
        case ready
        case saving
        case saved
        case failed(String)
    }

    var phase: Phase = .loading
    var url: URL?
    var title: String?
    /// 分享来的纯文字（不含和 url 相同的部分）。
    var sharedText: String?
    var note = ""

    var onCancel: () -> Void = {}
    var onFinish: () -> Void = {}

    var hasContent: Bool { url != nil || sharedText != nil }

    /// 从 NSExtensionItem 里取链接、标题和文字。只认 http / https 链接；文字可以来自附件或 attributedContentText。
    func load(from items: [NSExtensionItem]) async {
        var foundURL: URL?
        var texts: [String] = []
        var foundTitle: String?
        for item in items {
            if foundTitle == nil, let title = Self.clean(item.attributedTitle?.string) {
                foundTitle = title
            }
            if let content = Self.clean(item.attributedContentText?.string) {
                texts.append(content)
            }
            for provider in item.attachments ?? [] {
                if foundURL == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = await Self.loadURL(from: provider), Self.isWebURL(url) {
                    foundURL = url
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let text = Self.clean(await Self.loadText(from: provider)) {
                    texts.append(text)
                }
            }
        }
        // 文字里带链接、附件里没有链接时（微信常这样），从文字里取第一个 http(s) 链接。
        if foundURL == nil {
            foundURL = texts.lazy.compactMap(Self.firstWebURL(in:)).first
        }
        var seen = Set<String>()
        let uniqueTexts = texts.filter { text in
            text != foundURL?.absoluteString && seen.insert(text).inserted
        }
        url = foundURL
        title = foundTitle
        sharedText = uniqueTexts.isEmpty ? nil : uniqueTexts.joined(separator: "\n")
        phase = .ready
        logger.info(
            "share extension loaded hasURL=\(foundURL != nil, privacy: .public) host=\(foundURL?.host() ?? "nil", privacy: .public) hasTitle=\(foundTitle != nil, privacy: .public) textChars=\(self.sharedText?.count ?? 0, privacy: .public)"
        )
    }

    /// 写 inbox。成功后短暂显示「已收藏」再关闭面板。
    func save() {
        guard phase == .ready || phase.isFailed, hasContent else { return }
        phase = .saving
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        // 附注在前、分享文字在后；主 App 导入时会把和链接相同的部分去掉。
        let text = [trimmedNote, sharedText ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
        let item = ShareInboxItem(
            id: UUID(),
            url: url?.absoluteString,
            title: title,
            text: text.isEmpty ? nil : text,
            createdAt: .now
        )
        do {
            try ShareInbox.write(item)
            phase = .saved
            logger.info("share extension saved id=\(item.id.uuidString, privacy: .public)")
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                onFinish()
            }
        } catch {
            logger.error("share extension save failed error=\(error.localizedDescription, privacy: .public)")
            phase = .failed("收藏失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 附件读取

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let error {
                    logger.notice("share extension url load failed error=\(error.localizedDescription, privacy: .public)")
                }
                continuation.resume(returning: url)
            }
        }
    }

    private static func loadText(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, error in
                if let error {
                    logger.notice("share extension text load failed error=\(error.localizedDescription, privacy: .public)")
                }
                continuation.resume(returning: text)
            }
        }
    }

    nonisolated static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty else { return false }
        return true
    }

    nonisolated static func firstWebURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).lazy.compactMap(\.url).first(where: isWebURL)
    }

    nonisolated static func clean(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

private extension SharePanelModel.Phase {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - 界面

struct SharePanelView: View {

    @Bindable var model: SharePanelModel
    @FocusState private var noteFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    preview
                }
                if model.phase != .loading, model.hasContent {
                    Section {
                        TextField("附注（可选），如「周末去」", text: $model.note, axis: .vertical)
                            .lineLimit(1...4)
                            .focused($noteFocused)
                    } footer: {
                        Text("回到 IslandAsk 后会自动整理标题、摘要和标签。")
                    }
                }
                if case .failed(let message) = model.phase {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("收藏到 IslandAsk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { model.onCancel() }
                        .disabled(model.phase == .saving || model.phase == .saved)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("收藏") { model.save() }
                        .bold()
                        .disabled(!canSave)
                }
            }
            .overlay {
                if model.phase == .saved {
                    Label("已收藏", systemImage: "bookmark.fill")
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.regularMaterial, in: .capsule)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.snappy, value: model.phase)
            .sensoryFeedback(.success, trigger: model.phase == .saved) { _, new in new }
        }
    }

    private var canSave: Bool {
        guard model.hasContent else { return false }
        switch model.phase {
        case .ready, .failed: return true
        case .loading, .saving, .saved: return false
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch model.phase {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("正在读取分享内容…")
                    .foregroundStyle(.secondary)
            }
        default:
            if let url = model.url {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "link")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.title ?? url.host() ?? url.absoluteString)
                            .font(.headline)
                            .lineLimit(2)
                        // 显示链接实际指向的域名和地址，不用标题代替。
                        Text(url.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        if let text = model.sharedText {
                            Text(text)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                }
            } else if let text = model.sharedText {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "text.quote")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                    Text(text)
                        .font(.callout)
                        .lineLimit(6)
                }
            } else {
                Label("没有可以收藏的链接或文字", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
