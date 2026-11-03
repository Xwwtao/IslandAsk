# 灵动岛截屏问答 App：工程实现规格

Nov 1, 2026 · @Wentao Xie

## 1. 项目概述与目标交互

用户在任意 App 里按下 Action Button，不离开当前界面，就能对着屏幕提问：灵动岛实时显示语音转文字，说完后灵动岛直接显示简要回答；想深入追问时，点击灵动岛进入 App 主页面。

目标交互（一次完整提问）：

1. 用户在任意 App 中按下 Action Button。
2. 系统截下当前屏幕（用户无感知）。
3. 灵动岛出现，显示「正在听」和实时转录文字。
4. 用户说完（静音自动结束，或点灵动岛上的停止按钮）。
5. 灵动岛显示「思考中」，后台把截图和问题发给多模态大模型。
6. 回答返回，灵动岛自动展开几秒，显示 30–40 字的简要回答。
7. 用户点击灵动岛 → 进入 App 的这条会话页，查看截图和回答，并可继续追问。问题较复杂时，会话页自动用深度思考流式生成更完整的长回答。

非目标（第一版不做）：锁屏状态下提问、实时连续共享屏幕、语音播报回答、Android 版本。

参照产品：Grok Bot 已实现「Action Button → 不跳转 → 灵动岛自定义样式语音会话」，证明后台启动录音与自定义 Live Activity 的组合在 App Store 上可行。本项目的差异点是灵动岛内的文字转录、按键瞬间截屏、文字摘要回答。

## 2. 关键技术约束与设计决策

整套方案由下面五条 iOS 限制决定，实现时不要绕开或改动这些决策。

| 约束 | 决策 | 原因 |
| --- | --- | --- |
| 第三方 App 无法截取其他 App 的屏幕 | 用快捷指令内置的「截屏」动作截图，再作为参数传给 App Intent | 快捷指令截屏无需用户确认；ReplayKit 广播需要每次弹窗确认，太重 |
| 后台启动录音受限 | 录音 Intent 遵循 `AudioRecordingIntent`，在主 App 进程内运行 | 这是 Apple 为「按键即录音」提供的官方协议；Grok Bot 已验证可行 |
| Intent 运行时无法弹出权限授权框 | 麦克风、语音识别权限必须在首次打开 App 时申请完毕 | 开发者论坛上的失败案例多卡在这里 |
| Live Activity 只能显示，不能输入 | 灵动岛只放转录、状态、摘要和按钮；追问在 App 内完成 | WidgetKit 视图不支持文本输入 |
| Live Activity 内容有大小上限，更新会被节流 | ContentState 控制在 4KB 内；转录约每秒更新一次，只显示末尾一两行 | 超限或更新过频会被系统丢弃 |

两个附加决策：

- **大模型分两档回答**：
  - 快速档：不开思考，只请求一次，返回 JSON。其中 summary 不超过 40 字，放进灵动岛；answer 是简短完整回答；needs_deep 由模型判断要不要再做深度回答。
  - 深度档：只在 App 前台的会话页和追问里使用，开思考，流式输出 Markdown 长回答。
  - 原因：开思考的请求单次要十几秒以上，后台约 30 秒的保活时间不够用；M3 真机测到过「思考用完 max_tokens → 内容为空 → 重试后超时被取消」。
- **录音结束后要保住进程**：音频会话停止后 App 可能很快被挂起，大模型请求必须包在 `beginBackgroundTask` 里，或者等回答返回后再停止音频会话。

## 3. 系统架构

工程分两个 target：主 App 进程负责全部逻辑，Widget 扩展只负责渲染灵动岛和锁屏视图。

&#91;embedded content: 系统架构 · 两个 target，一个调度中心\]

`AskAboutScreenIntent` 只是入口；`SessionCoordinator` 串起录音、转录、截图和大模型，并且是唯一更新 Live Activity 和数据库的地方。灵动岛上的停止按钮通过 `StopAskIntent` 回调到主 App 进程。

**文件结构**

