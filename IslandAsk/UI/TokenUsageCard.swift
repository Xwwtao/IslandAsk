//
//  TokenUsageCard.swift
//  IslandAsk
//
//  会话页的 Token 卡片：这条会话每次调用大模型的 token 用量（快速回答 / 重新提问 / 深度回答 / 追问）。
//  样式和 TimingCard 一致，折叠显示合计；展开后每次调用一行，横条按输出 token 画比例。
//  被取消的提前请求拿不到用量，只显示次数。设置 → 诊断信息里和耗时卡片一起开关。
//

import SwiftUI
import UIKit

struct TokenUsageCard: View {

    let records: [TokenUsageRecord]
    /// 被取消的提前请求次数（服务端可能已按输入计费，但拿不到用量）。
    let cancelledSpeculativeRequests: Int

    @State private var isExpanded = false
    @State private var copied = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(records.enumerated()), id: \.offset) { index, record in
                    row(record, index: index)
                }
                if cancelledSpeculativeRequests > 0 {
                    Label(
                        "另有 \(cancelledSpeculativeRequests) 次提前请求被取消，用量未知",
                        systemImage: "exclamationmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                copyButton
            }
            .padding(.top, 10)
        } label: {
            Label("Token · 合计 \(records.totalTokens.formatted())", systemImage: "number.circle")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    /// 横条比例的基准：所有调用里最多的输出 token。
    private var maxCompletion: Int {
        max(records.compactMap(\.usage.completionTokens).max() ?? 1, 1)
    }

    /// 同类调用有多次时（追问）加序号。
    private func title(for record: TokenUsageRecord, index: Int) -> String {
        let sameKind = records.prefix(index + 1).filter { $0.kind == record.kind }.count
        let total = records.filter { $0.kind == record.kind }.count
        return total > 1 ? "\(record.kind.displayName) \(sameKind)" : record.kind.displayName
    }

    private func row(_ record: TokenUsageRecord, index: Int) -> some View {
        let usage = record.usage
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title(for: record, index: index))
                    .font(.footnote.weight(.semibold))
                Text(record.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(usage.totalTokens.formatted())
                    .font(.footnote.monospacedDigit().weight(.semibold))
            }
            HStack(spacing: 10) {
                metric("输入", usage.promptTokens)
                if let cached = usage.cacheHitTokens {
                    metric("缓存命中", cached)
                }
                metric("输出", usage.completionTokens)
                if let reasoning = usage.reasoningTokens {
                    metric("其中思考", reasoning)
                }
            }
            GeometryReader { proxy in
                Capsule()
                    .fill(.tint.opacity(0.6))
                    .frame(width: proxy.size.width * CGFloat(usage.completionTokens ?? 0) / CGFloat(maxCompletion))
            }
            .frame(height: 4)
        }
        .accessibilityElement(children: .combine)
    }

    private func metric(_ name: String, _ value: Int?) -> some View {
        HStack(spacing: 3) {
            Text(name)
                .foregroundStyle(.secondary)
            Text(value.map { $0.formatted() } ?? "—")
                .monospacedDigit()
        }
        .font(.caption)
    }

    private var copyButton: some View {
        Button {
            var lines = records.map(\.logLine)
            if cancelledSpeculativeRequests > 0 {
                lines.append("cancelledSpeculative=\(cancelledSpeculativeRequests)")
            }
            lines.append("total=\(records.totalTokens)")
            UIPasteboard.general.string = lines.joined(separator: "\n")
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(copied ? "已复制" : "复制用量", systemImage: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .font(.footnote.weight(.semibold))
        .buttonStyle(.glass)
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
    }
}

extension SessionTiming {
    /// 被取消的提前请求次数：命中的那一次已经算在快速回答的用量里。
    var cancelledSpeculativeRequests: Int {
        let sent = speculativeRequests ?? 0
        return max(sent - (speculation == .hit ? 1 : 0), 0)
    }
}
