# 拾屏（Beachcomb）隐私政策

生效日期：2026 年 11 月 10 日

拾屏是一款收藏和 AI 整理工具。我们（开发者）不运营任何服务器，不收集、不存储、也无法查看你的任何数据。

## 存在你设备上的数据

以下内容只保存在你的 iPhone 上，不会上传给开发者：

- 收藏的卡片：截图、标题、摘要、标签、附注、链接
- 提问记录：语音录音、转写文字、AI 回答
- 截图中识别出的文字
- 设置项；你填写的 API Key 保存在系统钥匙串中

卡片会加入 iPhone 的系统搜索（Spotlight）索引，方便你在系统搜索里找到。这个索引也只存在你的设备上。

## 在设备上完成的处理

- 语音转文字：使用 Apple 的设备端语音识别，录音不会上传。
- 截图文字识别：使用 Apple 的 Vision 框架，在设备上完成。

## 发送给第三方的数据

整理卡片和回答提问时，App 会把以下内容发送到你在设置页配置的大模型服务：

- 截图
- 截图中识别出的文字
- 你的问题或附注（语音转写后的文字，不发送录音）

默认的服务地址是 DeepSeek（https://api.deepseek.com ），你也可以改成其他兼容 OpenAI 接口的服务。请求使用你自己填写的 API Key，直接从你的设备发出，不经过开发者的服务器。这部分数据如何处理，以你所选服务商的隐私政策为准，例如 DeepSeek 隐私政策：https://www.deepseek.com/ 。

收藏链接时，App 会直接访问该链接，读取网页的标题、描述和预览图。

## 我们不做的事

- 不使用任何第三方统计、广告或追踪 SDK
- 不追踪你在其他 App 或网站上的行为
- 不出售或共享你的数据

## 权限

- 麦克风：录下你对屏幕内容的提问或附注
- 语音识别：把语音实时转成文字

你可以随时在 iPhone 的「设置」中关闭这些权限。

## 删除数据

- 在 App 内左滑即可删除单张卡片。
- 未收藏的问答会按你在设置中选择的天数自动清理。
- 删除 App 会删除上述所有本地数据。API Key 存在钥匙串中，删除 App 前可以先在设置页清空。

## 儿童

本 App 不面向 13 岁以下儿童，也不会有意收集儿童的信息。

## 变更

本政策更新时，我们会修改本页面并更新生效日期。

## 联系方式

如有问题，请联系：[你的联系邮箱]

---

# Beachcomb Privacy Policy

Effective date: November 10, 2026

Beachcomb is a tool for saving and organizing screen content with AI. The developer runs no servers and does not collect, store, or have access to any of your data.

**On your device.** Saved cards (screenshots, titles, summaries, tags, notes, links), questions (voice recordings, transcripts, AI answers), text recognized from screenshots, and settings are stored only on your iPhone. The API key you enter is stored in the system Keychain. Cards are added to the on-device Spotlight index so you can find them in system search.

**Processed on device.** Speech-to-text uses Apple's on-device speech recognition; recordings are never uploaded. Text recognition in screenshots uses Apple's Vision framework on device.

**Sent to third parties.** To organize cards and answer questions, the app sends the screenshot, text recognized from it, and your question or note (as transcribed text, not audio) to the AI service configured in Settings. The default is DeepSeek (https://api.deepseek.com); you can change it to any OpenAI-compatible service. Requests are sent directly from your device using your own API key and never pass through the developer's servers. That data is governed by your chosen provider's privacy policy. When you save a link, the app fetches that page to read its title, description, and preview image.

**We do not** use any third-party analytics, advertising, or tracking SDKs, track you across apps or websites, or sell or share your data.

**Permissions.** Microphone: to record your question or note. Speech Recognition: to transcribe your voice. You can turn these off at any time in iOS Settings.

**Deleting data.** Swipe left on a card to delete it. Unsaved Q&A is removed automatically after the number of days you choose in Settings. Deleting the app removes all local data; you can clear your API key in Settings first, since it is stored in the Keychain.

**Children.** The app is not directed to children under 13 and does not knowingly collect their information.

**Changes.** When this policy is updated, this page and its effective date will be updated.

**Contact:** [your contact email]