```
IslandAsk/                           // 主 App target
├── App/
│   ├── IslandAskApp.swift           // 入口，处理 islandask:// 深链，回到前台时预热音频会话
│   ├── AppState.swift               // 导航路径、暂存的深链
│   └── AppShortcuts.swift           // AppShortcutsProvider
├── Config/
│   ├── AppGroup.swift               // App Group 标识与容器路径
│   └── Secrets.swift                // 已废弃（gitignore），Key 改存 Keychain
├── Intents/
│   └── AskAboutScreenIntent.swift   // 只属于主 App
├── Session/
│   ├── SessionCoordinator.swift
│   └── StreamingReply.swift         // 深度回答流式状态、后台任务封装
├── Services/
│   ├── PermissionManager.swift
│   ├── SpeechModelManager.swift     // 转录模型状态检查与前台下载
│   ├── AudioCaptureService.swift
│   ├── SilenceDetector.swift
│   ├── TranscriptionService.swift
│   ├── ScreenshotStore.swift
│   ├── LLMClient.swift
│   ├── AppSettings.swift            // 设置项（UserDefaults）
│   └── KeychainStore.swift          // API Key
├── Shared/                          // 两个 target 共享（在 pbxproj 里逐个文件登记）
│   ├── AskActivityAttributes.swift  // 含深链 URL 辅助函数
│   ├── StopAskIntent.swift
│   └── DismissAskIntent.swift
├── Data/
│   ├── Models.swift                 // AskSession, ChatMessage
│   └── AppDatabase.swift            // 共享 ModelContainer（App Group）
└── UI/
    ├── OnboardingView.swift
    ├── HistoryView.swift
    ├── SessionDetailView.swift
    ├── SettingsView.swift
    ├── MarkdownText.swift           // 轻量 Markdown 块级渲染
    └── ScreenshotViewer.swift       // 截图全屏缩放

IslandAskWidget/                     // Widget 扩展 target
├── IslandAskWidgetBundle.swift
└── AskLiveActivity.swift            // 灵动岛 + 锁屏视图
```

## 4. 端到端流程与状态机

一次会话经过 listening → thinking → answered 三个状态，任何一步出错都进入 failed。状态定义与 `AskActivityAttributes.ContentState.Phase` 一一对应。

&#91;embedded content: 会话状态机 · 4 个状态，2 个失败入口\]

**调用顺序（实现时严格按此顺序）**

1. Action Button 运行快捷指令「屏幕提问」。
2. 快捷指令执行「截屏」，得到图片。
3. 快捷指令调用 `AskAboutScreenIntent` 并传入截图，系统在主 App 进程中执行 `perform()`。
4. `ScreenshotStore` 把截图存到 App Group 容器的 `sessions/<id>.png`，返回文件 URL。
5. `SessionCoordinator.start` 依次执行：
   1. 结束上一个仍在显示的 Live Activity。
   2. 用 `Activity.request` 启动新的 Live Activity（phase = listening）。
   3. 配置并激活音频会话。
   4. 启动 `AVAudioEngine`，开始转录和静音检测。
   5. 写入 `AskSession`（status = listening）。
6. `perform()` 返回，快捷指令结束；App 依靠后台音频模式继续运行。
7. 转录结果每秒最多更新一次 Live Activity 的 `transcriptTail`。
8. 静音检测或 `StopAskIntent` 触发 `stopListening`：停止 engine，取最终转录文字，更新 phase = thinking。
9. 调用 `beginBackgroundTask`，`LLMClient` 用快速档发送压缩后的截图和转录文字。
10. 收到 JSON 后：保存 summary、answer、needs_deep → 带 `AlertConfiguration` 更新 phase = answered → 停用音频会话 → `endBackgroundTask`。
11. 用户点击灵动岛 → 打开 `islandask://session/<id>` → App 显示该会话页，并结束这个 Live Activity（会话还在录音或思考中时不结束）。
12. 会话页：needs_deep 不为 false 时，自动用深度档流式生成长回答，结果写入 `deepAnswer`；为 false 时只显示快速回答和一个「深度思考」按钮。

