//
//  LibraryView.swift
//  IslandAsk
//
//  收藏库（M-C1，SPEC 第 6.12 节），替换原来的历史列表作为首页：
//  - 顶部分段「全部 / 收藏」（记住上次的选择），下面一行类型筛选；可搜索标题、摘要、标签、关键信息、翻译、OCR 文字和问答。
//  - M-C3 AI 搜索和普通搜索合在一起，没有单独的入口：回车时本地没匹配到或输入像一句话，自动按意思再搜一次。
//    结果作为「最相关」一组排在最前，本地结果里去掉重复的卡片；失败时只留本地结果。
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
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Card.createdAt, order: .reverse) private var cards: [Card]

    @AppStorage("library.segment") private var segment: Segment = .all
    @State private var typeFilter: CardType?
    @State private var searchText = ""
    @State private var aiSearch = AISearchModel()
    /// 列表里的标题行滚出屏幕后，顶栏中间显示小标题。
    @State private var showsInlineTitle = false
    @State private var showsShortcutGuide = false

    // 多选
    @State private var editMode: EditMode = .inactive
    @State private var selection: Set<UUID> = []
    @State private var showsDeleteConfirmation = false
    @State private var showsAddTag = false

    private var isSelecting: Bool { editMode.isEditing }

    var body: some View {
        @Bindable var appState = appState
        // 筛选、搜索、分组每次刷新只算一遍，列表、工具栏、全选都用这一份（之前每个用处各算一遍）。
        let state = makeListState()
        NavigationStack(path: $appState.path) {
            Group {
                if cards.isEmpty {
                    VStack(spacing: 0) {
                        titleHeader
                            .padding(.horizontal, Theme.Spacing.page + 4)
                        clipboardBanner
                            .padding(.horizontal, Theme.Spacing.page)
                        emptyState
                    }
                } else {
                    list(state)
                }
            }
            // M-C2 剪贴板入口：出现时和回到前台时检测剪贴板里有没有链接（不读内容、不弹粘贴提示）。
            .task {
                await ClipboardLinkDetector.shared.refresh()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                Task { await ClipboardLinkDetector.shared.refresh() }
            }
            .animation(.snappy, value: ClipboardLinkDetector.shared.state)
            // 标题「IslandAsk」和剪贴板粘贴按钮是列表里的第一行（titleHeader），系统大标题不用：
            // 放在系统大标题位置（ToolbarItemPlacement.largeTitle）的按钮，列表有内容时点不到（模拟器实测，普通按钮也一样）。
            .navigationTitle(isSelecting ? selectionTitle : "IslandAsk")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索，比如「上个月存的咖啡店」")
            .onSubmit(of: .search) {
                guard NaturalLanguageSearch.shouldAutoRun(query: searchText, localResultCount: textMatchedCards.count) else { return }
                logger.info("library: ai search auto on submit chars=\(searchText.count, privacy: .public)")
                runAISearch()
            }
            .onChange(of: searchText) { _, text in
                // 搜索词变了：作废旧的 AI 结果，取消进行中的请求。
                if aiSearch.query != text.trimmingCharacters(in: .whitespacesAndNewlines) {
                    aiSearch.reset()
                }
            }
            // 换了分段或类型筛选：候选变了，按新范围重搜（之前回车搜过的话）。
            .onChange(of: segment) { rerunAISearchIfNeeded() }
            .onChange(of: typeFilter) { rerunAISearchIfNeeded() }
            .toolbar { toolbarContent(state) }
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
            // 卡片详情里点了标签：按「#标签」搜索。切到「全部」、清掉类型筛选，避免结果被其他条件挡住。
            .onChange(of: appState.pendingLibrarySearch, initial: true) { _, query in
                guard let query else { return }
                appState.pendingLibrarySearch = nil
                endSelecting()
                segment = .all
                typeFilter = nil
                searchText = query
                logger.info("library: search by tag from card detail chars=\(query.count, privacy: .public)")
            }
            .onChange(of: state.visibleIDs) { _, visible in
                // 全选只作用于当前分段和筛选下可见的卡片；切换后看不见的不留在选中里。
                selection.formIntersection(visible)
            }
        }
    }

    // MARK: - 列表

    private func list(_ state: LibraryListState) -> some View {
        List(selection: listSelection) {
            if !isSelecting {
                Section {
                    titleHeader
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                        .listRowBackground(Color.clear)
                        .selectionDisabled()
                }
                .listSectionSpacing(0)
            }
            if ClipboardLinkDetector.shared.isShowingResult, !isSelecting {
                Section {
                    clipboardBanner
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .selectionDisabled()
                }
            }
            Section {
                filterBar
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .selectionDisabled()
            }
            if !state.aiResults.isEmpty {
                aiResultsSection(state.aiResults)
            }
            if state.textMatched.isEmpty, !hidesLocalEmptyState {
                Section {
                    filteredEmptyState
                        .listRowBackground(Color.clear)
                        .selectionDisabled()
                }
            }
            ForEach(state.groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.cards) { card in
                        row(card)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        // 标题行是列表第一行：去掉列表顶部默认留白，让它和系统大标题的位置差不多。
        .contentMargins(.top, 0, for: .scrollContent)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > Self.inlineTitleThreshold
        } action: { _, scrolledPast in
            showsInlineTitle = scrolledPast
        }
        .animation(.default, value: isSelecting)
    }

    // MARK: - 标题行

    /// 列表第一行：大号标题 + 剪贴板粘贴收藏按钮（M-C2 剪贴板入口）。
    private var titleHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            // 标题优先占位：字号调大、屏幕窄时先收起按钮旁的说明，实在放不下再略微缩小标题，不出现省略号。
            Text("IslandAsk")
                .font(.largeTitle.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .layoutPriority(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            ClipboardPasteButton()
        }
        .padding(.vertical, 4)
    }

    /// 标题行大约的高度：滚过这么多，顶栏显示小标题。
    private static let inlineTitleThreshold: CGFloat = 44

    // MARK: - AI 搜索

    private var showsAISearch: Bool {
        !isSelecting && !CardSearchQuery(searchText).isEmpty
    }

    /// AI 已有结果时，本地「没有匹配」的空状态不再显示。正在搜时由 filteredEmptyState 显示「正在搜索…」。
    private var hidesLocalEmptyState: Bool {
        guard showsAISearch, aiSearch.isCurrent(for: searchText) else { return false }
        switch aiSearch.phase {
        case .searching: return false
        case .results(let ids): return !ids.isEmpty
        case .idle, .failed: return false
        }
    }

    /// AI 结果对应的卡片（按模型给的相关度排序），已删除的跳过。
    private var aiResultCards: [Card] {
        // 多选时 AI 分组不显示，结果卡片回到本地分组里（否则会从列表里消失）。
        guard showsAISearch, aiSearch.isCurrent(for: searchText), case .results(let ids) = aiSearch.phase else { return [] }
        let byID = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }.filter { !$0.isGone }
    }

    private func aiResultsSection(_ aiResults: [Card]) -> some View {
        Section {
            ForEach(aiResults) { card in
                row(card)
            }
        } header: {
            Text("最相关")
        }
    }

    /// 候选是当前分段和类型筛选下的卡片（不按搜索词过滤），按时间倒序取前 200 张。
    /// 搜索结果里要高亮的关键字（M-C3）。搜索框为空时没有关键字，行按原样显示。
    private var highlightQuery: CardSearchQuery {
        CardSearchQuery(searchText)
    }

    private func runAISearch() {
        aiSearch.search(searchText, in: filteredCards)
    }

    private func rerunAISearchIfNeeded() {
        guard aiSearch.isCurrent(for: searchText) else {
            aiSearch.reset()
            return
        }
        logger.info("library: ai search rerun after filter change")
        aiSearch.reset()
        runAISearch()
    }

    private var isAISearching: Bool {
        showsAISearch && aiSearch.isCurrent(for: searchText) && aiSearch.phase == .searching
    }

    /// 收藏库最上方的剪贴板提示条；「已收藏过」时点开对应卡片。
    private var clipboardBanner: some View {
        ClipboardLinkBanner { cardID in
            appState.openSession(cardID)
        }
    }

    /// 只在多选模式下把 List 绑到真正的选中集合。
    /// 非多选时 List(selection:) 也会把点开的那行写进 selection：返回收藏库后那一行一直保持选中高亮，
    /// 再点「选择」时它还会被预先选中。非多选时给一个丢弃写入的绑定，点行仍由 NavigationLink(value:) 负责 push。
    private var listSelection: Binding<Set<UUID>> {
        guard isSelecting else {
            return Binding(get: { [] }, set: { _ in })
        }
        return $selection
    }

    @ViewBuilder
    private func row(_ card: Card) -> some View {
        // TODO: 核对官方文档：iOS 26 上 List(selection:) + editMode 时，非编辑状态下 NavigationLink(value:) 仍正常 push，
        // 编辑状态下点行只切换选中，需真机确认。
        NavigationLink(value: AppRoute.session(card.id)) {
            CardRow(card: card, highlight: highlightQuery)
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
    private func toolbarContent(_ state: LibraryListState) -> some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                let selectable = state.selectableIDs
                let allSelected = !selectable.isEmpty && selectable.isSubset(of: selection)
                Button(allSelected ? "取消全选" : "全选") {
                    selection = allSelected ? [] : selectable
                }
                .disabled(selectable.isEmpty)
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
            // 标题行（列表第一行）滚出屏幕后，顶栏中间才显示小标题；没滚动时顶栏不重复显示标题。
            ToolbarItem(placement: .principal) {
                Text("IslandAsk")
                    .font(.headline)
                    .opacity(showsInlineTitle ? 1 : 0)
                    .animation(Theme.Motion.quick, value: showsInlineTitle)
                    .accessibilityHidden(!showsInlineTitle)
            }
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

    /// 按分段和类型筛选，不看搜索词。
    private var filteredCards: [Card] {
        cards.filter { card in
            if segment == .saved, !card.isSavedValue { return false }
            if let typeFilter, card.cardTypeValue != typeFilter { return false }
            return true
        }
    }

    /// 再按搜索词做本地匹配。
    private var textMatchedCards: [Card] {
        let query = CardSearchQuery(searchText)
        guard !query.isEmpty else { return filteredCards }
        return filteredCards.filter { query.matches(texts: $0.searchableTexts, tags: $0.tags ?? []) }
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

    /// 一次刷新里列表要用的全部派生数据。
    private struct LibraryListState {
        let textMatched: [Card]
        let aiResults: [Card]
        let groups: [CardGroup]
        let visibleIDs: Set<UUID>
        /// 当前可见、不在进行中的卡片：多选「全选」用。
        let selectableIDs: Set<UUID>
    }

    private struct CardGroup {
        let title: String
        let cards: [Card]
    }

    private func makeListState() -> LibraryListState {
        let state = PerformanceTrace.signposter.beginInterval("library.derive")
        defer { PerformanceTrace.signposter.endInterval("library.derive", state) }

        let matched = textMatchedCards
        let aiResults = aiResultCards
        let aiIDs = Set(aiResults.map(\.id))
        let local = aiIDs.isEmpty ? matched : matched.filter { !aiIDs.contains($0.id) }

        let calendar = Calendar.current
        var today: [Card] = []
        var yesterday: [Card] = []
        var earlier: [Card] = []
        for card in local {
            if calendar.isDateInToday(card.createdAt) {
                today.append(card)
            } else if calendar.isDateInYesterday(card.createdAt) {
                yesterday.append(card)
            } else {
                earlier.append(card)
            }
        }
        let groups = [
            CardGroup(title: "今天", cards: today),
            CardGroup(title: "昨天", cards: yesterday),
            CardGroup(title: "更早", cards: earlier),
        ]
        .filter { !$0.cards.isEmpty }

        let visible = aiResults + local
        return LibraryListState(
            textMatched: matched,
            aiResults: aiResults,
            groups: groups,
            visibleIDs: Set(visible.map(\.id)),
            selectableIDs: Set(visible.filter { !$0.isBusy }.map(\.id))
        )
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
        if isAISearching {
            // 本地没匹配到、正在按意思搜：先显示进度，不急着说「无结果」。
            ProgressView("正在搜索…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        } else if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
    /// M-C3：命中的关键字在标题、摘要、标签里高亮；只在附注、OCR、回答等不显示的文字里命中时，摘要换成命中的那一小段。
    var highlight = CardSearchQuery("")

    /// 普通关键字（匹配全部文字）。
    private var textTerms: [String] {
        highlight.terms.filter { !$0.tagOnly }.map(\.text)
    }

    /// 标签行用：#标签 和普通关键字都会匹配标签。
    private var tagTerms: [String] {
        highlight.terms.map(\.text)
    }

    var body: some View {
        if !card.isGone {
            content
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 12) {
            if card.originValue == .share {
                LinkThumbnail(card: card)
            } else {
                ScreenshotThumbnail(url: card.screenshotURL)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(highlighted(card.displayTitle, terms: textTerms))
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
                if let detail = detailContent {
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
                Text(highlighted(tagsText, terms: tagTerms))
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
        // 搜索时命中的标签排到前面，免得排在第 4 个以后或被截断，看不到高亮。
        let all = card.tags ?? []
        let terms = tagTerms
        let ordered = terms.isEmpty
            ? all
            : all.filter { SearchHighlighter.contains(terms, in: $0) } + all.filter { !SearchHighlighter.contains(terms, in: $0) }
        let tags = ordered.prefix(3)
        guard !tags.isEmpty else { return nil }
        return tags.map { "#\($0)" }.joined(separator: " ")
    }

    private var isFailed: Bool {
        card.session?.statusValue == .failed || card.organizeStatusValue == .failed
    }

    /// 第二行：进行中、失败的状态说明照常显示；否则显示摘要（命中的关键字高亮）。
    /// 搜索时标题和摘要里都没有命中，就换成命中的那一小段，让用户知道为什么搜到这张卡片。
    private var detailContent: AttributedString? {
        if let status = statusText {
            return AttributedString(status)
        }
        let terms = textTerms
        let summary = card.summary ?? ""
        guard !terms.isEmpty, !SearchHighlighter.contains(terms, in: card.displayTitle) else {
            return summary.isEmpty ? nil : highlighted(summary, terms: terms)
        }
        // 摘要只显示两行：命中处太靠后会被截掉，改显示命中处前后的一段。
        if let hit = SearchHighlighter.ranges(of: terms, in: summary).first {
            if summary.distance(from: summary.startIndex, to: hit.lowerBound) <= Self.visibleSummaryLead {
                return highlighted(summary, terms: terms)
            }
            if let snippet = SearchHighlighter.snippet(in: [summary], terms: terms) {
                return highlighted(snippet, terms: terms)
            }
        }
        if let snippet = SearchHighlighter.snippet(in: card.hiddenSearchTexts, terms: terms) {
            return highlighted(snippet, terms: terms)
        }
        return summary.isEmpty ? nil : highlighted(summary, terms: terms)
    }

    /// 摘要两行大约能显示的字数；命中处在这之后就改显示片段。偏保守，宁可多显示片段。
    private static let visibleSummaryLead = 20

    /// 命中的部分加淡黄底色、加粗，和系统「信息」「邮件」的搜索高亮相近。
    private func highlighted(_ text: String, terms: [String]) -> AttributedString {
        var attributed = AttributedString(text)
        guard !terms.isEmpty else { return attributed }
        for range in SearchHighlighter.ranges(of: terms, in: text) {
            guard let attributedRange = Range(range, in: attributed) else { continue }
            attributed[attributedRange].backgroundColor = Color.yellow.opacity(0.4)
            attributed[attributedRange].foregroundColor = Color.primary
            attributed[attributedRange].inlinePresentationIntent = .stronglyEmphasized
        }
        return attributed
    }

    /// 进行中、失败、待整理时的状态说明；正常卡片返回 nil。
    private var statusText: String? {
        if let session = card.session {
            switch session.statusValue {
            case .listening: return "正在听…"
            case .thinking: return card.intentValue == .collect ? "正在整理…" : "正在想答案…"
            case .failed: return session.errorMessage ?? "整理失败"
            case .answered: break
            }
        }
        if card.originValue == .share {
            if LinkOrganizeStore.shared.organizingCardIDs.contains(card.id) { return "正在整理…" }
            switch card.organizeStatusValue {
            case .pending: return "待整理"
            case .failed: return card.organizeError ?? "整理失败"
            case .done: break
            }
        }
        if card.organizeStatusValue == .failed { return "整理失败" }
        return nil
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
/// M-C2：分享卡片没有截图，缩略图位置显示链接（或纯文字）图标，尺寸与 ScreenshotThumbnail 一致。
private struct LinkThumbnail: View {

    let card: Card

    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 48
    @ScaledMetric(relativeTo: .body) private var iconSide: CGFloat = 28

    var body: some View {
        // M-C2 补充：有封面图用封面图（和截图缩略图同尺寸）；没有就把网站图标放在浅色底上；都没有显示链接图标。
        if let coverURL = card.coverURL {
            ScreenshotThumbnail(url: coverURL)
        } else {
            RoundedRectangle(cornerRadius: Theme.Radius.inner)
                .fill(Theme.Colors.insetBackground)
                .frame(width: width, height: width * 4 / 3)
                .overlay {
                    if let iconURL = card.iconURL {
                        LinkIconImage(url: iconURL, side: iconSide)
                    } else {
                        Image(systemName: card.sourceLink != nil ? "link" : "text.quote")
                            .font(.title3)
                            .foregroundStyle(.tint)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.inner)
                        .strokeBorder(.separator.opacity(0.6))
                }
                .accessibilityHidden(true)
        }
    }
}

struct ScreenshotThumbnail: View {

    let url: URL?

    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 48
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    private var height: CGFloat { width * 4 / 3 }
    private var maxPixelSize: Int { Int(height * displayScale) }

    var body: some View {
        // 缓存命中时第一帧就显示图片：滚回来、从详情返回时不闪占位图。
        let shown = image ?? url.flatMap { ThumbnailCache.shared.cached(url: $0, maxPixelSize: maxPixelSize) }
        RoundedRectangle(cornerRadius: Theme.Radius.inner)
            .fill(Theme.Colors.insetBackground)
            .frame(width: width, height: height)
            .overlay(alignment: .top) {
                if let image = shown {
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
            .animation(.easeOut(duration: 0.2), value: shown != nil)
            .accessibilityHidden(true)
            .task(id: url) {
                guard let url else {
                    image = nil
                    return
                }
                image = await ThumbnailCache.shared.load(url: url, maxPixelSize: maxPixelSize)
            }
    }
}
