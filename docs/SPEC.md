# 灵动岛截屏问答 App：工程实现规格

Nov 1, 2026 · @Wentao Xie

Nov 6, 2026 修订：产品方向从「对屏幕提问」扩展为「全局收藏 + AI 整理」，屏幕提问保留，作为卡片的一种来源。新增内容见第 1、2 节，6.3、6.7、6.9–6.12 节，新的 6.13–6.15 节，第 7 节的 M-C1–M-C4，以及第 8、9 节的对应条目。

## 1. 项目概述与目标交互

iOS 没有跨 App 的收藏夹：微信、小红书、B 站、Safari 的收藏各自分散，事后很难找回。本 App 让用户在任意 App 里按下 Action Button，不离开当前界面，用一句话（或者什么都不说）完成下面两件事之一：

- **收藏**：截下当前屏幕，由大模型整理成一张卡片（标题、摘要、类型、标签、关键信息、外文翻译），存进 App 的收藏库。
- **提问**：对屏幕内容提问，灵动岛显示简要回答；想深入时点进 App 继续追问。

两件事由语音自动区分，用户不需要先选择。App 里的一切都是卡片：收藏得到卡片，每次提问也会生成一张卡片（默认不进收藏，可以一键收藏）。

agent 的定位：替用户「动手」整理，包括起标题、归类、打标签、翻译、提取关键信息、找回原始链接、在收藏里查找；不替用户操作其他 App。

目标交互 A（收藏）：

1. 用户在任意 App 中按下 Action Button，系统截下当前屏幕（用户无感知）。
2. 灵动岛出现「正在听」。用户说「收藏这个」「记一下，周末去这家店」，或者什么都不说。
3. 灵动岛显示「整理中」，后台把截图和语音文字发给多模态大模型。
4. 灵动岛显示「已收藏」和卡片标题。判断错了可以点「改为提问」。

目标交互 B（提问）：

1. 用户在任意 App 中按下 Action Button。
2. 系统截下当前屏幕（用户无感知）。
3. 灵动岛出现，显示「正在听」和实时转录文字。
4. 用户说完（静音自动结束，或点灵动岛上的停止按钮）。
5. 灵动岛显示「思考中」，后台把截图和问题发给多模态大模型。
6. 回答返回，灵动岛自动展开几秒，显示 30–40 字的简要回答，并带「收藏」按钮。
7. 用户点击灵动岛 → 进入 App 里这张卡片的详情页，查看截图和回答，并可继续追问。问题较复杂时，详情页自动用深度思考流式生成更完整的长回答。

目标交互 C（带链接收藏，M-C2）：在任意 App 里点「分享」→ 选择本 App，链接、标题和可选的附注文字直接存为卡片。小红书、微信等不调起系统分享菜单的 App：在它们的面板里点「复制链接」，回到本 App 后在收藏库顶部一键收藏。

非目标（当前不做）：锁屏状态下提问、实时连续共享屏幕、语音播报回答、Android 版本、自建服务端、iCloud 多设备同步、替用户操作其他 App。

参照产品：Grok Bot 已实现「Action Button → 不跳转 → 灵动岛自定义样式语音会话」，证明后台启动录音与自定义 Live Activity 的组合在 App Store 上可行。现有的收藏和稍后读工具依赖分享菜单和链接，在不能分享的地方（朋友圈、视频画面、App 内页面）无能为力。本项目的差异点是按键截屏收藏、语音附注、AI 自动整理，以及灵动岛内的文字转录和摘要回答。

## 2. 关键技术约束与设计决策

整套方案由下面七条 iOS 限制决定，实现时不要绕开或改动这些决策。

| 约束 | 决策 | 原因 |
| --- | --- | --- |
| 第三方 App 无法截取其他 App 的屏幕 | 用快捷指令内置的「截屏」动作截图，再作为参数传给 App Intent | 快捷指令截屏无需用户确认；ReplayKit 广播需要每次弹窗确认，太重 |
| 后台启动录音受限 | 录音 Intent 遵循 `AudioRecordingIntent`，在主 App 进程内运行 | 这是 Apple 为「按键即录音」提供的官方协议；Grok Bot 已验证可行 |
| Intent 运行时无法弹出权限授权框 | 麦克风、语音识别权限必须在首次打开 App 时申请完毕 | 开发者论坛上的失败案例多卡在这里 |
| Live Activity 只能显示，不能输入 | 灵动岛只放转录、状态、摘要和按钮；追问在 App 内完成 | WidgetKit 视图不支持文本输入 |
| Live Activity 内容有大小上限，更新会被节流 | ContentState 控制在 4KB 内；转录约每秒更新一次，只显示末尾一两行 | 超限或更新过频会被系统丢弃 |
| 截图拿不到来源链接 | 两条路互补：需要原链接时走分享入口（M-C2）；截图卡片由模型识别来源平台和原标题，必要时由 agent 搜索推测原链接，用户确认后才保存（M-C4） | 快捷指令截屏时不知道当前在哪个 App、哪个页面，系统也不向第三方暴露其他 App 的当前页面 |
| 分享扩展的内存和运行时间受限 | 扩展只把链接、标题、文字写进 App Group 的 inbox，不调大模型、不写 SwiftData；由主 App 导入并整理 | 扩展被系统强杀时不丢数据，也符合「只有 SessionCoordinator 写数据库」 |

附加决策：

- **大模型分两档回答**：
  - 快速档：不开思考，只请求一次，返回 JSON。其中 summary 不超过 40 字，放进灵动岛；answer 是简短完整回答；needs_deep 由模型判断要不要再做深度回答。
  - 深度档：只在 App 前台的会话页和追问里使用，开思考，流式输出 Markdown 长回答。
  - 原因：开思考的请求单次要十几秒以上，后台约 30 秒的保活时间不够用；M3 真机测到过「思考用完 max_tokens → 内容为空 → 重试后超时被取消」。
- **录音结束后要保住进程**：音频会话停止后 App 可能很快被挂起，大模型请求必须包在 `beginBackgroundTask` 里，或者等回答返回后再停止音频会话。
- **一次请求完成分流和整理**：快速档 JSON 同时返回意图（ask / collect / both）、回答和卡片字段，不为分流单独多发一次请求，后台耗时基本不变。
- **先落库，再整理**：按键后立即创建卡片并保存截图；大模型失败时卡片仍在收藏库里，状态为「待整理」，可以在 App 内重新整理。收藏不能因为网络问题丢失。
- **工具调用循环只在前台**：agent 的多轮工具调用（检索收藏、联网搜索、找原链接）只在 App 前台运行，和深度档同一原则。写操作类工具只产生「待确认」的建议，由用户确认后才写库。

