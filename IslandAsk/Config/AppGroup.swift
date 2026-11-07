//
//  AppGroup.swift
//  IslandAsk
//
//  App Group 容器（SPEC 第 5 节）：截图、录音、SwiftData 数据库、分享 inbox（M-C2）都放这里。
//  所有 target 都要在 Signing & Capabilities 里开启同一个 App Group。
//  M-C2 阶段 2 起这个文件也属于 IslandAskShare target：只依赖 Foundation 和 os，不引用主 App 的类型；
//  日志 subsystem 写死为主 App 的 bundle id，真机在 Console 里用同一个 subsystem 就能看到扩展的日志。
//

import Foundation
import os

nonisolated enum AppGroup {

    static let identifier = "group.com.wentao.islandask"

    /// 写死而不用 Bundle.main.bundleIdentifier：扩展里那是扩展自己的 id。
    static let logSubsystem = "com.wentao.IslandAsk"

    private static func makeLogger() -> Logger {
        Logger(subsystem: logSubsystem, category: "coordinator")
    }

    /// 主 App 用：App Group 容器根目录。没配好 entitlement 时打 error 日志并回退到 Documents，
    /// 让 App 仍可用（真机排查时看日志里的 "app group container unavailable"）。
    static func containerURL() throws -> URL {
        if let url = sharedContainerURL {
            return url
        }
        makeLogger().error(
            "app group container unavailable id=\(identifier, privacy: .public); falling back to Documents"
        )
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw AppGroupError.documentsDirectoryUnavailable
        }
        return documents
    }

    /// 只要真正的共享容器，拿不到就抛错、不回退。分享 inbox 用：扩展的 Documents 在扩展自己的沙盒里，
    /// 主 App 读不到，回退过去数据会悄悄丢掉。
    static func requireSharedContainerURL() throws -> URL {
        guard let url = sharedContainerURL else {
            makeLogger().error("app group container unavailable id=\(identifier, privacy: .public); no fallback")
            throw AppGroupError.containerUnavailable
        }
        return url
    }

    static var isContainerAvailable: Bool {
        sharedContainerURL != nil
    }

    /// 进程内只查一次：列表每一行的截图地址都要用它，每次都问系统要容器路径不划算。
    /// 容器路径在进程生命周期里不会变（重装后才变，而重装会重启进程）。
    private static let sharedContainerURL: URL? =
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
}

nonisolated enum AppGroupError: LocalizedError {
    case containerUnavailable
    case documentsDirectoryUnavailable

    var errorDescription: String? {
        switch self {
        case .containerUnavailable:
            return "App Group 容器不可用"
        case .documentsDirectoryUnavailable:
            return "找不到 App 的 Documents 目录"
        }
    }
}