## 5. 工程配置

最低系统版本定为 iOS 26，以便直接使用 SpeechAnalyzer；设备需为带 Action Button 和灵动岛的 iPhone（15 Pro 及以后）。

**Targets**

| Target | 类型 | 职责 |
| --- | --- | --- |
| IslandAsk | iOS App | 主 App：Intent、录音、转录、大模型调用、数据存储、UI |
| IslandAskWidget | Widget Extension | Live Activity 的灵动岛与锁屏视图 |

**Capabilities（两个 target 按需开启）**

- Background Modes → Audio, AirPlay, and Picture in Picture（主 App）
- App Groups：`group.com.wentao.islandask`（两个 target 都开，用于共享截图、录音和 SwiftData 数据库）
- Push Notifications：第一版不需要，后续做服务端推送更新时再开

**主 App 的 Info.plist**

| Key | 值 |
| --- | --- |
| `NSMicrophoneUsageDescription` | 用于录下你对屏幕内容的提问 |
| `NSSpeechRecognitionUsageDescription` | 用于把你的语音实时转成文字 |
| `NSSupportsLiveActivities` | YES |
| `NSSupportsLiveActivitiesFrequentUpdates` | YES |
| `CFBundleURLTypes` | URL scheme `islandask`，用于灵动岛点击跳转 |

**共享文件**：`Shared/` 下的 `AskActivityAttributes.swift`、`StopAskIntent.swift`、`DismissAskIntent.swift` 必须同时加入两个 target 的 Target Membership（工程用文件夹同步，Shared 文件在 pbxproj 里逐个登记）。

**依赖**：只用系统框架（AppIntents、ActivityKit、WidgetKit、AVFoundation、Speech、SwiftData、Vision 可选），不引入第三方库。网络请求用 URLSession。

## 6. 模块详细设计

每个模块独立成文件，模块之间只通过 `SessionCoordinator` 交互。下面的 Swift 签名是约定接口，实现时以 Apple 官方文档为准核对 API 名称。

### 6.1 权限与首次引导（PermissionManager）

首次打开 App 时依次完成，全部完成前不允许使用：

1. 申请麦克风权限：`AVAudioApplication.requestRecordPermission`。
2. 申请语音识别权限：`SFSpeechRecognizer.requestAuthorization`。
3. 下载转录模型：用 `AssetInventory` 检查 zh-CN 的 SpeechTranscriber 资源，未安装则在前台下载并显示进度。
4. 检查 Live Activity 是否被用户关闭：`ActivityAuthorizationInfo().areActivitiesEnabled`。
5. 显示快捷指令和 Action Button 的设置图文指引（见 6.12）。

### 6.2 提问 Intent（AskAboutScreenIntent）

```swift
struct AskAboutScreenIntent: AppIntent, AudioRecordingIntent {
    static var title: LocalizedStringResource = "对屏幕提问"
    static var openAppWhenRun = false

    @Parameter(title: "截图", supportedContentTypes: [.image])
    var screenshot: IntentFile?

    @MainActor
    func perform() async throws -> some IntentResult {
        let id = UUID()
        let imageURL = try ScreenshotStore.save(screenshot, sessionID: id)
        try await SessionCoordinator.shared.start(sessionID: id, screenshotURL: imageURL)
        return .result()   // 录音开始后立即返回，录音在后台继续
    }
}
```

要求：

- 文件只属于主 App target，保证 `perform()` 在主 App 进程运行。
- `perform()` 内先启动 Live Activity，再激活音频会话（顺序见第 4 节）。
- 截图参数为空时（例如用户没配快捷指令、直接调用）照常录音，只是不带图。
- 用 `AppShortcutsProvider` 注册这个 Intent，使它出现在快捷指令 App 的动作列表里。

### 6.3 灵动岛按钮 Intent（StopAskIntent / DismissAskIntent）