## 3. 系统架构

工程分两个 target：主 App 进程负责全部逻辑，Widget 扩展只负责渲染灵动岛和锁屏视图。

&#91;embedded content: 系统架构 · 两个 target，一个调度中心\]

`AskAboutScreenIntent` 只是入口；`SessionCoordinator` 串起录音、转录、截图和大模型，并且是唯一更新 Live Activity 和数据库的地方。灵动岛上的停止按钮通过 `StopAskIntent` 回调到主 App 进程。

**文件结构**

下面标注了（M-Cx）的是收藏方向计划新增的文件，在对应里程碑里创建。

```
IslandAsk/                           // 主 App target
├── App/
│   ├── IslandAskApp.swift           // 入口，处理 islandask:// 深链，回到前台时预热音频会话
│   ├── AppState.swift               // 导航路径、暂存的深链
│   └── AppShortcuts.swift           // AppShortcutsProvider
├── Config/
│   ├── AppGroup.swift               // App Group 标识与容器路径；M-C2 阶段 2 起同时属于 IslandAskShare target
│   └── Secrets.swift                // 已废弃（gitignore），Key 改存 Keychain
├── Intents/
│   ├── AskAboutScreenIntent.swift   // 只属于主 App
│   └── SaveLinkIntent.swift         // （M-C2）快捷指令共享表单收藏链接
├── Session/
│   ├── SessionCoordinator.swift
│   ├── SessionCoordinator+Cards.swift  // （M-C1）写卡片、灵动岛收藏 / 改为提问、批量操作、重新整理、旧会话补建卡片
│   ├── SessionCoordinator+Links.swift  // （M-C2）分享链接建卡与整理、回前台补整理、导入 inbox
│   └── StreamingReply.swift         // 深度回答流式状态、后台任务封装
├── Agent/                           // （M-C4）
│   ├── AgentTool.swift              // 工具协议与注册表
│   ├── AgentRunner.swift            // 前台工具调用循环
│   └── WebSearchClient.swift        // 联网搜索
├── Services/
│   ├── PermissionManager.swift
│   ├── SpeechModelManager.swift     // 转录模型状态检查与前台下载
│   ├── AudioCaptureService.swift
│   ├── SilenceDetector.swift
│   ├── TranscriptionService.swift
│   ├── ScreenshotStore.swift
│   ├── LLMClient.swift
│   ├── AppSettings.swift            // 设置项（UserDefaults）
│   ├── KeychainStore.swift          // API Key
│   ├── LinkMetadataFetcher.swift    // （M-C2）抓取链接标题、描述；（M-C2 补充）正文摘录、封面图和图标地址
│   ├── LinkImageStore.swift         // （M-C2 补充）链接封面图、网站图标的下载、缩小与存储
│   ├── ShareInbox.swift             // （M-C2）App Group inbox 读写；同时属于 IslandAskShare target
│   ├── ClipboardLinkDetector.swift  // （M-C2）剪贴板入口：检测剪贴板里是否有链接（不读内容）
│   ├── CardSearch.swift             // （M-C3）本地搜索词、自然语言搜索的候选与结果解析、AI 搜索状态
│   └── SpotlightIndexer.swift       // （M-C3）Core Spotlight 索引
├── Shared/                          // 两个 target 共享（在 pbxproj 里逐个文件登记）
│   ├── AskActivityAttributes.swift  // 含深链 URL 辅助函数
│   ├── StopAskIntent.swift
│   ├── DismissAskIntent.swift
│   ├── SaveCardIntent.swift         // （M-C1）灵动岛「收藏」
│   └── SwitchToAskIntent.swift      // （M-C1）灵动岛「改为提问」
├── Data/
│   ├── Models.swift                 // AskSession, ChatMessage, Card（M-C1）
│   └── AppDatabase.swift            // 共享 ModelContainer（App Group）
└── UI/
    ├── OnboardingView.swift
    ├── LibraryView.swift            // （M-C1）收藏库，替换原 HistoryView.swift（含 ScreenshotThumbnail）
    ├── ClipboardLinkBanner.swift    // （M-C2）收藏库顶部的剪贴板提示条
    ├── CardDetailView.swift         // （M-C1）卡片信息、编辑标题和标签、批量加标签；详情页本身复用会话页
    ├── SessionDetailView.swift
    ├── SettingsView.swift
    ├── MarkdownText.swift           // 轻量 Markdown 块级渲染
    └── ScreenshotViewer.swift       // 截图全屏缩放

IslandAskWidget/                     // Widget 扩展 target
├── IslandAskWidgetBundle.swift
└── AskLiveActivity.swift            // 灵动岛 + 锁屏视图

IslandAskShare/                      // （M-C2 阶段 2）Share Extension target
└── ShareViewController.swift        // 只写 inbox，不调大模型、不写 SwiftData
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

**分流与卡片（M-C1 起）**

状态机和 Phase 不变，用 ContentState 新增的 `kind` 区分收藏和提问的展示。上面的调用顺序有以下变化：

- 第 5.5 步：写入 `AskSession` 的同时创建 `Card`（id 与会话相同，origin = press，organizeStatus = pending，isSaved = nil），截图路径同时记在卡片上。
- 第 8 步：一直没有转录文字时：
  - 有截图：3 秒内没有任何转录文字，就按收藏处理。停止 engine，直接进入 thinking，灵动岛显示「整理中…」，intent 在本地定为 collect（模型返回的 intent 不再采用）。
  - 无截图：照旧等 6 秒，cancel，灵动岛提示「没听到」。
- 第 10 步：按返回的 intent 分支（缺省按 ask）：
  - ask：同原流程；卡片字段写入 `Card`，isSaved 保持 nil。
  - collect：isSaved = true，`Card.summary` 取 answer；Live Activity 以 kind = collect 更新为 answered，显示卡片标题；忽略 needs_deep。
  - both：同 ask，另外 isSaved = true。
  - 无论哪种，卡片 organizeStatus = done。
- 快速档失败：会话照原流程转为 failed，卡片保留，organizeStatus = failed，可在收藏库里重新整理。
- 第 11 步：深链 `islandask://session/<id>` 打开的是这张卡片的详情页（卡片 id 与会话 id 相同）。新增 `islandask://card/<id>`，供链接卡片和 Spotlight 使用。

## 5. 工程配置

