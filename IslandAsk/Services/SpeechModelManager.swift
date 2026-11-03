//
//  SpeechModelManager.swift
//  IslandAsk
//
//  SpeechTranscriber 模型资产的状态检查与前台下载（SPEC 第 6.1 节第 3 步）。
//  识别语言来自设置页（AppSettings.recognitionLanguage）；设置页切换语言前，用 locale 参数先下载目标语言的模型。
//
//  约束：模型下载只能在 App 前台做，不能放进 Intent。Intent 链路（TranscriptionService）
//  只调用 status() 判断，未安装就回退 SFSpeechRecognizer，绝不在这里触发下载。
//

import Foundation
import Speech
import os

/// 引导页和列表页共用的模型状态（比 AssetInventory.Status 少一个 raw 概念，便于 UI 展示）。
nonisolated enum SpeechModelStatus: Sendable, Equatable {
    case installed
    case needsDownload
    case downloading
    case unsupported
}

enum SpeechModelManager {

    /// 非隔离函数里用局部 Logger（文件级 let 会被工程默认的 MainActor 隔离）。
    nonisolated private static func makeLogger() -> Logger {
        Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
            category: "transcription"
        )
    }

    /// 当前识别语言（SPEC 第 6.12 节：设置页可选）。每次会话开始时读取。
    nonisolated static var locale: Locale { AppSettings.recognitionLanguage.locale }

    /// 统一的转录器配置：volatileResults + fastResults（= Apple 的 progressiveTranscription 预设），
    /// 前者给实时临时结果，后者用更小 context window 降低首条结果的延迟（SPEC 第 6.6 节）。
    nonisolated static func makeTranscriber(locale: Locale = SpeechModelManager.locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
    }

    /// 检查模型状态。不触发下载，可在后台/Intent 链路调用。
    nonisolated static func status(locale: Locale = SpeechModelManager.locale) async -> SpeechModelStatus {
        let logger = makeLogger()
        guard await isSupportedLocale(locale) else {
            logger.notice("speech transcriber locale unsupported locale=\(locale.identifier, privacy: .public)")
            return .unsupported
        }

        let transcriber = makeTranscriber(locale: locale)
        let rawStatus = await AssetInventory.status(forModules: [transcriber])
        let mapped = map(rawStatus)
        logger.info(
            "speech model status=\(String(describing: mapped), privacy: .public) locale=\(locale.identifier, privacy: .public) raw=\(String(describing: rawStatus), privacy: .public)"
        )
        return mapped
    }

    nonisolated static func isSupportedLocale(_ locale: Locale = SpeechModelManager.locale) async -> Bool {
        await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil
    }

    /// 确保指定语言的模型已安装；仅允许在 App 前台调用（引导页、设置页）。
    /// - Returns: true = 已安装；false = 该 locale 不支持（调用方应使用回退引擎）。
    @MainActor
    @discardableResult
    static func ensureInstalled(
        locale: Locale = SpeechModelManager.locale,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> Bool {
        let logger = makeLogger()
        guard await isSupportedLocale(locale) else {
            logger.notice("speech model install skipped: locale unsupported")
            return false
        }

        let transcriber = makeTranscriber(locale: locale)
        let current = await status(locale: locale)
        switch current {
        case .installed:
            progress(1)
            return true
        case .unsupported:
            return false
        case .needsDownload, .downloading:
            break
        }

        logger.info("requesting speech model installation request locale=\(locale.identifier, privacy: .public)")
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            // 文档：当前状态是 .installed 时返回 nil，表示无需下载。
            let after = await status(locale: locale)
            logger.info("speech model installation request is nil status=\(String(describing: after), privacy: .public)")
            if after == .installed {
                progress(1)
                return true
            }
            // 极少数情况（系统正在后台下载等）拿不到 request：让 UI 走错误提示 + 重试，而不是静默卡住。
            throw SpeechModelError.installDidNotComplete
        }

        logger.info("speech model download started")
        // 下载期间轮询 Progress；进度回调固定跳回主线程，UI 不直接接触 Speech 框架对象。
        let progressTask = Task { @MainActor in
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { progressTask.cancel() }

        do {
            try await request.downloadAndInstall()
        } catch {
            logger.error("speech model download failed \(describe(error), privacy: .public)")
            throw error
        }

        progressTask.cancel()
        progress(1)

        let after = await status(locale: locale)
        guard after == .installed else {
            logger.error("speech model installed but status=\(String(describing: after), privacy: .public)")
            throw SpeechModelError.installDidNotComplete
        }
        logger.info("speech model installed locale=\(locale.identifier, privacy: .public)")
        return true
    }

    // MARK: - Helpers

    nonisolated private static func map(_ status: AssetInventory.Status) -> SpeechModelStatus {
        switch status {
        case .installed:
            return .installed
        case .supported:
            return .needsDownload
        case .downloading:
            return .downloading
        case .unsupported:
            return .unsupported
        @unknown default:
            return .unsupported
        }
    }

    nonisolated private static func describe(_ error: any Error) -> String {
        let nsError = error as NSError
        return "domain=\(nsError.domain) code=\(nsError.code) error=\(nsError.localizedDescription)"
    }
}

enum SpeechModelError: LocalizedError {
    case installDidNotComplete

    var errorDescription: String? {
        switch self {
        case .installDidNotComplete:
            return "语音模型安装未完成，请重试"
        }
    }
}
