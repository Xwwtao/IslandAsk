//
//  SessionCoordinator+Cards.swift
//  IslandAsk
//
//  SessionCoordinator 的卡片部分（M-C1，SPEC 第 4 节「分流与卡片」、6.4、6.11）：
//  - 快速档结果写进卡片（applyQuickAnswer）。
//  - 灵动岛按钮：收藏（SaveCardIntent）、改为提问（SwitchToAskIntent）。
//  - 收藏库与卡片详情：收藏 / 取消收藏、加标签、编辑、删除（单张和批量）、重新整理。
//  - 启动时为旧会话补建卡片。
//  仍是 SessionCoordinator 的方法，守住「只有 SessionCoordinator 写 SwiftData」的约定；批量操作只保存一次。
//

import ActivityKit
import Foundation
import SwiftData
import UIKit
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
    category: "coordinator"
)

private let activityLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
    category: "activity"
)

extension SessionCoordinator {

    // MARK: - 快速档结果 → 卡片

    /// 快速档成功（或降级为只有摘要）：写会话的回答字段，再按意图写卡片。卡片不存在时补建（同 id）。
    /// - ask：卡片 isSaved 不动（新卡片为 nil）。
    /// - collect：isSaved = true，卡片摘要取 answer（2–4 句内容摘要），不做深度回答。
    /// - both：同 ask，另外 isSaved = true。
    func applyQuickAnswer(_ answer: LLMAnswer, intent: LLMIntent, sessionID: UUID, reason: String) {
        guard let session = AppDatabase.fetchSession(id: sessionID) else {
            logger.error(
                "apply answer skipped: session not found session=\(sessionID.uuidString, privacy: .public) reason=\(reason, privacy: .public)"
            )
            return
        }
        session.summary = answer.summary
        session.answer = answer.answer
        session.needsDeepAnswer = intent == .collect ? false : (answer.needsDeep ?? true)
        session.clearFailure()
        session.statusValue = .answered

        let card = session.card ?? insertCard(for: session)
        let fields = answer.card
        card.intent = intent.rawValue
        card.organizeStatus = Card.OrganizeStatus.done.rawValue
        card.title = fields?.title ?? String(answer.summary.prefix(Card.maxTitleLength))
        card.summary = intent == .collect ? answer.answer : answer.summary
        if let fields {
            card.cardType = fields.type ?? CardType.other.rawValue
            if let tags = fields.tags, !tags.isEmpty {
                card.tags = tags
            }
            card.keyInfoData = fields.keyInfo.flatMap { $0.isEmpty ? nil : try? JSONEncoder().encode($0) }
            card.note = fields.note ?? card.note
            card.translation = fields.translation
            card.sourcePlatform = fields.sourcePlatform
            card.sourceTitle = fields.sourceTitle
        } else if card.cardType == nil {
            card.cardType = CardType.other.rawValue
        }
        if intent != .ask {
            card.isSaved = true
        }
        AppDatabase.save(reason: "\(reason) session=\(sessionID.uuidString)")
        logger.info(
            "card organized session=\(sessionID.uuidString, privacy: .public) intent=\(intent.rawValue, privacy: .public) type=\(card.cardType ?? "nil", privacy: .public) tags=\(card.tags?.count ?? 0, privacy: .public) hasFields=\(fields != nil, privacy: .public) saved=\(card.isSavedValue, privacy: .public)"
        )
    }

    /// 会话没有卡片时补一张（不保存，调用方负责保存）。
    @discardableResult
    private func insertCard(for session: AskSession) -> Card {
        let card = Card(id: session.id, createdAt: session.createdAt, origin: .press, screenshotPath: session.screenshotPath)
        AppDatabase.context.insert(card)
        card.session = session
        logger.notice("card inserted for session without card session=\(session.id.uuidString, privacy: .public)")
        return card
    }

    // MARK: - 灵动岛按钮