最低系统版本定为 iOS 26，以便直接使用 SpeechAnalyzer；设备需为带 Action Button 和灵动岛的 iPhone（15 Pro 及以后）。

**Targets**

| Target | 类型 | 职责 |
| --- | --- | --- |
| IslandAsk | iOS App | 主 App：Intent、录音、转录、大模型调用、数据存储、UI |
| IslandAskWidget | Widget Extension | Live Activity 的灵动岛与锁屏视图 |
| IslandAskShare（M-C2 阶段 2） | Share Extension | 从分享菜单接收链接和文字，写入 App Group inbox |

**Capabilities（两个 target 按需开启）**

- Background Modes → Audio, AirPlay, and Picture in Picture（主 App）
- App Groups：`group.com.wentao.islandask`（两个 target 都开，用于共享截图、录音和 SwiftData 数据库；M-C2 的 Share Extension 也要开，用于写 inbox）
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

**依赖**：只用系统框架（AppIntents、ActivityKit、WidgetKit、AVFoundation、Speech、SwiftData、Vision 可选；收藏方向新增 LinkPresentation（M-C2）、CoreSpotlight（M-C3）），不引入第三方库。网络请求用 URLSession。M-C4 的联网搜索调用第三方搜索服务的 HTTP API，不引入 SDK。

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

收藏方向新增两个按钮 Intent（M-C1），结构与 `StopAskIntent` 相同，放在 `Shared/`，引用 `SessionCoordinator` 的代码用 `#if !WIDGET_EXTENSION` 包起来：

- `SaveCardIntent`：提问回答出来后的「收藏」按钮。把卡片 isSaved 设为 true，Live Activity 的按钮变成不可点的「已收藏」。
- `SwitchToAskIntent`：收藏后的「改为提问」按钮，只在转录文字不为空时显示。用同一张截图和转录文字、强制 intent = ask 重跑快速档：phase 回到 thinking，再到 answered；卡片 isSaved 改回 nil。
  - 此时音频会话已经停止，后台保活只能靠 `beginBackgroundTask`，能否跑完需要真机验证。跑不完时转为 failed，提示「点开 App 查看」，App 内用快速档重问。

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

    // M-C1 起：卡片（灵动岛按钮和 App 前台都会调用）
    func saveCard(sessionID: String) async                     // SaveCardIntent
    func switchToAsk(sessionID: String) async                  // SwitchToAskIntent
    func setSaved(cardID: UUID, _ saved: Bool)
    func reorganizeCard(id: UUID) async                        // 整理失败后重新整理
    func updateCard(id: UUID, title: String?, tags: [String]?)
    func deleteCard(id: UUID)                                  // 级联删除会话和文件
    func deleteCards(ids: [UUID])                              // 收藏库多选批量删除
    func setSaved(cardIDs: [UUID], _ saved: Bool)              // 多选批量收藏 / 取消收藏
    func addTag(_ tag: String, toCards ids: [UUID])            // 多选批量追加标签
    func backfillCardsForLegacySessions()                      // 启动时为旧会话补建卡片
    // M-C2 起
    func saveSharedLink(url: URL?, text: String?) async -> SaveSharedLinkResult   // SaveLinkIntent
    func organizePendingShareCards() async                     // 回前台补整理 pending 的分享卡片
    func organizeShareCard(id: UUID, metadataTimeout: Duration, allowRetry: Bool) async -> Bool
    func importShareInbox() -> Int                             // 导入分享扩展写入的 inbox：只建卡，返回新建数
    func saveClipboardText(_ text: String) async -> SaveClipboardResult   // 剪贴板提示条的「收藏」；同链接已有卡片时不新建
    // M-C3 起
    func askAboutCard(cardID: UUID, text: String) async throws  // 卡片详情底部提问；没有会话的卡片先建同 id 会话
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
| 一直不说话（有截图，M-C1） | 3 秒内没有任何转录文字 | 按收藏处理（见第 4 节） |
| 一直不说话（无截图） | 6 秒内没有任何转录文字 | 触发 `cancel`，灵动岛提示「没听到」 |
| 最长录音 | 60 秒 | 强制 `stopListening` |

- 音量条件是安静环境下的快速结束路径；吵的环境靠「文字不再变化」结束，会比安静时晚约 0.5–1 秒（转录延迟）。
- 临时结果转成已确定结果、文字内容不变时，不算变化。

阈值放进设置页，方便真机调参。

- 3 秒以「转录出现第一个字」为准，而转录本身有约 0.5–1 秒延迟，所以用户实际要在按键后约 2 秒内开口，否则会被当成收藏。真机重点观察；开口慢的用户可以在设置页调长。
- 被误判成收藏时没有转录文字，灵动岛上不会出现「改为提问」，只能重新按键提问。

### 6.8 截图处理（ScreenshotStore）

- 原图保存到 App Group 容器：`sessions/<sessionID>.png`（录音 `sessions/<sessionID>.m4a` 同目录）。数据库里只存相对容器的路径。
- 发送给大模型前：长边缩放到 1536 px，转 JPEG（质量 0.75），再转 base64。
- 可选增强（M4）：用 Vision 的文字识别提取截图文字，作为补充上下文一起发送，提高中文小字的识别准确率。

### 6.9 大模型调用（LLMClient）

```swift
struct LLMTurn: Sendable { enum Role { case user, assistant }; let role: Role; let content: String }
struct LLMAnswer: Codable {
    let summary: String; let answer: String; var needsDeep: Bool?
    var intent: LLMIntent?       // M-C1：ask / collect / both；无法识别时为 nil，按 ask
    var card: CardFields?        // M-C1：卡片字段；nil 时卡片只用 summary / answer
}
struct CardFields: Codable {     // 全部可选，模型漏字段时不报格式错误
    var title: String?; var type: String?; var tags: [String]?
    var keyInfo: [KeyInfo]?      // [{label, value}]
    var note: String?            // 用户话里除收藏指令之外的附注
    var sourcePlatform: String?; var sourceTitle: String?
    var translation: String?
}
enum LLMStreamEvent: Sendable { case reasoning(String), content(String) }

protocol LLMProvider: Sendable {
    // 快速档：灵动岛用。screenText 是截图 OCR 文字（M4）；intentHint 是本地已确定的意图（M-C1：没说话 = collect，
    // 「改为提问」= ask）；onSummary 在流式 summary 一完整时回调，同时带上已到达的 intent
    func ask(imageJPEG: Data?, screenText: String?, question: String, history: [LLMTurn],
             intentHint: LLMIntent?, onSummary: ((String, LLMIntent?) async -> Void)?) async throws -> LLMAnswer
    // M-C2 链接整理：不带图的快速档，intent 固定 collect；allowRetry = false 时不重试（Intent 链路有时限）
    func organizeLink(url: URL?, pageTitle: String?, pageDescription: String?, pageExcerpt: String?,
                      sharedText: String?, coverJPEG: Data?, allowRetry: Bool) async throws -> LLMAnswer
    // M-C3 自然语言搜索：不带图的快速档，返回相关候选的序号（相关度从高到低）
    func searchCards(query: String, candidates: [CardSearchCandidate], today: Date) async throws -> [Int]
    // 深度档：会话页和追问用。cardContext（M-C3）：没有截图的卡片（链接、文字收藏）的卡片信息
    func streamDeepAnswer(imageJPEG: Data?, screenText: String?, cardContext: String?, question: String, history: [LLMTurn]) -> AsyncThrowingStream<LLMStreamEvent, Error>
}
```

