// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) BikeMemory.kt
//
// The garage (session-network.md §8.1, app-features.md §4): remembered bikes, most recently saved
// first, plus the selected bike used by one-tap Connect / auto-connect.
//
// iOS changes vs Android (spec GAP fixes):
// - Identity is the dash SSID (+ MAC when both sides know it), not the raw QR string: the QR `sn`
//   is a per-scan nonce, so Android adds a duplicate entry on every re-scan. Re-scanning updates the
//   stored raw QR of the existing bike instead.
// - The raw QR (it contains the Wi-Fi password) lives in a `SecretStore` (Keychain), never in
//   UserDefaults or logs. Metadata (name, photo file name, profile hint) lives in the KeyValueStore.
// - Photos are stored as a file NAME (relative), never an absolute path.
// - Removing a bike really deletes its per-bike scoped settings (and the SSID-keyed learned data
//   when no other bike shares the SSID).
// - Each bike keeps a stable `id` = `BikeScope.id(forRaw:)` of the raw it was first saved with, so
//   its scoped settings keys are Android-compatible (`video_quality#b58cde373`) and survive re-scans.

import Foundation

/// One remembered bike (metadata only; the raw QR is in the SecretStore).
public struct GarageBike: Sendable, Equatable, Hashable, Codable, Identifiable {
    /// Stable id and per-bike settings scope (`"b" + hex(javaHash(firstRaw))`). Never changes.
    public var id: String
    /// Dash Wi-Fi SSID (exact, case-sensitive) — the identity together with `mac`.
    public var ssid: String
    /// Normalised dash MAC from the QR, when known.
    public var mac: String?
    /// User-editable display name.
    public var name: String
    /// Photo file name inside the app's bike-photo directory (e.g. `"b58cde373.jpg"`), or nil.
    public var photoFileName: String?
    /// Profile chosen at the last successful connect (CLIENT_INFO), to pre-pick next time.
    public var profileHint: BikeProfileID?

    public init(id: String, ssid: String, mac: String? = nil, name: String, photoFileName: String? = nil,
                profileHint: BikeProfileID? = nil) {
        self.id = id
        self.ssid = ssid
        self.mac = mac
        self.name = name
        self.photoFileName = photoFileName
        self.profileHint = profileHint
    }

    /// The per-bike settings scope (same as `id`).
    public var scopeId: String { id }

    /// Whether a scanned QR belongs to this bike: same SSID and no conflicting MAC.
    public func matches(_ qr: BikeQR) -> Bool {
        guard qr.ssid == ssid else { return false }
        if let a = mac, let b = qr.mac { return a.lowercased() == b.lowercased() }
        return true
    }
}

/// One entry of Android's `bikes_json` (`SavedBike(raw, name, photoPath)`).
public struct AndroidSavedBike: Sendable, Equatable {
    public var raw: String
    public var name: String
    public var photoPath: String?
    public init(raw: String, name: String, photoPath: String? = nil) {
        self.raw = raw; self.name = name; self.photoPath = photoPath
    }
}

/// Outcome of `Garage.importAndroidBikesJSON`.
public struct GarageImportResult: Sendable, Equatable {
    /// Bikes created by the import.
    public var added: Int
    /// Bikes that already existed (raw QR refreshed, iOS name/photo kept).
    public var updated: Int
    /// Entries whose raw QR does not parse (cannot be connected; not imported).
    public var skippedUnparsable: Int
    /// Android photo paths are absolute device paths and are never imported.
    public var droppedPhotos: Int
}

/// Thread-safe garage over a `KeyValueStore` (metadata) and a `SecretStore` (raw QR strings).
/// All methods may be called from any thread (`NSLock`).
public final class Garage: @unchecked Sendable {
    /// KeyValueStore key of the bike list (JSON array of `GarageBike`, most recent first).
    public static let bikesKey = "garage_bikes_v1"
    /// KeyValueStore key of the selected bike id.
    public static let selectedKey = "garage_selected_v1"
    /// SecretStore key prefix of a bike's raw QR: `garage.raw.<id>`.
    public static let rawSecretPrefix = "garage.raw."
    /// Android per-SSID transport memory key prefix (`transport_<ssid>` → `"AP"` / `"P2P"`).
    public static let transportKeyPrefix = "transport_"

    private let lock = NSLock()
    private let store: KeyValueStore
    private let secrets: SecretStore
    private var list: [GarageBike]

    public init(store: KeyValueStore, secrets: SecretStore) {
        self.store = store
        self.secrets = secrets
        self.list = Self.load(from: store)
    }

