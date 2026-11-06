//
//  LibraryView.swift
//  IslandAsk
//
//  收藏库（M-C1，SPEC 第 6.12 节），替换原来的历史列表作为首页：
//  - 顶部分段「全部 / 收藏」（记住上次的选择），下面一行类型筛选；可搜索标题、摘要、标签、关键信息、翻译和问答。
//  - 按「今天 / 昨天 / 更早」分组。每条显示截图缩略图、标题、摘要或状态、类型和标签、时间、收藏标记。
//  - 点进卡片详情（复用会话页）；左滑删除；长按菜单里有「选择」，点了进入多选并选中这张。
//  - 多选：右上角「选择」进入。顶部「已选 N 项」+ 全选，底部工具栏收藏 / 加标签 / 删除（删除前确认）。
//    进行中（录音、思考、整理中）的卡片不能选中。
//  所有写入经 SessionCoordinator，本页只读 @Query。导航路径放在 AppState，深链可直接 push 卡片详情。
//

import SwiftData
import SwiftUI
import UIKit
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
    category: "coordinator"
)

struct LibraryView: View {

    enum Segment: String, CaseIterable, Identifiable {
        case all
        case saved

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "全部"
            case .saved: return "收藏"
            }
        }
    }

    @Environment(AppState.self) private var appState
    @Query(sort: \Card.createdAt, order: .reverse) private var cards: [Card]

    @AppStorage("library.segment") private var segment: Segment = .all
    @State private var typeFilter: CardType?
    @State private var searchText = ""
    @State private var showsShortcutGuide = false

    // 多选
    @State private var editMode: EditMode = .inactive
    @State private var selection: Set<UUID> = []
    @State private var showsDeleteConfirmation = false
    @State private var showsAddTag = false

    private var isSelecting: Bool { editMode.isEditing }

    var body: some View {
        @Bindable var appState = appState
        NavigationStack(path: $appState.path) {
            Group {
                if cards.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle(isSelecting ? selectionTitle : "IslandAsk")
            .navigationBarTitleDisplayMode(isSelecting ? .inline : .automatic)
            .searchable(text: $searchText, prompt: "搜索标题、标签或内容")
            .toolbar { toolbarContent }
            .environment(\.editMode, $editMode)
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .session(let id):
                    // 点灵动岛会把路径直接换成另一张卡片：同一位置的页面会被沿用，@State 跟着串到新卡片。
                    // 按 ID 区分身份，换卡片就整页重建。
                    SessionDetailView(sessionID: id)
                        .id(id)
                case .settings:
                    SettingsView()
                }
            }
            .sheet(isPresented: $showsShortcutGuide) {
                shortcutGuideSheet
            }
            .sheet(isPresented: $showsAddTag) {
                AddTagSheet(existingTags: allTags) { tag in
                    let ids = Array(selection)
                    logger.info("library: add tag to selection count=\(ids.count, privacy: .public)")
                    SessionCoordinator.shared.addTag(tag, toCards: ids)
                }
            }
            .confirmationDialog(
                "删除 \(selection.count) 张卡片？",
                isPresented: $showsDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive, action: deleteSelection)
                Button("取消", role: .cancel) {}
            } message: {
                Text("截图和录音也会一起删除")
            }
            .onChange(of: visibleCardIDs) { _, visible in
                // 全选只作用于当前分段和筛选下可见的卡片；切换后看不见的不留在选中里。
                selection.formIntersection(visible)
            }
        }
    }

    // MARK: - 列表

    private var list: some View {
        List(selection: $selection) {
            Section {
                filterBar
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .selectionDisabled()
            }
            if visibleCards.isEmpty {
                Section {
                    filteredEmptyState
                        .listRowBackground(Color.clear)
                        .selectionDisabled()
                }
            }
            ForEach(groupedCards, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.cards) { card in
                        row(card)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .animation(.default, value: isSelecting)
    }

    @ViewBuilder
    private func row(_ card: Card) -> some View {
        // TODO: 核对官方文档：iOS 26 上 List(selection:) + editMode 时，非编辑状态下 NavigationLink(value:) 仍正常 push，
        // 编辑状态下点行只切换选中，需真机确认。
        NavigationLink(value: AppRoute.session(card.id)) {
            CardRow(card: card)
        }
        .tag(card.id)
        .selectionDisabled(card.isBusy)
        .swipeActions(edge: .trailing) {
            if !card.isBusy {
                Button("删除", systemImage: "trash", role: .destructive) {
                    SessionCoordinator.shared.deleteCard(id: card.id)
                }
            }
        }
        .contextMenu {
            CardRowMenu(card: card) {
                beginSelecting(with: card)
            }
        }
    }

    /// 分段 + 类型筛选。只列出当前卡片里出现过的类型。
    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("范围", selection: $segment) {
                ForEach(Segment.allCases) { segment in
                    Text(segment.title).tag(segment)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 4)

            if availableTypes.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        TypeChip(title: "全部类型", systemImage: nil, isSelected: typeFilter == nil) {
                            typeFilter = nil
                        }
                        ForEach(availableTypes) { type in
                            TypeChip(title: type.displayName, systemImage: type.systemImage, isSelected: typeFilter == type) {
                                typeFilter = typeFilter == type ? nil : type
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(allVisibleSelected ? "取消全选" : "全选") {
                    selection = allVisibleSelected ? [] : selectableVisibleIDs
                }
                .disabled(selectableVisibleIDs.isEmpty)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("完成", action: endSelecting)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                let allSaved = !selectedCards.isEmpty && selectedCards.allSatisfy(\.isSavedValue)
                Button(allSaved ? "取消收藏" : "收藏", systemImage: allSaved ? "bookmark.slash" : "bookmark") {
                    let ids = Array(selection)
                    logger.info("library: set saved=\(!allSaved, privacy: .public) count=\(ids.count, privacy: .public)")
                    SessionCoordinator.shared.setSaved(cardIDs: ids, !allSaved)
                }
                Spacer()
                Button("加标签", systemImage: "tag") {
                    showsAddTag = true
                }
                Spacer()
                Button("删除", systemImage: "trash", role: .destructive) {
                    showsDeleteConfirmation = true
                }
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                if !cards.isEmpty {
                    Button("选择") {
                        editMode = .active
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: AppRoute.settings) {
                    Label("设置", systemImage: "gearshape")
                }
            }
        }
    }

    private var selectionTitle: String {
        selection.isEmpty ? "选择卡片" : "已选 \(selection.count) 项"
    }

    // MARK: - 多选动作

    private func beginSelecting(with card: Card) {
        selection = card.isBusy ? [] : [card.id]
        editMode = .active
    }

    private func endSelecting() {
        editMode = .inactive
        selection = []
    }

    private func deleteSelection() {
        let ids = Array(selection)
        logger.info("library: delete selection count=\(ids.count, privacy: .public)")
        SessionCoordinator.shared.deleteCards(ids: ids)
        endSelecting()
    }

    // MARK: - 筛选、搜索、分组

    private var visibleCards: [Card] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return cards.filter { card in
            if segment == .saved, !card.isSavedValue { return false }
            if let typeFilter, card.cardTypeValue != typeFilter { return false }
            guard !query.isEmpty else { return true }
            return Self.searchableTexts(of: card).contains { $0.localizedStandardContains(query) }
        }
    }

    private var visibleCardIDs: Set<UUID> {
        Set(visibleCards.map(\.id))
    }

    private var selectableVisibleIDs: Set<UUID> {
        Set(visibleCards.filter { !$0.isBusy }.map(\.id))
    }

    private var allVisibleSelected: Bool {
        !selectableVisibleIDs.isEmpty && selectableVisibleIDs.isSubset(of: selection)
    }

    private var selectedCards: [Card] {
        cards.filter { selection.contains($0.id) }
    }

    private var availableTypes: [CardType] {
        let present = Set(cards.map(\.cardTypeValue))
        return CardType.allCases.filter(present.contains)
    }

    private var allTags: [String] {
        var seen = Set<String>()
        return cards.flatMap { $0.tags ?? [] }.filter { seen.insert($0).inserted }
    }

    private static func searchableTexts(of card: Card) -> [String] {
        var texts = [card.title, card.summary, card.note, card.translation, card.sourceTitle, card.sourcePlatform]
            .compactMap { $0 }
        texts += card.tags ?? []
        texts += card.keyInfo.flatMap { [$0.label, $0.value] }
        if let session = card.session {
            texts += [session.transcript, session.answer, session.deepAnswer].compactMap { $0 }
        }
        return texts
    }

    private struct CardGroup {
        let title: String
        let cards: [Card]
    }

    private var groupedCards: [CardGroup] {
        let calendar = Calendar.current
        var today: [Card] = []
        var yesterday: [Card] = []
        var earlier: [Card] = []
        for card in visibleCards {
            if calendar.isDateInToday(card.createdAt) {
                today.append(card)
            } else if calendar.isDateInYesterday(card.createdAt) {
                yesterday.append(card)
            } else {
                earlier.append(card)
            }
        }
        return [
            CardGroup(title: "今天", cards: today),
            CardGroup(title: "昨天", cards: yesterday),
            CardGroup(title: "更早", cards: earlier),
        ]
        .filter { !$0.cards.isEmpty }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有卡片", systemImage: "waveform.badge.mic")
                .symbolEffect(.variableColor.iterative, options: .repeating)
        } description: {
            Text("在任意 App 里按下操作按钮：说出问题，回答会出现在灵动岛里；不说话就把这一屏收藏起来。")
        } actions: {
            Button("设置快捷指令", systemImage: "square.2.layers.3d") {
                showsShortcutGuide = true
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private var filteredEmptyState: some View {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else if segment == .saved {
            ContentUnavailableView(
                "还没有收藏",
                systemImage: "bookmark",
                description: Text("按下操作按钮后不说话，或在灵动岛上点「收藏」，卡片就会出现在这里。")
            )
        } else {
            ContentUnavailableView("没有这类卡片", systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    private var shortcutGuideSheet: some View {
        NavigationStack {
            ScrollView {
                ShortcutGuideView()
                    .padding(20)
            }
            .background(Theme.Colors.pageBackground)
            .navigationTitle("快捷指令设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showsShortcutGuide = false }
                }
            }
        }
        .presentationDetents([.large])
    }
}

// MARK: - 行

extension Card {
    /// 正在录音、等回答或 App 内请求中：不能删除、编辑，也不能被多选选中。
    /// 按调度器的运行时状态判断，不看库里的状态：App 被杀时停在 thinking 的旧卡片仍能删。
    @MainActor var isBusy: Bool {
        SessionCoordinator.shared.isCardBusy(id: id)
    }
}

private struct CardRow: View {

    let card: Card

    var body: some View {
        if !card.isGone {
            content
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 12) {
            ScreenshotThumbnail(url: card.screenshotURL)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(card.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if card.isSavedValue {
                        Image(systemName: "bookmark.fill")
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .accessibilityLabel("已收藏")
                    }
                }
                if let detail = detailText {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(isFailed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                }
                metaRow
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// 底部一行：类型 · 标签 …… 时间 状态。
    /// 类型、时间、状态固定宽度不压缩；宽度不够时只截断标签。
    /// 之前每个元素都可压缩，SwiftUI 会把「聊天」这类短文字挤成竖排。
    private var metaRow: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                Image(systemName: card.cardTypeValue.systemImage)
                Text(card.cardTypeValue.displayName)
            }
            .fixedSize()

            if let tagsText {
                Text(tagsText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            Text(card.createdAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                .foregroundStyle(.tertiary)
                .fixedSize()

            statusBadge
                .fixedSize()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var tagsText: String? {
        let tags = (card.tags ?? []).prefix(3)
        guard !tags.isEmpty else { return nil }
        return tags.map { "#\($0)" }.joined(separator: " ")
    }

    private var isFailed: Bool {
        card.session?.statusValue == .failed || card.organizeStatusValue == .failed
    }

    private var detailText: String? {
        if let session = card.session {
            switch session.statusValue {
            case .listening: return "正在听…"
            case .thinking: return card.intentValue == .collect ? "正在整理…" : "正在想答案…"
            case .failed: return session.errorMessage ?? "整理失败"
            case .answered: break
            }
        }
        if card.organizeStatusValue == .failed { return "整理失败" }
        return card.summary
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let status = card.session?.statusValue, status != .answered {
            SessionStatusBadge(status: status)
        }
    }
}

/// 长按菜单：选择、收藏 / 取消收藏、复制、分享、删除。
private struct CardRowMenu: View {

    let card: Card
    let onSelect: () -> Void

    var body: some View {
        if !card.isGone {
            items
        }
    }

    @ViewBuilder
    private var items: some View {
        if !card.isBusy {
            Button("选择", systemImage: "checkmark.circle", action: onSelect)
            Button(card.isSavedValue ? "取消收藏" : "收藏", systemImage: card.isSavedValue ? "bookmark.slash" : "bookmark") {
                SessionCoordinator.shared.setSaved(cardID: card.id, !card.isSavedValue)
            }
        }
        if let text = copyText {
            Button(card.intentValue == .collect ? "复制摘要" : "复制回答", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = text
            }
            ShareLink("分享", item: text)
        }
        if !card.isBusy {
            Divider()
            Button("删除", systemImage: "trash", role: .destructive) {
                SessionCoordinator.shared.deleteCard(id: card.id)
            }
        }
    }

    private var copyText: String? {
        let session = card.session
        let text = card.intentValue == .collect
            ? (card.summary ?? session?.answer)
            : (session?.deepAnswer ?? session?.answer ?? card.summary)
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}

/// 类型筛选的胶囊按钮。
private struct TypeChip: View {

    let title: String
    let systemImage: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - 缩略图

/// 竖版缩略图，比例接近手机截图，顶部对齐，能看到截图的主要内容。按需在主线程外解码，列表滚动时不卡。
struct ScreenshotThumbnail: View {

    let url: URL?

    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 48
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    private var height: CGFloat { width * 4 / 3 }

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.inner)
            .fill(Theme.Colors.insetBackground)
            .frame(width: width, height: height)
            .overlay(alignment: .top) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width, height: height, alignment: .top)
                        .transition(.opacity)
                } else {
                    Image(systemName: url == nil ? "photo.badge.exclamationmark" : "photo")
                        .foregroundStyle(.secondary)
                        .frame(maxHeight: .infinity)
                }
            }
            .clipShape(.rect(cornerRadius: Theme.Radius.inner))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.inner)
                    .strokeBorder(.separator.opacity(0.6))
            }
            .animation(.easeOut(duration: 0.2), value: image != nil)
            .accessibilityHidden(true)
            .task(id: url) {
                guard let url else {
                    image = nil
                    return
                }
                image = await Self.loadThumbnail(url: url, maxPixelSize: Int(height * displayScale))
            }
    }

    @concurrent
    private static func loadThumbnail(url: URL, maxPixelSize: Int) async -> UIImage? {
        ScreenshotStore.thumbnail(url: url, maxPixelSize: maxPixelSize)
    }
}
