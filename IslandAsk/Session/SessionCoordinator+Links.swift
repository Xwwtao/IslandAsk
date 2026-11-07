//
//  SessionCoordinator+Links.swift
//  IslandAsk
//
//  SessionCoordinator 的链接收藏部分（M-C2，SPEC 第 6.13 节）：
//  - saveSharedLink：SaveLinkIntent（快捷指令共享表单）调用。先建卡落库，再抓网页元数据、快速档整理、写回卡片。
//  - organizePendingShareCards：App 回到前台时补整理 pending 的分享卡片。
//  - organizeShareCard：单张分享卡片的整理，「重新整理」也走这里。
//  - importShareInbox：导入 Share Extension 写进 App Group 的 inbox（阶段 2）。
//  失败分两种（与 SPEC 6.13「失败保留 pending」的细化）：
//  - 网络类（断网、超时、5xx、429、被取消）→ 留在 pending，回前台自动补整理（网络失败不消耗 token）。
//  - 其他（没配 Key、地址错、4xx、格式错误、被截断）→ failed，在 App 里手动点「重新整理」，避免每次回前台白白重试。
//  抓网页元数据失败不算整理失败：只是少了标题或描述，照常整理。
//  仍是 SessionCoordinator 的方法，守住「只有 SessionCoordinator 写 SwiftData」的约定。
//

import Foundation
import Observation
import SwiftData
import UIKit
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
    category: "coordinator"
)

/// 正在整理的分享卡片 id。放在可观察的 store 里，界面据此区分「整理中」（请求进行中）和「待整理」。
/// SessionCoordinator 不是 @Observable，isCardBusy 读这里，Card.isBusy 也就能驱动界面刷新。
@MainActor
@Observable
final class LinkOrganizeStore {
    static let shared = LinkOrganizeStore()
    var organizingCardIDs: Set<UUID> = []
    private init() {}
}

/// saveSharedLink 的结果，SaveLinkIntent 据此返回 dialog。
enum SaveSharedLinkResult: Sendable {
    /// 链接和文字都为空，没建卡。
    case empty
    /// 建卡后保存失败（数据库不可用），没收藏上。
    case saveFailed
    /// 已收藏且整理完成。
    case organized(title: String)
    /// 已收藏，但整理没在时限内完成（或失败），回到 App 后再整理。
    case savedPending(title: String)
}

/// saveClipboardText 的结果，收藏库顶部的剪贴板提示条据此显示。
enum SaveClipboardResult: Sendable {
    case saved(cardID: UUID, title: String)
    /// 同一个链接已经有卡片了，不再新建。
    case duplicate(cardID: UUID, title: String)
    /// 粘贴出来的内容里找不到 http(s) 链接。
    case noLink
    case saveFailed
}

extension SessionCoordinator {

    /// Intent 链路的时间预算：抓元数据最多 5 秒（标题和描述两路并行），整个流程最多约 15 秒，大模型不重试。
    static let intentMetadataTimeout: Duration = .seconds(5)
    static let intentTotalTimeout: Duration = .seconds(15)
    /// 回前台补整理和手动重新整理：元数据最多 8 秒（SPEC 6.13），大模型可重试 1 次。
    static let foregroundMetadataTimeout: Duration = .seconds(8)

    // MARK: - 分享入口

