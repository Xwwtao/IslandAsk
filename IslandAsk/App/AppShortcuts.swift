//
//  AppShortcuts.swift
//  IslandAsk
//
//  用 AppShortcutsProvider 注册 AskAboutScreenIntent，使其出现在快捷指令 App / Siri / 聚焦里。
//  只属于主 App target（SPEC 第 6.2 节）。
//

import AppIntents

struct IslandAskAppShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskAboutScreenIntent(),
            phrases: [
                "用 \(.applicationName) 对屏幕提问",
                "用 \(.applicationName) 问一下这个屏幕",
            ],
            shortTitle: "屏幕提问",
            systemImageName: "text.viewfinder"
        )
    }
}
