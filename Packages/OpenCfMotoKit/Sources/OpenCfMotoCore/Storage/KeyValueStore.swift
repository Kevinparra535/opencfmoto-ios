// SPDX-License-Identifier: AGPL-3.0-or-later
// CONTRACT FILE — persistence abstractions. Production: `UserDefaultsKeyValueStore` (App Group
// suite, shared with the ReplayKit extension) and `KeychainSecretStore` in OpenCfMotoApple.
// Tests: the in-memory versions below.

import Foundation

public protocol KeyValueStore: AnyObject, Sendable {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
    func bool(forKey key: String) -> Bool?
    func set(_ value: Bool?, forKey key: String)
    func int(forKey key: String) -> Int?
    func set(_ value: Int?, forKey key: String)
    func double(forKey key: String) -> Double?
    func set(_ value: Double?, forKey key: String)
    func data(forKey key: String) -> Data?
    func set(_ value: Data?, forKey key: String)
    func removeValue(forKey key: String)
    func allKeys() -> [String]
}

/// Secrets (garage raw QR strings contain the bike Wi-Fi password).
public protocol SecretStore: AnyObject, Sendable {
    func secret(forKey key: String) -> String?
    func setSecret(_ value: String?, forKey key: String)
    func allSecretKeys() -> [String]
}

public final class InMemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    public init() {}
    private func get<T>(_ k: String) -> T? { lock.lock(); defer { lock.unlock() }; return values[k] as? T }
    private func put(_ v: Any?, _ k: String) { lock.lock(); values[k] = v; lock.unlock() }
    public func string(forKey key: String) -> String? { get(key) }
    public func set(_ value: String?, forKey key: String) { put(value, key) }
    public func bool(forKey key: String) -> Bool? { get(key) }
    public func set(_ value: Bool?, forKey key: String) { put(value, key) }
    public func int(forKey key: String) -> Int? { get(key) }
    public func set(_ value: Int?, forKey key: String) { put(value, key) }
    public func double(forKey key: String) -> Double? { get(key) }
    public func set(_ value: Double?, forKey key: String) { put(value, key) }
    public func data(forKey key: String) -> Data? { get(key) }
    public func set(_ value: Data?, forKey key: String) { put(value, key) }
    public func removeValue(forKey key: String) { put(nil, key) }
    public func allKeys() -> [String] { lock.lock(); defer { lock.unlock() }; return Array(values.keys) }
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    public init() {}
    public func secret(forKey key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    public func setSecret(_ value: String?, forKey key: String) { lock.lock(); values[key] = value; lock.unlock() }
    public func allSecretKeys() -> [String] { lock.lock(); defer { lock.unlock() }; return Array(values.keys) }
}