    private static func load(from store: KeyValueStore) -> [GarageBike] {
        guard let data = store.data(forKey: bikesKey),
              let decoded = try? JSONDecoder().decode([GarageBike].self, from: data) else { return [] }
        return decoded
    }

    /// Re-reads the bike list from the store (another process — e.g. the broadcast extension sharing
    /// the App Group suite — may have changed it).
    public func reload() {
        lock.lock(); defer { lock.unlock() }
        list = Self.load(from: store)
    }

    // MARK: - Reading

    /// All bikes, most recently saved first.
    public var bikes: [GarageBike] {
        lock.lock(); defer { lock.unlock() }
        return list
    }

    public var isEmpty: Bool { bikes.isEmpty }

    /// The explicitly selected bike, else the most recent one, else nil (Android `selected()`).
    public var selected: GarageBike? {
        lock.lock(); defer { lock.unlock() }
        return selectedLocked()
    }

    private func selectedLocked() -> GarageBike? {
        guard !list.isEmpty else { return nil }
        let sel = store.string(forKey: Self.selectedKey)
        return list.first(where: { $0.id == sel }) ?? list.first
    }

    public func bike(id: String) -> GarageBike? {
        lock.lock(); defer { lock.unlock() }
        return list.first(where: { $0.id == id })
    }

    /// The bike a scanned QR belongs to (same SSID, compatible MAC), if any.
    public func bike(matching qr: BikeQR) -> GarageBike? {
        lock.lock(); defer { lock.unlock() }
        return list.first(where: { $0.matches(qr) })
    }

    /// The latest raw QR text of a bike (secret: contains the Wi-Fi password — never log it).
    public func raw(for id: String) -> String? {
        secrets.secret(forKey: Self.rawSecretPrefix + id)
    }

    /// The parsed QR of a bike (re-parsed from the stored raw, like Android).
    public func qr(for id: String) -> BikeQR? {
        raw(for: id).flatMap(BikeQR.parse)
    }

    // MARK: - Writing

    /// Remembers a successfully scanned / manually entered bike (Android `save(raw, qr)`): the matching
    /// bike moves to the front keeping its name, photo and profile hint (its raw QR is refreshed),
    /// otherwise a new bike is created named `qr.name` (if not blank) else `qr.ssid`. Selects it.
    @discardableResult
    public func save(_ qr: BikeQR) -> GarageBike {
        lock.lock(); defer { lock.unlock() }
        var bike: GarageBike
        if let idx = list.firstIndex(where: { $0.matches(qr) }) {
            bike = list.remove(at: idx)
            if bike.mac == nil, let mac = qr.mac { bike.mac = mac }
        } else {
            var id = BikeScope.id(forRaw: qr.raw)
            var n = 2
            while list.contains(where: { $0.id == id }) { // astronomically unlikely hash collision
                id = BikeScope.id(forRaw: qr.raw) + "x\(n)"
                n += 1
            }
            let name: String
            if let n = qr.name, !AppJvmText.isBlank(n) { name = n } else { name = qr.ssid }
            bike = GarageBike(id: id, ssid: qr.ssid, mac: qr.mac, name: name)
        }
        list.insert(bike, at: 0)
        secrets.setSecret(qr.raw, forKey: Self.rawSecretPrefix + bike.id)
        store.set(bike.id, forKey: Self.selectedKey)
        persistLocked()
        return bike
    }

    /// Selects a bike (no reordering).
    public func select(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        store.set(id, forKey: Self.selectedKey)
    }

    /// Renames a bike (Kotlin-trimmed; a blank name keeps the current one).
    public func rename(_ id: String, to newName: String) {
        let trimmed = AppJvmText.trim(newName)
        guard !AppJvmText.isBlank(trimmed) else { return }
        mutate(id) { $0.name = trimmed }
    }

    /// Sets or clears a bike's photo file name.
    public func setPhoto(_ id: String, fileName: String?) {
        mutate(id) { $0.photoFileName = (fileName?.isEmpty ?? true) ? nil : fileName }
    }

    /// Remembers the profile the dash was identified as (or nil to forget it).
    public func setProfileHint(_ id: String, _ profile: BikeProfileID?) {
        mutate(id) { $0.profileHint = profile }
    }

    private func mutate(_ id: String, _ body: (inout GarageBike) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
        body(&list[idx])
        persistLocked()
    }