```swift
struct StopAskIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "结束提问"
    @Parameter(title: "会话") var sessionID: String
    func perform() async throws -> some IntentResult {
        await SessionCoordinator.shared.stopListening(sessionID: sessionID)
        return .result()
    }
}
```

- 文件同时属于两个 target（widget 需要引用它来渲染按钮），`perform()` 由系统在主 App 进程执行。
- `DismissAskIntent` 结构相同，作用是立即结束 Live Activity（回答阶段右上角的关闭按钮）。

### 6.4 会话调度器（SessionCoordinator）

`@MainActor` 单例，持有当前会话状态，是唯一能修改 Live Activity 和数据库的地方。

```swift
@MainActor final class SessionCoordinator {
    static let shared = SessionCoordinator()
    func start(sessionID: UUID, screenshotURL: URL?) async throws
    func stopListening(sessionID: String) async   // 用户点停止或静音检测触发
    func cancel(sessionID: String) async          // 没说话、出错

    // App 前台（会话页）使用，不更新灵动岛
    func startDeepAnswer(sessionID: UUID)                      // 深度档流式长回答
    func askFollowUp(sessionID: UUID, text: String) async throws
    func retryAnswer(sessionID: UUID) async                    // 快速档失败后重问
    func openedSession(id: UUID) async                         // 深链进入，结束对应 Live Activity
    func deleteSession(id: UUID)
}
```

- 同一时间只允许一个会话；新会话开始时结束上一个仍在显示的 Live Activity。
- 状态机见第 4 节，任何状态转换都要同步写入数据库并更新 Live Activity。

### 6.5 录音（AudioCaptureService）

- 音频会话：category `.record`，mode `.default`，`setActive(true)`。
- 用 `AVAudioEngine` 的 `inputNode.installTap(bufferSize: 1024)` 采集，把 buffer 同时分发给转录服务和静音检测器。
- 监听 `AVAudioSession.interruptionNotification`（来电、Siri），中断时把会话转为 failed 并提示。
- 停止顺序：移除 tap → 停止 engine → 等大模型回答返回后再 `setActive(false)`。

### 6.6 转录（TranscriptionService）

- 首选 iOS 26 的 `SpeechAnalyzer` + `SpeechTranscriber`，locale 为 zh-CN，开启 volatile results 以获得实时的临时结果。
- 用 `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` 获取目标格式，用 `AVAudioConverter` 转换 tap 出来的 buffer，再写入 `AsyncStream<AnalyzerInput>`。
- 对外输出：`AsyncStream<TranscriptUpdate>`，其中 `TranscriptUpdate { finalizedText, volatileText }`，显示文本 = finalized + volatile。
- 回退：若 SpeechTranscriber 不支持当前 locale 或模型未安装，改用 `SFSpeechRecognizer(locale: zh-CN)`，`requiresOnDeviceRecognition = true`。

### 6.7 静音检测（SilenceDetector）

以转录文字为主、音量为辅。只看音量时，环境噪音持续高于阈值会让「说完」永远不成立、「没听到」也不触发（M1/M2 真机已复现）；语音识别会过滤掉非人声，所以用转录判断是否在说话。

| 规则 | 默认值 | 行为 |
| --- | --- | --- |
| 开始说话的判定 | 转录出现第一个字 | 标记已开口 |
| 说完的判定 | 已开口后满足任一条件：转录文字（已确定 + 临时）连续 1.5 秒没变化；或音量 RMS 连续 1.5 秒低于 -45 dB | 触发 `stopListening` |
| 一直不说话 | 6 秒内没有任何转录文字 | 触发 `cancel`，灵动岛提示「没听到」 |
| 最长录音 | 60 秒 | 强制 `stopListening` |

- 音量条件是安静环境下的快速结束路径；吵的环境靠「文字不再变化」结束，会比安静时晚约 0.5–1 秒（转录延迟）。
- 临时结果转成已确定结果、文字内容不变时，不算变化。

阈值放进设置页，方便真机调参。

### 6.8 截图处理（ScreenshotStore）