    /// 快捷指令共享表单收藏链接（SaveLinkIntent）。
    /// url 不是 http(s) 时当作没有链接；url 为空时从 text 里找第一个链接。text 去掉链接本身后剩下的部分存为附注。
    /// 链接和文字都没有时不建卡。卡片一建好就落库，之后整理失败也不会丢。
    func saveSharedLink(url: URL?, text: String?) async -> SaveSharedLinkResult {
        let input = Self.resolveSharedInput(url: url, text: text)
        guard input.url != nil || input.note != nil else {
            logger.notice("share link ignored: empty input hasURL=\(url != nil, privacy: .public) textChars=\(text?.count ?? 0, privacy: .public)")
            return .empty
        }

        // 顺带导入分享扩展留下的 inbox（只建卡，不在 Intent 的时限里整理）。
        importShareInbox()

        let card = insertShareCard(id: UUID(), url: input.url, note: input.note, title: nil, createdAt: .now)
        guard AppDatabase.save(reason: "share card created card=\(card.id.uuidString)") else {
            logger.error("share card create failed: save error card=\(card.id.uuidString, privacy: .public)")
            AppDatabase.context.delete(card)
            return .saveFailed
        }
        let id = card.id
        logger.info(
            "share card created card=\(id.uuidString, privacy: .public) host=\(input.url?.host() ?? "nil", privacy: .public) noteChars=\(input.note?.count ?? 0, privacy: .public)"
        )

        // 整理在独立 Task 里跑：Intent 等到时限就先返回，请求继续在后台任务里跑完。
        let work = Task { @MainActor in
            await SessionCoordinator.shared.organizeShareCard(
                id: id,
                metadataTimeout: Self.intentMetadataTimeout,
                allowRetry: false
            )
        }
        let organized = await Self.waitForResult(of: work, timeout: Self.intentTotalTimeout)
        let title = AppDatabase.fetchCard(id: id)?.displayTitle ?? "未命名卡片"
        switch organized {
        case true?:
            return .organized(title: title)
        case false?:
            return .savedPending(title: title)
        case nil:
            logger.notice("share card organize exceeded intent budget, continuing in background card=\(id.uuidString, privacy: .public)")
            return .savedPending(title: title)
        }
    }

    // MARK: - 分享扩展 inbox（阶段 2）

    /// 导入分享扩展写进 App Group 的 inbox：逐条建卡，写库成功后再删对应文件（写库失败就留着，下次再导）。
    /// 只建卡、不整理；整理由 organizePendingShareCards 统一做（回前台时）。
    /// 调用时机：回到前台、SaveLinkIntent 运行时、AskAboutScreenIntent 开始录音之后。返回新建的卡片数。
    @discardableResult
    func importShareInbox() -> Int {
        let items = ShareInbox.readAll()
        guard !items.isEmpty else { return 0 }
        logger.info("import share inbox start count=\(items.count, privacy: .public)")
        var imported = 0
        for item in items {
            // 上次已建卡但删文件失败：只删文件，不重复建卡。
            if AppDatabase.fetchCard(id: item.id) != nil {
                logger.notice("import share inbox: card exists, removing file id=\(item.id.uuidString, privacy: .public)")
                ShareInbox.remove(id: item.id)
                continue
            }
            let input = Self.resolveSharedInput(url: item.url.flatMap(URL.init(string:)), text: item.text)
            let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard input.url != nil || input.note != nil || title?.isEmpty == false else {
                logger.notice("import share inbox: empty item dropped id=\(item.id.uuidString, privacy: .public)")
                ShareInbox.remove(id: item.id)
                continue
            }
            let card = insertShareCard(
                id: item.id,
                url: input.url,
                note: input.note,
                title: title?.isEmpty == false ? title : nil,
                createdAt: item.createdAt
            )
            guard AppDatabase.save(reason: "share inbox imported card=\(item.id.uuidString)") else {
                logger.error("import share inbox: save failed, keeping file id=\(item.id.uuidString, privacy: .public)")
                AppDatabase.context.delete(card)
                continue
            }
            ShareInbox.remove(id: item.id)
            imported += 1
            logger.info(
                "share inbox card created card=\(item.id.uuidString, privacy: .public) host=\(input.url?.host() ?? "nil", privacy: .public) noteChars=\(input.note?.count ?? 0, privacy: .public)"
            )
        }
        logger.info("import share inbox finished imported=\(imported, privacy: .public) total=\(items.count, privacy: .public)")
        return imported
    }

