//
//  StreamingReply.swift
//  IslandAsk
//
//  深度回答 / 追问的流式状态。只在内存里，结束后由 SessionCoordinator 把最终文字写进 SwiftData。
//  片段先进缓冲，每 150ms 推一次给 UI，避免每个 token 都重新渲染 Markdown。
//

import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class StreamingReply {

    enum Kind: Equatable {
        case deepAnswer
        case followUp
    }

    let kind: Kind
    let startedAt = Date.now
    private(set) var reasoning = ""
    private(set) var content = ""

    /// 耗时记录（会话页耗时卡片）：第一个思考片段、第一个正文片段到达的时间。
    @ObservationIgnored let startedInstant = ContinuousClock.now
    @ObservationIgnored private(set) var firstReasoningAt: ContinuousClock.Instant?
    @ObservationIgnored private(set) var firstContentAt: ContinuousClock.Instant?
    /// 流结束前收到的 token 用量和发请求用的模型（会话页 Token 卡片）。
    @ObservationIgnored private(set) var usage: TokenUsage?
    @ObservationIgnored var model: String?

    @ObservationIgnored private var pendingReasoning = ""
    @ObservationIgnored private var pendingContent = ""
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    init(kind: Kind) {
        self.kind = kind
    }

    func append(_ event: LLMStreamEvent) {
        switch event {
        case .reasoning(let text):
            if firstReasoningAt == nil { firstReasoningAt = .now }
            pendingReasoning += text
        case .content(let text):
            if firstContentAt == nil { firstContentAt = .now }
            pendingContent += text
        case .usage(let usage):
            // 不进正文，也不需要刷新 UI。
            self.usage = usage
            return
        }
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            self?.flush()
        }
    }

    /// 把缓冲推给 UI；流结束时调用方要先 flush 再读 reasoning / content。
    func flush() {
        flushTask?.cancel()
        flushTask = nil
        if !pendingReasoning.isEmpty {
            reasoning += pendingReasoning
            pendingReasoning = ""
        }
        if !pendingContent.isEmpty {
            content += pendingContent
            pendingContent = ""
        }
    }
}

/// 正在进行的流，按会话 ID 索引（同一会话同时只有一个）。UI 直接观察这里。
@MainActor
@Observable
final class StreamingReplyStore {

    static let shared = StreamingReplyStore()

    private(set) var replies: [UUID: StreamingReply] = [:]

    private init() {}

    func begin(sessionID: UUID, kind: StreamingReply.Kind) -> StreamingReply {
        let reply = StreamingReply(kind: kind)
        replies[sessionID] = reply
        return reply
    }

    func end(sessionID: UUID) {
        replies[sessionID] = nil
    }
}

/// 后台任务包装：过期时先执行 onExpire（取消请求），再立即结束后台任务（不结束会被系统杀进程）。
@MainActor
final class BackgroundTaskToken {

    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String, onExpire: @escaping @MainActor @Sendable () -> Void) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                onExpire()
                self?.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