- 原图保存到 App Group 容器：`sessions/<sessionID>.png`（录音 `sessions/<sessionID>.m4a` 同目录）。数据库里只存相对容器的路径。
- 发送给大模型前：长边缩放到 1536 px，转 JPEG（质量 0.75），再转 base64。
- 可选增强（M4）：用 Vision 的文字识别提取截图文字，作为补充上下文一起发送，提高中文小字的识别准确率。

### 6.9 大模型调用（LLMClient）

```swift
struct LLMTurn: Sendable { enum Role { case user, assistant }; let role: Role; let content: String }
struct LLMAnswer: Codable { let summary: String; let answer: String; var needsDeep: Bool? }
enum LLMStreamEvent: Sendable { case reasoning(String), content(String) }

protocol LLMProvider: Sendable {
    // 快速档：灵动岛用
    func ask(imageJPEG: Data?, question: String, history: [LLMTurn]) async throws -> LLMAnswer
    // 深度档：会话页和追问用
    func streamDeepAnswer(imageJPEG: Data?, question: String, history: [LLMTurn]) -> AsyncThrowingStream<LLMStreamEvent, Error>
}
```

- history 用值类型 `LLMTurn`，不直接用 `ChatMessage`：`@Model` 不是 Sendable，不能传给跨 actor 的请求。调用方在主线程上用 `AskSession.conversationTurns` 转换（首轮问题 + 首轮回答（优先用深度回答）+ 追问）。
- 实现 `OpenAICompatibleProvider`（baseURL、apiKey、model 由设置页配置，每次请求重新读），走 `/chat/completions`。图片以 `image_url` 的 data URI 传入，`detail: high`，只放在第一条 user 消息里（DeepSeek 不接受 system/assistant 消息里的图片）。追问沿用同一张截图。
- 当前接入 DeepSeek `deepseek-flash`（支持图片输入，默认开思考模式）。
- 原型阶段 API Key 存 Keychain（`AfterFirstUnlockThisDeviceOnly`，保证后台能读），由设置页填写；正式发布前改为经自己的服务端代理转发，不在 App 里存 Key。

**快速档**

- `stream: false`，`thinking: disabled`，`response_format: json_object`，`max_tokens: 2048`。
- 超时 30 秒，可重试的错误（超时、断网、5xx、429、空内容、格式错误）重试 1 次。
- `finish_reason = length`：报「回答太长被截断」，不重试。
- 系统提示词：

```
你是屏幕助手。用户会给你一张手机截图和一个口语化的问题（来自语音转写，可能有错别字）。请结合截图回答。
只输出 JSON：{"summary": "...", "answer": "...", "needs_deep": false}
summary：不超过 40 个汉字，直接给结论，不寒暄。
answer：完整回答，可使用 Markdown。
needs_deep：true 或 false。answer 已经完整准确回答了问题时为 false；需要逐项识别图中多个细节、多步推理、你没有把握，或 answer 只是概要时为 true。
如果截图与问题无关或看不清，在 summary 中直接说明。
```

- summary 超过 40 字时截断加「…」；没有返回 needs_deep 时按 true 处理。

**深度档**

- `stream: true`（SSE），`thinking: enabled`，`reasoning_effort: high`，不用 JSON 模式，不设 `max_tokens`。
- 思考片段在 `delta.reasoning_content`，正文片段在 `delta.content`。不带 tools 时 API 会忽略历史里的 reasoning_content，所以不回传。
- 超时：数据包之间最多 60 秒，整次请求最多 300 秒。不自动重试，失败后在会话页手动重新生成。
- 系统提示词：

```
你是屏幕助手。用户会给你一张手机截图和一个问题（首轮问题来自语音转写，可能有错别字）。请结合截图仔细分析后详细回答。
直接输出回答正文，使用 Markdown（可用标题、列表、粗体），不要输出 JSON，不要寒暄。
如果截图与问题无关或看不清，直接说明。
```

### 6.10 Live Activity（AskActivityAttributes + AskLiveActivity）

