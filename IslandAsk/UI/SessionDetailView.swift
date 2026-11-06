//
//  SessionDetailView.swift
//  IslandAsk
//
//  会话页（SPEC 第 6.12 节，UI 优化后）：整页是一条「和屏幕聊天」的时间线。
//  - 顶部截图卡：模糊截图做底、清晰截图叠在上面，点开看大图；下方玻璃按钮看 OCR 文字、播放原始录音。
//  - 右侧问题气泡（语音提问），接着是仿灵动岛的黑色摘要卡片（回答最早出现在灵动岛上）。
//  - 回答卡片：Markdown 正文 + 复制 / 分享 / 深度思考；深度思考中卡片边框有流光，思考过程可折叠。
//  - 追问接在时间线后面，底部是玻璃胶囊输入栏。
//  数据：追问沿用同一张截图和上下文，由 SessionCoordinator.askFollowUp 发送并写库；本页只读 @Query。
//  回答分两档：灵动岛用的快速回答先显示；needs_deep 不为 false 时打开本页自动用深度思考流式生成长回答，
//  流式中的内容来自 StreamingReplyStore，结束后落库。失败且有问题文字的会话显示「重新提问」（SPEC 第 8 节）。
//

import SwiftData
import SwiftUI
import UIKit
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
    category: "coordinator"
)

struct SessionDetailView: View {

    let sessionID: UUID

    @Query private var sessions: [AskSession]

    @State private var draft = ""
    @State private var isSending = false
    @State private var isRetrying = false
    @State private var followUpError: FollowUpError?
    @State private var fullScreenImage: ViewerImage?
    @State private var player = RecordingPlayer()
    @State private var didAutoStartDeepAnswer = false
    @State private var showsScreenText = false
    @FocusState private var inputFocused: Bool

