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
                TagList(tags: tags)
            }
            if !card.keyInfo.isEmpty {
                keyInfoGrid
            }
            if let note = card.note {
                Label(note, systemImage: "text.bubble")
                    .font(.callout)
                    .textSelection(.enabled)
            }
            if let source = sourceText {
                Label(source, systemImage: "link")
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
                if card.organizeStatusValue == .pending {
                    Label("整理中", systemImage: "ellipsis")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.cyan)
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                }
            }
            Text(card.displayTitle)
                .font(.title3.bold())
                .textSelection(.enabled)
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
private struct TagList: View {

    let tags: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    Text("#\(tag)")
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.tint.opacity(0.12), in: .capsule)
                        .foregroundStyle(.tint)
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