- history 用值类型 `LLMTurn`，不直接用 `ChatMessage`：`@Model` 不是 Sendable，不能传给跨 actor 的请求。调用方在主线程上用 `AskSession.conversationTurns` 转换（首轮问题 + 首轮回答（优先用深度回答）+ 追问）。
- 实现 `OpenAICompatibleProvider`（baseURL、apiKey、model 由设置页配置，每次请求重新读），走 `/chat/completions`。图片以 `image_url` 的 data URI 传入，`detail: high`，只放在第一条 user 消息里（DeepSeek 不接受 system/assistant 消息里的图片）。追问沿用同一张截图。
- 当前接入 DeepSeek `deepseek-flash`（支持图片输入，默认开思考模式）。
- 原型阶段 API Key 存 Keychain（`AfterFirstUnlockThisDeviceOnly`，保证后台能读），由设置页填写；正式发布前改为经自己的服务端代理转发，不在 App 里存 Key。

**快速档**

- `stream: true`（M4 起，summary 一完整就更新灵动岛），`thinking: disabled`，`response_format: json_object`，`max_tokens: 3072`（M-C1 起从 2048 上调：输出多了卡片字段和翻译）。
- 超时 30 秒，可重试的错误（超时、断网、5xx、429、空内容、格式错误）重试 1 次。
- `finish_reason = length`：报「回答太长被截断」，不重试。
- 系统提示词（M-C1 起使用，同时完成意图判断、回答和卡片整理）：

```
你是屏幕助手兼收藏整理员。用户会给你一张手机截图和一句口语化的话（来自语音转写，可能有错别字，也可能为空）。
先判断用户意图：
- collect：用户要收藏、保存、记下这个内容（如「收藏」「存一下」「记一下」「以后看」），或者话为空；
- ask：用户在提问；
- both：既提问又要求收藏。
只输出 JSON：
{"intent": "ask", "summary": "...", "answer": "...", "needs_deep": false,
 "card": {"title": "...", "type": "article", "tags": ["..."], "key_info": [{"label": "...", "value": "..."}],
          "note": null, "source_platform": null, "source_title": null, "translation": null}}
summary：不超过 80 个汉字，显示在灵动岛。ask / both 时直接给结论，不寒暄；collect 时概括收藏了什么。
answer：ask / both 时是完整回答，可使用 Markdown；collect 时是 2–4 句的内容摘要。
needs_deep：true 或 false，只在 ask / both 时有意义，collect 时为 false。answer 已经完整准确回答了问题时为 false；需要逐项识别图中多个细节、多步推理、你没有把握，或 answer 只是概要时为 true。
card.title：不超过 20 个汉字，概括截图内容本身（不是概括问题）。
card.type：article / product / place / event / recipe / knowledge / media / chat / other 之一。
card.tags：1–4 个中文短标签。
card.key_info：截图里值得单独记下的信息，如店名、地址、价格、时间、书名、作者，最多 6 条；没有就给空数组。
card.note：用户话里除收藏指令之外的附注（如「周末去」），没有时为 null。
card.source_platform / card.source_title：根据界面特征判断截图来自哪个 App 或网站、原内容的标题；看不出来时为 null，不要猜。
card.translation：截图主要内容不是中文时，给出中文翻译，最多 600 字，超出时只翻译开头并以「…」结尾；是中文时为 null。
如果截图与问题无关或看不清，在 summary 中直接说明。
```

- summary 超过 80 字时截断加「…」（M4 灵动岛 UI 优化后展开态能放 5 行）；没有返回 needs_deep 时按 true 处理（collect 除外）。
- card.title 超过 20 字时截断；card.type 不在列表里时按 other；tags 去空、去重后最多取 4 个；key_info 丢掉缺 label 或 value 的条目，最多 6 条；translation 超过 600 字截断加「…」。
- intent 无法识别、card 不是对象时按缺失处理，不算格式错误；card 里单个字段类型不对只丢这个字段。
- 用户没说话时 user 文字写「用户没有说话，请按 intent = collect 整理」；「改为提问」时写明 intent 必须为 ask（转录为空时用默认问法「请解释这张截图的主要内容。」）。
- 截图主要是外文长文时，输出最长，最容易触发 `finish_reason = length` 或超时。日志里要记录 completion_tokens，M-C1 真机测试时重点观察。
- 用户话为空（本地已定为 collect）时，question 传空字符串，提示词按 collect 处理。

**深度档**

- `stream: true`（SSE），`stream_options: {include_usage: true}`（最后一个 chunk 带 token 用量），`thinking: enabled`，`reasoning_effort: high`，不用 JSON 模式，不设 `max_tokens`。
- 思考片段在 `delta.reasoning_content`，正文片段在 `delta.content`。不带 tools 时 API 会忽略历史里的 reasoning_content，所以不回传。
- 超时：数据包之间最多 60 秒，整次请求最多 300 秒。不自动重试，失败后在会话页手动重新生成。
- 系统提示词：

```
你是屏幕助手。用户会给你一张手机截图和一个问题（首轮问题来自语音转写，可能有错别字）。请结合截图仔细分析后详细回答。
直接输出回答正文，使用 Markdown（可用标题、列表、粗体），不要输出 JSON，不要寒暄。
如果截图与问题无关或看不清，直接说明。
```

**深度档：对没有截图的卡片提问（M-C3）**

- 链接、文字收藏卡片没有截图，`cardContext` 带上卡片信息（标题、类型、收藏时间、来源、链接、标签、摘要、附注、关键信息、翻译），挂在第一条 user 消息上。
- 只有卡片信息、没有截图时，系统提示词换成：

