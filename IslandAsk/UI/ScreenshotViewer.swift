//
//  ScreenshotViewer.swift
//  IslandAsk
//
//  会话页的截图全屏查看（SPEC 第 6.12 节：截图可放大）：双指缩放、放大后拖动、双击切换放大/复位。
//  VoiceOver 下用「放大 / 缩小」自定义操作代替手势。
//

import SwiftUI
import UIKit

struct ScreenshotViewer: View {

    let image: UIImage

    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let maxScale: CGFloat = 5

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(magnifyGesture.simultaneously(with: dragGesture))
                // 需要双击次数，只能用 onTapGesture；无障碍改走下面的自定义操作。
                .onTapGesture(count: 2, perform: toggleZoom)
                .accessibilityLabel("截图")
                .accessibilityAddTraits(.isImage)
                .accessibilityHint("双指缩放查看细节")
                .accessibilityAction(named: "放大") { zoom(to: min(scale + 1, maxScale)) }
                .accessibilityAction(named: "缩小") { zoom(to: max(scale - 1, 1)) }

            Button("关闭", systemImage: "xmark") {
                dismiss()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .environment(\.colorScheme, .dark)
            .padding()
        }
        .statusBarHidden()
        .sensoryFeedback(.impact(weight: .light), trigger: scale > 1)
    }

    private func toggleZoom() {
        zoom(to: scale > 1 ? 1 : 2.5)
    }

    private func zoom(to target: CGFloat) {
        withAnimation(Theme.Motion.quick) {
            if target <= 1 {
                reset()
            } else {
                scale = target
                lastScale = target
            }
        }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(lastScale * value.magnification, 1), maxScale)
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1 {
                    withAnimation(Theme.Motion.quick) { reset() }
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }

    private func reset() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
    }
}