    /// 提问回答后的「收藏」按钮（SaveCardIntent）：卡片加入收藏，按钮变成不可点的「已收藏」。
    func saveCard(sessionID: String) async {
        guard let id = UUID(uuidString: sessionID), let card = AppDatabase.fetchCard(id: id) else {
            logger.error("save card failed: card not found session=\(sessionID, privacy: .public)")
            return
        }
        card.isSaved = true
        AppDatabase.save(reason: "card saved from island session=\(sessionID)")
        logger.info("card saved from island session=\(sessionID, privacy: .public)")
        await updateActivities(sessionID: sessionID, alert: nil) { state in
            guard state.phase == .answered else { return false }
            state.isSaved = true
            return true
        }
    }

    /// 收藏后的「改为提问」按钮（SwitchToAskIntent，SPEC 6.3）：用同一张截图和转录文字、强制 intent = ask 重跑快速档。
    /// 灵动岛 thinking → answered（kind = ask）；成功后卡片 isSaved 改回 nil。
    /// 这时音频会话已经停了，只能靠 beginBackgroundTask 保活；时间用完就转 failed，提示打开 App 查看。
    func switchToAsk(sessionID: String) async {
        guard let id = UUID(uuidString: sessionID), let session = AppDatabase.fetchSession(id: id) else {
            logger.error("switch to ask failed: session not found session=\(sessionID, privacy: .public)")
            return
        }
        guard !isCardBusy(id: id), currentSessionID == nil, answeringSessionID == nil else {
            logger.notice("switch to ask ignored: busy session=\(sessionID, privacy: .public)")
            return
        }
        guard let screenshotURL = session.screenshotURL else {
            logger.error("switch to ask failed: no screenshot session=\(sessionID, privacy: .public)")
            return
        }
        inAppRequestSessionIDs.insert(id)
        defer { inAppRequestSessionIDs.remove(id) }

        let question = session.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        session.statusValue = .thinking
        session.clearFailure()
        session.card?.intent = LLMIntent.ask.rawValue
        AppDatabase.save(reason: "switch to ask thinking session=\(sessionID)")
        logger.info(
            "switch to ask start session=\(sessionID, privacy: .public) chars=\(question.count, privacy: .public) backgroundTimeRemaining=\(UIApplication.shared.backgroundTimeRemaining, privacy: .public)"
        )
        await updateActivities(sessionID: sessionID, alert: nil) { state in
            state.phase = .thinking
            state.kind = .ask
            state.transcriptTail = String(question.suffix(Self.maxTranscriptTailLength))
            state.summary = nil
            state.cardTitle = nil
            state.isSaved = nil
            state.canSwitchToAsk = nil
            state.answerCopied = nil
            return true
        }

        let work = Task { () -> (LLMAnswer, String) in
            let imageJPEG = await Self.uploadJPEGIfPossible(url: screenshotURL, sessionID: id)
            let screenText = await SessionCoordinator.shared.screenTextForInAppRequest(sessionID: id)
            let provider = try OpenAICompatibleProvider.fromSettings()
            let answer = try await provider.ask(
                imageJPEG: imageJPEG,
                screenText: screenText,
                question: question,
                history: [],
                intentHint: .ask,
                onSummary: nil
            )
            return (answer, provider.model)
        }
        // TODO: 核对官方文档：LiveActivityIntent 唤起、没有音频会话时 beginBackgroundTask 能拿到多少时间，需真机验证。
        let backgroundToken = BackgroundTaskToken(name: "islandask.switchToAsk") { work.cancel() }
        defer { backgroundToken.end() }

        switch await work.result {
        case .success(let (answer, model)):
            applyQuickAnswer(answer, intent: .ask, sessionID: id, reason: "switch to ask answered")
            if let card = AppDatabase.fetchCard(id: id) {
                card.isSaved = nil
                AppDatabase.save(reason: "switch to ask unsaved session=\(sessionID)")
            }
            appendTokenUsage(sessionID: id, kind: .switchToAsk, usage: answer.usage, model: model)
            logger.info("switch to ask succeeded session=\(sessionID, privacy: .public)")
            await updateActivities(sessionID: sessionID, alert: alert(body: answer.summary)) { state in
                state.phase = .answered
                state.kind = .ask
                state.summary = answer.summary
                state.errorMessage = nil
                state.errorHint = nil
                state.isSaved = false
                return true
            }
        case .failure(let error):
            let base = UserFacingFailure.answerFailure(for: error)
            updateSession(id, reason: "switch to ask failed") { $0.markFailed(base) }
            logger.error(
                "switch to ask failed session=\(sessionID, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            await updateActivities(sessionID: sessionID, alert: alert(body: base.message)) { state in
                state.phase = .failed
                state.kind = .ask
                state.summary = nil
                state.errorMessage = base.message
                state.errorHint = UserFacingFailure.openAppHint
                return true
            }
        }
    }

