//
//  ShortcutGuideView.swift
//  IslandAsk
//
//  快捷指令与 Action Button 设置指引（SPEC 第 6.12 节，M4 图文版）。引导页和设置页共用。
//  - 配了 iCloud 分享链接（ShortcutLink.iCloudURL）：两步。第 1 步「一键添加」，下面折叠着手动创建的子步骤（不编号）；
//    第 2 步设置操作按钮。没有链接时：第 1–3 步手动创建，第 4 步设置操作按钮。
//    （以前有链接时手动步骤折叠、第 4 步始终显示，页面一打开只看到孤零零的「4」。）
//  - 每一步配一张用 SwiftUI 画的示意图，不依赖截图素材，深浅色都能看。
//  - 把操作按钮设为这个快捷指令只能在系统设置里手动完成，所以这一步始终显示。
//

import SwiftUI
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
    category: "coordinator"
)

struct ShortcutGuideView: View {

    @State private var showsManualSteps = false
    @ScaledMetric(relativeTo: .footnote) private var stepBadgeSide: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let shareURL = ShortcutLink.iCloudURL {
                step("1", "添加「屏幕提问」快捷指令。") {
                    VStack(alignment: .leading, spacing: 10) {
                        Link(destination: shareURL) {
                            Label("一键添加", systemImage: "plus.square.on.square")
                                .bold()
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .simultaneousGesture(TapGesture().onEnded {
                            logger.info("shortcut guide: open iCloud share link")
                        })

                        DisclosureGroup("一键添加不可用？手动创建", isExpanded: $showsManualSteps) {
                            manualSteps(numbered: false)
                                .padding(.top, 10)
                        }
                        .font(.footnote)
                    }
                }
                actionButtonStep(index: "2")
            } else {
                manualSteps(numbered: true)
                actionButtonStep(index: "4")
            }
        }
    }

    private func actionButtonStep(index: String) -> some View {
        step(index, "进入 设置 → 操作按钮，滑到「快捷指令」，选择「屏幕提问」。") {
            ActionButtonSettingsMock()
        }
    }

    /// 手动创建的三步。作为一键添加的备选时不编号（用圆点），避免和主步骤的序号混在一起。
    private func manualSteps(numbered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            step(numbered ? "1" : nil, "打开快捷指令 App，点右上角「＋」新建快捷指令，命名为「屏幕提问」。") {
                NewShortcutMock()
            }
            step(numbered ? "2" : nil, "添加动作「截屏」。") {
                ShortcutEditorMock(showsAskAction: false)
            }
            step(numbered ? "3" : nil, "再添加动作「对屏幕提问」，把「截图」参数设为上一步的「截屏」。") {
                ShortcutEditorMock(showsAskAction: true)
            }
            if let shortcutsURL = ShortcutLink.shortcutsAppURL {
                Link(destination: shortcutsURL) {
                    Label("打开快捷指令 App", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .padding(.leading, stepBadgeSide + 10)
            }
        }
    }

    /// index 为 nil 时显示小圆点（子步骤）。
    private func step<Illustration: View>(
        _ index: String?,
        _ text: String,
        @ViewBuilder illustration: () -> Illustration
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Group {
                    if let index {
                        Text(index)
                            .font(.caption.bold())
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .frame(width: stepBadgeSide, height: stepBadgeSide)
                            .background(Color.accentColor.gradient, in: .circle)
                            .accessibilityLabel("第 \(index) 步")
                    } else {
                        Circle()
                            .fill(.secondary)
                            .frame(width: 6, height: 6)
                            .frame(width: stepBadgeSide)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                            .accessibilityHidden(true)
                    }
                }
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            illustration()
                .padding(.leading, stepBadgeSide + 10)
        }
    }
}

// MARK: - 示意图

/// 示意图的统一底板：像一块缩小的系统界面。
private struct MockPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.insetBackground, in: .rect(cornerRadius: Theme.Radius.inner))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.inner)
                .strokeBorder(.separator)
        }
        // 示意图只是装饰，旁白读步骤文字就够了。
        .accessibilityHidden(true)
    }
}

/// 第 1 步：新建快捷指令、填名字。
private struct NewShortcutMock: View {
    var body: some View {
        MockPanel {
            HStack {
                Text("快捷指令")
                    .font(.caption.bold())
                Spacer()
                Image(systemName: "plus")
                    .font(.caption.bold())
                    .foregroundStyle(.tint)
                    .padding(4)
                    .background(Color.accentColor.opacity(0.15), in: Circle())
            }
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.indigo.gradient)
                    .frame(width: 26, height: 26)
                    .overlay {
                        Image(systemName: "text.viewfinder").font(.caption).foregroundStyle(.white)
                    }
                Text("屏幕提问")
                    .font(.caption.weight(.semibold))
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 1.5, height: 14)
            }
        }
    }
}

/// 第 2、3 步：快捷指令编辑器里的动作卡片。
private struct ShortcutEditorMock: View {
    let showsAskAction: Bool

    var body: some View {
        MockPanel {
            actionRow(icon: "camera.viewfinder", tint: .blue) {
                Text("截屏")
                    .font(.caption.weight(.semibold))
            }
            if showsAskAction {
                Image(systemName: "arrow.down")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 9)
                actionRow(icon: "waveform.badge.mic", tint: .indigo) {
                    HStack(spacing: 4) {
                        Text("对屏幕提问")
                            .font(.caption.weight(.semibold))
                        Text("截图：")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Label("截屏", systemImage: "camera.viewfinder")
                            .font(.caption2.weight(.semibold))
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue, in: Capsule())
                    }
                }
            }
        }
    }

    private func actionRow<Title: View>(
        icon: String,
        tint: Color,
        @ViewBuilder title: () -> Title
    ) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 5)
                .fill(tint.gradient)
                .frame(width: 22, height: 22)
                .overlay {
                    Image(systemName: icon).font(.caption2.bold()).foregroundStyle(.white)
                }
            title()
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Theme.Colors.cardBackground, in: .rect(cornerRadius: 8))
    }
}

/// 第 4 步：设置 → 操作按钮 → 快捷指令 → 屏幕提问。
private struct ActionButtonSettingsMock: View {
    var body: some View {
        MockPanel {
            HStack(spacing: 4) {
                crumb("设置", icon: "gear")
                chevron
                crumb("操作按钮", icon: "button.vertical.right.press")
                chevron
                crumb("快捷指令", icon: "square.2.layers.3d")
            }
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.caption2.bold())
                    .foregroundStyle(.tint)
                Text("屏幕提问")
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Theme.Colors.cardBackground, in: .rect(cornerRadius: 8))
        }
    }

    private func crumb(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption2.weight(.medium))
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.bold())
            .imageScale(.small)
            .foregroundStyle(.secondary)
    }
}

#Preview {
    ScrollView {
        ShortcutGuideView()
            .padding()
    }
}
