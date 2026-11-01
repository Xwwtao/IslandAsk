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
7. 用户点击灵动岛 → 进入 App 的这条会话页，查看截图、完整回答，并可继续追问。

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

- **大模型输出两份内容**：一份不超过 40 字的摘要放进灵动岛，一份完整回答存进 App。
- **录音结束后要保住进程**：音频会话停止后 App 可能很快被挂起，大模型请求必须包在 `beginBackgroundTask` 里，或者等回答返回后再停止音频会话。

## 3. 系统架构

工程分两个 target：主 App 进程负责全部逻辑，Widget 扩展只负责渲染灵动岛和锁屏视图。

&#91;embedded content: 系统架构 · 两个 target，一个调度中心\]

`AskAboutScreenIntent` 只是入口；`SessionCoordinator` 串起录音、转录、截图和大模型，并且是唯一更新 Live Activity 和数据库的地方。灵动岛上的停止按钮通过 `StopAskIntent` 回调到主 App 进程。

**文件结构**

```
IslandAsk/                           // 主 App target
├── App/
│   ├── IslandAskApp.swift           // 入口，处理 islandask:// 深链
│   └── AppShortcuts.swift           // AppShortcutsProvider
├── Intents/
│   ├── AskAboutScreenIntent.swift
│   ├── StopAskIntent.swift          // 两个 target 共享
│   └── DismissAskIntent.swift       // 两个 target 共享
├── Session/
│   └── SessionCoordinator.swift
├── Services/
│   ├── PermissionManager.swift
│   ├── AudioCaptureService.swift
│   ├── SilenceDetector.swift
│   ├── TranscriptionService.swift
│   ├── ScreenshotStore.swift
│   └── LLMClient.swift
├── Shared/
│   └── AskActivityAttributes.swift  // 两个 target 共享
├── Data/
│   └── Models.swift                 // AskSession, ChatMessage
└── UI/
    ├── OnboardingView.swift
    ├── HistoryView.swift
    ├── SessionDetailView.swift
    └── SettingsView.swift

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
4. `ScreenshotStore` 把截图存到 App Group 容器，返回文件 URL。
5. `SessionCoordinator.start` 依次执行：
   1. 结束上一个仍在显示的 Live Activity。
   2. 用 `Activity.request` 启动新的 Live Activity（phase = listening）。
   3. 配置并激活音频会话。
   4. 启动 `AVAudioEngine`，开始转录和静音检测。
   5. 写入 `AskSession`（status = listening）。
6. `perform()` 返回，快捷指令结束；App 依靠后台音频模式继续运行。
7. 转录结果每秒最多更新一次 Live Activity 的 `transcriptTail`。
8. 静音检测或 `StopAskIntent` 触发 `stopListening`：停止 engine，取最终转录文字，更新 phase = thinking。
9. 调用 `beginBackgroundTask`，`LLMClient` 发送压缩后的截图和转录文字。
10. 收到 JSON 后：保存 summary 和 answer → 带 `AlertConfiguration` 更新 phase = answered → 停用音频会话 → `endBackgroundTask`。
11. 用户点击灵动岛 → 打开 `islandask://session/<id>` → App 显示该会话页，并结束这个 Live Activity。

## 5. 工程配置

最低系统版本定为 iOS 26，以便直接使用 SpeechAnalyzer；设备需为带 Action Button 和灵动岛的 iPhone（15 Pro 及以后）。

**Targets**

| Target | 类型 | 职责 |
| --- | --- | --- |
| IslandAsk | iOS App | 主 App：Intent、录音、转录、大模型调用、数据存储、UI |
| IslandAskWidget | Widget Extension | Live Activity 的灵动岛与锁屏视图 |

**Capabilities（两个 target 按需开启）**

- Background Modes → Audio, AirPlay, and Picture in Picture（主 App）
- App Groups：`group.<bundle-prefix>.islandask`（两个 target 都开，用于共享截图路径和会话数据）
- Push Notifications：第一版不需要，后续做服务端推送更新时再开

**主 App 的 Info.plist**

| Key | 值 |
| --- | --- |
| `NSMicrophoneUsageDescription` | 用于录下你对屏幕内容的提问 |
| `NSSpeechRecognitionUsageDescription` | 用于把你的语音实时转成文字 |
| `NSSupportsLiveActivities` | YES |
| `NSSupportsLiveActivitiesFrequentUpdates` | YES |
| `CFBundleURLTypes` | URL scheme `islandask`，用于灵动岛点击跳转 |

