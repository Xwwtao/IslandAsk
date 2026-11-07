//
//  ClipboardLinkDetector.swift
//  IslandAsk
//
//  剪贴板收藏入口（M-C2，SPEC 第 6.13 节）：小红书、微信不调起系统分享菜单，用户在它们的面板里点「复制链接」，
//  回到 IslandAsk 时收藏库顶部提示「剪贴板里有链接」，点系统的 PasteButton 收藏。
//  - 只用 detectPatterns 判断「可能有网址」，不读剪贴板内容：读内容会弹「是否允许粘贴」。
//    所以收藏之前提示条显示不了是哪个链接；PasteButton 由系统粘贴，也不弹框。
//  - 收藏、关闭过的剪贴板（按 changeCount 记）不再提示，剪贴板内容变了才会再出现。
//  - 本 App 自己复制（「复制摘要」「复制链接」）造成的变化直接记为已处理，不提示收藏自己的内容。
//  只是界面状态，不写 SwiftData；建卡经 SessionCoordinator.saveClipboardText。日志 category：link。
//

import Foundation
import Observation
import UIKit
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
    category: "link"
)

@MainActor
@Observable
final class ClipboardLinkDetector {

    static let shared = ClipboardLinkDetector()

    enum State: Equatable {
        case hidden
        /// 剪贴板里可能有网址，等用户点「收藏」。
        case available(changeCount: Int)
        case saving
        case saved(title: String)
        /// 这个链接已经收藏过：提示条可以点开那张卡片。
        case duplicate(cardID: UUID, title: String)
        /// 粘贴出来的内容里没有链接。
        case noLink
    }

    private(set) var state: State = .hidden

    /// 结果提示（已收藏 / 已收藏过 / 没有链接）显示多久后自动收起。
    private static let resultDisplayDuration: Duration = .seconds(2)
    private static let duplicateDisplayDuration: Duration = .seconds(4)

    private var dismissTask: Task<Void, Never>?
    private var changeObserver: NSObjectProtocol?

    private init() {
        // App 在前台时剪贴板变了，只可能是本 App 自己复制的：记为已处理。
        changeObserver = NotificationCenter.default.addObserver(
            forName: UIPasteboard.changedNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let count = UIPasteboard.general.changeCount
                AppSettings.lastHandledClipboardChangeCount = count
                logger.info("clipboard changed in app, marked handled changeCount=\(count, privacy: .public)")
                ClipboardLinkDetector.shared.hideIfAvailable()
            }
        }
    }

    // MARK: - 检测

    /// 回到前台、收藏库出现时调用。正在收藏或显示结果时不打断。
    func refresh() async {
        switch state {
        case .saving, .saved, .duplicate, .noLink:
            return
        case .hidden, .available:
            break
        }
        let pasteboard = UIPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != AppSettings.lastHandledClipboardChangeCount else {
            state = .hidden
            return
        }
        // hasStrings / hasURLs 不会触发粘贴提示；两者都没有就不用再检测。
        guard pasteboard.hasStrings || pasteboard.hasURLs else {
            state = .hidden
            return
        }
        let hasWebURL = await Self.detectProbableWebURL(in: pasteboard)
        // 检测期间剪贴板又变了：以最新的为准，下次再检测。
        guard changeCount == pasteboard.changeCount else { return }
        state = hasWebURL ? .available(changeCount: changeCount) : .hidden
        logger.info(
            "clipboard checked changeCount=\(changeCount, privacy: .public) probableWebURL=\(hasWebURL, privacy: .public)"
        )
    }

    /// iOS 15 起的 key path 版本（旧的 DetectionPattern 版本已弃用），签名已对照 SDK 的 UIKit.swiftinterface。
    // TODO: 核对官方文档：小红书复制的「标题 + 短链 + 宣传语」文字能否被识别为 probableWebURL，需真机确认
    // （识别不了时提示条不会出现）。
    private static func detectProbableWebURL(in pasteboard: UIPasteboard) async -> Bool {
        do {
            let patterns = try await pasteboard.detectedPatterns(for: [\UIPasteboard.DetectedValues.probableWebURL])
            return patterns.contains(\UIPasteboard.DetectedValues.probableWebURL)
        } catch {
            logger.notice("clipboard pattern detection failed error=\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - 动作

    /// 点「✕」：这次剪贴板内容不再提示。
    func dismiss() {
        if case .available(let changeCount) = state {
            AppSettings.lastHandledClipboardChangeCount = changeCount
            logger.info("clipboard banner dismissed changeCount=\(changeCount, privacy: .public)")
        }
        dismissTask?.cancel()
        state = .hidden
    }

    /// PasteButton 粘贴出来的内容。
    func handlePaste(_ strings: [String]) {
        guard case .available(let changeCount) = state else { return }
        AppSettings.lastHandledClipboardChangeCount = changeCount
        let text = strings
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        logger.info("clipboard paste received items=\(strings.count, privacy: .public) chars=\(text.count, privacy: .public)")
        state = .saving
        Task {
            let result = await SessionCoordinator.shared.saveClipboardText(text)
            switch result {
            case .saved(_, let title):
                show(.saved(title: title), for: Self.resultDisplayDuration)
            case .duplicate(let cardID, let title):
                show(.duplicate(cardID: cardID, title: title), for: Self.duplicateDisplayDuration)
            case .noLink:
                show(.noLink, for: Self.resultDisplayDuration)
            case .saveFailed:
                // 没存上：回到可收藏状态，让用户再点一次。
                AppSettings.lastHandledClipboardChangeCount = nil
                state = .available(changeCount: changeCount)
            }
        }
    }

    /// 打开「已收藏过」的那张卡片后收起提示条。
    func didOpenDuplicate() {
        dismissTask?.cancel()
        state = .hidden
    }

    private func show(_ newState: State, for duration: Duration) {
        state = newState
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            state = .hidden
        }
    }

    private func hideIfAvailable() {
        if case .available = state {
            state = .hidden
        }
    }
}
