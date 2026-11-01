//
//  AskLiveActivity.swift
//  IslandAskWidget
//
//  M1 的灵动岛与锁屏布局（SPEC 第 6.10 节，按真机反馈调整）：
//    - listening：展开态中间两行「最新」转录文字，停止按钮缩成 trailing 里的小图标，
//      把底部整行让给文字；紧凑态右侧直接显示最近几个字，不展开也能看到进度。
//    - failed：警告图标 + 错误说明（M1 用于「没听到」）；thinking / answered 的完整布局留到 M2。
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

    @ViewBuilder
    private func expandedLeading(context: ActivityViewContext<AskActivityAttributes>) -> some View {
        if context.state.phase == .failed {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .padding(.leading, 8)
        } else {
            // 只放麦克风：leading 区域太窄，塞计时会显示不下变成省略号。
            // 计时只保留在收起态的兜底显示和锁屏视图里。
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
                .padding(.leading, 8)
        }
    }

    @ViewBuilder
    private func expandedCenter(context: ActivityViewContext<AskActivityAttributes>) -> some View {
        if context.state.phase == .failed {
            VStack(alignment: .leading, spacing: 2) {
                Text(context.state.errorMessage ?? "没有听到")
                    .font(.headline)
                Text("请再说一次")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(visibleTranscript(context))
                .font(.callout)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func expandedTrailing(context: ActivityViewContext<AskActivityAttributes>) -> some View {
        if context.state.phase == .failed {
            EmptyView()
        } else {
            // 用固定尺寸的纯色圆形按钮：borderedProminent 的外描边/光晕会贴到灵动岛圆角上被裁掉。
            Button(intent: StopAskIntent(sessionID: context.attributes.sessionID)) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Color.red, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("停止")
            // 和灵动岛右边缘留出距离，避免圆角裁切。
            .padding(.trailing, 8)
        }
    }

    // MARK: - 紧凑态 / 最小态

    @ViewBuilder
    private func compactLeading(context: ActivityViewContext<AskActivityAttributes>) -> some View {
        if context.state.phase == .failed {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func compactTrailing(context: ActivityViewContext<AskActivityAttributes>) -> some View {
        if context.state.phase == .failed {
            Text("失败")
                .font(.caption2)
                .foregroundStyle(.orange)
        } else if let preview = compactTranscriptPreview(context) {
            Text(preview)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        } else {
            elapsedTime(for: context.state.startedAt)
                .font(.caption2.monospacedDigit())
        }
    }

    @ViewBuilder
    private func minimal(context: ActivityViewContext<AskActivityAttributes>) -> some View {
        if context.state.phase == .failed {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            // 跳动的麦克风。
            // TODO: 核对官方文档：确认最小态 Live Activity 是否支持 symbolEffect 动画；不支持就退化为静态图标。
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating)
        }
    }

    // MARK: - 锁屏（空间充足，保持完整内容）

    private func lockScreenView(context: ActivityViewContext<AskActivityAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: context.state.phase == .failed ? "exclamationmark.triangle.fill" : "mic.fill")
                    .foregroundStyle(context.state.phase == .failed ? .orange : .red)
                Text(context.state.phase == .failed ? "提问未完成" : "正在听")
                    .font(.headline)
                Spacer()
                if context.state.phase == .listening {
                    elapsedTime(for: context.state.startedAt)
                        .font(.title3.monospacedDigit())
                }
            }

            if context.state.phase == .failed {
                Text(context.state.errorMessage ?? "请再试一次")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text(visibleTranscript(context))
                    .font(.body)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                stopButton(sessionID: context.attributes.sessionID)
            }
        }
        .padding()
    }

    // MARK: - 组件

    /// 只取最新的一小段，放不下时让旧文字先消失（用户要求的「新的优先」）。
    private func visibleTranscript(_ context: ActivityViewContext<AskActivityAttributes>) -> String {
        let tail = context.state.transcriptTail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return "正在听…" }
        guard tail.count > Self.visibleTailLength else { return tail }
        return "…" + String(tail.suffix(Self.visibleTailLength - 1))
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

    private func stopButton(sessionID: String) -> some View {
        Button(intent: StopAskIntent(sessionID: sessionID)) {
            Label("停止", systemImage: "stop.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
    }
}
