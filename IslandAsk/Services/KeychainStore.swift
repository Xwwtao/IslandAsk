//
//  KeychainStore.swift
//  IslandAsk
//
//  原型阶段的 API Key 存 Keychain（SPEC 第 6.9 节），由设置页填写。
//  可访问性用 AfterFirstUnlockThisDeviceOnly：Action Button 触发时 App 在后台，也要读得到。
//  日志只记操作结果和 OSStatus，不记 Key 内容。
//

import Foundation
import Security
import os

nonisolated enum KeychainStore {

    static let apiKeyAccount = "llm.apiKey"

    private static var service: String {
        Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk"
    }

    private static func makeLogger() -> Logger {
        Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
            category: "llm"
        )
    }

    private static func baseQuery(account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
    }

    static func read(account: String = apiKeyAccount) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            makeLogger().error("keychain read failed account=\(account, privacy: .public) status=\(status, privacy: .public)")
            return nil
        }
    }

    /// 空字符串等同于删除。
    static func write(_ value: String, account: String = apiKeyAccount) throws {
        let logger = makeLogger()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try delete(account: account)
            return
        }
        let data = Data(trimmed.utf8)

        let updateStatus = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            logger.info("keychain updated account=\(account, privacy: .public) chars=\(trimmed.count, privacy: .public)")
            return
        }
        guard updateStatus == errSecItemNotFound else {
            logger.error("keychain update failed account=\(account, privacy: .public) status=\(updateStatus, privacy: .public)")
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var addQuery = baseQuery(account: account)
        addQuery[kSecValueData] = data
        addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            logger.error("keychain add failed account=\(account, privacy: .public) status=\(addStatus, privacy: .public)")
            throw KeychainError.unexpectedStatus(addStatus)
        }
        logger.info("keychain added account=\(account, privacy: .public) chars=\(trimmed.count, privacy: .public)")
    }

    static func delete(account: String = apiKeyAccount) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            makeLogger().error("keychain delete failed account=\(account, privacy: .public) status=\(status, privacy: .public)")
            throw KeychainError.unexpectedStatus(status)
        }
        makeLogger().info("keychain deleted account=\(account, privacy: .public)")
    }
}

nonisolated enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "钥匙串保存失败（\(status)）"
        }
    }
}
