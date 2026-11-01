//
//  AskLiveActivity.swift
//  IslandAskWidget
//
//  M0 最简 Live Activity：灵动岛显示「录音中」和计时，展开态底部有「停止」按钮。
//  数据结构和 StopAskIntent 来自 Shared/（同时属于主 App 和 widget 两个 target）。
//

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct AskLiveActivity: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AskActivityAttributes.self) { context in
            lockScreenView(context: context)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.red)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("录音中")
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    elapsedTime(for: context.state.startedAt)
                        .font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Button(intent: StopAskIntent(sessionID: context.attributes.sessionID)) {
                        Label("停止", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            } compactLeading: {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
            } compactTrailing: {
                elapsedTime(for: context.state.startedAt)
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    /// 系统自动刷新的计时文本，不需要每秒更新 ContentState。
    private func elapsedTime(for startedAt: Date) -> Text {
        Text(startedAt, style: .timer)
    }

    private func lockScreenView(context: ActivityViewContext<AskActivityAttributes>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("录音中")
                    .font(.headline)
                Text("正在录下你对屏幕的提问")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            elapsedTime(for: context.state.startedAt)
                .font(.title3.monospacedDigit())
        }
        .padding()
    }
}
