//
//  AskLiveActivity.swift
//  IslandAskWidget
//
//  灵动岛与锁屏布局（SPEC 第 6.10 节）：
//    - listening：展开态中间三行「最新」转录文字，停止按钮缩成 trailing 里的小圆按钮，
//      把整行让给文字；紧凑态右侧直接显示最近几个字，不展开也能看到进度。
//    - thinking：一行问题原文 + 「思考中…」，紧凑态/最小态显示加载动画。
//    - answered：摘要最多 3 行，trailing 放关闭按钮（DismissAskIntent）。
//    - failed：警告图标 + 错误说明 + 「再试一次」提示，同样带关闭按钮。
//
//  注意：灵动岛展开态由系统控制，几秒后会自动收回 compact，App 没有 API 强制保持展开；
//  因此这里把最新转录同步放到 compact trailing，用户不点开也能看到最新几个字。
//

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct AskLiveActivity: Widget {

    /// 展开态只显示最新的一小段：放不下时旧的直接滚掉，保证新文字始终可见。
    private static let visibleTailLength = 30
    /// compact trailing 面积极小，只放最近几个字。
    private static let compactTailLength = 6

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AskActivityAttributes.self) { context in
            lockScreenView(context: context)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    expandedLeading(context: context)
                }
                DynamicIslandExpandedRegion(.center) {
                    expandedCenter(context: context)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    expandedTrailing(context: context)
                }
            } compactLeading: {
                compactLeading(context: context)
            } compactTrailing: {
                compactTrailing(context: context)
            } minimal: {
                minimal(context: context)
            }
        }
    }

    // MARK: - 展开态

    private func expandedLeading(context: ActivityViewContext<AskActivityAttributes>) -> some View {
        // leading 区域太窄，只放图标：塞计时会显示不下变成省略号。
        phaseIcon(context.state.phase)
            .padding(.leading, 8)
    }

    @ViewBuilder
    private func expandedCenter(context: ActivityViewContext<AskActivityAttributes>) -> some View {
        switch context.state.phase {
        case .listening:
            Text(visibleTranscript(context))
                .font(.callout)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thinking:
            VStack(alignment: .leading, spacing: 2) {
                Text(questionLine(context))
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text("思考中…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .answered:
            Text(context.state.summary ?? "")
                .font(.callout)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .failed:
            VStack(alignment: .leading, spacing: 2) {
                Text(context.state.errorMessage ?? "没有听到")
                    .font(.headline)
                    .lineLimit(2)
                Text("按操作按钮再试一次")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func expandedTrailing(context: ActivityViewContext<AskActivityAttributes>) -> some View {
        switch context.state.phase {
        case .listening:
            Button(intent: StopAskIntent(sessionID: context.attributes.sessionID)) {
                circleButtonLabel(systemName: "stop.fill", tint: .red)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("停止")
            // 和灵动岛右边缘留出距离，避免圆角裁切。
            .padding(.trailing, 8)
        case .thinking:
            EmptyView()
        case .answered, .failed:
            Button(intent: DismissAskIntent(sessionID: context.attributes.sessionID)) {
                circleButtonLabel(systemName: "xmark", tint: Color.white.opacity(0.25))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
            .padding(.trailing, 8)
        }
    }

    // MARK: - 紧凑态 / 最小态

    private func compactLeading(context: ActivityViewContext<AskActivityAttributes>) -> some View {
        phaseIcon(context.state.phase)
    }

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
            // 跳动的麦克风。
            // TODO: 核对官方文档：确认最小态 Live Activity 是否支持 symbolEffect 动画；不支持就退化为静态图标。
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating)
        case .thinking:
            loadingIndicator
        case .answered:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    // MARK: - 锁屏（与展开态内容一致，空间更充足）

    private func lockScreenView(context: ActivityViewContext<AskActivityAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                phaseIcon(context.state.phase)
                Text(lockScreenTitle(context.state.phase))
                    .font(.headline)
                Spacer()
                switch context.state.phase {
                case .listening:
                    elapsedTime(for: context.state.startedAt)
                        .font(.title3.monospacedDigit())
                case .thinking:
                    loadingIndicator
                case .answered, .failed:
                    Button(intent: DismissAskIntent(sessionID: context.attributes.sessionID)) {
                        circleButtonLabel(systemName: "xmark", tint: Color.white.opacity(0.25))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")
                }
            }

            switch context.state.phase {
            case .listening:
                Text(visibleTranscript(context))
                    .font(.body)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(intent: StopAskIntent(sessionID: context.attributes.sessionID)) {
                    Label("停止", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            case .thinking:
                Text(questionLine(context))
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.secondary)
            case .answered:
                Text(context.state.summary ?? "")
                    .font(.body)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .failed:
                Text(context.state.errorMessage ?? "请再试一次")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    // MARK: - 组件

    @ViewBuilder
    private func phaseIcon(_ phase: AskActivityAttributes.ContentState.Phase) -> some View {
        switch phase {
        case .listening:
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
        case .thinking:
            // SPEC：截图缩略图标。
            Image(systemName: "photo")
                .foregroundStyle(.cyan)
        case .answered:
            // SPEC 写的是 App 图标；widget 里取不到 AppIcon 资源，先用 SF Symbol 代替（M4 再加图片资源）。
            Image(systemName: "sparkles")
                .foregroundStyle(.cyan)
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
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(tint, in: Circle())
    }

    private func lockScreenTitle(_ phase: AskActivityAttributes.ContentState.Phase) -> String {
        switch phase {
        case .listening: return "正在听"
        case .thinking: return "思考中…"
        case .answered: return "回答"
        case .failed: return "提问未完成"
        }
    }

    /// 只取最新的一小段，放不下时让旧文字先消失（用户要求的「新的优先」）。
    private func visibleTranscript(_ context: ActivityViewContext<AskActivityAttributes>) -> String {
        let tail = context.state.transcriptTail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return "正在听…" }
        guard tail.count > Self.visibleTailLength else { return tail }
        return "…" + String(tail.suffix(Self.visibleTailLength - 1))
    }

    /// thinking 的一行问题原文；放不下时由 truncationMode(.head) 截掉开头。
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
