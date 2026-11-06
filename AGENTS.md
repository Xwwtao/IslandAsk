# IslandAsk

按下 iPhone 的 Action Button，不离开当前 App，就能在灵动岛里用语音对当前屏幕内容提问的 iOS App。

## 先读规格

- 完整规格见 `docs/SPEC.md`。每次开始任务前，先读与当前里程碑相关的章节，至少包括第 2、4、6、7 节。
- 规格里的两张架构图在导出时被省略了，以文字描述为准。

## 硬性约束

- iOS 26+，Swift 6（严格并发检查），SwiftUI。
- 只用系统框架，不引入任何第三方依赖。
- 不修改 `IslandAsk.xcodeproj/project.pbxproj`、Info.plist、entitlements 文件。需要改工程配置时，停下来告诉我具体操作步骤，由我在 Xcode 里完成。
- `docs/SPEC.md` 可以有限修改：
  - 可以直接改：我明确要求的修改；按已实现的代码同步文件结构、字段名、接口签名、日志 category 等实现细节；更正错别字和与代码不一致的描述。改完在汇报里列出改了哪些章节。
  - 不能自行改：产品方向、交互流程、里程碑范围、第 2 节的约束与决策。发现规格与实际 API 冲突或不可行时，先停下来说明问题，不要自行换方案，也不要先改 SPEC 再实现。
- 只做我指定的里程碑，不实现范围以外的功能。

## 文件放置（与 SPEC 第 3 节不同时，以这里为准）

- 工程使用 Xcode 文件夹同步：在对应文件夹里新建 `.swift` 文件，会自动加入主 App target。
- `Shared/` 下的文件是在 pbxproj 里逐个登记（membershipExceptions）才属于 widget target 的：新加 Shared 文件时，要告诉我去 Xcode 里勾选 IslandAskWidget 的 target membership。
- `IslandAsk/Shared/` 同时属于 IslandAsk 和 IslandAskWidget 两个 target。以下文件放在这里：
  - `AskActivityAttributes.swift`
  - `StopAskIntent.swift`
  - `DismissAskIntent.swift`
- Shared 里的文件也会被 widget 编译。凡是引用主 App 才有的类型（如 `SessionCoordinator`）的代码，必须用 `#if !WIDGET_EXTENSION ... #endif` 包起来；widget target 已定义 `WIDGET_EXTENSION` 编译条件。
- `AskAboutScreenIntent.swift` 只能放在 `IslandAsk/Intents/`，只属于主 App。
- Widget 代码放在 `IslandAskWidget/`。Xcode 模板生成的 Live Activity 示例文件，要替换为使用 `Shared/AskActivityAttributes` 的 `AskLiveActivity.swift`，并删除模板自带的 attributes 定义。
- 其余文件按 SPEC 第 3 节的目录放置（第 3 节已按 M3 实际结构更新）。
- `Config/Secrets.swift` 已废弃（gitignore，可能含明文 Key），不要读取、引用或修改它。API Key 存 Keychain，由设置页填写。

## 大模型调用约定

- 灵动岛链路（Intent 后台）只用快速档：`thinking: disabled`、JSON 模式。不要在后台链路开思考：单次十几秒以上，会被截断或超出后台保活时间（M3 真机已复现）。
- 深度思考（流式）只在 App 前台使用：会话页的深度回答和追问。
- 只有 `SessionCoordinator` 写 SwiftData；新增模型字段一律用可选类型，靠自动轻量迁移。

## 编译检查（每次改完代码必须执行）

```
xcodebuild -project IslandAsk.xcodeproj -scheme IslandAsk \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)"
```

- 看到 `BUILD SUCCEEDED` 才算完成。
- 有报错自己修。连续修 3 轮仍未通过，停下来把完整报错和你的判断发给我。

## 使用较新的 API

- `SpeechAnalyzer`、`SpeechTranscriber`、`AudioRecordingIntent`、`LiveActivityIntent` 等较新的 API，不确定签名时，在代码里标注 `// TODO: 核对官方文档`，并在回复里列出来。禁止编造方法名或参数。
- 我贴给你的 Apple 官方文档内容，优先于你的记忆。

## 日志

- 统一使用 `os.Logger`，subsystem 取 `Bundle.main.bundleIdentifier`，category 按模块划分：`intent`、`coordinator`、`audio`、`transcription`、`llm`、`activity`，M-C4 起加 `agent`。
- 链路上每个关键动作的开始、成功、失败都要打日志，失败时带上错误信息，方便我在真机上排查。

## 工作方式

1. 先用计划模式列出要新建或修改的文件、每个文件的职责、实现顺序，等我确认后再写代码。
2. 写完代码运行编译检查，直到通过。
3. 完成时按以下格式汇报：
   - 新建或修改了哪些文件
   - 对照 SPEC 第 8 节：哪些已在代码中处理，哪些需要我在真机上验证
   - 需要我在 Xcode 里手动完成的配置
   - 标注了 `TODO: 核对官方文档` 的位置
4. 不要执行 `git commit`，由我真机测试通过后提交。
