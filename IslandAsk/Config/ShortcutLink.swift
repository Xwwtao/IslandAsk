//
//  ShortcutLink.swift
//  IslandAsk
//
//  「屏幕提问」快捷指令的 iCloud 分享链接（SPEC 第 6.12 节：一键添加）。
//  生成方法：在快捷指令 App 里长按「屏幕提问」→ 共享 → 拷贝 iCloud 链接，填到下面。
//  链接不是密钥，可以提交。为 nil 时引导页只显示手动设置步骤。
//

import Foundation

nonisolated enum ShortcutLink {

    /// 形如 https://www.icloud.com/shortcuts/<id>。
    static let iCloudURL: URL? = URL(string: "https://www.icloud.com/shortcuts/aa326825abdb42cf915afb364a4fe3bd")

    /// 打开快捷指令 App（手动创建时用）。
    static let shortcutsAppURL = URL(string: "shortcuts://")
}
