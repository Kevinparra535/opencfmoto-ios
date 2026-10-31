// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) MapPlaces.kt
//
// Favorites, markers, history, parked spot and home (docs/spec/navigation-dash.md §12.1). Each key
// stores a JSON ARRAY STRING of `{"name","lat","lon","category","subtitle"}` exactly like the
// Android SharedPreferences file `opencfmoto_map_places` (org.json formatting, newest first).

import Foundation

/// Persistent saved places over a `KeyValueStore`. Thread-safe (`NSRecursiveLock`).
public final class PlacesStore: @unchecked Sendable {
    public static let maxFavorites = 100
    public static let maxMarkers = 50
    /// Android `MAX_HISTORY`.
    public static let maxHistory = 30

    /// Storage keys (Android names, prefixed by `keyPrefix`).
    public enum Key: String, CaseIterable, Sendable {
        case favorites, markers, history, parked, home
    }

    private let store: KeyValueStore
    private let keyPrefix: String
    private let lock = NSRecursiveLock()
    private var rev: UInt64 = 0
    private var listeners: [UUID: @Sendable (UInt64) -> Void] = [:]

    /// - Parameter keyPrefix: namespace inside a shared store (Android used its own prefs file).
    public init(store: KeyValueStore, keyPrefix: String = "opencfmoto_map_places.") {
        self.store = store
        self.keyPrefix = keyPrefix
    }

