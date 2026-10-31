// SPDX-License-Identifier: AGPL-3.0-or-later
// `KeyValueStore` (OpenCfMotoCore Storage/KeyValueStore.swift) backed by UserDefaults.
// Production uses the App Group suite (`OCMAppGroupIdentifier` in Info.plist) so the ReplayKit
// extension sees the same settings; it falls back to `.standard` when the group is not configured
// or not entitled. Secrets (QR strings with the Wi-Fi password) belong in `KeychainSecretStore`.

#if canImport(Foundation)
import Foundation
import OpenCfMotoCore

/// Thread-safety: UserDefaults is thread-safe; this wrapper holds only immutable state.
public final class UserDefaultsKeyValueStore: KeyValueStore, @unchecked Sendable {
    public let defaults: UserDefaults
    /// Persistent-domain name whose keys `allKeys()` lists (the suite name, or the bundle id for
    /// `.standard`); nil → `dictionaryRepresentation()` (includes system keys).
    public let domainName: String?
    /// The suite actually used (nil = `.standard`).
    public let suiteName: String?

    /// `suiteName` nil → `UserDefaults.standard`. An invalid suite falls back to `.standard`.
    public init(suiteName: String?) {
        if let suiteName, let d = UserDefaults(suiteName: suiteName) {
            self.defaults = d
            self.suiteName = suiteName
            self.domainName = suiteName
        } else {
            self.defaults = .standard
            self.suiteName = nil
            self.domainName = Bundle.main.bundleIdentifier
        }
    }

    public init(defaults: UserDefaults, domainName: String?) {
        self.defaults = defaults
        self.suiteName = domainName
        self.domainName = domainName
    }

    /// The App Group suite from Info.plist (`OCMAppGroupIdentifier`), else `.standard`.
    public static func appGroup(bundle: Bundle = .main) -> UserDefaultsKeyValueStore {
        guard let id = AppGroup.identifier(in: bundle) else { return UserDefaultsKeyValueStore(suiteName: nil) }
        #if canImport(Darwin)
        // Without the entitlement the suite would silently be app-private: prefer .standard then.
        if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) == nil {
            Log.w("STORE", "App Group \(id) not entitled — using standard UserDefaults")
            return UserDefaultsKeyValueStore(suiteName: nil)
        }
        #endif
        return UserDefaultsKeyValueStore(suiteName: id)
    }

    public func string(forKey key: String) -> String? { defaults.object(forKey: key) as? String }

    public func set(_ value: String?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    public func bool(forKey key: String) -> Bool? { defaults.object(forKey: key) as? Bool }

    public func set(_ value: Bool?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    public func int(forKey key: String) -> Int? { defaults.object(forKey: key) as? Int }

    public func set(_ value: Int?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    public func double(forKey key: String) -> Double? {
        let o = defaults.object(forKey: key)
        if let d = o as? Double { return d }
        if let i = o as? Int { return Double(i) }
        return nil
    }

    public func set(_ value: Double?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    public func data(forKey key: String) -> Data? { defaults.object(forKey: key) as? Data }

    public func set(_ value: Data?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    public func removeValue(forKey key: String) { defaults.removeObject(forKey: key) }

    public func allKeys() -> [String] {
        if let domainName {
            return Array((defaults.persistentDomain(forName: domainName) ?? [:]).keys)
        }
        return Array(defaults.dictionaryRepresentation().keys)
    }

    /// Removes every key of this store's persistent domain (tests / "reset settings").
    public func removeAll() {
        if let domainName {
            defaults.removePersistentDomain(forName: domainName)
        } else {
            for k in allKeys() { defaults.removeObject(forKey: k) }
        }
    }
}
#endif
