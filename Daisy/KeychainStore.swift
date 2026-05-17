//
//  KeychainStore.swift
//  Daisy
//
//  Thin Keychain wrapper for storing API tokens (Notion). Items live in
//  the app's default keychain, scoped to this bundle ID by the sandbox.
//

import Foundation
import Security
import os

nonisolated enum KeychainStore {
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "Keychain")
    private static let service = "app.essazanov.Daisy"

    enum KeychainError: Error {
        case osError(OSStatus)
    }

    /// Store or update a string value under `account`.
    static func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let attrs: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                log.error("Keychain add failed: \(addStatus)")
                throw KeychainError.osError(addStatus)
            }
            return
        }
        log.error("Keychain update failed: \(updateStatus)")
        throw KeychainError.osError(updateStatus)
    }

    /// Retrieve a string value, or nil if not present.
    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// Remove a stored value.
    @discardableResult
    static func remove(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

// MARK: - Typed accessors

nonisolated enum SecretKey {
    static let notionToken = "notion.token"
    static let notionParentID = "notion.parent_id"
    static let anthropicAPIKey = "anthropic.api_key"
    static let openaiAPIKey = "openai.api_key"
}