    /// Forgets a bike: removes it (clearing the selection if it was selected), deletes its raw QR,
    /// its per-bike scoped settings (`*#<id>` keys) and, when no other bike uses the same SSID, the
    /// SSID-keyed learned canvas and transport memory. Returns the removed bike so the caller can
    /// delete its photo file.
    @discardableResult
    public func remove(_ id: String) -> GarageBike? {
        lock.lock(); defer { lock.unlock() }
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = list.remove(at: idx)
        if store.string(forKey: Self.selectedKey) == id { store.removeValue(forKey: Self.selectedKey) }
        secrets.setSecret(nil, forKey: Self.rawSecretPrefix + id)
        for key in store.allKeys() where BikeScope.isKey(key, scopedTo: id) {
            store.removeValue(forKey: key)
        }
        if !list.contains(where: { $0.ssid == removed.ssid }) {
            store.removeValue(forKey: DashMemory.keyPrefix + removed.ssid)
            store.removeValue(forKey: Self.transportKeyPrefix + removed.ssid)
        }
        persistLocked()
        return removed
    }

    /// Forgets every bike (Android `clear()`): list, selection and raw QR secrets. Scoped settings of
    /// the removed bikes are deleted too.
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        let ids = list.map(\.id)
        for id in ids {
            secrets.setSecret(nil, forKey: Self.rawSecretPrefix + id)
            for key in store.allKeys() where BikeScope.isKey(key, scopedTo: id) {
                store.removeValue(forKey: key)
            }
        }
        list.removeAll()
        store.removeValue(forKey: Self.selectedKey)
        store.removeValue(forKey: Self.bikesKey)
    }

    private func persistLocked() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(list) {
            store.set(data, forKey: Self.bikesKey)
        }
    }

    // MARK: - Transport memory (Android `winningTransport`)

    /// The Wi-Fi transport (`"AP"` / `"P2P"`) that last brought Wi-Fi up for `ssid`, if any.
    public func winningTransport(ssid: String) -> String? {
        AppJvmText.isBlank(ssid) ? nil : store.string(forKey: Self.transportKeyPrefix + ssid)
    }

    public func setWinningTransport(ssid: String, transport: String) {
        guard !AppJvmText.isBlank(ssid) else { return }
        store.set(transport, forKey: Self.transportKeyPrefix + ssid)
    }

    // MARK: - Android import

    /// Parses Android's `bikes_json` exactly like `BikeMemory.devices()`: an unparsable array → empty;
    /// non-object entries skipped; `raw`/`name`/`photo` read with `optString`; blank raw skipped;
    /// blank name → raw; blank photo → nil.
    public static func parseAndroidBikesJSON(_ json: String) -> [AndroidSavedBike] {
        guard let arr = try? AndroidOrgJSON.parseArray(json) else { return [] }
        var out: [AndroidSavedBike] = []
        for i in arr.indices {
            guard let o = arr.orgOptObject(i) else { continue }
            let raw = o.orgOptString("raw")
            let name = o.orgOptString("name")
            let photo = o.orgOptString("photo")
            if AppJvmText.isBlank(raw) { continue }
            out.append(AndroidSavedBike(raw: raw, name: AppJvmText.isBlank(name) ? raw : name,
                                        photoPath: AppJvmText.isBlank(photo) ? nil : photo))
        }
        return out
    }

    /// Imports an Android `bikes_json` array (most recent first) into this garage, preserving its
    /// order and the Android display names of newly created bikes. Existing bikes (same SSID/MAC)
    /// get their raw QR refreshed but keep their iOS name and photo. Entries whose raw QR does not
    /// parse are skipped; Android photo paths are dropped. `selectedRaw` (Android `selected_raw`)
    /// selects the matching bike; otherwise the first imported bike is selected.
    @discardableResult
    public func importAndroidBikesJSON(_ json: String, selectedRaw: String? = nil) -> GarageImportResult {
        let entries = Self.parseAndroidBikesJSON(json)
        var result = GarageImportResult(added: 0, updated: 0, skippedUnparsable: 0, droppedPhotos: 0)
        var selectedId: String?
        for entry in entries.reversed() {
            guard let qr = BikeQR.parse(entry.raw) else {
                result.skippedUnparsable += 1
                continue
            }
            if entry.photoPath != nil { result.droppedPhotos += 1 }
            let existed = bike(matching: qr) != nil
            let saved = save(qr)
            if existed {
                result.updated += 1
            } else {
                result.added += 1
                rename(saved.id, to: entry.name)
            }
            if let selectedRaw, selectedRaw == entry.raw { selectedId = saved.id }
        }
        if let selectedId { select(selectedId) }
        return result
    }
}
