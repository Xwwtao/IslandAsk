//
//  AskLiveActivity.swift
//  IslandAskWidget
//
//  灵动岛与锁屏布局（SPEC 第 6.10 节，UI 优化后）：
//    - 展开态顶部一行：leading 阶段图标，center 阶段标题（录音时带计时），trailing 停止 / 关闭按钮；
//      正文放在 bottom 区域，占满整个岛宽：
//      · listening：最新约 80 字转录，最多 4 行，旧文字从前面滚掉，最新几个字高亮。
//      · thinking：问题原文 2 行。
//      · answered：摘要最多 5 行（summary 上限 80 字）。
//      · failed：错误说明 + 下一步提示（errorHint，默认「再试一次」）。
//      · M-C1 收藏（kind = collect）：thinking 显示「整理中」；answered 显示「已收藏」+ 卡片标题一行 + 摘要最多 2 行，
//        按钮为「改为提问」（canSwitchToAsk 时）+ 关闭。提问的 answered 按钮为复制 + 收藏 + 关闭，合计不超过 3 个。
//    - 紧凑态右侧直接显示最近几个字，不展开也能看到进度。
//    - 配色统一：红 = 录音，青 = 思考，绿 = 完成，橙 = 失败；keylineTint 跟随阶段。
//
//  注意：灵动岛展开态由系统控制，几秒后会自动收回 compact，App 没有 API 强制保持展开；
//  展开态和锁屏视图高度上限约 160pt，正文行数按这个上限留余量。
//

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct AskLiveActivity: Widget {

    /// 展开态 / 锁屏的转录只显示最新一段：放不下时旧的直接滚掉，保证新文字始终可见。
    private static let visibleTailLength = 80
    /// 最新的这几个字用白色高亮，其余用次要色，让用户一眼看到「刚说的」。
    private static let highlightedTailLength = 8
    /// compact trailing 面积极小，只放最近几个字。
    private static let compactTailLength = 6

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AskActivityAttributes.self) { context in
            lockScreenView(context: context)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
                // 点击锁屏通知跳到对应会话页（SPEC 第 6.10 节）。
                .widgetURL(AskActivityAttributes.sessionURL(sessionID: context.attributes.sessionID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    stateIcon(context.state)
                        .font(.title3)
                        .padding(.leading, 8)
                }
                DynamicIslandExpandedRegion(.center) {
                    phaseTitle(context: context)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    trailingButton(context: context)
                        .padding(.trailing, 8)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    phaseBody(context: context, isLockScreen: false)
                        .padding(.horizontal, 8)
                        .padding(.top, 2)
                }
            } compactLeading: {
                stateIcon(context.state)
            } compactTrailing: {
                compactTrailing(context: context)
            } minimal: {
                minimal(context: context)
            }
            .keylineTint(phaseColor(context.state.phase))
            // TODO: 核对官方文档：确认 DynamicIsland 的 widgetURL 同时作用于紧凑态、最小态和展开态的点击。
            .widgetURL(AskActivityAttributes.sessionURL(sessionID: context.attributes.sessionID))
        }
    }

    // MARK: - 展开态 / 锁屏共用

    /// 顶部一行的标题；录音时附带计时（leading 太窄放不下计时，所以放在 center）。
    private func phaseTitle(context: ActivityViewContext<AskActivityAttributes>) -> some View {
        HStack(spacing: 6) {
            Text(title(for: context.state))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(phaseColor(context.state.phase))
            if context.state.phase == .listening {
                elapsedTime(for: context.state.startedAt)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private func trailingButton(context: ActivityViewContext<AskActivityAttributes>) -> some View {
        switch context.state.phase {
        case .listening:
            Button(intent: StopAskIntent(sessionID: context.attributes.sessionID)) {
                circleButtonLabel(systemName: "stop.fill", tint: .red)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("停止")
        case .thinking:
            loadingIndicator
        case .answered where context.state.isCollect:
            HStack(spacing: 8) {
                if context.state.canSwitchToAsk == true {
                    Button(intent: SwitchToAskIntent(sessionID: context.attributes.sessionID)) {
                        circleButtonLabel(systemName: "questionmark.bubble", tint: Color.white.opacity(0.25))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("改为提问")
                }
                dismissButton(context: context)
            }
        case .answered:
            HStack(spacing: 8) {
                let copied = context.state.answerCopied == true
                Button(intent: CopyAnswerIntent(sessionID: context.attributes.sessionID)) {
                    circleButtonLabel(
                        systemName: copied ? "checkmark" : "doc.on.doc",
                        tint: copied ? .green : Color.white.opacity(0.25)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "已复制" : "复制回答")
                saveButton(context: context)
                dismissButton(context: context)
            }
        case .failed:
            dismissButton(context: context)
        }
    }

    /// 提问回答后的「收藏」（SaveCardIntent）；已收藏后换成不可点的实心书签。
    @ViewBuilder
    private func saveButton(context: ActivityViewContext<AskActivityAttributes>) -> some View {
        if context.state.isSaved == true {
            circleButtonLabel(systemName: "bookmark.fill", tint: .green)
                .accessibilityLabel("已收藏")
        } else {
            Button(intent: SaveCardIntent(sessionID: context.attributes.sessionID)) {
                circleButtonLabel(systemName: "bookmark", tint: Color.white.opacity(0.25))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("收藏")
        }
    }

    private func dismissButton(context: ActivityViewContext<AskActivityAttributes>) -> some View {
        Button(intent: DismissAskIntent(sessionID: context.attributes.sessionID)) {
            circleButtonLabel(systemName: "xmark", tint: Color.white.opacity(0.25))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关闭")
    }

    /// 正文：灵动岛 bottom 区域和锁屏共用，宽度占满。
    @ViewBuilder
    private func phaseBody(context: ActivityViewContext<AskActivityAttributes>, isLockScreen: Bool) -> some View {
        switch context.state.phase {
        case .listening:
            Text(highlightedTranscript(context))
                .font(.callout)
                .lineLimit(4)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thinking where context.state.isCollect:
            Text("正在整理这张截图…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thinking:
            Text(questionLine(context))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .answered where context.state.isCollect:
            VStack(alignment: .leading, spacing: 3) {
                if let cardTitle = context.state.cardTitle, !cardTitle.isEmpty {
                    Text(cardTitle)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                }
                Text(context.state.summary ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .answered:
            Text(context.state.summary ?? "")
                .font(.callout)
                .lineLimit(isLockScreen ? 4 : 5)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .failed:
            VStack(alignment: .leading, spacing: 3) {
                Text(context.state.errorMessage ?? "没有听到")
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                Text(context.state.errorHint ?? "按操作按钮再试一次")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 紧凑态 / 最小态

    @ViewBuilder
    private func compactTrailing(context: ActivityViewContext<AskActivityAttributes>) -> some View {
        switch context.state.phase {
        case .listening:
            if let preview = compactTranscriptPreview(context) {
                Text(preview)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else {
                elapsedTime(for: context.state.startedAt)
                    .font(.caption2.monospacedDigit())
            }
        case .thinking:
            loadingIndicator
        case .answered:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Text("失败")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func minimal(context: ActivityViewContext<AskActivityAttributes>) -> some View {
        switch context.state.phase {
        case .listening:
            // 跳动的声波。
            // TODO: 核对官方文档：确认最小态 Live Activity 是否支持 symbolEffect 动画；不支持就退化为静态图标。
            phaseIcon(.listening)
        case .thinking:
            loadingIndicator
        case .answered where context.state.isCollect:
            Image(systemName: "bookmark.fill")
                .foregroundStyle(.green)
        case .answered:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            phaseIcon(.failed)
        }
    }

    // MARK: - 锁屏（与展开态内容一致）

    /// 锁屏视图同样有约 160pt 的高度上限：停止按钮放进标题行，把高度留给 4 行正文。
    private func lockScreenView(context: ActivityViewContext<AskActivityAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                stateIcon(context.state)
                    .font(.headline)
                phaseTitle(context: context)
                Spacer()
                trailingButton(context: context)
            }
            phaseBody(context: context, isLockScreen: true)
        }
        .padding()
    }

    // MARK: - 组件

    private func title(for state: AskActivityAttributes.ContentState) -> String {
        switch state.phase {
        case .listening: return "正在听"
        case .thinking: return state.isCollect ? "整理中" : "思考中"
        case .answered: return state.isCollect ? "已收藏" : "回答"
        case .failed: return state.isCollect ? "收藏未完成" : "提问未完成"
        }
    }

    /// 阶段图标；收藏完成时换成书签（M-C1）。
    @ViewBuilder
    private func stateIcon(_ state: AskActivityAttributes.ContentState) -> some View {
        if state.phase == .answered, state.isCollect {
            Image(systemName: "bookmark.fill")
                .foregroundStyle(.green)
        } else {
            phaseIcon(state.phase)
        }
    }

    private func phaseColor(_ phase: AskActivityAttributes.ContentState.Phase) -> Color {
        switch phase {
        case .listening: return .red
        case .thinking: return .cyan
        case .answered: return .green
        case .failed: return .orange
        }
    }

    @ViewBuilder
    private func phaseIcon(_ phase: AskActivityAttributes.ContentState.Phase) -> some View {
        switch phase {
        case .listening:
            Image(systemName: "waveform")
                .foregroundStyle(.red)
                .symbolEffect(.variableColor.iterative, options: .repeating)
        case .thinking:
            Image(systemName: "sparkle.magnifyingglass")
                .foregroundStyle(.cyan)
        case .answered:
            // SPEC 写的是 App 图标；widget 里取不到 AppIcon 资源，用 SF Symbol 代替。
            Image(systemName: "sparkles")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    /// 加载动画。ProgressView 在 Live Activity 里不会转，改用会动的 SF Symbol。
    /// TODO: 核对官方文档：确认紧凑态/最小态里 variableColor 的 symbolEffect 会持续播放。
    private var loadingIndicator: some View {
        Image(systemName: "ellipsis")
            .foregroundStyle(.cyan)
            .symbolEffect(.variableColor.iterative, options: .repeating)
    }

    /// 固定尺寸的纯色圆形按钮：borderedProminent 的外描边/光晕会贴到灵动岛圆角上被裁掉。
    private func circleButtonLabel(systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(tint, in: Circle())
    }

    /// 只取最新的一段（新的优先），最后几个字白色高亮，前面用次要色。
    private func highlightedTranscript(_ context: ActivityViewContext<AskActivityAttributes>) -> AttributedString {
        let tail = context.state.transcriptTail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else {
            var placeholder = AttributedString("请说出你的问题…")
            placeholder.foregroundColor = .white.opacity(0.5)
            return placeholder
        }
        let visible = tail.count > Self.visibleTailLength
            ? "…" + String(tail.suffix(Self.visibleTailLength - 1))
            : tail
        let newestCount = min(Self.highlightedTailLength, visible.count)
        var older = AttributedString(String(visible.dropLast(newestCount)))
        older.foregroundColor = .white.opacity(0.6)
        var newest = AttributedString(String(visible.suffix(newestCount)))
        newest.foregroundColor = .white
        return older + newest
    }

    /// thinking 的问题原文；放不下时由 truncationMode(.head) 截掉开头。
    private func questionLine(_ context: ActivityViewContext<AskActivityAttributes>) -> String {
        let question = context.state.transcriptTail.trimmingCharacters(in: .whitespacesAndNewlines)
        return question.isEmpty ? "正在提问" : question
    }

    /// compact trailing 空间很小，放最近几个字；没有文字时回退到计时。
    private func compactTranscriptPreview(_ context: ActivityViewContext<AskActivityAttributes>) -> String? {
        let tail = context.state.transcriptTail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return nil }
        return String(tail.suffix(Self.compactTailLength))
    }

    /// 系统自动刷新的计时文本，不需要每秒更新 ContentState。
    private func elapsedTime(for startedAt: Date) -> Text {
        Text(startedAt, style: .timer)
    }
}
