//
//  DesignComponents.swift
//  IslandAsk
//
//  UI 共用组件：设置 App 风格的彩色图标、会话状态小标、深度思考的流光边框、依次淡入。
//  配色与灵动岛一致：红 = 录音，青 = 思考，绿 = 完成，橙 = 失败。
//

import SwiftUI

// MARK: - 设置 App 风格图标

/// 彩色圆角方块 + 白色 SF Symbol，尺寸与系统设置 App 的行图标一致。
/// 随 Dynamic Type 等比缩放，大字号下图标不会显得过小。
struct SettingsIcon: View {
    let systemName: String
    let color: Color

    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 29

    var body: some View {
        Image(systemName: systemName)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(color.gradient, in: .rect(cornerRadius: side * 0.24))
            .accessibilityHidden(true)
    }
}

/// Form 行标签：左侧 SettingsIcon，右侧文字。
struct SettingsLabel: View {
    let title: String
    let systemName: String
    let color: Color

    init(_ title: String, systemName: String, color: Color) {
        self.title = title
        self.systemName = systemName
        self.color = color
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            SettingsIcon(systemName: systemName, color: color)
        }
    }
}

// MARK: - 会话状态

extension AskSession.Status {
    var tint: Color {
        switch self {
        case .listening: return .red
        case .thinking: return .cyan
        case .answered: return .green
        case .failed: return .orange
        }
    }

    var symbolName: String {
        switch self {
        case .listening: return "waveform"
        case .thinking: return "sparkle.magnifyingglass"
        case .answered: return "sparkles"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var displayName: String {
        switch self {
        case .listening: return "正在听"
        case .thinking: return "思考中"
        case .answered: return "已回答"
        case .failed: return "未完成"
        }
    }
}

/// 列表里的状态小标：进行中显示图标动画，失败显示橙色，已回答不显示（避免满屏都是标）。
struct SessionStatusBadge: View {
    let status: AskSession.Status

    var body: some View {
        switch status {
        case .answered:
            EmptyView()
        case .listening, .thinking:
            Label(status.displayName, systemImage: status.symbolName)
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .modifier(BadgeStyle(tint: status.tint))
        case .failed:
            Label(status.displayName, systemImage: status.symbolName)
                .modifier(BadgeStyle(tint: status.tint))
        }
    }

    private struct BadgeStyle: ViewModifier {
        let tint: Color

        func body(content: Content) -> some View {
            content
                .font(.caption.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(tint.opacity(0.14), in: .capsule)
        }
    }
}

// MARK: - 流光边框（深度思考中）

/// 卡片边框上一圈缓慢旋转的渐变光，表示模型正在思考。系统开了「减弱动态效果」时不转，只显示静态渐变。
struct ThinkingGlow: ViewModifier {
    let isActive: Bool
    var cornerRadius: CGFloat = Theme.Radius.card

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            if isActive {
                TimelineView(.animation(paused: reduceMotion)) { timeline in
                    let angle = reduceMotion
                        ? 0
                        : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4 * 360
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(
                            AngularGradient(
                                colors: [.cyan, .blue, .purple, .pink, .orange, .cyan],
                                center: .center,
                                angle: .degrees(angle)
                            ),
                            lineWidth: 2
                        )
                        .blur(radius: 0.5)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
    }
}

// MARK: - 依次淡入

/// 进入页面时各块按顺序淡入上移；「减弱动态效果」时直接显示。
struct StaggeredAppear: ViewModifier {
    let index: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .opacity(isVisible || reduceMotion ? 1 : 0)
            .offset(y: isVisible || reduceMotion ? 0 : 12)
            .onAppear {
                guard !reduceMotion, !isVisible else { return }
                withAnimation(Theme.Motion.appear.delay(Double(index) * 0.07)) {
                    isVisible = true
                }
            }
    }
}

extension View {
    func thinkingGlow(_ isActive: Bool, cornerRadius: CGFloat = Theme.Radius.card) -> some View {
        modifier(ThinkingGlow(isActive: isActive, cornerRadius: cornerRadius))
    }

    func staggeredAppear(_ index: Int) -> some View {
        modifier(StaggeredAppear(index: index))
    }
}