    /// 新建一张分享卡片并插入上下文（不保存，调用方负责保存）。
    /// title 是分享来源附带的标题，先记成 sourceTitle：没整理时列表显示它，整理时也作为网页标题的兜底。
    private func insertShareCard(id: UUID, url: URL?, note: String?, title: String?, createdAt: Date) -> Card {
        let card = Card(id: id, createdAt: createdAt, origin: .share, screenshotPath: nil)
        card.isSaved = true
        card.intent = LLMIntent.collect.rawValue
        card.note = note
        card.sourceTitle = title
        if let url {
            card.sourceURL = url.absoluteString
            card.sourceURLState = "shared"
        }
        AppDatabase.context.insert(card)
        return card
    }

    // MARK: - 剪贴板入口

    /// 收藏库顶部「剪贴板里有链接」提示条的「收藏」（PasteButton 粘贴出来的文字）。
    /// 剪贴板入口最容易重复（同一个链接复制多次），所以和分享入口不同：同一个链接已有卡片时不再新建，返回那张卡片。
    /// App 在前台，不受 Intent 的时限：建卡后立即返回，整理在后台跑（元数据 8 秒、可重试）。
    func saveClipboardText(_ text: String) async -> SaveClipboardResult {
        let input = Self.resolveSharedInput(url: nil, text: text)
        guard let link = input.url else {
            logger.notice("clipboard save ignored: no link chars=\(text.count, privacy: .public)")
            return .noLink
        }
        if let existing = findShareCard(sourceURL: link.absoluteString) {
            logger.info(
                "clipboard save duplicate card=\(existing.id.uuidString, privacy: .public) host=\(link.host() ?? "", privacy: .public)"
            )
            return .duplicate(cardID: existing.id, title: existing.displayTitle)
        }
        let card = insertShareCard(id: UUID(), url: link, note: input.note, title: nil, createdAt: .now)
        guard AppDatabase.save(reason: "clipboard card created card=\(card.id.uuidString)") else {
            logger.error("clipboard card create failed: save error card=\(card.id.uuidString, privacy: .public)")
            AppDatabase.context.delete(card)
            return .saveFailed
        }
        let id = card.id
        let title = card.displayTitle
        logger.info(
            "clipboard card created card=\(id.uuidString, privacy: .public) host=\(link.host() ?? "", privacy: .public) noteChars=\(input.note?.count ?? 0, privacy: .public)"
        )
        Task {
            await SessionCoordinator.shared.organizeShareCard(
                id: id,
                metadataTimeout: Self.foregroundMetadataTimeout,
                allowRetry: true
            )
        }
        return .saved(cardID: id, title: title)
    }