    /// 按会话 id 更新它的所有 Live Activity（改为提问时它已不一定是 currentActivityID）。mutate 返回 false 表示这个不用更新。
    private func updateActivities(
        sessionID: String,
        alert: AlertConfiguration?,
        _ mutate: (inout AskActivityAttributes.ContentState) -> Bool
    ) async {
        let activityIDs = Self.activityIDs(sessionID: sessionID)
        guard !activityIDs.isEmpty else {
            activityLogger.notice("update skipped: no live activity for session=\(sessionID, privacy: .public)")
            return
        }
        for activityID in activityIDs {
            guard let activity = Self.findActivity(id: activityID) else { continue }
            var state = activity.content.state
            guard mutate(&state) else { continue }
            if activityID == currentActivityID {
                currentState = state
            }
            let content = ActivityContent(state: state, staleDate: nil)
            if let alert {
                await activity.update(content, alertConfiguration: alert)
            } else {
                await activity.update(content)
            }
            activityLogger.info(
                "live activity updated session=\(sessionID, privacy: .public) phase=\(state.phase.rawValue, privacy: .public) kind=\(state.kind?.rawValue ?? "nil", privacy: .public) saved=\(state.isSaved.map(String.init(describing:)) ?? "nil", privacy: .public)"
            )
        }
    }

    // MARK: - 收藏库 / 卡片详情

    func setSaved(cardID: UUID, _ saved: Bool) {
        setSaved(cardIDs: [cardID], saved)
    }

    /// 多选批量收藏 / 取消收藏。取消收藏写 nil（与「提问产生的卡片默认不进收藏」一致）。
    func setSaved(cardIDs: [UUID], _ saved: Bool) {
        let cards = AppDatabase.fetchCards(ids: Set(cardIDs))
        guard !cards.isEmpty else {
            logger.error("set saved failed: cards not found count=\(cardIDs.count, privacy: .public)")
            return
        }
        for card in cards {
            card.isSaved = saved ? true : nil
        }
        AppDatabase.save(reason: "cards \(saved ? "saved" : "unsaved") count=\(cards.count)")
        logger.info("cards set saved=\(saved, privacy: .public) count=\(cards.count, privacy: .public)")
    }

    /// 多选批量追加标签：不覆盖原有标签，已有的跳过。
    func addTag(_ tag: String, toCards ids: [UUID]) {
        let tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        let cards = AppDatabase.fetchCards(ids: Set(ids))
        guard !cards.isEmpty else {
            logger.error("add tag failed: cards not found count=\(ids.count, privacy: .public)")
            return
        }
        var changed = 0
        for card in cards {
            var tags = card.tags ?? []
            guard !tags.contains(tag) else { continue }
            tags.append(tag)
            card.tags = tags
            changed += 1
        }
        AppDatabase.save(reason: "tag added count=\(changed)")
        logger.info("tag added cards=\(cards.count, privacy: .public) changed=\(changed, privacy: .public)")
    }

