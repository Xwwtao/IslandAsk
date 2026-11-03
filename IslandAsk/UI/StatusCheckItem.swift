//
//  StatusCheckItem.swift
//  IslandAsk
//
//  设置页「状态」里的一项检查（麦克风、语音识别、转录模型、实时活动、API Key）。fix 为 nil 表示正常。
//

import SwiftUI

struct StatusCheckItem: Identifiable {

    enum Fix {
        case systemSettings
        case downloadModel
        case fillAPIKey

        /// VoiceOver 提示：点按方块后会发生什么（界面上不显示）。
        var title: String {
            switch self {
            case .systemSettings: return "去设置"
            case .downloadModel: return "点按下载"
            case .fillAPIKey: return "点按填写"
            }
        }
    }

    let id: String
    let title: String
    let systemName: String
    let color: Color
    let detail: String
    let fix: Fix?
}
