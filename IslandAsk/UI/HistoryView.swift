//
//  HistoryView.swift
//  IslandAsk
//
//  历史列表（SPEC 第 6.12 节，UI 优化后）：按「今天 / 昨天 / 更早」分组，可搜索问题和回答。
//  每条显示截图缩略图、问题、摘要、相对时间和状态小标。点进会话页；左滑删除；长按可复制回答或删除；右上角进设置。
//  导航路径放在 AppState，深链可直接 push 会话页。
//

import SwiftData
import SwiftUI
import UIKit

struct HistoryView: View {

    @Environment(AppState.self) private var appState
    @Query(sort: \AskSession.createdAt, order: .reverse) private var sessions: [AskSession]

    @State private var searchText = ""
    @State private var showsShortcutGuide = false

    var body: some View {
        @Bindable var appState = appState
        NavigationStack(path: $appState.path) {
            Group {
                if sessions.isEmpty {
                    emptyState
                } else if filteredSessions.isEmpty {
                    ContentUnavailableView.search
                } else {
                    List {
                        ForEach(groupedSessions, id: \.title) { group in
                            Section(group.title) {
                                ForEach(group.sessions) { session in
                                    NavigationLink(value: AppRoute.session(session.id)) {
                                        HistoryRow(session: session)
                                    }
                                    .swipeActions(edge: .trailing) {
                                        Button("删除", systemImage: "trash", role: .destructive) {
                                            delete(session.id)
                                        }
                                    }
                                    .contextMenu {
                                        HistoryRowMenu(session: session) {
                                            delete(session.id)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("IslandAsk")
            .searchable(text: $searchText, prompt: "搜索问题或回答")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink(value: AppRoute.settings) {
                        Label("设置", systemImage: "gearshape")
                    }
                }
            }
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .session(let id):
                    // 点灵动岛会把路径直接换成另一个会话：同一位置的页面会被沿用，@State（录音播放器、
                    // 输入框、自动深度回答标记）跟着串到新会话。按会话 ID 区分身份，换会话就整页重建。
                    SessionDetailView(sessionID: id)
                        .id(id)
                case .settings:
                    SettingsView()
                }
            }
            .sheet(isPresented: $showsShortcutGuide) {
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
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有提问", systemImage: "waveform.badge.mic")
                .symbolEffect(.variableColor.iterative, options: .repeating)
        } description: {
            Text("在任意 App 里按下操作按钮，对着屏幕说出你的问题，回答会出现在灵动岛里。")
        } actions: {
            Button("设置快捷指令", systemImage: "square.2.layers.3d") {
                showsShortcutGuide = true
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
    }

    // MARK: - 搜索与分组

    private var filteredSessions: [AskSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sessions }
        return sessions.filter { session in
            [session.transcript, session.summary, session.answer, session.deepAnswer]
                .compactMap { $0 }
                .contains { $0.localizedStandardContains(query) }
        }
    }

    private struct SessionGroup {
        let title: String
        let sessions: [AskSession]
    }

    private var groupedSessions: [SessionGroup] {
        let calendar = Calendar.current
        var today: [AskSession] = []
        var yesterday: [AskSession] = []
        var earlier: [AskSession] = []
        for session in filteredSessions {
            if calendar.isDateInToday(session.createdAt) {
                today.append(session)
            } else if calendar.isDateInYesterday(session.createdAt) {
                yesterday.append(session)
            } else {
                earlier.append(session)
            }
        }
        return [
            SessionGroup(title: "今天", sessions: today),
            SessionGroup(title: "昨天", sessions: yesterday),
            SessionGroup(title: "更早", sessions: earlier),
        ]
        .filter { !$0.sessions.isEmpty }
    }

    private func delete(_ id: UUID) {
        SessionCoordinator.shared.deleteSession(id: id)
    }
}

// MARK: - 行

private struct HistoryRow: View {

    let session: AskSession

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ScreenshotThumbnail(url: session.screenshotURL)
            VStack(alignment: .leading, spacing: 4) {
                Text(questionText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(session.transcript.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                if let detail = detailText {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(session.statusValue == .failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(session.createdAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    SessionStatusBadge(status: session.statusValue)
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var questionText: String {
        if !session.transcript.isEmpty { return session.transcript }
        return session.statusValue == .listening ? "正在听…" : "没有识别到文字"
    }

    private var detailText: String? {
        switch session.statusValue {
        case .listening, .thinking:
            return nil
        case .answered:
            return session.summary
        case .failed:
            return session.errorMessage
        }
    }
}

/// 长按菜单：复制问题 / 回答、分享回答、删除。
private struct HistoryRowMenu: View {

    let session: AskSession
    let onDelete: () -> Void

    var body: some View {
        if !session.transcript.isEmpty {
            Button("复制问题", systemImage: "text.quote", action: copyQuestion)
        }
        if let answer = answerText {
            Button("复制回答", systemImage: "doc.on.doc", action: copyAnswer)
            ShareLink("分享回答", item: answer)
        }
        Divider()
        Button("删除", systemImage: "trash", role: .destructive, action: onDelete)
    }

    private var answerText: String? {
        let text = session.deepAnswer ?? session.answer ?? session.summary
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    private func copyQuestion() {
        UIPasteboard.general.string = session.transcript
    }

    private func copyAnswer() {
        UIPasteboard.general.string = answerText
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