    init(sessionID: UUID) {
        self.sessionID = sessionID
        _sessions = Query(filter: #Predicate<AskSession> { $0.id == sessionID })
    }

    var body: some View {
        Group {
            if let session = sessions.first {
                content(session)
            } else {
                ContentUnavailableView("找不到这条会话", systemImage: "questionmark.bubble")
            }
        }
        .background(Theme.Colors.pageBackground)
        .navigationTitle(sessions.first.map { $0.createdAt.formatted(date: .abbreviated, time: .shortened) } ?? "会话")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: sessionID) {
            player.load(sessionID: sessionID)
            logger.info("session detail opened session=\(sessionID.uuidString, privacy: .public)")
        }
        // 快速回答到达（含在本页重新提问成功）后，自动开始深度回答；每次进入本页最多自动触发一次。
        // 快速模型判断回答已够用（needsDeepAnswer == false）时不自动开始，只留「深度思考」按钮。
        .task(id: sessions.first?.status) {
            guard !didAutoStartDeepAnswer,
                  let session = sessions.first,
                  session.statusValue == .answered,
                  session.deepAnswer == nil,
                  session.needsDeepAnswer != false,
                  liveReply == nil else { return }
            didAutoStartDeepAnswer = true
            SessionCoordinator.shared.startDeepAnswer(sessionID: sessionID)
        }
        .onDisappear {
            player.stop()
        }
        .fullScreenCover(item: $fullScreenImage) { item in
            ScreenshotViewer(image: item.image)
        }
        .sheet(isPresented: $showsScreenText) {
            ScreenTextSheet(text: sessions.first?.ocrText ?? "")
        }
        .alert("追问失败", isPresented: $followUpError.isPresented, presenting: followUpError) { _ in
            Button("好", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
    }

    // MARK: - 内容

    private func content(_ session: AskSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                    screenshotSection(session)
                        .staggeredAppear(0)
                    QuestionBubble(text: session.transcript, date: session.createdAt, player: player)
                        .staggeredAppear(1)
                    if session.statusValue == .answered, let summary = session.summary, !summary.isEmpty {
                        IslandSummaryCard(summary: summary)
                            .staggeredAppear(2)
                    }
                    answerSection(session)
                        .staggeredAppear(3)
                    if AppSettings.showsTiming, let timing = session.timing {
                        TimingCard(timing: timing)
                    }
                    if AppSettings.showsTiming, !session.tokenUsages.isEmpty {
                        TokenUsageCard(
                            records: session.tokenUsages,
                            cancelledSpeculativeRequests: session.timing?.cancelledSpeculativeRequests ?? 0
                        )
                    }
                    followUpSection(session)
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(Theme.Spacing.page)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: session.messages.count) {
                withAnimation { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            }
            .onChange(of: isSending) {
                withAnimation { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            }
            .safeAreaInset(edge: .bottom) {
                if session.statusValue == .answered {
                    inputBar(session)
                }
            }
        }
    }

    private let bottomAnchor = "bottom"

    private var liveReply: StreamingReply? {
        StreamingReplyStore.shared.replies[sessionID]
    }

    @ViewBuilder
    private func screenshotSection(_ session: AskSession) -> some View {
        if let url = session.screenshotURL {
            ScreenshotHero(url: url, showsAccessories: session.ocrText?.isEmpty == false) {
                openScreenshot(url: url, sessionID: session.id)
            } accessories: {
                if session.ocrText?.isEmpty == false {
                    Button("识别到的文字", systemImage: "text.viewfinder") {
                        showsScreenText = true
                    }
                }
            }
        } else {
            Label("这次提问没有截图", systemImage: "photo.badge.exclamationmark")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.Colors.cardBackground, in: .rect(cornerRadius: Theme.Radius.card))
        }
    }

    @ViewBuilder
    private func answerSection(_ session: AskSession) -> some View {
        switch session.statusValue {
        case .listening:
            WaitingCard(status: .listening, text: "正在听你说…")
        case .thinking:
            WaitingCard(status: .thinking, text: "正在看截图、想答案…")
        case .answered:
            answeredCard(session)
        case .failed:
            failedCard(session)
        }
    }

    private func answeredCard(_ session: AskSession) -> some View {
        let deepLive = liveReply?.kind == .deepAnswer ? liveReply : nil
        let finalText = session.deepAnswer ?? session.answer ?? session.summary ?? ""
        let badge: String = if deepLive != nil || session.deepAnswer != nil { "深度回答" } else { "快速回答" }
        return AnswerCard(badge: badge, isThinking: deepLive != nil) {
            if let deepLive {
                LiveReplyView(reply: deepLive)
            } else if let deepAnswer = session.deepAnswer {
                if let reasoning = session.deepReasoning {
                    ReasoningDisclosure(reasoning: reasoning)
                }
                MarkdownText(markdown: deepAnswer)
            } else {
                MarkdownText(markdown: session.answer ?? session.summary ?? "")
                if let deepError = session.deepError {
                    Label("深度回答失败：\(deepError)", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        } actions: {
            if deepLive == nil {
                AnswerActions(text: finalText)
                if session.deepAnswer == nil {
                    Spacer(minLength: 0)
                    Button(session.deepError == nil ? "深度思考" : "重新生成", systemImage: "brain") {
                        SessionCoordinator.shared.startDeepAnswer(sessionID: session.id)
                    }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.glassProminent)
                    .tint(.indigo)
                }
            }
        }
    }

    private func failedCard(_ session: AskSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(session.errorMessage ?? "回答失败", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            if let detail = session.errorDetail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                if !session.transcript.isEmpty {
                    Button {
                        retry(session)
                    } label: {
                        if isRetrying {
                            ProgressView()
                        } else {
                            Label("重新提问", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(isRetrying)
                }
                failureActionButton(session.errorActionValue)
            }
            .controlSize(.large)
        }
        .cardStyle(tint: .orange)
    }

    @ViewBuilder
    private func followUpSection(_ session: AskSession) -> some View {
        let followUpReply = liveReply?.kind == .followUp ? liveReply : nil
        ForEach(session.sortedMessages) { message in
            MessageBubble(message: message)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        if let followUpReply {
            AnswerCard(badge: "追问", isThinking: true) {
                LiveReplyView(reply: followUpReply)
            } actions: {
                EmptyView()
            }
        }
    }

    private func inputBar(_ session: AskSession) -> some View {
        let isBusy = isSending || liveReply != nil
        let canSend = !isBusy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return GlassEffectContainer(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(isBusy ? "正在回答…" : "继续追问这张截图…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
                    .disabled(isBusy)
                Button {
                    send(session)
                } label: {
                    Label("发送追问", systemImage: isBusy ? "ellipsis" : "arrow.up")
                        .labelStyle(.iconOnly)
                        .bold()
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isBusy)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .disabled(!canSend)
                .sensoryFeedback(.impact(weight: .light), trigger: isSending) { _, new in new }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 失败卡片上的「去设置」：Key/地址类错误进 App 设置页，权限类错误进系统设置。
    @ViewBuilder
    private func failureActionButton(_ action: UserFacingFailure.Action?) -> some View {
        switch action {
        case .appSettings:
            NavigationLink(value: AppRoute.settings) {
                Label("去设置", systemImage: "gearshape")
            }
            .buttonStyle(.glass)
        case .systemSettings:
            if let url = PermissionManager.appSettingsURL {
                Link(destination: url) {
                    Label("去系统设置", systemImage: "gearshape")
                }
                .buttonStyle(.glass)
            }
        case nil:
            EmptyView()
        }
    }

    // MARK: - 动作

    private func send(_ session: AskSession) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        let id = session.id
        draft = ""
        isSending = true
        Task {
            defer { isSending = false }
            do {
                try await SessionCoordinator.shared.askFollowUp(sessionID: id, text: text)
            } catch {
                // 失败时 coordinator 已撤回这条 user 消息；把文字放回输入框方便重发。
                draft = text
                followUpError = FollowUpError(message: error.localizedDescription)
            }
        }
    }

    private func openScreenshot(url: URL, sessionID: UUID) {
        guard let image = UIImage(contentsOfFile: url.path) else {
            logger.error("screenshot open failed session=\(sessionID.uuidString, privacy: .public)")
            return
        }
        fullScreenImage = ViewerImage(image: image)
    }

    private func retry(_ session: AskSession) {
        guard !isRetrying else { return }
        let id = session.id
        isRetrying = true
        Task {
            await SessionCoordinator.shared.retryAnswer(sessionID: id)
            isRetrying = false
        }
    }
}

// MARK: - 弹窗数据

/// 全屏查看的截图：用 item 驱动 fullScreenCover，不用在 body 里手写 Binding。
private struct ViewerImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct FollowUpError {
    let message: String
}

private extension Optional where Wrapped == FollowUpError {
    /// alert 的 isPresented：关闭时清空错误。
    var isPresented: Bool {
        get { self != nil }
        set { if !newValue { self = nil } }
    }
}

// MARK: - 子视图

/// 右侧的问题气泡：带声波图标，表示这是语音问的。
/// 右侧的蓝色问题气泡。有录音时左边是播放键；播放中整个气泡先变淡，再由实色从左往右铺满，当作进度条。
private struct QuestionBubble: View {

    let text: String
    let date: Date
    let player: RecordingPlayer

    /// 已播放比例 0...1。开始播放时用一次线性动画从 0 走到 1（时长 = 录音时长），由 SwiftUI 插值，不逐帧重算 body。
    @State private var playedFraction: CGFloat = 0
    /// 播放键中心到文字基线的距离：让按钮和第一行中文的视觉中心对齐，随动态字号缩放。
    @ScaledMetric(relativeTo: .body) private var iconBaselineOffset: CGFloat = 6

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                leadingIcon
                Text(text.isEmpty ? "（没有识别到文字）" : text)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background {
                ZStack {
                    // 播放中底色变淡，作为进度条的「未播放」部分。
                    BubbleShape(isUser: true)
                        .fill(Color.accentColor.opacity(player.isPlaying ? 0.4 : 1))
                    if player.isPlaying {
                        Rectangle()
                            .fill(Color.accentColor.gradient)
                            // 缩放为 0 是奇异矩阵，留一点点。
                            .scaleEffect(x: max(playedFraction, 0.001), y: 1, anchor: .leading)
                            .clipShape(BubbleShape(isUser: true))
                    }
                }
                .animation(.easeOut(duration: 0.2), value: player.isPlaying)
            }
            .onChange(of: player.isPlaying) { _, playing in
                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) { playedFraction = 0 }
                guard playing, player.duration > 0 else { return }
                withAnimation(.linear(duration: player.duration)) { playedFraction = 1 }
            }
            Text("语音提问 · \(date.formatted(date: .omitted, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 40)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if player.hasRecording {
            let baselineOffset = iconBaselineOffset
            Button(action: player.toggle) {
                Image(systemName: player.isPlaying ? "stop.fill" : "play.fill")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(.white.opacity(0.22), in: .circle)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + baselineOffset }
            .accessibilityLabel(player.isPlaying ? "停止播放录音" : "播放原始录音")
        } else {
            Image(systemName: "waveform")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.8))
                .accessibilityHidden(true)
        }
    }
}

/// 仿灵动岛的黑色摘要卡片：呼应这条回答最早出现在灵动岛上。出现时轻微弹出。
private struct IslandSummaryCard: View {

    let summary: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPopped = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: isPopped)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("灵动岛摘要")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Text(summary)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.black, in: .rect(cornerRadius: Theme.Radius.island))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.island)
                .strokeBorder(.white.opacity(0.1))
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
        .scaleEffect(isPopped || reduceMotion ? 1 : 0.92)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(Theme.Motion.pop.delay(0.2)) {
                isPopped = true
            }
        }
    }
}