    /// 详情页手动编辑标题和标签；传 nil 的字段不改。标题为空串时清掉（列表退回显示摘要）。
    func updateCard(id: UUID, title: String?, tags: [String]?) {
        guard let card = AppDatabase.fetchCard(id: id) else {
            logger.error("update card failed: not found card=\(id.uuidString, privacy: .public)")
            return
        }
        if let title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            card.title = trimmed.isEmpty ? nil : trimmed
        }
        if let tags {
            var seen = Set<String>()
            card.tags = tags
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        AppDatabase.save(reason: "card edited card=\(id.uuidString)")
        logger.info("card edited card=\(id.uuidString, privacy: .public) tags=\(card.tags?.count ?? 0, privacy: .public)")
    }

    func deleteCard(id: UUID) {
        deleteCards(ids: [id])
    }

    /// 删除卡片（级联删除会话和追问）以及截图、录音文件。进行中的跳过；没有卡片的旧会话直接删会话。只保存一次。
    func deleteCards(ids: [UUID]) {
        let requested = Set(ids)
        let busy = requested.filter { isCardBusy(id: $0) }
        let deletable = requested.subtracting(busy)
        if !busy.isEmpty {
            logger.notice("delete skipped in-progress cards count=\(busy.count, privacy: .public)")
        }
        guard !deletable.isEmpty else { return }

        var deleted: [UUID] = []
        let cards = AppDatabase.fetchCards(ids: deletable)
        for card in cards {
            AppDatabase.context.delete(card)
            deleted.append(card.id)
        }
        for id in deletable.subtracting(cards.map(\.id)) {
            guard let session = AppDatabase.fetchSession(id: id) else {
                logger.error("delete failed: card and session not found id=\(id.uuidString, privacy: .public)")
                continue
            }
            AppDatabase.context.delete(session)
            deleted.append(id)
        }
        guard !deleted.isEmpty else { return }
        AppDatabase.save(reason: "cards deleted count=\(deleted.count)")
        for id in deleted {
            ScreenshotStore.removeArtifacts(sessionID: id)
        }
        logger.info("cards deleted count=\(deleted.count, privacy: .public)")
    }

    // MARK: - 重新整理

