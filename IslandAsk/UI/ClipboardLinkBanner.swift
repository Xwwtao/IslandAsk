//
//  ClipboardLinkBanner.swift
//  IslandAsk
//
//  收藏库最上方的剪贴板提示条（M-C2，SPEC 第 6.13 节「剪贴板入口」）。状态来自 ClipboardLinkDetector：
//  - 剪贴板里可能有链接：「剪贴板里有链接」+ 系统 PasteButton「收藏」+「✕」。收藏前读不到内容，所以不显示是哪个链接。
//  - 收藏中 / 已收藏：<标题> / 已收藏过（可点开那张卡片）/ 没有找到链接。
//  hidden 时不占位置。
//

import SwiftUI

struct ClipboardLinkBanner: View {

    let onOpenCard: (UUID) -> Void

    private var detector: ClipboardLinkDetector { .shared }

    var body: some View {
        switch detector.state {
        case .hidden:
            EmptyView()
        case .available:
            HStack(spacing: 12) {
                icon("doc.on.clipboard", tint: .accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("剪贴板里有链接")
                        .font(.subheadline.weight(.semibold))
                    Text("从小红书、微信「复制链接」后，可以在这里收藏")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                // TODO: 核对官方文档：PasteButton(payloadType:onPaste:) 回调所在线程；这里统一切回主线程再处理。
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in
                        ClipboardLinkDetector.shared.handlePaste(strings)
                    }
                }
                .labelStyle(.titleOnly)
                .buttonBorderShape(.capsule)
                .tint(.accentColor)
                Button("不收藏", systemImage: "xmark") {
                    detector.dismiss()
                }
                .labelStyle(.iconOnly)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .buttonStyle(.borderless)
            }
            .bannerStyle()
        case .saving:
            HStack(spacing: 12) {
                ProgressView()
                Text("正在收藏…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .bannerStyle()
        case .saved(let title):
            resultRow(symbol: "bookmark.fill", tint: .accentColor, title: "已收藏", detail: title)
        case .duplicate(let cardID, let title):
            Button {
                detector.didOpenDuplicate()
                onOpenCard(cardID)
            } label: {
                HStack(spacing: 12) {
                    icon("bookmark.circle", tint: .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("这个链接已收藏过")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text("查看")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tint)
                }
                .bannerStyle()
            }
            .buttonStyle(.plain)
        case .noLink:
            resultRow(symbol: "link.badge.plus", tint: .orange, title: "剪贴板里没有找到链接", detail: nil)
        }
    }

    private func resultRow(symbol: String, tint: Color, title: String, detail: String?) -> some View {
        HStack(spacing: 12) {
            icon(symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .bannerStyle()
        .sensoryFeedback(.success, trigger: title)
    }

    private func icon(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.title3)
            .foregroundStyle(tint)
            .frame(width: 28)
            .accessibilityHidden(true)
    }
}

private extension View {
    func bannerStyle() -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.cardBackground, in: .rect(cornerRadius: Theme.Radius.card))
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