```swift
struct AskActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable { case listening, thinking, answered, failed }
        var phase: Phase
        var transcriptTail: String   // 最多 60 字，只取末尾
        var summary: String?         // 最多 40 字
        var errorMessage: String?
        var startedAt: Date
    }
    var sessionID: String
}
```

各状态的灵动岛布局：

| 状态 | 紧凑态（左 / 右） | 最小态 | 展开态 |
| --- | --- | --- | --- |
| listening | 麦克风图标 / 最近 6 个字（还没有文字时显示计时） | 跳动的麦克风 | 左侧只放麦克风图标；中间最多 3 行转录，只显示最新 30 字（超出时前面加「…」，旧文字先滚掉）；右侧 26pt 红色圆形「停止」小按钮（StopAskIntent） |
| thinking | 截图缩略图标 / 加载动画 | 加载动画 | 一行问题原文 + 「思考中…」 |
| answered | App 图标 / 对勾 | 对勾 | 摘要文字最多 3 行；右上角关闭按钮（DismissAskIntent） |
| failed | 警告图标 / 「失败」 | 警告图标 | 错误说明 + 「再试一次」提示 |

listening 布局按 M1 真机反馈调整，原因：

- 灵动岛展开态由系统控制，几秒后会自动收回紧凑态，App 无法强制保持展开；所以紧凑态右侧直接显示最近几个字，不点开也能看到进度。
- 展开态左侧区域太窄，放计时会被截成省略号，计时只保留在紧凑态兜底和锁屏视图里。
- 停止按钮放进右侧区域，把整行留给转录文字；用固定尺寸纯色圆形，避免 `borderedProminent` 的描边被灵动岛圆角裁掉。

更新规则：

- 转录更新节流为每秒最多 1 次（第一条立即推送）。
- 进入 answered 时，带 `AlertConfiguration` 更新，使展开态自动弹出几秒。
- 锁屏视图和 `DynamicIsland` 都设置 `widgetURL(islandask://session/<sessionID>)`，点击跳到会话页。
- answered 状态保持显示，直到用户点关闭、打开 App 查看这条会话，或开始下一次提问时再结束。
- 锁屏视图与展开态内容一致。

### 6.11 数据存储（SwiftData）

```swift
@Model final class AskSession {
    @Attribute(.unique) var id: UUID; var createdAt: Date
    var screenshotPath: String?   // 相对 App Group 容器的路径：sessions/<id>.png
    var transcript: String
    var summary: String?; var answer: String?   // 快速档
    var status: String            // listening / thinking / answered / failed
    var errorMessage: String?     // failed 的原因
    var needsDeepAnswer: Bool?    // 快速档判断；nil 按 true 处理
    var deepAnswer: String?; var deepReasoning: String?; var deepError: String?   // 深度档
    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.session)
    var messages: [ChatMessage]   // App 内追问记录（不含首轮），显示时按 createdAt 排序
}
@Model final class ChatMessage {
    var role: String; var content: String; var createdAt: Date
    var reasoning: String?        // assistant 的思考过程
    var session: AskSession?
}
```

- 存储位置用 App Group 容器（`ModelConfiguration(groupContainer: .identifier("group.com.wentao.islandask"))`），方便以后 widget 读取；容器不可用时退回默认位置并记 error 日志。
- 只有 `SessionCoordinator` 写数据库，UI 用 `@Query` 读。流式生成中的内容只放在内存（`StreamingReplyStore`），结束后再一次性写库。
- 新增字段一律用可选类型，靠 SwiftData 自动轻量迁移。

### 6.12 App 界面

| 页面 | 内容 |
| --- | --- |
| 首次引导 | 权限申请、模型下载、快捷指令和 Action Button 设置指引 |
| 历史列表 | 按时间倒序，每条显示截图缩略图、问题、摘要或状态；左滑删除（连同截图和录音） |
| 会话页 | 截图（可放大）、问题原文、摘要、回答（Markdown 渲染）、底部追问输入框；追问沿用同一张截图和上下文 |
| 设置 | API 地址、Key、模型名、识别语言（中文 / 英文，切换前在前台下载模型）、静音阈值、权限与环境状态 |

