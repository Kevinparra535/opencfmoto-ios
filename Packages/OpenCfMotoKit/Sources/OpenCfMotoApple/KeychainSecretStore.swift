// SPDX-License-Identifier: AGPL-3.0-or-later
// `SecretStore` (OpenCfMotoCore Storage/KeyValueStore.swift) backed by the Keychain: generic
// passwords, service "OpenCfMoto", one item per key (kSecAttrAccount = key, value = UTF-8 data).
// Used for the garage's raw QR strings, which contain the bike Wi-Fi password
// (session-network.md §11.7: keep the PSK out of UserDefaults / backups).

#if canImport(Security) && canImport(Foundation)
import Foundation
import Security
import OpenCfMotoCore

/// Thread-safety: Keychain calls are thread-safe; this wrapper holds only immutable state.
public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    public static let defaultService = "OpenCfMoto"

    public let service: String
    /// Keychain access group (e.g. the App Group id, to share with the extension); nil = default.
    public let accessGroup: String?
    /// `kSecAttrAccessibleAfterFirstUnlock` (default) or its ThisDeviceOnly variant (not migrated to
    /// other devices through backups).
    public let thisDeviceOnly: Bool

    public init(service: String = KeychainSecretStore.defaultService, accessGroup: String? = nil,
                thisDeviceOnly: Bool = false) {
        self.service = service
        self.accessGroup = accessGroup
        self.thisDeviceOnly = thisDeviceOnly
    }

    /// OSStatus of the last failing write, for diagnostics (0 = none).
    private let lastErrorLock = NSLock()
    private var _lastError: OSStatus = errSecSuccess
    public var lastError: OSStatus { lastErrorLock.lock(); defer { lastErrorLock.unlock() }; return _lastError }

    private var accessibility: CFString {
        thisDeviceOnly ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly : kSecAttrAccessibleAfterFirstUnlock
    }

    private func baseQuery(_ key: String?) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let key { q[kSecAttrAccount as String] = key }
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    public func secret(forKey key: String) -> String? {
        var q = baseQuery(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ value: String?, forKey key: String) {
        guard let value else {
            let status = SecItemDelete(baseQuery(key) as CFDictionary)
            record(status == errSecItemNotFound ? errSecSuccess : status, "delete")
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: accessibility,
        ]
        var status = SecItemUpdate(baseQuery(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(key)
            for (k, v) in attributes { add[k] = v }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        record(status, "write")
    }

    public func allSecretKeys() -> [String] {
        var q = baseQuery(nil)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Deletes every item of this service (and access group).
    public func removeAll() {
        let status = SecItemDelete(baseQuery(nil) as CFDictionary)
        record(status == errSecItemNotFound ? errSecSuccess : status, "delete all")
    }

    private func record(_ status: OSStatus, _ op: String) {
        lastErrorLock.lock()
        _lastError = status
        lastErrorLock.unlock()
        if status != errSecSuccess { Log.w("STORE", "keychain \(op) failed: OSStatus \(status)") }
    }
}
#endif
