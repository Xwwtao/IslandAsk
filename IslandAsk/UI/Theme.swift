//
//  Theme.swift
//  IslandAsk
//
//  全 App 共用的视觉常量：圆角、间距、背景色、动画。改这里就能统一调整各页面风格。
//  配色语义与灵动岛一致（见 DesignComponents 的 AskSession.Status.tint）。
//

import SwiftUI
import UIKit

enum Theme {

    enum Radius {
        /// 页面上的大卡片（回答卡、引导卡、截图卡）。
        static let card: CGFloat = 22
        /// 卡片内的小块（截图缩略图、代码块、示意图）。
        static let inner: CGFloat = 12
        /// 仿灵动岛的摘要卡片。
        static let island: CGFloat = 30
    }

    enum Spacing {
        /// 页面左右边距。
        static let page: CGFloat = 16
        /// 时间线 / 卡片之间的间距。
        static let section: CGFloat = 18
        /// 卡片内边距。
        static let cardPadding: CGFloat = 16
    }

    enum Colors {
        /// 页面底色：与 Form 的分组背景一致，卡片浮在上面。
        static let pageBackground = Color(uiColor: .systemGroupedBackground)
        /// 卡片底色。
        static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
        /// 卡片里再嵌一层（示意图、缩略图占位）。
        static let insetBackground = Color(uiColor: .tertiarySystemGroupedBackground)
        /// AI 回答的品牌渐变：头像、思考流光共用。
        static let brandGradient = LinearGradient(
            colors: [.cyan, .blue, .purple],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    enum Motion {
        static let appear = Animation.spring(duration: 0.5, bounce: 0.25)
        static let pop = Animation.spring(duration: 0.5, bounce: 0.45)
        static let quick = Animation.spring(duration: 0.3)
    }
}

// MARK: - 卡片

/// 统一卡片外观：内边距 + 卡片底色 + 连续圆角。tint 不为 nil 时用淡色底（失败、提示类卡片）。
struct CardStyle: ViewModifier {
    var tint: Color?

    func body(content: Content) -> some View {
        content
            .padding(Theme.Spacing.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if let tint {
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .fill(tint.opacity(0.1))
                } else {
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .fill(Theme.Colors.cardBackground)
                }
            }
    }
}

extension View {
    func cardStyle(tint: Color? = nil) -> some View {
        modifier(CardStyle(tint: tint))
    }
}