```
你是收藏助手。用户收藏了一条内容（链接或一段文字），第一条消息里附有这张收藏卡片的信息：标题、摘要、附注、关键信息、来源链接等。网页正文没有保存，只有整理后的摘要。
请结合卡片信息回答用户的问题。卡片信息不足以回答时直接说明，可以给出基于常识的建议，但不要编造卡片里没有的具体事实。
直接输出回答正文，使用 Markdown（可用标题、列表、粗体），不要输出 JSON，不要寒暄。
```

**自然语言搜索（M-C3）**

- 不流式（输出只有几个序号），`thinking: disabled`，`response_format: json_object`，`max_tokens: 512`，超时 15 秒，不重试。
- user 消息：今天的日期和星期、查找需求、候选列表（每行「序号 | 收藏日期 | 类型 | 标题 | 标签 | 摘要首句」）。
- 系统提示词：

```
你是收藏库检索助手。用户会给你一句查找需求和一份收藏卡片列表，每行一张，格式为：序号 | 收藏日期 | 类型 | 标题 | 标签 | 摘要。
需求里的「上个月」「上周」「前几天」「去年」等时间，按用户给出的今天日期换算，再按收藏日期筛选。
找出与需求最相关的卡片，按相关度从高到低排列，最多 10 张。需求里提到的时间范围、类型、地点等条件都要满足；没有相关的卡片就返回空数组，不要硬凑。
只输出 JSON，ids 是卡片的序号：
{"ids": [3, 17]}
```

- 解析：序号可以是数字或数字字符串；越界、重复的丢掉，最多 10 个。

### 6.10 Live Activity（AskActivityAttributes + AskLiveActivity）

