//
//  TimingCard.swift
//  IslandAsk
//
//  会话页的耗时卡片（M4 调试用）：按「提问 / 回答 / 深度回答」列出各环节耗时，横条按组内最长一项画比例。
//  「复制耗时」复制的是 SessionTiming.logLine，和 Console 里的 timing 日志同一行。设置 → 诊断信息里可以关掉。
//

import SwiftUI
import UIKit

struct TimingCard: View {

    let timing: SessionTiming

    @State private var isExpanded = false
    @State private var copied = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 16) {
                TimingGroup(title: "提问", rows: askRows)
                TimingGroup(title: "回答", rows: answerRows)
                if !deepRows.isEmpty {
                    TimingGroup(title: "深度回答", rows: deepRows)
                }
                copyButton
            }
            .padding(.top, 10)
        } label: {
            Label(title, systemImage: "stopwatch")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var title: String {
        guard let total = timing.answerTotalMs else { return "耗时" }
        return "耗时 · 说完到回答 \(Self.format(total))"
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = timing.logLine
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(copied ? "已复制" : "复制耗时", systemImage: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .font(.footnote.weight(.semibold))
        .buttonStyle(.glass)
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
    }

    // MARK: - 行

    private var askRows: [TimingRow] {
        [
            TimingRow("按键到开始听", timing.pressToListeningMs),
            TimingRow("保存截图", timing.screenshotSaveMs, isDetail: true),
            TimingRow("结束上一个", timing.startEndPreviousMs, isDetail: true),
            TimingRow("启动灵动岛", timing.startActivityRequestMs, isDetail: true),
            TimingRow("准备转录", timing.startTranscriptionPrepareMs, isDetail: true),
            TimingRow("启动录音", timing.startAudioMs, isDetail: true),
            TimingRow("启动转录", timing.startTranscriptionActivateMs, isDetail: true),
            TimingRow("录音时长", timing.listeningMs),
            TimingRow("说完判定", timing.endDetectionMs, note: [stopTriggerText, levelText].compactMap { $0 }.joined(separator: " · ")),
            TimingRow("截掉末尾静音", timing.trimmedSilenceMs, note: "回答后处理，不计入等待"),
        ]
    }

    private var answerRows: [TimingRow] {
        let network = timing.network
        var rows = [
            TimingRow("转录收尾", timing.transcriptFinishMs),
            TimingRow("等截图压缩", timing.jpegEncodeMs, note: timing.imageBytes.map { Int64($0).formatted(.byteCount(style: .file)) }),
            TimingRow("等文字识别", timing.ocrWaitMs),
            TimingRow("大模型请求", timing.llmMs, note: requestNote),
            TimingRow("拿到摘要", timing.llmSummaryMs, note: "发出请求到摘要完整", isDetail: true),
        ]
        if let network {
            rows += [
                TimingRow("DNS", network.dnsMs, isDetail: true),
                TimingRow("建连", network.connectMs, isDetail: true),
                TimingRow("TLS", network.tlsMs, isDetail: true),
                TimingRow("上传", network.uploadMs, isDetail: true),
                TimingRow("模型处理（等首字节）", network.waitFirstByteMs, isDetail: true),
                TimingRow("下载", network.downloadMs, isDetail: true),
            ]
        }
        rows += [
            TimingRow("灵动岛更新", timing.activityUpdateMs),
            TimingRow("完整回答", timing.fullAnswerMs, note: timing.answerError.map { "失败：\($0)" } ?? "说完到完整回答写入"),
            TimingRow("合计", timing.answerTotalMs, note: timing.succeeded == false ? "失败" : "说完到灵动岛出摘要", isTotal: true),
        ]
        return rows
    }

    private var deepRows: [TimingRow] {
        guard timing.deepTotalMs != nil else { return [] }
        return [
            TimingRow("首个思考字", timing.deepFirstReasoningMs),
            TimingRow("首个正文字", timing.deepFirstContentMs),
            TimingRow("总耗时", timing.deepTotalMs, note: timing.deepSucceeded == false ? "失败" : nil, isTotal: true),
        ]
    }

    /// 说话音量 / 结束时音量，调提前请求的相对阈值用。
    private var levelText: String? {
        guard let speech = timing.speechLevelDB, let end = timing.endLevelDB else { return nil }
        return "说话 \(speech) dB，结束 \(end) dB"
    }

    private var stopTriggerText: String? {
        switch timing.stopTrigger {
        case .silence: return "静音自动结束"
        case .button: return "点了停止"
        case .maxDuration: return "到 60 秒上限"
        case nil: return nil
        }
    }

    private var requestNote: String? {
        var parts: [String] = []
        if let reused = timing.network?.reused {
            parts.append(reused ? "复用连接" : "新连接")
        }
        switch timing.speculation {
        case .hit:
            parts.append("提前请求命中" + (timing.speculationLeadMs.map { "（早 \(Self.format($0))）" } ?? ""))
        case .miss:
            if let distance = timing.missEditDistance,
               let speculativeChars = timing.missSpeculativeChars,
               let finalChars = timing.missFinalChars {
                let kind = timing.missIsExtension == true ? "后面补了话" : "差 \(distance) 字"
                parts.append("提前请求未命中（\(kind)，\(speculativeChars)→\(finalChars) 字）")
            } else {
                parts.append("提前请求未命中")
            }
        case nil:
            break
        }
        if let count = timing.speculativeRequests, count > 1 {
            parts.append("提前发了 \(count) 次")
        }
        if let attempts = timing.attempts, attempts > 1 {
            parts.append("重试 \(attempts - 1) 次")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func format(_ ms: Int) -> String {
        ms < 1000 ? "\(ms) 毫秒" : String(format: "%.1f 秒", Double(ms) / 1000)
    }
}

private struct TimingRow: Identifiable {
    let name: String
    let ms: Int?
    var note: String?
    var isDetail = false
    var isTotal = false

    var id: String { name }

    init(_ name: String, _ ms: Int?, note: String? = nil, isDetail: Bool = false, isTotal: Bool = false) {
        self.name = name
        self.ms = ms
        self.note = note
        self.isDetail = isDetail
        self.isTotal = isTotal
    }
}

private struct TimingGroup: View {

    let title: String
    let rows: [TimingRow]

    /// 横条比例的基准：组内最长的一项（有合计时就是合计）。
    private var scale: Int {
        max(rows.compactMap(\.ms).max() ?? 1, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(rows) { row in
                rowView(row)
            }
        }
    }

    private func rowView(_ row: TimingRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.name)
                    .font(row.isDetail ? .caption : .footnote.weight(row.isTotal ? .semibold : .regular))
                    .foregroundStyle(row.isDetail ? .secondary : .primary)
                if let note = row.note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(row.ms.map(TimingCard.format) ?? "—")
                    .font(.footnote.monospacedDigit().weight(row.isTotal ? .semibold : .regular))
                    .foregroundStyle(row.ms == nil ? .tertiary : .primary)
            }
            GeometryReader { proxy in
                Capsule()
                    .fill(row.isTotal ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(row.isDetail ? 0.35 : 0.6)))
                    .frame(width: proxy.size.width * CGFloat(row.ms ?? 0) / CGFloat(scale))
            }
            .frame(height: 4)
        }
        .padding(.leading, row.isDetail ? 14 : 0)
        .accessibilityElement(children: .combine)
    }
}
