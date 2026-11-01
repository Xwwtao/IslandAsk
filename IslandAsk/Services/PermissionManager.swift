//
//  PermissionManager.swift
//  IslandAsk
//
//  首次引导要用的权限：麦克风、语音识别、Live Activity 开关（SPEC 第 6.1 节）。
//  转录模型下载不在这里，见 SpeechModelManager（M1）。
//

import AVFAudio
import ActivityKit
import Foundation
import Speech
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

    // MARK: - 语音识别

    /// 语音识别授权状态。Intent 在后台运行时无法弹权限框，必须在首次引导里申请完（SPEC 第 2 节）。
    static var speechRecognitionStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    static var isSpeechRecognitionGranted: Bool {
        speechRecognitionStatus == .authorized
    }

    /// 首次打开 App 时调用：未决定则弹系统授权框，已决定则只读状态。
    @discardableResult
    static func requestSpeechRecognitionIfNeeded() async -> Bool {
        switch speechRecognitionStatus {
        case .authorized:
            logger.info("speech recognition permission already granted")
            return true
        case .denied:
            logger.error("speech recognition permission denied")
            return false
        case .restricted:
            logger.error("speech recognition permission restricted")
            return false
        case .notDetermined:
            logger.info("requesting speech recognition permission")
            let status = await Self.requestSpeechAuthorization()
            if status == .authorized {
                logger.info("speech recognition permission granted")
                return true
            } else {
                logger.error(
                    "speech recognition permission not granted status=\(status.rawValue, privacy: .public)"
                )
                return false
            }
        @unknown default:
            logger.error("speech recognition permission unknown status")
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

    /// SFSpeechRecognizer 的授权回调由 TCC 在非主线程触发。
    /// 闭包必须在 nonisolated 上下文创建（不能继承 @MainActor），否则 Swift 6 运行时会在
    /// 回调时命中 swift_task_isCurrentExecutor -> dispatch_assert_queue_fail（真机已复现的崩溃类型）。
    nonisolated private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