```swift
struct AskActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable { case listening, thinking, answered, failed }
        var phase: Phase
        var transcriptTail: String   // 最多 60 字，只取末尾
        var summary: String?         // 最多 80 字
        var errorMessage: String?
        var startedAt: Date
        // M-C1 新增，全部可选，兼容旧的 Activity
        var kind: Kind?              // ask / collect；nil 按 ask
        var cardTitle: String?       // collect 时的卡片标题，最多 20 字
        var isSaved: Bool?           // ask 回答后是否已点「收藏」
        var canSwitchToAsk: Bool?    // 转录文字不为空时为 true，控制「改为提问」按钮
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
| thinking（M-C1，不说话收藏） | 截图缩略图标 / 加载动画 | 加载动画 | 「整理中…」 |
| answered（M-C1，kind = ask） | 同上方 answered | 同上方 answered | 同上方 answered，另加「收藏」按钮（SaveCardIntent），已收藏后显示为不可点的「已收藏」 |
| answered（M-C1，kind = collect） | 书签图标 / 对勾 | 书签图标 | 「已收藏」+ 卡片标题一行 + summary 最多 2 行；「改为提问」按钮（SwitchToAskIntent，canSwitchToAsk 为 true 时才显示）+ 右上角关闭按钮 |

answered 展开态的按钮（含关闭和现有的复制按钮）合计不超过 3 个，避免挤占文字区域。

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
    var timingData: Data?         // 各环节耗时（SessionTiming 的 JSON）
    var tokenUsageData: Data?     // 每次大模型调用的 token 用量（[TokenUsageRecord] 的 JSON）
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

**卡片（M-C1）**

卡片是收藏库里唯一的「东西」。`AskSession` 保留，作为卡片的问答记录和一次按键的生命周期记录（转录、录音、状态、耗时）。新增实体、新增可选关系都在自动轻量迁移的范围内，不改造 `AskSession` 本身。

```swift
@Model final class Card {
    @Attribute(.unique) var id: UUID   // 按键产生的卡片与 AskSession 同 id
    var createdAt: Date
    var origin: String                 // press（按键）/ share（分享，M-C2）
    var isSaved: Bool?                 // nil 按 false：提问产生的卡片默认不进收藏
    var organizeStatus: String?        // pending / done / failed
    var intent: String?                // ask / collect / both；nil 按 ask。详情页据此显示问答或内容摘要
    var title: String?; var summary: String?
    var cardType: String?              // 与 CardFields.type 相同的取值
    var tags: [String]?
    var keyInfoData: Data?             // [{label, value}] 的 JSON
    var note: String?                  // 收藏时的语音附注，或分享时填写的文字
    var translation: String?
    var screenshotPath: String?        // 与 AskSession 指向同一个文件
    var sourceURL: String?
    var sourceURLState: String?        // shared（分享得到）/ guessed（agent 推测，待确认）/ confirmed（用户确认）
    var sourcePlatform: String?; var sourceTitle: String?
    var organizeError: String?         // （M-C2）分享卡片最近一次整理失败的原因
    var coverPath: String?             // （M-C2 补充）链接封面图，相对 App Group 容器：sessions/<id>-cover.jpg
    var iconPath: String?              // （M-C2 补充）网站图标：sessions/<id>-icon.png
    var linkImagesFetchedAt: Date?     // （M-C2 补充）取过图片的时间，取到没取到都记
    var linkBlocked: Bool?             // （M-C2 补充）网站拦截读取或什么都没抓到，详情页提示改用按键截屏
    @Relationship(deleteRule: .cascade, inverse: \AskSession.card)
    var session: AskSession?           // 分享得到的卡片在用户提问前为 nil
}
// AskSession 新增：var card: Card?
```

- App 启动时，为没有卡片的旧会话补建卡片：origin = press，isSaved = nil，organizeStatus = done，title 取 summary（为空时取转录文字前 20 字）。不为旧会话调大模型。
- 删除卡片时级联删除会话、截图和录音。
- 设置里的保留天数只清理未收藏的卡片（连同会话、截图、录音），收藏的卡片永不过期。
- 会话转为 failed 时，卡片 organizeStatus 同时记为 failed。
- 卡片的创建、整理、编辑、删除同样只经 `SessionCoordinator`。

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

**收藏方向的界面变化（M-C1）**

| 页面 | 内容 |
| --- | --- |
| 收藏库（替换历史列表，作为首页） | 顶部分段「全部 / 收藏」，默认「全部」，记住上次的选择；下面一行类型筛选。每条显示截图缩略图、标题、类型和标签、时间、收藏标记；待整理或整理失败的显示状态。左滑删除。右上角「选择」进入多选模式（见下） |
| 卡片详情 | 截图（可放大）、标题、类型、标签、关键信息、附注、翻译（可折叠）、来源（链接；推测的链接显示「推测来源，待确认」）。有问答的卡片在下方显示原会话页的内容（回答、深度回答、追问）。操作：收藏 / 取消收藏、复制、重新整理（整理失败时）、删除；标题和标签可以手动编辑 |
| 设置 | 新增：不说话时的行为（收藏 / 取消，默认收藏）、不说话判定时间（2 / 3 / 5 秒，默认 3 秒）；保留天数改名为「未收藏的问答保留」 |

- 灵动岛深链和收藏库都进入卡片详情；原会话页作为卡片详情的问答部分复用，不另开页面。

收藏库多选模式：

- 进入：点右上角「选择」，或长按某张卡片、在弹出的菜单里点「选择」（这张卡片直接选中）。长按菜单另有收藏 / 取消收藏、复制、分享、删除。进入后每条前面显示勾选圈，点卡片切换选中，不再进入详情。
- 顶部：显示「已选 N 项」，以及「全选 / 取消全选」（只作用于当前分段和筛选下可见的卡片）、「完成」退出。
- 底部工具栏，未选中时置灰：
  - 收藏 / 取消收藏：选中的卡片全部已收藏时显示「取消收藏」，否则显示「收藏」。
  - 加标签：弹出输入框，可以输入新标签，也可以从已有标签里选；给所有选中的卡片追加，不覆盖原有标签。
  - 删除：先弹确认「删除 N 张卡片？截图和录音也会一起删除」，确认后批量删除。
- 正在录音或思考中的卡片不能被选中删除。
- 批量操作全部经 `SessionCoordinator`，一次操作只保存一次数据库。
- 重新整理：用快速档、同一张截图和转录文字重跑，不更新灵动岛。

### 6.13 链接收藏（M-C2）

**阶段 1：快捷指令共享表单**（不新建 target，用来先验证）

```swift
struct SaveLinkIntent: AppIntent {
    static var title: LocalizedStringResource = "收藏到 IslandAsk"
    static let supportedModes: IntentModes = .background   // iOS 26 起 openAppWhenRun 已弃用
    @Parameter(title: "链接") var url: URL?
    @Parameter(title: "附注") var text: String?
    func perform() async throws -> some IntentResult & ProvidesDialog   // 返回「已收藏：<标题>」
}
```

- 用户新建快捷指令「收藏」，在快捷指令详情里打开「在共享表单中显示」，接收 URL 和文本，动作为「收藏到 IslandAsk」。
- 流程：立即建卡（origin = share，sourceURL，sourceURLState = shared，organizeStatus = pending，isSaved = true）→ 抓取链接元数据 → 快速档整理（无截图，输入为网页标题、描述、用户附注）→ 写回卡片 → 返回 dialog。
- 输入：只认 http / https 链接；url 为空时从文字里找第一个链接；文字去掉链接本身后剩下的部分存为附注（原文保存，不用模型改写）。文字里没有链接时照常建卡（纯文字收藏）。链接和文字都为空时不建卡。
- 元数据：`LinkPresentation` 的 `LPMetadataProvider` 取标题，取不到时用 `og:title`、`<title>` 兜底；描述用 URLSession 读页面的 `og:description`（最多读 512KB，读到 `</head>` 即停）。两路并行。`LPMetadataProvider` 能否在后台 Intent 里使用需要核对官方文档。
- 微信、小红书这类 App 分享出的常是短链或需要登录的页面，抓不到内容时只用标题和附注整理。抓取失败不算整理失败。
- 时间预算：Intent 链路元数据最多 5 秒，整个流程最多约 15 秒，大模型不重试；超时先返回「已收藏，回到 App 后整理」，请求在后台任务里继续。回前台补整理和手动重新整理时元数据最多 8 秒，大模型可重试 1 次。
- 整理失败分两种：网络类（断网、超时、5xx、429、被取消）保留为 pending，下次 App 回到前台时由 `SessionCoordinator` 补整理；其他（没配 Key、地址错、4xx、格式错误、被截断）标为 failed，在 App 里手动「重新整理」，避免每次回前台白白重试。
- 界面：「整理中」只在请求真正进行时显示，其余 pending 显示「待整理」。

**阶段 2：Share Extension**

- 新建 target `IslandAskShare`，开启 App Group。激活规则支持 URL 和纯文本（`NSExtensionActivationRule` 的具体写法需要核对官方文档）。
- 界面只有一个确认面板：标题预览、可选的附注输入框、「收藏」按钮。
- 扩展只把 `{id, url, title, text, createdAt}` 写进 App Group 的 `inbox/<id>.json`，不调大模型、不写 SwiftData。
- 主 App 在回到前台、每次 Intent 运行时，由 `SessionCoordinator` 导入 inbox：建卡，成功写库后再删除对应文件（写库失败时保留文件，下次再导）；整理统一由 `organizePendingShareCards` 在回到前台时进行。
  - 回到前台：导入，然后整理全部 pending 的分享卡片。
  - `SaveLinkIntent`：导入只建卡，不在 Intent 的时限里整理这些卡片。
  - `AskAboutScreenIntent`：等录音开始后再导入，只建卡、不在后台整理，不能拖慢按键后的响应。
- 扩展附带的标题先记为卡片的 sourceTitle：未整理时列表显示它，整理时作为网页标题的兜底。

**M-C2 补充：正文摘录和图片**（真机测试发现很多链接只抓到标题，摘要没内容可写；链接卡片在列表里没有图片）

- 页面读到 512KB 上限（不再在 `</head>` 处停），请求头用手机 Safari 的 User-Agent（默认的 CFNetwork UA 会被部分网站当成爬虫）。到上限还没看到正文容器（`id="js_content"`）时继续读，最多 2MB，找到后再读 150KB 就停（真机样例：微信公众号正文从第 630KB 开始）。
- 网页标题去掉末尾的站名后缀（「 - rednote」「 - 小红书」「 - 知乎」等）。
- 正文摘录：微信公众号取 `id="js_content"` 的容器，其次 `<article>`、`<main>`、`<body>`；去掉 script、style、导航、页眉页脚等，最多 3000 字，和标题、描述、附注一起发给快速档。不足 40 字的当作没有。
- 封面图取 `og:image` / `twitter:image`（微信公众号退回脚本里的 `msg_cdn_url`），网站图标取 `apple-touch-icon`，其次 `icon`，都没有时试 `/favicon.ico`。只用网站自己声明的图片，不内置任何 App 的图标素材。
- 图片与大模型请求并行下载（最多 3MB、8 秒），不占 Intent 的时限；封面长边缩到 600px 存 JPEG，图标缩到 128px 存 PNG，删除卡片时一起删除。
- 回到前台时为还没取过图片的链接卡片补取，每次最多 10 张。
- 列表缩略图：有封面图显示封面图，否则浅色底上放网站图标，都没有时显示链接符号。卡片详情：顶部显示封面大图，来源一行显示网站图标和域名。
- 文字很少（正文摘录不到 500 字、描述不到 100 字）又有封面图时，先下载封面图（长边 1280px）随文字一起发给快速档识图；Intent 链路最多等 4 秒，前台最多 8 秒，等不到就只用文字。小红书笔记的内容多在图里，页面能提取的只有评论和推荐。
- 网站拦截程序读取时（状态码 401、403、412、429、451、567，跳转到访客验证、验证码类主机，或标题、描述、正文全都拿不到），卡片记 `linkBlocked = true`，详情页提示「这个网站不允许直接读取内容」，建议在原 App 里按键截屏收藏。真机样例：知乎 403、酷安 567、微博跳转访客验证。
- 不做绕过：不用隐藏的 WKWebView 执行网站的验证脚本，不调用网站未公开的接口。
- 链接卡片详情的「更多」菜单有「重新整理」，任何状态都可用（已整理的也可以）：确认后重新读取网页和图片，标题、摘要、标签被新结果覆盖，附注保留。

**剪贴板入口**（小红书、微信的分享面板不调起系统分享菜单，Share Extension 和共享表单都用不了）

- 用户在这些 App 里点「复制链接」，回到本 App。收藏库最上方显示提示条「剪贴板里有链接」，带系统 `PasteButton`「收藏」和「✕」。
- 检测只用 `UIPasteboard.detectedPatterns(for: [\.probableWebURL])`，不读剪贴板内容（读内容会弹「是否允许粘贴」）；所以收藏前提示条不显示是哪个链接。`PasteButton` 由系统粘贴，不弹框。
- 收藏、点「✕」过的剪贴板（按 `changeCount` 记）不再提示，内容变了才再出现；本 App 在前台时自己复制造成的变化直接记为已处理。
- 同一个链接已有卡片时不新建，提示条显示「这个链接已收藏过」，可以点开那张卡片（剪贴板入口最容易重复；分享入口仍不去重）。
- 建卡后立即返回，整理按前台规则（元数据 8 秒、可重试）。
- 所有入口的分享文字都去掉已知的宣传语和口令（目前覆盖小红书：「复制本条信息，打开【小红书】App查看精彩内容！」「| 小红书 - 你的生活指南」、表情包住的口令），附注和发给模型的都是干净的内容；认不出的文字原样保留。

### 6.14 检索与找回（M-C3）

- 本地搜索：在标题、摘要、标签、附注、OCR 文字、转录文字、翻译、关键信息中做文本包含匹配（另含来源平台、来源标题、链接和问答）。收藏库的搜索框已先实现（M-C2 时修复）：按空白拆词，每个词都要匹配；以 `#` 或 `＃` 开头的词只匹配标签（标签存储时不带 #）。卡片详情里点标签回到收藏库，搜索框填入「#标签」，同时切到「全部」、清掉类型筛选。
- 关键字高亮（M-C3）：搜索结果的标题、摘要、标签里，命中的关键字加淡黄底色并加粗（`#标签` 只在标签里高亮）。标题和摘要里都没有命中时，摘要换成命中处前后的一小段（来自附注、关键信息、转录、回答、OCR 文字、翻译、来源），让用户知道为什么搜到这张卡片。
- 自然语言搜索：只在前台调用，提示词和请求参数见 6.9。
  - 触发：和普通搜索合在一起，没有单独的按钮。按回车时，本地匹配为空，或输入像一句话（不含 `#标签`，中文至少 6 个字，或至少 3 个词），自动按意思再搜一次。不逐字触发。
  - 候选：当前分段和类型筛选下最近 200 张卡片，每张发「序号 + 收藏日期 + 类型 + 标题 + 标签 + 摘要首句」，user 消息里带今天的日期。用本地序号代替卡片 id（省 token，模型也不会抄错）；带日期是为了理解「上个月」这类说法。模型返回序号列表，本地换回卡片。
  - 显示：结果作为「最相关」一组排在最前，本地结果里去掉重复的卡片。本地没匹配到时，搜索中显示「正在搜索…」，没找到再显示无结果；失败时只留本地结果（记日志，不提示）。搜索词变了就作废旧结果；换了分段或类型筛选，按新范围重搜。