**共享文件**：`AskActivityAttributes.swift` 和 `StopAskIntent.swift` 必须同时加入两个 target 的 Target Membership。

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

| 规则 | 默认值 | 行为 |
| --- | --- | --- |
| 开始说话的判定 | 音量 RMS 高于 -40 dB | 标记已开口 |
| 说完的判定 | 已开口后连续 1.5 秒低于 -45 dB | 触发 `stopListening` |
| 一直不说话 | 6 秒内未开口 | 触发 `cancel`，灵动岛提示「没听到」 |
| 最长录音 | 60 秒 | 强制 `stopListening` |

阈值放进设置页，方便真机调参。

### 6.8 截图处理（ScreenshotStore）

- 原图保存到 App Group 容器：`sessions/<sessionID>.png`。
- 发送给大模型前：长边缩放到 1536 px，转 JPEG（质量 0.75），再转 base64。
- 可选增强（M4）：用 Vision 的文字识别提取截图文字，作为补充上下文一起发送，提高中文小字的识别准确率。

### 6.9 大模型调用（LLMClient）

```swift
protocol LLMProvider {
    func ask(imageJPEG: Data?, question: String, history: [ChatMessage]) async throws -> LLMAnswer
}
struct LLMAnswer: Codable { let summary: String; let answer: String }
```

- 第一版实现 `OpenAICompatibleProvider`（baseURL、apiKey、model 可配置），走 `/chat/completions`，图片以 `image_url` 的 data URI 传入。这样可以切换任意支持 OpenAI 兼容格式的视觉模型，例如 GPT 系列、通义千问 VL。
- 必须选支持图片输入的模型；接入前确认所选服务商的 API 是否接受图片。
- 设置 `response_format` 为 JSON，超时 30 秒，失败重试 1 次。
- 原型阶段 API Key 存 Keychain，由设置页填写；正式发布前改为经自己的服务端代理转发，不在 App 里存 Key。

系统提示词：

```
你是屏幕助手。用户会给你一张手机截图和一个口语化的问题（来自语音转写，可能有错别字）。请结合截图回答。
只输出 JSON：{"summary": "...", "answer": "..."}
summary：不超过 40 个汉字，直接给结论，不寒暄。
answer：完整回答，可使用 Markdown。
如果截图与问题无关或看不清，在 summary 中直接说明。
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
| listening | 麦克风图标 / 计时 | 跳动的麦克风 | 中间两行转录文字；底部「停止」按钮（StopAskIntent） |
| thinking | 截图缩略图标 / 加载动画 | 加载动画 | 一行问题原文 + 「思考中…」 |
| answered | App 图标 / 对勾 | 对勾 | 摘要文字最多 3 行；右上角关闭按钮（DismissAskIntent） |
| failed | 警告图标 / 「失败」 | 警告图标 | 错误说明 + 「再试一次」提示 |

更新规则：

- 转录更新节流为每秒最多 1 次。
- 进入 answered 时，带 `AlertConfiguration` 更新，使展开态自动弹出几秒。
- 整个 Live Activity 设置 `widgetURL(islandask://session/<sessionID>)`，点击跳到会话页。
- answered 状态保持显示，直到用户点关闭、打开 App 查看这条会话，或开始下一次提问时再结束。
- 锁屏视图与展开态内容一致。

### 6.11 数据存储（SwiftData）

```swift
@Model final class AskSession {
    var id: UUID; var createdAt: Date
    var screenshotPath: String?
    var transcript: String
    var summary: String?; var answer: String?
    var status: String          // listening / thinking / answered / failed
    var messages: [ChatMessage] // App 内追问记录
}
@Model final class ChatMessage { var role: String; var content: String; var createdAt: Date }
```

存储位置用 App Group 容器（`ModelConfiguration(groupContainer:)`），方便以后 widget 读取。

### 6.12 App 界面

| 页面 | 内容 |
| --- | --- |
| 首次引导 | 权限申请、模型下载、快捷指令和 Action Button 设置指引 |
| 历史列表 | 按时间倒序，每条显示截图缩略图、问题、摘要 |
| 会话页 | 截图（可放大）、问题原文、完整回答（Markdown 渲染）、底部追问输入框；追问沿用同一张截图和上下文 |
| 设置 | API 地址、Key、模型名、识别语言、静音阈值 |

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
