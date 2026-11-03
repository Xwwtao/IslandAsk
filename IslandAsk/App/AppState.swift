//
//  AppState.swift
//  IslandAsk
//
//  App 级 UI 状态：导航路径（深链 push 会话页）、引导完成前暂存的深链、前台音频预热结果。
//

import Foundation
import Observation

enum AppRoute: Hashable {
    case session(UUID)
    case settings
}

@MainActor
@Observable
final class AppState {
    var path: [AppRoute] = []
    /// 引导还没完成时收到的深链，进入主界面后再打开。
    var pendingSessionID: UUID?
    /// 前台是否成功预热过录音会话（后台起录的前置条件），设置页「状态」里显示。
    var audioSessionPrimed = false

    func openSession(_ id: UUID) {
        path = [.session(id)]
    }
}