/// 左侧的回答卡片：头像行 + 正文 + 操作行；思考中边框流光。
private struct AnswerCard<Content: View, Actions: View>: View {

    let badge: String
    let isThinking: Bool
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    @ScaledMetric(relativeTo: .subheadline) private var avatarSide: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(width: avatarSide, height: avatarSide)
                    .background(Theme.Colors.brandGradient, in: .circle)
                    .accessibilityHidden(true)
                Text("IslandAsk")
                    .font(.subheadline.bold())
                Text(badge)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.fill.tertiary, in: .capsule)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content
            HStack(spacing: 8) {
                actions
            }
        }
        .cardStyle()
        .thinkingGlow(isThinking)
        .animation(.easeInOut(duration: 0.3), value: isThinking)
    }
}

/// 复制 / 分享。复制后图标短暂变成对勾，并有触感反馈。
private struct AnswerActions: View {

    let text: String

    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            Label(copied ? "已复制" : "复制回答", systemImage: copied ? "checkmark" : "doc.on.doc")
                .labelStyle(.iconOnly)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .sensoryFeedback(.success, trigger: copied) { _, new in new }

        ShareLink(item: text) {
            Label("分享回答", systemImage: "square.and.arrow.up")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
    }

    private func copy() {
        UIPasteboard.general.string = text
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

/// 录音中 / 思考中的占位卡片。
private struct WaitingCard: View {

    let status: AskSession.Status
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status.symbolName)
                .font(.title3)
                .foregroundStyle(status.tint)
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
        .thinkingGlow(status == .thinking)
        .accessibilityElement(children: .combine)
    }
}

