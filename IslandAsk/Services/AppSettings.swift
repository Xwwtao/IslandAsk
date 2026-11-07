//
//  AppSettings.swift
//  IslandAsk
//
//  设置页的持久化（SPEC 第 6.12 节）：API 地址、模型名、截图文字识别开关、识别语言、历史保留天数存 UserDefaults；
//  API Key 不在这里，存 Keychain（KeychainStore）。
//  各模块在每次会话开始时读一次快照，设置改完下一次提问生效。
//

import Foundation

nonisolated enum AppSettings {

    // MARK: - 识别语言

    enum RecognitionLanguage: String, CaseIterable, Identifiable, Sendable {
        case chinese = "zh_CN"
        case english = "en_US"

        var id: String { rawValue }

        var locale: Locale { Locale(identifier: rawValue) }

        var displayName: String {
            switch self {
            case .chinese: return "中文（普通话）"
            case .english: return "English (US)"
            }
        }
    }

    // MARK: - 默认值

    static let defaultBaseURL = "https://api.deepseek.com"
    static let defaultModel = "deepseek-flash"

    /// SPEC 第 6.7 节的阈值。设置页已不再提供调节，SilenceDetector 直接用这些常量；
    /// 以前存在 UserDefaults 里的 silence.* 值不再读取。
    enum SilenceDefaults {
        static let speechEndRMSDB: Double = -45
        static let endSilenceSeconds: Double = 1.5
        static let transcriptStableSeconds: Double = 1.5
        /// 没有截图（或关掉了「不说话就收藏」）时，一直不开口多久就取消。
        static let noSpeechTimeoutSeconds: Double = 6
        static let maxRecordingSeconds: Double = 60
        /// 转录稳定多久就提前发快速档请求（说完判定仍是 transcriptStableSeconds）。
        static let speculativeStableSeconds: Double = 0.8
        /// 提前发请求还要求音量相对安静这么久（避免说话中途误发），见 speculativeRelativeDropDB。
        static let speculativeQuietSeconds: Double = 0.5
        /// 提前发请求的「安静」：比说话时的平滑音量低这么多 dB。
        /// 真机：说话 -25～-29 dB、环境 -41～-44 dB，只差 15–18 dB；15 dB 时卡在边上常发不出来，改为 12 dB。
        static let speculativeRelativeDropDB: Double = 12
    }

    // MARK: - Keys

    enum Key {
        static let baseURL = "llm.baseURL"
        static let model = "llm.model"
        static let recognitionLanguage = "speech.recognitionLanguage"
        static let screenTextRecognition = "llm.screenTextRecognition"
        static let historyRetentionDays = "history.retentionDays"
        static let showsTiming = "debug.showsTiming"
        static let noSpeechCollects = "collect.noSpeechCollects"
        static let collectNoSpeechSeconds = "collect.noSpeechSeconds"
        static let lastHandledClipboardChangeCount = "clipboard.lastHandledChangeCount"
    }

    private static var defaults: UserDefaults { .standard }

    // MARK: - 大模型

    static var baseURLString: String {
        get { nonEmptyString(Key.baseURL) ?? defaultBaseURL }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.baseURL) }
    }

    static var model: String {
        get { nonEmptyString(Key.model) ?? defaultModel }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.model) }
    }

    /// M4：截图文字识别增强（Vision OCR 结果随截图一起发给大模型），默认开。
    static var screenTextRecognitionEnabled: Bool {
        get { defaults.object(forKey: Key.screenTextRecognition) == nil ? true : defaults.bool(forKey: Key.screenTextRecognition) }
        set { defaults.set(newValue, forKey: Key.screenTextRecognition) }
    }

    // MARK: - 收藏（M-C1）

    /// 有截图时不说话的行为：true = 收藏（默认），false = 取消。
    static var noSpeechCollects: Bool {
        get { defaults.object(forKey: Key.noSpeechCollects) == nil ? true : defaults.bool(forKey: Key.noSpeechCollects) }
        set { defaults.set(newValue, forKey: Key.noSpeechCollects) }
    }

    /// 设置页可选的「不说话判定时间」（秒）。
    static let collectNoSpeechOptions: [Double] = [2, 3, 5]
    static let defaultCollectNoSpeechSeconds: Double = 3

    /// 有截图且开启「不说话就收藏」时，多久没有转录文字就收藏。
    static var collectNoSpeechSeconds: Double {
        get {
            let value = defaults.double(forKey: Key.collectNoSpeechSeconds)
            return collectNoSpeechOptions.contains(value) ? value : defaultCollectNoSpeechSeconds
        }
        set { defaults.set(newValue, forKey: Key.collectNoSpeechSeconds) }
    }

    // MARK: - 剪贴板收藏（M-C2）

    /// 已经处理过（收藏、关闭、或是本 App 自己复制）的剪贴板 changeCount；剪贴板没变就不再提示。nil = 从没处理过。
    static var lastHandledClipboardChangeCount: Int? {
        get { defaults.object(forKey: Key.lastHandledClipboardChangeCount) as? Int }
        set { defaults.set(newValue, forKey: Key.lastHandledClipboardChangeCount) }
    }

    // MARK: - 历史记录

    /// 设置页可选的保留天数；0 = 永久保留（默认）。
    static let historyRetentionOptions = [0, 7, 30, 90]

    /// M4：超过这么多天的会话（连同截图、录音）在 App 回到前台时自动删除。
    /// M-C1：只清理未收藏的卡片，收藏的永不过期。
    static var historyRetentionDays: Int {
        get { defaults.integer(forKey: Key.historyRetentionDays) }
        set { defaults.set(newValue, forKey: Key.historyRetentionDays) }
    }

    // MARK: - 调试

    /// M4：会话页显示各环节耗时卡片，默认开。
    static var showsTiming: Bool {
        get { defaults.object(forKey: Key.showsTiming) == nil ? true : defaults.bool(forKey: Key.showsTiming) }
        set { defaults.set(newValue, forKey: Key.showsTiming) }
    }

    // MARK: - 识别语言

    static var recognitionLanguage: RecognitionLanguage {
        get {
            defaults.string(forKey: Key.recognitionLanguage).flatMap(RecognitionLanguage.init(rawValue:)) ?? .chinese
        }
        set { defaults.set(newValue.rawValue, forKey: Key.recognitionLanguage) }
    }

    // MARK: - Helpers

    private static func nonEmptyString(_ key: String) -> String? {
        guard let value = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