会话页的回答区：

- needs_deep 不为 false：进入页面自动开始深度回答（每次进入最多自动触发一次）。生成中显示「深度思考中… N 秒」，思考过程实时展开；正文开始输出后自动收起，长回答逐字显示。完成后思考过程留在折叠块里。
- needs_deep 为 false：只显示快速回答，下面一个「深度思考」按钮，手动触发。
- 深度回答失败（如切到后台被中断）：显示快速回答 + 错误说明 +「重新生成深度回答」。
- 快速档失败且有问题文字：显示「重新提问」，用快速档重问，不更新灵动岛。
- 追问：深度思考 + 流式，失败时撤回这条追问并把文字放回输入框；生成中禁用输入框。
- 深度回答由 `SessionCoordinator` 持有，离开会话页也继续；切到后台时靠后台任务保活约 30 秒，到期取消。
- 右上角可播放原始录音，便于排查转录问题。

快捷指令设置指引（引导页里用图文展示）：

1. 打开快捷指令 App，新建快捷指令，命名为「屏幕提问」。
2. 添加动作「截屏」。
3. 添加动作「对屏幕提问」，把「截图」参数设为上一步的「截屏」结果。
4. 进入 设置 → 操作按钮 → 快捷指令，选择「屏幕提问」。

后续可以提供 iCloud 快捷指令分享链接，让用户一键添加。

## 7. 开发里程碑

按顺序推进，每个里程碑达到完成标准后再进入下一个；M0 不通过时，直接转到第 9 节的兜底路线 B。

1. **M0 技术验证（1–2 天）**
   - 内容：权限引导、`AskAboutScreenIntent`、录音、最简 Live Activity（只显示「录音中」和计时）、停止按钮。
   - 完成标准：在另一个 App 里通过「截屏 → 对屏幕提问」快捷指令触发，**画面不跳转**，灵动岛出现，录音文件有声音，点停止能结束。
2. **M1 灵动岛实时转录（2–3 天）**
   - 内容：TranscriptionService、SilenceDetector、listening 状态的完整布局、节流更新。
   - 完成标准：说一句 10 秒左右的中文，灵动岛里转录基本实时跟上，停顿 1.5 秒自动结束。
3. **M2 大模型回答（2–3 天）**
   - 内容：ScreenshotStore、LLMClient、thinking / answered / failed 三种状态、AlertConfiguration 自动展开、后台任务保活。
   - 完成标准：从按键到灵动岛出现摘要，全程不跳转；回答内容与截图相关。
4. **M3 App 内追问（3–4 天）**
   - 内容：SwiftData 存储、历史列表、会话页、追问、设置页、灵动岛点击跳转。
   - 完成标准：点灵动岛进入对应会话页，能基于同一截图继续追问。
   - 追加（M3 真机测试后）：快速档 / 深度档两档回答、深度回答流式显示、needs_deep 判断。
5. **M4 打磨（持续）**
   - 内容：Vision 文字识别增强、错误提示文案、引导页图文、快捷指令分享链接、服务端代理。

## 8. 验收测试清单

全部在真机上测试，模拟器不支持 Action Button 和灵动岛的真实行为。

**核心链路**

- [ ] 在 Safari、微信、相册三个 App 中分别触发，均不跳转，灵动岛正常出现
- [ ] 通过 Action Button 触发与在快捷指令 App 里手动运行，行为一致
- [ ] 截图内容正确：是触发瞬间的画面，不是本 App 的画面
- [ ] 实时转录延迟可接受（说完到文字出现约 1 秒内）
- [ ] 静音 1.5 秒自动结束；6 秒不说话自动取消
- [ ] 回答到达时展开态自动弹出，摘要不超过 3 行
- [ ] 点击灵动岛进入对应会话页

**异常情况**