    /// Bumped on every write so open UIs can refresh pins / lists (Android `MapPlaces.revision`).
    public var revision: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return rev
    }

    /// Registers a change listener (called after every mutating operation, outside the store lock,
    /// on the writer's thread). Do not call back into `NavigationSession` synchronously from it:
    /// the session writes places while holding its own state lock (dispatch asynchronously, or use
    /// `NavEffect.placesChanged`; the session itself picks up external edits via `revision`).
    @discardableResult
    public func addChangeListener(_ listener: @escaping @Sendable (UInt64) -> Void) -> UUID {
        let id = UUID()
        lock.lock(); listeners[id] = listener; lock.unlock()
        return id
    }

    public func removeChangeListener(_ id: UUID) {
        lock.lock(); listeners[id] = nil; lock.unlock()
    }

    public func storageKey(_ key: Key) -> String { keyPrefix + key.rawValue }

    // MARK: Reads

    public func favorites() -> [Place] { load(.favorites) }
    public func markers() -> [Place] { load(.markers) }
    public func history() -> [Place] { load(.history) }
    /// The active parked-bike pin (at most one).
    public func parked() -> Place? { load(.parked).first }
    /// Saved Home.
    public func home() -> Place? { load(.home).first }

    /// Android identity: |Δlat| < 1e-5 and |Δlon| < 1e-5 (names ignored).
    public static func same(_ a: Place, _ b: Place) -> Bool { a.isSameLocation(as: b) }

    public func isParked(_ place: Place) -> Bool {
        guard let p = parked() else { return false }
        return Self.same(p, place)
    }

    public func isFavorite(_ place: Place) -> Bool { favorites().contains { Self.same($0, place) } }
    public func isMarker(_ place: Place) -> Bool { markers().contains { Self.same($0, place) } }
    public func isInHistory(_ place: Place) -> Bool { history().contains { Self.same($0, place) } }

    // MARK: Writes

    /// Replaces the parked pin: removes the previous one's marker + history entry, stores
    /// `place` with category "parking" (blank name → `defaultName`), adds it as a marker and pushes
    /// a history copy with subtitle `historySubtitle`.
    public func setParked(_ place: Place, defaultName: String = "Parked", historySubtitle: String = "Parked here") {
        mutate {
            if let old = parked() {
                save(.markers, markers().filter { !Self.same($0, old) })
                save(.history, history().filter { !Self.same($0, old) })
            }
            var pin = place
            pin.category = "parking"
            if pin.name.isNavBlank { pin.name = defaultName }
            save(.parked, [pin])
            save(.markers, Array(([pin] + markers().filter { !Self.same($0, pin) }).prefix(Self.maxMarkers)))
            var hist = pin
            hist.subtitle = historySubtitle
            save(.history, Array(([hist] + history().filter { !Self.same($0, hist) }).prefix(Self.maxHistory)))
        }
    }

    /// Clears the parked pin (and its marker / history row). Without a parked pin, purges ghost
    /// history rows of category "parking".
    public func clearParked() {
        mutate {
            if let p = parked() {
                save(.markers, markers().filter { !Self.same($0, p) })
                save(.history, history().filter { !Self.same($0, p) })
            } else {
                save(.history, history().filter { $0.category != "parking" })
            }
            save(.parked, [])
        }
    }

    /// Sets Home (category "home", blank name → `defaultName`, subtitle `subtitle`) and adds it
    /// to favorites, markers and history.
    public func setHome(_ place: Place, defaultName: String = "Home", subtitle: String = "Home") {
        mutate {
            var h = place
            h.category = "home"
            if h.name.isNavBlank { h.name = defaultName }
            h.subtitle = subtitle
            save(.home, [h])
            save(.favorites, Array(([h] + favorites().filter { !Self.same($0, h) }).prefix(Self.maxFavorites)))
            save(.markers, Array(([h] + markers().filter { !Self.same($0, h) }).prefix(Self.maxMarkers)))
            save(.history, Array(([h] + history().filter { !Self.same($0, h) }).prefix(Self.maxHistory)))
        }
    }

    public func clearHome() { mutate { save(.home, []) } }

    public func addFavorite(_ place: Place) {
        mutate { save(.favorites, Array(([place] + favorites().filter { !Self.same($0, place) }).prefix(Self.maxFavorites))) }
    }

    public func removeFavorite(_ place: Place) { mutate { save(.favorites, favorites().filter { !Self.same($0, place) }) } }

    public func addMarker(_ place: Place) {
        mutate { save(.markers, Array(([place] + markers().filter { !Self.same($0, place) }).prefix(Self.maxMarkers))) }
    }

    public func removeMarker(_ place: Place) { mutate { save(.markers, markers().filter { !Self.same($0, place) }) } }

    /// Inserts at the front after removing the same place; capped at 30.
    public func pushHistory(_ place: Place) {
        mutate { save(.history, Array(([place] + history().filter { !Self.same($0, place) }).prefix(Self.maxHistory))) }
    }

    public func removeHistory(_ place: Place) { mutate { save(.history, history().filter { !Self.same($0, place) }) } }

    /// Removes a place from parked / home / markers / favorites / history in one shot.
    public func deletePlace(_ place: Place) {
        mutate {
            if isParked(place) || place.category == "parking" {
                if let p = parked() {
                    save(.markers, markers().filter { !Self.same($0, p) })
                    save(.history, history().filter { !Self.same($0, p) })
                } else {
                    save(.history, history().filter { $0.category != "parking" })
                }
                save(.parked, [])
            }
            if let h = home(), Self.same(h, place) { save(.home, []) }
            save(.markers, markers().filter { !Self.same($0, place) })
            save(.favorites, favorites().filter { !Self.same($0, place) })
            save(.history, history().filter { !Self.same($0, place) })
        }
    }

    /// Full replace used by the map-data import (caps 100 / 50 / 30).
    public func replaceAll(favorites: [Place], markers: [Place], history: [Place], parked: Place?, home: Place?) {
        mutate {
            save(.favorites, Array(favorites.prefix(Self.maxFavorites)))
            save(.markers, Array(markers.prefix(Self.maxMarkers)))
            save(.history, Array(history.prefix(Self.maxHistory)))
            save(.parked, parked.map { [$0] } ?? [])
            save(.home, home.map { [$0] } ?? [])
        }
    }

    // MARK: Derived lists

    /// Search-sheet idle list (`GpxDashUi.showIdle`): home, parked, favorites, markers, history
    /// (minus categories "mode" / "parking" and (0,0)), distinct by "<name>|%.4f|%.4f", first `limit`.
    public func idleSuggestions(limit: Int = 12) -> [Place] {
        let hist = history().filter { $0.category != "mode" && $0.category != "parking" && !($0.lat == 0 && $0.lon == 0) }
        let all = [home(), parked()].compactMap { $0 } + favorites() + markers() + hist
        var seen = Set<String>()
        var out: [Place] = []
        for p in all {
            let key = "\(p.name)|\(NavNumberFormat.fixed(p.lat, decimals: 4))|\(NavNumberFormat.fixed(p.lon, decimals: 4))"
            if seen.insert(key).inserted { out.append(p) }
            if out.count >= limit { break }
        }
        return out
    }

    /// True when the search sheet should offer "Delete" for `place`.
    public func canDelete(_ place: Place) -> Bool {
        isMarker(place) || ["pin", "parking", "home"].contains(place.category) || isFavorite(place)
            || isParked(place) || isInHistory(place)
    }

    // MARK: JSON (Android format)

    /// `[{"name":…,"lat":…,"lon":…,"category":…,"subtitle":…}]` with org.json formatting.
    public static func encodeList(_ places: [Place]) -> String {
        JSONValue.array(places.map { .object(placeJSON($0)) }).jsonString
    }

    static func placeJSON(_ p: Place) -> OrderedJSONObject {
        var o = OrderedJSONObject()
        o.put("name", p.name)
        o.put("lat", p.lat)
        o.put("lon", p.lon)
        o.put("category", p.category)
        o.put("subtitle", p.subtitle)
        return o
    }

    /// Lenient decode: invalid JSON → []; elements without numeric lat/lon are skipped.
    public static func decodeList(_ json: String?) -> [Place] {
        guard let json, let data = json.data(using: .utf8), let root = try? NavJSON.parse(data), root.array != nil else { return [] }
        return root.elements.compactMap { parsePlace($0) }
    }

    static func parsePlace(_ o: NavJSON) -> Place? {
        guard o.object != nil, let lat = o["lat"].doubleOrNil, let lon = o["lon"].doubleOrNil else { return nil }
        return Place(name: o["name"].string(""), lat: lat, lon: lon, category: o["category"].string(""),
                     subtitle: o["subtitle"].string(""))
    }

    // MARK: Internals

    private func load(_ key: Key) -> [Place] {
        lock.lock(); defer { lock.unlock() }
        return Self.decodeList(store.string(forKey: storageKey(key)))
    }

    private func save(_ key: Key, _ list: [Place]) {
        store.set(Self.encodeList(list), forKey: storageKey(key))
    }

    private func mutate(_ body: () -> Void) {
        lock.lock()
        body()
        rev &+= 1
        let r = rev
        let ls = Array(listeners.values)
        lock.unlock()
        for l in ls { l(r) }
    }
}
