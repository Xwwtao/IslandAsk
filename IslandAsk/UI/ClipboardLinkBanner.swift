//
//  ClipboardLinkBanner.swift
//  IslandAsk
//
//  剪贴板收藏（M-C2，SPEC 第 6.13 节「剪贴板入口」）的界面，状态来自 ClipboardLinkDetector：
//  - ClipboardPasteButton：收藏库标题「IslandAsk」右边一直显示的系统 PasteButton，左边两行小字说明；检测到链接时说明变主题色。
//  - ClipboardLinkBanner：只在粘贴之后短暂显示结果：收藏中 / 已收藏：<标题> / 已收藏过（可点开那张卡片）/ 没有找到链接。
//  其余时候不占位置。
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
            // 检测到链接时只让大标题右边的粘贴按钮高亮，不再占一条提示条。
            EmptyView()
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

/// 大标题右边的粘贴收藏按钮（系统 PasteButton，不弹「是否允许粘贴」）+ 左边两行小字说明。
/// 按钮固定用主题色：系统会校验 PasteButton 的外观，灰色这类低对比度的 tint 会让点击被静默拒绝
/// （模拟器实测：蓝色能粘贴，灰色点了没有任何回调）。检测到链接时由说明文字变色提示。
/// 按钮上不能盖其它视图，否则系统同样会拒绝粘贴。
struct ClipboardPasteButton: View {

    private var detector: ClipboardLinkDetector { .shared }

    var body: some View {
        HStack(spacing: 8) {
            // 放不下时（字号调大、屏幕窄）整段说明不显示，把空间让给标题。
            ViewThatFits(in: .horizontal) {
                hint
                Color.clear.frame(width: 0, height: 0)
            }
            // TODO: 核对官方文档：PasteButton(payloadType:onPaste:) 回调所在线程；这里统一切回主线程再处理。
            PasteButton(payloadType: String.self) { strings in
                Task { @MainActor in
                    ClipboardLinkDetector.shared.handlePaste(strings)
                }
            }
            .labelStyle(.titleAndIcon)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .tint(.accentColor)
            .disabled(detector.isShowingResult)
            .accessibilityHint("粘贴剪贴板里的链接并收藏")
        }
    }

    /// 告诉用户这个按钮是收藏用的：检测到链接时用主题色说「剪贴板有链接」，否则灰色说明用法。
    private var hint: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(detector.hasLink ? "剪贴板有链接" : "点击粘贴")
            Text("收藏链接")
        }
        .font(.caption2.weight(detector.hasLink ? .semibold : .regular))
        .foregroundStyle(detector.hasLink ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .multilineTextAlignment(.trailing)
        .lineLimit(1)
        .fixedSize()
        .animation(Theme.Motion.quick, value: detector.hasLink)
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