- [ ] 首次未授权麦克风时触发：给出清晰提示，引导去设置
- [ ] 录音中来电或唤起 Siri：会话转为失败，不崩溃
- [ ] 断网或 API 超时：灵动岛显示失败，App 内可重试
- [ ] 正在播放音乐或视频时触发：录音正常，记录对其他音频的影响
- [ ] 连续快速按两次 Action Button：只保留一个会话
- [ ] 用户在设置中关闭 Live Activity：录音照常，结果以通知或 App 内展示
- [ ] 快捷指令未配置截屏步骤：无图也能提问

**性能**

- [ ] 从按键到灵动岛出现不超过 1 秒
- [ ] 从说完到摘要出现，记录实际耗时（目标 5 秒内，取决于模型）
- [ ] 一次完整会话后 App 能正常进入挂起，不长期占用麦克风

## 9. 风险与兜底方案

最大的风险是 M0：从快捷指令调用时，后台启动录音可能失败（论坛上有报错 "Target is not foreground" 和音频会话激活失败的案例）。按下表依次排查和降级。

| 风险 | 先排查 | 兜底 |
| --- | --- | --- |
| 后台无法启动录音 | 权限是否已在 App 内授予；Intent 是否只在主 App target；是否先启动 Live Activity 再激活音频会话；是否开启 audio 后台模式 | 路线 B：快捷指令「截屏 → 听写文本 → 对屏幕提问（传入图片和文字）」，系统听写界面浮在当前 App 上，不跳转；本 App 只负责调用大模型和显示回答 |
| 只有 ControlWidget 触发能录音，快捷指令触发不行 | 对比两种触发方式的日志 | 同上，改走路线 B；或取消截屏，仅做语音问答 |
| 路线 B 也无法在后台启动 Live Activity | `AskAboutScreenIntent` 改为遵循 `LiveActivityIntent` | 回答改用本地通知展示；或服务端 push-to-start（iOS 17.2+） |
| 以上都不行 | — | 路线 C：Intent 打开 App，在前台开始录音，用户再划回原 App（ChatGPT 的做法） |
| 大模型回答慢 | 换更快的模型；截图压到更小 | 先推送「思考中」，回答分两步：先出摘要，完整回答后台继续生成 |
| 转录模型不支持中文或未下载 | 检查 `SpeechTranscriber` 支持的 locale | 回退 `SFSpeechRecognizer` |
| 模型默认开思考，后台请求被截断或超时 | 日志看 `finish_reason=length`、后台任务是否过期 | 灵动岛链路显式关闭思考；需要思考的回答放到 App 前台的深度档 |

路线 B 与主方案共用截图、大模型、Live Activity 回答这三部分，切换时只需替换录音和转录模块。

## 10. 交给 AI 编码时的使用说明

不要一次让 AI 生成整个工程，按里程碑分批要代码，每批编译通过、真机测完再进入下一批。

**推荐做法**

1. 每次对话都把第 1–6 节作为背景贴给 AI，再说明当前要做哪个里程碑。
2. 要求 AI 按第 3 节的文件结构逐个文件输出完整代码，并说明每个文件属于哪个 target。
3. `SpeechAnalyzer`、`AudioRecordingIntent` 是较新的 API，AI 可能不熟悉或编造方法名。遇到编译错误时，把 Apple 官方文档对应页面的内容贴给它，让它对照修改。
4. Xcode 里的 Capabilities、Info.plist、Target Membership 需要手动配置，AI 只能告诉你步骤。

**第一次对话的提示词模板**

```
下面是我的 iOS 项目技术规格（第 1–6 节）：
<粘贴规格>

现在只做里程碑 M0。请：
1. 列出 M0 需要的文件，标明各属于 IslandAsk 还是 IslandAskWidget target；
2. 逐个文件给出完整、可编译的 Swift 代码（Swift 6、iOS 26）；
3. 列出我需要在 Xcode 里手动完成的配置步骤；
4. 对你不确定的 API 名称或签名，明确标注「需核对官方文档」，不要编造。
不要实现 M0 范围以外的功能。
```