    /// 整理失败（或快速档失败）的卡片在 App 内重跑快速档：同一张截图和转录文字，不更新灵动岛。
    /// 转录为空时：卡片意图已是 ask（点过「改为提问」）就按 ask，否则按 collect。
    func reorganizeCard(id: UUID) async {
        // M-C2：分享卡片没有会话，走链接整理。任何状态都可以手动重来（M-C2 补充：已整理的也可以，
        // 重新抓网页、重取图片，覆盖标题、摘要和标签；详情页先弹确认）。正在整理时由 organizeShareCard 拦下。
        if let card = AppDatabase.fetchCard(id: id), card.originValue == .share {
            logger.info(
                "reorganize share card card=\(id.uuidString, privacy: .public) status=\(card.organizeStatusValue.rawValue, privacy: .public)"
            )
            await organizeShareCard(id: id, metadataTimeout: Self.foregroundMetadataTimeout, allowRetry: true)
            return
        }
        guard let session = AppDatabase.fetchSession(id: id) else {
            logger.error("reorganize failed: session not found card=\(id.uuidString, privacy: .public)")
            return
        }
        let question = session.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let screenshotURL = session.screenshotURL
        guard question.isEmpty == false || screenshotURL != nil else {
            logger.notice("reorganize ignored: nothing to organize card=\(id.uuidString, privacy: .public)")
            return
        }
        guard session.statusValue == .failed || session.card?.organizeStatusValue == .failed,
              answeringSessionID != id, currentSessionID != id else {
            logger.notice(
                "reorganize ignored card=\(id.uuidString, privacy: .public) status=\(session.status, privacy: .public)"
            )
            return
        }
        guard inAppRequestSessionIDs.insert(id).inserted else {
            logger.notice("reorganize ignored: request in flight card=\(id.uuidString, privacy: .public)")
            return
        }
        defer { inAppRequestSessionIDs.remove(id) }

        let intentHint: LLMIntent? = question.isEmpty
            ? (session.card?.intent == LLMIntent.ask.rawValue ? .ask : .collect)
            : nil
        session.statusValue = .thinking
        session.clearFailure()
        session.card?.organizeStatus = Card.OrganizeStatus.pending.rawValue
        AppDatabase.save(reason: "reorganize thinking card=\(id.uuidString)")
        logger.info(
            "reorganize start card=\(id.uuidString, privacy: .public) intentHint=\(intentHint?.rawValue ?? "nil", privacy: .public)"
        )

        let backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "islandask.reorganize")
        defer {
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
            }
        }

        do {
            let imageJPEG = await Self.uploadJPEGIfPossible(url: screenshotURL, sessionID: id)
            let screenText = await screenTextForInAppRequest(sessionID: id)
            let provider = try OpenAICompatibleProvider.fromSettings()
            let answer = try await provider.ask(
                imageJPEG: imageJPEG,
                screenText: screenText,
                question: question,
                history: [],
                intentHint: intentHint,
                onSummary: nil
            )
            let intent = intentHint ?? answer.intent ?? .ask
            applyQuickAnswer(answer, intent: intent, sessionID: id, reason: "reorganize answered")
            appendTokenUsage(sessionID: id, kind: .retry, usage: answer.usage, model: provider.model)
            logger.info("reorganize succeeded card=\(id.uuidString, privacy: .public) intent=\(intent.rawValue, privacy: .public)")
        } catch {
            updateSession(id, reason: "reorganize failed") { $0.markFailed(.answerFailure(for: error)) }
            logger.error(
                "reorganize failed card=\(id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - 旧会话补建卡片

    /// App 回到前台时为没有卡片的旧会话补建卡片（SPEC 6.11）：origin = press，isSaved = nil，organizeStatus = done，
    /// title 取 summary（为空时取转录文字），截到 20 字。不为旧会话调大模型。进行中的会话跳过。
    /// 性能优化：全部补完后记下标记，之后回前台不再把所有会话读出来检查（新会话创建时就带卡片）。
    func backfillCardsForLegacySessionsIfNeeded() {
        guard !AppSettings.legacyCardBackfillDone else { return }
        let (done, ms) = PerformanceTrace.measure("maintenance.legacyBackfill") { backfillCardsForLegacySessions() }
        if done {
            AppSettings.legacyCardBackfillDone = true
        }
        logger.info("backfill check finished done=\(done, privacy: .public) elapsedMs=\(ms, privacy: .public)")
    }

    /// 返回旧会话是否已全部补完（有进行中被跳过的、或读写失败时返回 false，下次回前台再补）。
    @discardableResult
    func backfillCardsForLegacySessions() -> Bool {
        let sessions: [AskSession]
        do {
            // 关系为 nil 的谓词在 SwiftData 里支持情况不明，数据量小，取出来在内存里过滤。
            sessions = try AppDatabase.context.fetch(FetchDescriptor<AskSession>()).filter { $0.card == nil }
        } catch {
            logger.error("backfill failed: fetch error=\(error.localizedDescription, privacy: .public)")
            return false
        }
        let legacy = sessions.filter { !isCardBusy(id: $0.id) }
        let skippedBusy = sessions.count - legacy.count
        guard !legacy.isEmpty else { return skippedBusy == 0 }
        for session in legacy {
            let card = Card(id: session.id, createdAt: session.createdAt, origin: .press, screenshotPath: session.screenshotPath)
            AppDatabase.context.insert(card)
            card.session = session
            card.organizeStatus = Card.OrganizeStatus.done.rawValue
            card.intent = LLMIntent.ask.rawValue
            card.cardType = CardType.other.rawValue
            card.summary = session.summary
            let summary = session.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let transcript = session.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            let titleSource = summary.isEmpty ? transcript : summary
            card.title = titleSource.isEmpty ? nil : String(titleSource.prefix(Card.maxTitleLength))
        }
        let saved = AppDatabase.save(reason: "backfill cards count=\(legacy.count)")
        logger.info("backfill cards for legacy sessions count=\(legacy.count, privacy: .public) saved=\(saved, privacy: .public)")
        return saved && skippedBusy == 0
    }
}
