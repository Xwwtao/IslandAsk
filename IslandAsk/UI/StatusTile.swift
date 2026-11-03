//
//  StatusTile.swift
//  IslandAsk
//
//  设置页状态区的一个紧凑方块：左侧图标，中间标题和状态，右侧对勾 / 感叹号。
//  正常的方块只展示；需要处理的方块描橙边，整块可点，点了直接执行修复（去系统设置 / 下载模型 / 填 Key）。
//

import SwiftUI

struct StatusTile: View {

    let item: StatusCheckItem
    /// 模型下载中的进度；nil 表示没在下载。
    var progress: Double?
    let onFix: () -> Void

    var body: some View {
        if item.fix != nil, progress == nil {
            Button(action: onFix) {
                content
            }
            .buttonStyle(.plain)
            .accessibilityHint(item.fix?.title ?? "")
        } else {
            content
        }
    }

    private var isOK: Bool { item.fix == nil }

    private var content: some View {
        HStack(spacing: 10) {
            SettingsIcon(systemName: item.systemName, color: item.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                if let progress {
                    ProgressView(value: progress)
                        .tint(item.color)
                        .padding(.vertical, 5)
                } else {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(isOK ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: isOK ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isOK ? Color.green : Color.orange)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.cardBackground, in: .rect(cornerRadius: Theme.Radius.inner + 4))
        .overlay {
            if !isOK {
                RoundedRectangle(cornerRadius: Theme.Radius.inner + 4)
                    .strokeBorder(.orange.opacity(0.5), lineWidth: 1.5)
            }
        }
        .contentShape(.rect(cornerRadius: Theme.Radius.inner + 4))
        .accessibilityElement(children: .combine)
    }

    /// 方块上只写状态；可点按由橙色描边表示，VoiceOver 走 accessibilityHint。
    private var statusText: String {
        item.detail
    }
}