/// 追问记录：用户的在右侧气泡，回答在左侧卡片。
private struct MessageBubble: View {

    let message: ChatMessage

    var body: some View {
        if message.isUser {
            Text(message.content)
                .textSelection(.enabled)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor.gradient, in: BubbleShape(isUser: true))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 40)
                .accessibilityLabel("追问：\(message.content)")
        } else {
            AnswerCard(badge: "追问", isThinking: false) {
                if let reasoning = message.reasoning {
                    ReasoningDisclosure(reasoning: reasoning)
                }
                MarkdownText(markdown: message.content)
            } actions: {
                AnswerActions(text: message.content)
            }
        }
    }
}

/// 气泡形状：大圆角，用户气泡右下角收小一点，像聊天 App。
nonisolated private struct BubbleShape: Shape {
    let isUser: Bool

    func path(in rect: CGRect) -> Path {
        let large: CGFloat = 20
        let small: CGFloat = 6
        return UnevenRoundedRectangle(
            topLeadingRadius: large,
            bottomLeadingRadius: isUser ? large : small,
            bottomTrailingRadius: isUser ? small : large,
            topTrailingRadius: large,
            style: .continuous
        )
        .path(in: rect)
    }
}

/// 正在流式生成的回答：还没有正文时展开思考过程并计时；正文开始后自动收起（用户手动展开过则保持）。
private struct LiveReplyView: View {

