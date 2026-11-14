// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: persistence. Fuel data lives ONLY under scoped keys `<base>#<bikeId>` and is read with NO
// fallback: the SettingsStore scoped → global → default chain would leak one bike's tank into another, so
// this store talks to the KeyValueStore directly and never reads or writes a bare base key. Because every
// key ends in `#<bikeId>`, `Garage.remove(id)` / `Garage.clear()` delete them with no extra code. Nothing here
// is part of the settings export (SettingsBackup names its keys).
//
// Documents are JSON (`.sortedKeys`) with `"v": 1`; a document that does not decode or is newer reads as
// absent (logged once per key) and is left in place.

import Foundation

public final class FuelStore: @unchecked Sendable {
    public enum Keys {
        /// FuelProfile JSON.
        public static let profile = "fuel_profile_v1"
        /// RefuelLog JSON.
        public static let log = "fuel_log_v1"
        /// FuelOdometerState JSON.
        public static let odometer = "fuel_odo_v1"
        /// String "low" | "reserve" (absent = armed).
        public static let alert = "fuel_alert_v1"
        /// Bool true («Luego»).
        public static let setupDeferred = "fuel_setup_later_v1"
        public static let all = [profile, log, odometer, alert, setupDeferred]
    }

    /// The pump's volume unit (String "L" | "gal"): ONE global preference, not bike data (no tank, log or
    /// position), iOS-prefixed, never exported, kept when a bike is removed.
    public static let volumeUnitKey = "ios_fuel_volume_unit_v1"

    private let store: KeyValueStore
    private let lock = NSLock()
    private var warned = Set<String>()

    public init(store: KeyValueStore) {
        self.store = store
    }

    /// "<base>#<bikeId>", or nil when `bikeId` is empty or not `^[A-Za-z0-9]+$` (Garage ids are `b<hex>[x<n>]`).
    /// A nil key means: read nothing, write nothing — never the bare base.
    public static func key(_ base: String, bikeId: String) -> String? {
        guard !bikeId.isEmpty, bikeId.unicodeScalars.allSatisfy({
            ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9")
        }) else { return nil }
        return base + "#" + bikeId
    }

    // MARK: Documents

    public func profile(bikeId: String) -> FuelProfile? {
        read(FuelProfile.self, Keys.profile, bikeId)
    }

    public func setProfile(_ p: FuelProfile?, bikeId: String) {
        write(p, Keys.profile, bikeId)
    }

    /// Empty when absent / unreadable.
    public func log(bikeId: String) -> RefuelLog {
        read(RefuelLog.self, Keys.log, bikeId) ?? RefuelLog()
    }

    /// An empty log removes the key.
    public func setLog(_ l: RefuelLog, bikeId: String) {
        write(l.entries.isEmpty ? nil : l, Keys.log, bikeId)
    }

    /// Fresh when absent / unreadable.
    public func odometer(bikeId: String) -> FuelOdometerState {
        read(FuelOdometerState.self, Keys.odometer, bikeId) ?? FuelOdometerState()
    }

    public func setOdometer(_ s: FuelOdometerState, bikeId: String) {
        write(s, Keys.odometer, bikeId)
    }

    /// True when a document is stored under `<base>#<bikeId>` but does not read as v1 (broken or newer): it
    /// is left in place until the rider writes that document explicitly.
    public func isUnreadable(_ base: String, bikeId: String) -> Bool {
        guard let key = Self.key(base, bikeId: bikeId), store.data(forKey: key) != nil else { return false }
        switch base {
        case Keys.profile: return profile(bikeId: bikeId) == nil
        case Keys.log: return read(RefuelLog.self, Keys.log, bikeId) == nil
        case Keys.odometer: return read(FuelOdometerState.self, Keys.odometer, bikeId) == nil
        default: return false
        }
    }

    // MARK: Flags

    public func alertLevel(bikeId: String) -> FuelAlertLevel? {
        guard let key = Self.key(Keys.alert, bikeId: bikeId), let s = store.string(forKey: key) else { return nil }
        return FuelAlertLevel(rawValue: s)
    }

    public func setAlertLevel(_ l: FuelAlertLevel?, bikeId: String) {
        guard let key = Self.key(Keys.alert, bikeId: bikeId) else { return }
        if let l { store.set(l.rawValue, forKey: key) } else { store.removeValue(forKey: key) }
    }

    public func isSetupDeferred(bikeId: String) -> Bool {
        guard let key = Self.key(Keys.setupDeferred, bikeId: bikeId) else { return false }
        return store.bool(forKey: key) == true
    }

    /// false removes the key.
    public func setSetupDeferred(_ on: Bool, bikeId: String) {
        guard let key = Self.key(Keys.setupDeferred, bikeId: bikeId) else { return }
        if on { store.set(true, forKey: key) } else { store.removeValue(forKey: key) }
    }

    /// Deletes the bike's five fuel keys (Garage.remove does it too, through the `#<id>` suffix).
    public func removeAll(bikeId: String) {
        for base in Keys.all {
            if let key = Self.key(base, bikeId: bikeId) { store.removeValue(forKey: key) }
        }
    }

    // MARK: The pump's volume unit (global preference)

    /// nil = never chosen (FuelModel then uses `FuelVolumeUnit.defaultFor`).
    public func volumeUnit() -> FuelVolumeUnit? {
        store.string(forKey: Self.volumeUnitKey).flatMap(FuelVolumeUnit.init(rawValue:))
    }

    public func setVolumeUnit(_ u: FuelVolumeUnit) {
        store.set(u.rawValue, forKey: Self.volumeUnitKey)
    }

    // MARK: Private

    private func read<T: Decodable>(_ type: T.Type, _ base: String, _ bikeId: String) -> T? {
        guard let key = Self.key(base, bikeId: bikeId), let data = store.data(forKey: key) else { return nil }
        if let value = try? JSONDecoder().decode(T.self, from: data) { return value }
        lock.lock()
        let first = warned.insert(key).inserted
        lock.unlock()
        if first { Log.w("fuel", "ignoring stored \(base) (unreadable or newer)") }
        return nil
    }

    private func write<T: Encodable>(_ value: T?, _ base: String, _ bikeId: String) {
        guard let key = Self.key(base, bikeId: bikeId) else { return }
        guard let value else {
            store.removeValue(forKey: key)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        store.set(data, forKey: key)
        lock.lock()
        warned.remove(key)
        lock.unlock()
    }
}