    /// 已有的同链接卡片（任何来源，按 sourceURL 完全相同判断）。
    private func findShareCard(sourceURL: String) -> Card? {
        var descriptor = FetchDescriptor<Card>(predicate: #Predicate { $0.sourceURL == sourceURL })
        descriptor.fetchLimit = 1
        do {
            return try AppDatabase.context.fetch(descriptor).first
        } catch {
            logger.error("find card by url failed error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 回到前台时补整理 pending 的分享卡片。不并发执行；遇到网络类失败就停（断网时后面的也会失败）。
    func organizePendingShareCards() async {
        guard !isOrganizingPendingShareCards else {
            logger.notice("organize pending share cards skipped: already running")
            return
        }
        isOrganizingPendingShareCards = true
        defer { isOrganizingPendingShareCards = false }

        let share = Card.Origin.share.rawValue
        let pending = Card.OrganizeStatus.pending.rawValue
        let descriptor = FetchDescriptor<Card>(
            predicate: #Predicate { $0.origin == share && $0.organizeStatus == pending },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        let ids: [UUID]
        do {
            ids = try AppDatabase.context.fetch(descriptor).map(\.id).filter { !isCardBusy(id: $0) }
        } catch {
            logger.error("organize pending share cards failed: fetch error=\(error.localizedDescription, privacy: .public)")
            return
        }
        guard !ids.isEmpty else { return }
        logger.info("organize pending share cards start count=\(ids.count, privacy: .public)")
        var organized = 0
        for id in ids {
            guard !isCardBusy(id: id) else { continue }
            let succeeded = await organizeShareCard(id: id, metadataTimeout: Self.foregroundMetadataTimeout, allowRetry: true)
            if succeeded {
                organized += 1
            } else if AppDatabase.fetchCard(id: id)?.organizeStatusValue == .pending {
                logger.notice("organize pending share cards stopped: deferrable failure card=\(id.uuidString, privacy: .public)")
                break
            }
        }
        logger.info("organize pending share cards finished organized=\(organized, privacy: .public) total=\(ids.count, privacy: .public)")
    }

    // MARK: - 单张整理

    /// 整理一张分享卡片：抓元数据 → 快速档 → 写回。返回是否整理成功。
    /// 正在整理的卡片 id 记在 LinkOrganizeStore 里，isCardBusy 会认出它：整理中不能删、不能编辑，也不会被重复整理。
    @discardableResult
    func organizeShareCard(id: UUID, metadataTimeout: Duration, allowRetry: Bool) async -> Bool {
        guard let card = AppDatabase.fetchCard(id: id), card.originValue == .share else {
            logger.error("organize share card failed: card not found or not share card=\(id.uuidString, privacy: .public)")
            return false
        }
        guard !isCardBusy(id: id) else {
            logger.notice("organize share card ignored: busy card=\(id.uuidString, privacy: .public)")
            return false
        }
        let store = LinkOrganizeStore.shared
        store.organizingCardIDs.insert(id)
        defer { store.organizingCardIDs.remove(id) }

        // 后台被挂起前尽量跑完；到期时什么都不做，请求失败会按网络类留在 pending。
        // TODO: 核对官方文档：App Intent 返回后进程还能运行多久、beginBackgroundTask 在 Intent 进程里能拿到多少时间，需真机验证。
        let backgroundToken = BackgroundTaskToken(name: "islandask.organizeLink") {
            logger.notice("organize share card background time expired card=\(id.uuidString, privacy: .public)")
        }
        defer { backgroundToken.end() }

        let link = card.sourceLink
        let sharedText = card.note
        let knownTitle = card.sourceTitle
        card.organizeStatus = Card.OrganizeStatus.pending.rawValue
        card.organizeError = nil
        AppDatabase.save(reason: "share card organizing card=\(id.uuidString)")
        let startedAt = clock.now
        logger.info(
            "organize share card start card=\(id.uuidString, privacy: .public) host=\(link?.host() ?? "nil", privacy: .public) allowRetry=\(allowRetry, privacy: .public)"
        )

        let metadata: LinkMetadata = if let link {
            await LinkMetadataFetcher.fetch(link, timeout: metadataTimeout)
        } else {
            .empty
        }
        // M-C2 补充：网站拦截读取（或什么都没抓到）时记下来，详情页提示改用按键截屏。
        if link != nil, let card = AppDatabase.fetchCard(id: id) {
            card.linkBlocked = metadata.blocked ? true : nil
        }

        // M-C2 补充：正文很少（摘录不到 500 字、描述不到 100 字）又有封面图时，先下载封面图交给模型识图，
        // 小红书这类内容主要在图里的笔记才有东西可写。Intent 链路最多等 4 秒，前台最多 8 秒；等不到就只用文字。
        var coverForModel: Data?
        if let imageURL = metadata.imageURL, Self.isTextThin(metadata) {
            let download = Task {
                await LinkImageStore.download(imageURL, kind: .cover, maxPixelSize: Self.modelCoverPixelSize)
            }
            coverForModel = await Self.waitForResult(of: download, timeout: allowRetry ? .seconds(8) : .seconds(4)) ?? nil
            logger.info(
                "organize share card thin text, cover for model card=\(id.uuidString, privacy: .public) bytes=\(coverForModel?.count ?? 0, privacy: .public)"
            )
        }
        // 封面图和网站图标与大模型请求并行保存，不拖慢整理（也不占 Intent 的时限）。已为模型下载过封面就复用。
        if link != nil {
            let prefetchedCover = coverForModel
            Task {
                await SessionCoordinator.shared.storeLinkImages(cardID: id, metadata: metadata, prefetchedCover: prefetchedCover)
            }
        }

        do {
            let provider = try OpenAICompatibleProvider.fromSettings()
            let answer = try await provider.organizeLink(
                url: link,
                pageTitle: metadata.title ?? knownTitle,
                pageDescription: metadata.description,
                pageExcerpt: metadata.excerpt,
                sharedText: sharedText,
                coverJPEG: coverForModel,
                allowRetry: allowRetry
            )
            guard let card = AppDatabase.fetchCard(id: id) else {
                logger.error("organize share card result dropped: card gone card=\(id.uuidString, privacy: .public)")
                return false
            }
            applyLinkAnswer(answer, metadata: metadata, to: card)
            AppDatabase.save(reason: "share card organized card=\(id.uuidString)")
            logger.info(
                "organize share card succeeded card=\(id.uuidString, privacy: .public) type=\(card.cardType ?? "nil", privacy: .public) tags=\(card.tags?.count ?? 0, privacy: .public) completionTokens=\(answer.usage?.completionTokens ?? -1, privacy: .public) promptTokens=\(answer.usage?.promptTokens ?? -1, privacy: .public) elapsedMs=\(Self.milliseconds(self.clock.now - startedAt), privacy: .public)"
            )
            return true
        } catch {
            let deferrable = Self.isDeferrableOrganizeError(error)
            if let card = AppDatabase.fetchCard(id: id) {
                card.organizeStatus = (deferrable ? Card.OrganizeStatus.pending : Card.OrganizeStatus.failed).rawValue
                card.organizeError = error.localizedDescription
                // 元数据抓到了标题，先记下来，列表里至少能显示网页标题。
                if card.sourceTitle == nil {
                    card.sourceTitle = metadata.title
                }
                AppDatabase.save(reason: "share card organize failed card=\(id.uuidString)")
            }
            logger.error(
                "organize share card failed card=\(id.uuidString, privacy: .public) deferrable=\(deferrable, privacy: .public) elapsedMs=\(Self.milliseconds(self.clock.now - startedAt), privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    /// 快速档结果写进分享卡片。附注保留分享时的原文，不用模型的 note；来源标题优先用抓到的网页标题。
    private func applyLinkAnswer(_ answer: LLMAnswer, metadata: LinkMetadata, to card: Card) {
        let fields = answer.card
        card.intent = LLMIntent.collect.rawValue
        card.organizeStatus = Card.OrganizeStatus.done.rawValue
        card.organizeError = nil
        card.title = fields?.title ?? metadata.title.map { String($0.prefix(Card.maxTitleLength)) }
            ?? String(answer.summary.prefix(Card.maxTitleLength))
        card.summary = answer.answer
        card.cardType = fields?.type ?? CardType.other.rawValue
        if let tags = fields?.tags, !tags.isEmpty {
            card.tags = tags
        }
        card.keyInfoData = fields?.keyInfo.flatMap { $0.isEmpty ? nil : try? JSONEncoder().encode($0) }
        card.translation = fields?.translation
        card.sourcePlatform = fields?.sourcePlatform
        card.sourceTitle = metadata.title ?? card.sourceTitle ?? fields?.sourceTitle
    }

    // MARK: - 封面图和网站图标（M-C2 补充）

    /// 下载并保存封面图、网站图标，写回卡片；取到没取到都记 linkImagesFetchedAt。已有的图片只在取到新图时替换。
    func storeLinkImages(cardID: UUID, metadata: LinkMetadata, prefetchedCover: Data? = nil) async {
        // 为模型下载过的封面（1280px）直接缩成存储尺寸，不再下载一次。
        let prefetched = prefetchedCover.flatMap { LinkImageStore.downsample($0, kind: .cover) }
        async let cover = prefetched != nil ? prefetched : Self.downloadImage(metadata.imageURL, kind: .cover)
        async let icon = Self.downloadImage(metadata.iconURL, kind: .icon)
        let (coverData, iconData) = await (cover, icon)
        guard let card = AppDatabase.fetchCard(id: cardID), !card.isGone else {
            logger.notice("link images dropped: card gone card=\(cardID.uuidString, privacy: .public)")
            return
        }
        for (data, kind) in [(coverData, LinkImageStore.Kind.cover), (iconData, .icon)] {
            guard let data else { continue }
            do {
                let path = try LinkImageStore.save(data, cardID: cardID, kind: kind)
                switch kind {
                case .cover: card.coverPath = path
                case .icon: card.iconPath = path
                }
            } catch {
                logger.error(
                    "link image save failed card=\(cardID.uuidString, privacy: .public) kind=\(kind.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
        card.linkImagesFetchedAt = .now
        AppDatabase.save(reason: "link images stored card=\(cardID.uuidString)")
        logger.info(
            "link images stored card=\(cardID.uuidString, privacy: .public) cover=\(coverData != nil, privacy: .public) icon=\(iconData != nil, privacy: .public)"
        )
    }

    /// 回到前台时为还没取过图片的链接卡片补取（升级前收藏的卡片）。每次最多 10 张，不并发执行；
    /// 待整理的卡片跳过，它们整理时会顺带取图。
    func backfillLinkImages() async {
        guard !isBackfillingLinkImages else { return }
        isBackfillingLinkImages = true
        defer { isBackfillingLinkImages = false }

        let share = Card.Origin.share.rawValue
        let done = Card.OrganizeStatus.done.rawValue
        var descriptor = FetchDescriptor<Card>(
            predicate: #Predicate {
                $0.origin == share && $0.organizeStatus == done && $0.linkImagesFetchedAt == nil && $0.sourceURL != nil
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 10
        let targets: [(UUID, URL)]
        do {
            targets = try AppDatabase.context.fetch(descriptor).compactMap { card in
                guard !isCardBusy(id: card.id), let link = card.sourceLink else { return nil }
                return (card.id, link)
            }
        } catch {
            logger.error("link images backfill failed: fetch error=\(error.localizedDescription, privacy: .public)")
            return
        }
        guard !targets.isEmpty else { return }
        logger.info("link images backfill start count=\(targets.count, privacy: .public)")
        for (id, link) in targets {
            let metadata = await LinkMetadataFetcher.fetch(link, timeout: Self.foregroundMetadataTimeout)
            await storeLinkImages(cardID: id, metadata: metadata)
        }
        logger.info("link images backfill finished count=\(targets.count, privacy: .public)")
    }

    /// 发给模型识图的封面尺寸：比存储用的 600px 大，图里的文字也看得清。
    static let modelCoverPixelSize = 1280

    /// 文字信息很少：正文摘录不到 500 字（小红书页面能提取出 300 多字，但全是评论和推荐，不是笔记内容），描述不到 100 字。
    nonisolated static func isTextThin(_ metadata: LinkMetadata) -> Bool {
        (metadata.excerpt?.count ?? 0) < thinExcerptLength && (metadata.description?.count ?? 0) < 100
    }

    nonisolated static let thinExcerptLength = 500

    private nonisolated static func downloadImage(_ url: URL?, kind: LinkImageStore.Kind) async -> Data? {
        guard let url else { return nil }
        return await LinkImageStore.download(url, kind: kind)
    }

    // MARK: - 工具

    /// 网络类失败：回前台自动重试。其他失败要用户处理（配 Key、改地址）或重试也没用，标 failed。
    nonisolated static func isDeferrableOrganizeError(_ error: any Error) -> Bool {
        guard let llmError = error as? LLMError else {
            return error is URLError
        }
        switch llmError {
        case .timeout, .offline, .network, .cancelled:
            return true
        case .http(let status):
            return status == 429 || (500..<600).contains(status)
        case .missingAPIKey, .invalidBaseURL, .emptyContent, .truncated, .badResponse:
            return false
        }
    }

    /// 解析分享输入：取 http(s) 链接，附注为文字去掉这个链接后剩下的部分（空则 nil）。
    /// 快捷指令把同一个输入同时传给「链接」和「附注」时，附注就是网址本身，去掉后为 nil。
    nonisolated static func resolveSharedInput(url: URL?, text: String?) -> (url: URL?, note: String?) {
        var link = url.flatMap { LinkMetadataFetcher.isFetchable($0) ? $0 : nil }
        var remaining = text ?? ""
        if link == nil, let found = LinkMetadataFetcher.firstLink(in: remaining) {
            link = found.url
            remaining.removeSubrange(found.range)
        } else if let link {
            for candidate in [link.absoluteString, url?.absoluteString].compactMap({ $0 }) {
                remaining = remaining.replacingOccurrences(of: candidate, with: "")
            }
        }
        // 非 http(s) 的 url（如 file://）不抓取，但也不丢：并进附注。
        if link == nil, let url, !LinkMetadataFetcher.isFetchable(url), !remaining.contains(url.absoluteString) {
            remaining = remaining.isEmpty ? url.absoluteString : "\(remaining)\n\(url.absoluteString)"
        }
        let note = cleanPromotionalText(remaining)
        return (link, note.isEmpty ? nil : note)
    }

    /// 去掉 App「复制链接」时附带的宣传语和口令，让附注和发给模型的文字只剩内容本身（目前覆盖小红书）。例：
    /// 「【周末去的咖啡店 - 小王 | 小红书 - 你的生活指南】 😆 AbCdEf123 😆 http://xhslink.com/a/x，复制本条信息，打开【小红书】App查看精彩内容！」
    /// → 「周末去的咖啡店 - 小王」（链接本身在调用前已去掉）。只匹配已知句式，认不出的文字原样保留。
    nonisolated static func cleanPromotionalText(_ text: String) -> String {
        var result = text
        let patterns = [
            // 「复制本条信息，打开【小红书】App查看精彩内容！」「复制后打开【小红书】查看笔记！」
            #"[，,。\s]*复制(本条信息|此条消息|后|这条信息)?[，,]?\s*打开【?小红书】?\s*(App|APP|app)?\s*查看[^！!。]*[！!。]?"#,
            // 标题里的「| 小红书 - 你的生活指南」「| 小红书 - 你的生活兴趣社区」
            #"\s*[|｜]\s*小红书\s*[-–—]\s*你的生活(指南|兴趣社区)"#,
            // 口令：两侧同一个表情包住的一串字母数字，如「😆 AbCdEf123 😆」
            #"(\p{So})\s*[A-Za-z0-9]{6,20}\s*\1"#,
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        result = result.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "，,。")))
        // 整段只剩一对【】包住的标题时去掉括号。
        if result.hasPrefix("【"), result.hasSuffix("】"), result.filter({ $0 == "【" }).count == 1 {
            result = String(result.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    /// 等 task 的结果，超时返回 nil；超时后 task 不取消，继续跑完。
    nonisolated static func waitForResult<T: Sendable>(of task: Task<T, Never>, timeout: Duration) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let resume: @Sendable (T?) -> Void = { value in
                let isFirst = resumed.withLock { done in
                    guard !done else { return false }
                    done = true
                    return true
                }
                if isFirst {
                    continuation.resume(returning: value)
                }
            }
            Task { resume(await task.value) }
            Task {
                try? await Task.sleep(for: timeout)
                resume(nil)
            }
        }
    }
}