    let reply: StreamingReply

    @State private var userExpanded: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: Binding(
                get: { userExpanded ?? reply.content.isEmpty },
                set: { userExpanded = $0 }
            )) {
                Text(reasoningTail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            } label: {
                TimelineView(.periodic(from: reply.startedAt, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(reply.startedAt)))
                    Label {
                        Text(reply.content.isEmpty ? "深度思考中… \(seconds) 秒" : "正在回答… \(seconds) 秒")
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "brain")
                            .symbolEffect(.pulse, options: .repeating)
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                }
            }
            if !reply.content.isEmpty {
                MarkdownText(markdown: reply.content, isStreaming: true)
            }
        }
    }

    /// 流式中只显示思考过程的末尾：整段长文字每次追加都要全量重排，是滑动卡顿的来源之一。
    /// 完成后由 ReasoningDisclosure 显示全文。
    private var reasoningTail: String {
        let reasoning = reply.reasoning
        guard !reasoning.isEmpty else { return "等待模型开始思考…" }
        guard reasoning.count > Self.reasoningTailLength else { return reasoning }
        return "…" + reasoning.suffix(Self.reasoningTailLength)
    }

    private static let reasoningTailLength = 600
}

/// 已完成回答的思考过程，默认折叠。
private struct ReasoningDisclosure: View {

    let reasoning: String

    var body: some View {
        DisclosureGroup {
            Text(reasoning)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Label("思考过程", systemImage: "brain")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}

/// 顶部截图卡：模糊截图铺底，清晰截图居中叠放，下方一排玻璃按钮。
private struct ScreenshotHero<Accessories: View>: View {

    let url: URL
    /// 下面那排玻璃按钮没有内容时不显示，免得留一块空白。
    var showsAccessories = true
    let onOpen: () -> Void
    @ViewBuilder var accessories: Accessories

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    private let height: CGFloat = 300

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: height)
                        .blur(radius: 28)
                        .opacity(0.55)
                        .clipped()
                        .accessibilityHidden(true)
                    Button(action: onOpen) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: height - 32)
                            .clipShape(.rect(cornerRadius: Theme.Radius.inner))
                            .overlay {
                                RoundedRectangle(cornerRadius: Theme.Radius.inner)
                                    .strokeBorder(.white.opacity(0.15))
                            }
                            .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看截图大图")
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.35), in: .circle)
                            .padding(12)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Theme.Colors.cardBackground)
            .clipShape(.rect(cornerRadius: Theme.Radius.card))

            if showsAccessories {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        accessories
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.glass)
                }
            }
        }
        .task(id: url) {
            image = await HeroImageLoader.load(url: url, maxPixelSize: Int(height * displayScale))
        }
    }
}

/// 放在泛型视图外面：泛型参数的 View 一致性可能带隔离，不能传进 @concurrent 函数。
nonisolated private enum HeroImageLoader {
    @concurrent
    static func load(url: URL, maxPixelSize: Int) async -> UIImage? {
        ScreenshotStore.thumbnail(url: url, maxPixelSize: maxPixelSize)
    }
}

/// OCR 文字：可选中、可一键复制。
private struct ScreenTextSheet: View {

    let text: String

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .navigationTitle("识别到的文字")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(copied ? "已复制" : "复制全部文字", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = text
                        copied = true
                    }
                    .contentTransition(.symbolEffect(.replace))
                    .sensoryFeedback(.success, trigger: copied) { _, new in new }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