- Core Spotlight：收藏库「全部」里的卡片都索引（含没收藏的提问卡片），卡片创建、整理完成、编辑、删除（含过期清理）时同步 `CSSearchableItem`（标题、摘要、标签和类型作为关键词、缩略图：截图 → 封面图 → 网站图标），不过期。
  - 同步入口统一在 `AppDatabase.save`：保存前收集这次插入、修改、删除的卡片，保存成功后合并 1 秒内的改动再写索引。
  - 第一次运行（或索引格式版本号变了）时，回到前台全量重建一次：延后 5 秒、后台低优先级进行，主线程上只分批（每批 20 张）读卡片字段，生成缩略图和写索引都在主线程之外，不影响启动和滑动。
  - 点开系统搜索结果：系统以 `CSSearchableItemActionType` 的 `NSUserActivity` 打开 App（不经过 URL），按 `islandask://card/<id>` 同样的路由进入卡片详情。
- 对卡片提问：所有卡片的详情底部都有输入框（收藏卡片、分享卡片也有）。还没有会话的卡片（如分享得到的）首次提问时创建同 id 的 `AskSession`（status = answered，不自动做深度回答），首次提问失败时连同会话一起撤回；之后同现有追问（深度档流式）。没有截图的卡片把卡片信息作为上下文（见 6.9）。分享卡片正在整理时不能提问。

### 6.15 Agent 工具调用（M-C4）

- 只在 App 前台运行，使用深度档（开思考、流式）加 function calling。
- 工具约定：每个工具有名称、描述、参数的 JSON Schema、`isReadOnly`，以及 `perform(argumentsJSON:) async throws -> String`，由注册表统一提供给 `LLMClient`。
- 首批工具：

| 工具 | 类型 | 作用 |
| --- | --- | --- |
| `search_cards(query)` | 只读 | 检索收藏库，返回卡片摘要列表 |
| `get_card(id)` | 只读 | 读取一张卡片的完整内容（含 OCR 文字） |
| `web_search(query)` | 只读 | 联网搜索，返回标题、链接、摘要 |
| `fetch_url(url)` | 只读 | 读取网页正文摘录 |
| `propose_source_link(card_id, url, reason)` | 写（待确认） | 为截图卡片提出原链接建议，卡片 sourceURLState = guessed，用户确认后改为 confirmed |

