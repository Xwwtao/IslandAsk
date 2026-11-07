//
//  CardDetailView.swift
//  IslandAsk
//
//  卡片详情的组件（M-C1，SPEC 第 6.12 节）。卡片详情页本身复用会话页（SessionDetailView）：
//  截图下面插入 CardInfoSection，有问答的卡片接着显示原会话页内容。
//  - CardInfoSection：标题、类型、标签、关键信息、附注、来源、可折叠的翻译。
//  - CardEditSheet：手动编辑标题和标签。
//  - AddTagSheet：收藏库多选「加标签」，可输入新标签或从已有标签里选。
//  所有写入经 SessionCoordinator。
//

import SwiftUI
import UIKit

// MARK: - 卡片信息

struct CardInfoSection: View {

    let card: Card

    @Environment(AppState.self) private var appState
    @State private var showsTranslation = false

    var body: some View {
        if !card.isGone {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let tags = card.tags, !tags.isEmpty {
                TagList(tags: tags) { tag in
                    appState.searchLibrary(tag: tag)
                }
            }
            if !card.keyInfo.isEmpty {
                keyInfoGrid
            }
            if let note = card.note {
                Label(note, systemImage: "text.bubble")
                    .font(.callout)
                    .textSelection(.enabled)
            }
            sourceLinkRow
            if let source = sourceText {
                Label(source, systemImage: "app.badge")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let translation = card.translation {
                DisclosureGroup(isExpanded: $showsTranslation) {
                    Text(translation)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                } label: {
                    Label("中文翻译", systemImage: "character.bubble")
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
        .cardStyle()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(card.cardTypeValue.displayName, systemImage: card.cardTypeValue.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.fill.tertiary, in: .capsule)
                if card.isSavedValue {
                    Label("已收藏", systemImage: "bookmark.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
                if card.originValue == .share {
                    // 分享卡片的 pending 可能停很久（断网），只有请求真正进行时才显示「整理中」。
                    if LinkOrganizeStore.shared.organizingCardIDs.contains(card.id) {
                        organizingBadge
                    } else if card.organizeStatusValue == .pending {
                        Label("待整理", systemImage: "clock")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                } else if card.organizeStatusValue == .pending {
                    organizingBadge
                }
            }
            Text(card.displayTitle)
                .font(.title3.bold())
                .textSelection(.enabled)
        }
    }

    private var organizingBadge: some View {
        Label("整理中", systemImage: "ellipsis")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.cyan)
            .symbolEffect(.variableColor.iterative, options: .repeating)
    }

    /// M-C2 原链接：显示真实域名（从 URL 解析，不用网页标题代替），点击用系统浏览器打开。
    /// 与 LinkSafety 同一原则：用户看到的域名必须是链接实际指向的域名。
    @ViewBuilder
    private var sourceLinkRow: some View {
        if let link = card.sourceLink, let host = link.host() {
            Link(destination: link) {
                HStack(spacing: 10) {
                    if let iconURL = card.iconURL {
                        LinkIconImage(url: iconURL, side: 24)
                    } else {
                        Image(systemName: "link")
                            .font(.callout)
                            .foregroundStyle(.tint)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(link.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(Theme.Colors.insetBackground, in: .rect(cornerRadius: Theme.Radius.inner))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开原链接 \(host)")
            .contextMenu {
                Button("复制链接", systemImage: "doc.on.doc") {
                    UIPasteboard.general.url = link
                }
                ShareLink("分享链接", item: link)
            }
        }
    }

    private var keyInfoGrid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(Array(card.keyInfo.enumerated()), id: \.offset) { _, item in
                GridRow {
                    Text(item.label)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(item.value)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .background(Theme.Colors.insetBackground, in: .rect(cornerRadius: Theme.Radius.inner))
    }

    private var sourceText: String? {
        let parts = [card.sourcePlatform, card.sourceTitle].compactMap { $0 }
        return parts.isEmpty ? nil : "来自 " + parts.joined(separator: " · ")
    }
}

/// 一行可横向滚动的标签。
/// 点标签：回到收藏库，按这个标签筛选（搜索框填入「#标签」）。
private struct TagList: View {

    let tags: [String]
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    Button {
                        onSelect(tag)
                    } label: {
                        Text("#\(tag)")
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.tint.opacity(0.12), in: .capsule)
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("在收藏库里查看带这个标签的卡片")
                }
            }
        }
    }
}

// MARK: - 编辑标题和标签

struct CardEditSheet: View {

    let card: Card

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var tags: [String]
    @State private var newTag = ""

    init(card: Card) {
        self.card = card
        _title = State(initialValue: card.title ?? "")
        _tags = State(initialValue: card.tags ?? [])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("标题") {
                    TextField("标题", text: $title, prompt: Text(card.displayTitle))
                }
                Section("标签") {
                    ForEach(tags, id: \.self) { tag in
                        Text("#\(tag)")
                    }
                    .onDelete { tags.remove(atOffsets: $0) }
                    HStack {
                        TextField("新标签", text: $newTag)
                            .onSubmit(addTag)
                        Button("添加", action: addTag)
                            .disabled(trimmedNewTag.isEmpty)
                    }
                }
            }
            .navigationTitle("编辑卡片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        addTag()
                        SessionCoordinator.shared.updateCard(id: card.id, title: title, tags: tags)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var trimmedNewTag: String {
        newTag.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addTag() {
        let tag = trimmedNewTag
        guard !tag.isEmpty else { return }
        if !tags.contains(tag) {
            tags.append(tag)
        }
        newTag = ""
    }
}

// MARK: - 批量加标签

struct AddTagSheet: View {

    let existingTags: [String]
    let onAdd: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("输入新标签", text: $text)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { add(text) }
                } footer: {
                    Text("会追加到所有选中的卡片上，不覆盖原有标签。")
                }
                if !matchingTags.isEmpty {
                    Section("已有标签") {
                        ForEach(matchingTags, id: \.self) { tag in
                            Button("#\(tag)") { add(tag) }
                        }
                    }
                }
            }
            .navigationTitle("加标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") { add(text) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private var matchingTags: [String] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return existingTags }
        return existingTags.filter { $0.localizedStandardContains(query) }
    }

    private func add(_ tag: String) {
        let tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        onAdd(tag)
        dismiss()
    }
}

// MARK: - 分享卡片详情（M-C2）

/// 分享得到的卡片没有会话：只显示卡片信息（含原链接）和整理状态 / 内容摘要。
/// 「整理中」只在请求真正进行时显示（LinkOrganizeStore）；断网留下的 pending 显示「待整理」和「现在整理」。
struct LinkCardContent: View {

    let card: Card

    @State private var isRetrying = false
    @State private var copied = false

    private var isOrganizing: Bool {
        LinkOrganizeStore.shared.organizingCardIDs.contains(card.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                if let coverURL = card.coverURL {
                    LinkCoverImage(url: coverURL)
                        .staggeredAppear(0)
                }
                CardInfoSection(card: card)
                    .staggeredAppear(0)
                statusSection
                    .staggeredAppear(1)
                if card.linkBlocked == true {
                    blockedHint
                        .staggeredAppear(2)
                }
            }
            .padding(Theme.Spacing.page)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if isOrganizing {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(.cyan)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .accessibilityHidden(true)
                Text(card.sourceLink == nil ? "正在整理这段文字…" : "正在读取链接、整理内容…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        } else {
            switch card.organizeStatusValue {
            case .done:
                summaryCard
            case .pending:
                retryCard(
                    title: "待整理",
                    message: card.organizeError.map { "上次没整理完：\($0)。联网后回到 App 会自动整理。" }
                        ?? "回到 App 时会自动整理。",
                    buttonTitle: "现在整理",
                    tint: nil
                )
            case .failed:
                retryCard(
                    title: card.organizeError ?? "整理失败",
                    message: "检查设置里的 API 配置后，点「重新整理」再试一次。",
                    buttonTitle: "重新整理",
                    tint: .orange
                )
            }
        }
    }

    /// M-C2 补充：网站不允许程序读取（知乎、微博、酷安等），摘要只能根据标题和附注写。
    /// 不做绕过，提示用户在原 App 里按键截屏，让模型直接看到内容。
    private var blockedHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("这个网站不允许直接读取内容", systemImage: "lock.doc")
                .font(.subheadline.weight(.semibold))
            Text("摘要只根据标题和附注整理。可以在原 App 里打开这条内容，按操作按钮截屏收藏，让 AI 看到完整内容。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    @ViewBuilder
    private var summaryCard: some View {
        if let summary = card.summary, !summary.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("内容摘要", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    Button {
                        UIPasteboard.general.string = summary
                        copied = true
                    } label: {
                        Label(copied ? "已复制" : "复制摘要", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .labelStyle(.iconOnly)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .sensoryFeedback(.success, trigger: copied) { _, new in new }
                }
                MarkdownText(markdown: summary)
            }
            .cardStyle()
        }
    }

    private func retryCard(title: String, message: String, buttonTitle: String, tint: Color?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: tint == nil ? "clock" : "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(tint ?? .secondary)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                reorganize()
            } label: {
                if isRetrying {
                    ProgressView()
                } else {
                    Label(buttonTitle, systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(isRetrying)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(tint: tint)
    }

    private func reorganize() {
        guard !isRetrying else { return }
        let id = card.id
        isRetrying = true
        Task {
            await SessionCoordinator.shared.reorganizeCard(id: id)
            isRetrying = false
        }
    }
}

// MARK: - 链接图片（M-C2 补充）

/// 网站图标：圆角小方块，按需在主线程外解码；加载失败显示链接符号。
struct LinkIconImage: View {

    let url: URL
    let side: CGFloat

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "link")
                    .font(.system(size: side * 0.55, weight: .semibold))
                    .foregroundStyle(.tint)
            }
        }
        .frame(width: side, height: side)
        .clipShape(.rect(cornerRadius: side * 0.22))
        .accessibilityHidden(true)
        .task(id: url) {
            image = await Self.load(url, maxPixelSize: Int(side * displayScale))
        }
    }

    @concurrent
    nonisolated static func load(_ url: URL, maxPixelSize: Int) async -> UIImage? {
        ScreenshotStore.thumbnail(url: url, maxPixelSize: maxPixelSize)
    }
}

/// 链接卡片详情顶部的封面大图：宽度占满，最高 220pt，按比例裁切。
struct LinkCoverImage: View {

    let url: URL

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: min(220, max(140, image.size.height / max(image.size.width, 1) * 360)))
                    .clipped()
                    .clipShape(.rect(cornerRadius: Theme.Radius.card))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: image != nil)
        .accessibilityHidden(true)
        .task(id: url) {
            image = await LinkIconImage.load(url, maxPixelSize: Int(600 * displayScale))
        }
    }
}
