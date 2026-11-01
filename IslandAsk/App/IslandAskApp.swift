//
//  IslandAskApp.swift
//  IslandAsk
//
//  App 入口。M0 的根视图是临时验证用的 SessionListView（M3 会替换为历史列表）。
//

import SwiftUI

@main
struct IslandAskApp: App {
    var body: some Scene {
        WindowGroup {
            SessionListView()
        }
    }
}