- 规则：只读工具自动执行；写操作类工具只产生待确认的建议，界面上由用户确认后才经 `SessionCoordinator` 写库。单次任务最多 8 轮工具调用、总时长 120 秒，超出时让模型基于已有结果作答。工具出错时把错误文本返回给模型，不中断循环。
- 使用场景：卡片详情的深度回答和追问（需要时联网查证）、卡片详情的「找回原链接」按钮、收藏库的「问问我的收藏」。
- 联网搜索服务待选定，Key 存 Keychain，在设置页填写。
- 需要核对官方文档：DeepSeek 思考模式下带 tools 时，工具循环内是否必须回传 `reasoning_content`；JSON 模式能否与 tools 同时使用。
- 日志新增 category `agent`：记录每轮工具调用的名称、参数摘要、耗时和结果长度。

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

收藏方向的里程碑在 M4 当前的改动真机测试通过并提交后开始，按顺序推进。

6. **M-C1 收藏主链路（4–5 天）**
   - 内容：`Card` 模型和旧会话补建卡片、快速档提示词与 `LLMAnswer` 扩展、语音分流、不说话即收藏、灵动岛 collect 布局、`SaveCardIntent` / `SwitchToAskIntent`、收藏库首页（含多选批量删除、收藏、加标签）、卡片详情、重新整理。
   - 完成标准：在微信里按键不说话 → 灵动岛显示「已收藏」和标题；说「这家店周末去，记一下」→ 收藏成功，附注为「周末去」；提问照常，回答后点「收藏」生效；外文截图的卡片带中文翻译；收藏库里能看到所有卡片，旧会话都已补建成卡片。
7. **M-C2 链接收藏（阶段 1 约 1 天，阶段 2 约 2–3 天）**
   - 内容：阶段 1 `SaveLinkIntent` 加快捷指令共享表单；阶段 2 Share Extension 加 inbox 导入；剪贴板入口（小红书、微信）。
   - 完成标准：在 Safari 通过分享菜单收藏，小红书、微信「复制链接」后回到 App 收藏，卡片带原链接和标题，附注里没有宣传语；断网时收藏，卡片保留为待整理，联网后回到 App 自动补整理。
8. **M-C3 检索与找回（2–3 天）**
   - 内容：本地搜索、自然语言搜索、Core Spotlight、对卡片提问。
   - 完成标准：用「上个月存的那家咖啡店」能找到对应卡片；系统搜索能搜到卡片标题并跳到详情。
9. **M-C4 Agent 工具调用（4–6 天）**
   - 内容：工具协议和注册表、前台工具调用循环、联网搜索、找回原链接、「问问我的收藏」。另外评估按 Action Button 时读取剪贴板里的链接挂到截图卡片上（M-C2 时决定推迟：每次按键可能弹「是否允许粘贴」，且剪贴板里可能是无关的旧链接；需要借助 guessed / confirmed 的确认界面）。
   - 完成标准：对需要最新信息的问题，深度回答会先搜索并给出来源；截图卡片点「找回原链接」能给出候选，确认后保存。

## 8. 验收测试清单

全部在真机上测试，模拟器不支持 Action Button 和灵动岛的真实行为。

**核心链路**

- [ ] 在 Safari、微信、相册三个 App 中分别触发，均不跳转，灵动岛正常出现
- [ ] 通过 Action Button 触发与在快捷指令 App 里手动运行，行为一致
- [ ] 截图内容正确：是触发瞬间的画面，不是本 App 的画面
- [ ] 实时转录延迟可接受（说完到文字出现约 1 秒内）
- [ ] 静音 1.5 秒自动结束；无截图时 6 秒不说话自动取消
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

**收藏（M-C 系列）**

- [ ] 按键不说话：3 秒后自动收藏，灵动岛显示「已收藏」和标题
- [ ] 按键后正常速度开口提问：不会被误判成收藏（记录按键到第一个字出现的耗时）
- [ ] 多选：选中多张卡片批量删除、批量收藏 / 取消收藏、批量加标签，结果正确；批量删除前有确认
- [ ] 说「收藏」「存一下」「记一下」「以后看」：判为收藏；说普通问题：判为提问；「这个怎么样，帮我存一下」：判为 both
- [ ] 误判后点「改为提问」：灵动岛给出回答，卡片取消收藏（记录后台能否跑完）
- [ ] 提问回答后点「收藏」：收藏库「收藏」分段里出现这张卡片
- [ ] 断网时收藏：卡片和截图都在，状态为整理失败，联网后可重新整理
- [ ] 外文长文截图：有中文翻译，没有被截断报错（记录 completion_tokens 和耗时）
- [ ] 从说完到「已收藏」出现，记录实际耗时，与普通提问对比
- [ ] 升级后旧会话全部补建为卡片，内容不丢
- [ ] 删除卡片：截图、录音、会话一并删除，Spotlight 里也消失（M-C3）
- [ ] 分享链接（M-C2）：Safari 走分享菜单，微信、小红书走「复制链接 → 回到 App 收藏」，各试一次，记录哪些能抓到标题和描述
- [ ] 剪贴板入口（M-C2）：复制链接后回到 App 出现提示条；点「✕」或收藏后不再出现；同一链接再收藏提示「已收藏过」；附注里没有小红书宣传语

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
| 语音意图误判（该收藏的判成提问，或反过来） | 日志记录转录文字和返回的 intent，整理误判样例 | 灵动岛上的「收藏」和「改为提问」按钮纠正；样例多时调整提示词里的指令词列表 |
| 快速档输出变长（卡片字段、翻译）导致变慢或被截断 | 日志看 completion_tokens、耗时、`finish_reason` | 翻译只给开头、完整翻译移到前台；必要时卡片整理拆成第二次请求，在 App 回到前台时补做 |
| 「改为提问」在后台跑不完 | 日志看后台任务是否过期 | 转为 failed 并提示点开 App，App 内用快速档重问 |
| 分享扩展内存超限被杀 | 扩展里不做图片处理和网络请求 | 只写 inbox，所有处理交给主 App |
| 搜不到截图内容的原链接 | 记录 source_platform 和搜索结果 | 卡片保留来源平台和标题，不强行给链接；需要链接时提示用户改用分享入口 |

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
