//
//  PermissionManager.swift
//  IslandAsk
//
//  M0 只做两件事：首次打开 App 时申请麦克风权限、检查 Live Activity 是否被允许。
//  语音识别权限和转录模型下载按里程碑安排放到 M1（SPEC 第 6.1 节）。
//

import AVFAudio
import ActivityKit
import Foundation
import UIKit
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
    category: "coordinator"
)

enum PermissionManager {

    static var microphoneStatus: AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    /// 首次打开 App 时调用：未决定则弹系统授权框，已决定则只读状态。
    @discardableResult
    static func requestMicrophoneIfNeeded() async -> Bool {
        switch microphoneStatus {
        case .granted:
            logger.info("microphone permission already granted")
            return true
        case .denied:
            logger.error("microphone permission denied")
            return false
        case .undetermined:
            logger.info("requesting microphone permission")
            let granted = await AVAudioApplication.requestRecordPermission()
            if granted {
                logger.info("microphone permission granted")
            } else {
                logger.error("microphone permission denied by user")
            }
            return granted
        @unknown default:
            logger.error("microphone permission unknown status")
            return false
        }
    }

    /// 用户在系统设置里关掉 Live Activity 后，这里返回 false。
    static var areLiveActivitiesEnabled: Bool {
        let enabled = ActivityAuthorizationInfo().areActivitiesEnabled
        if enabled {
            logger.info("live activities enabled")
        } else {
            logger.error("live activities disabled")
        }
        return enabled
    }

    /// 跳到本 App 的系统设置页（麦克风、实时活动开关都在那里）。
    static var appSettingsURL: URL? {
        URL(string: UIApplication.openSettingsURLString)
    }
}
