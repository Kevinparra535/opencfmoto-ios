// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) MapDataBackup.kt, SavedPlaces.kt
//
// "opencfmoto.map" v1 exchange file (docs/spec/navigation-dash.md §12.2, app-features.md §3.8):
// map preferences + favorites / markers / history / parked / home, pretty-printed like Android's
// org.json `toString(2)`. The ORS key is deliberately not exported.

import Foundation

public enum MapDataBackup {
    public static let format = "opencfmoto.map"
    public static let version = 1

    public struct ImportResult: Sendable, Equatable {
        public var ok: Bool
        /// "Map data imported" / "Not valid JSON: …" / "Not an OpenCfMoto map file" /
        /// "Unsupported map backup version <v>" / "Import failed: …".
        public var message: String
        /// Preferences after applying the file (persist them); nil when the import failed.
        public var preferences: MapPreferences?
        /// The file's `buildings3d` value when present (no iOS equivalent on the bike).
        public var buildings3d: Bool?
    }

    /// Export JSON (2-space pretty print). `exportedAt` = `yyyy-MM-dd'T'HH:mm:ssXXX` in `timeZone`.
    public static func exportJSON(places: PlacesStore, preferences p: MapPreferences, buildings3d: Bool = true,
                                  appVersion: String = AppHTTPIdentity.appVersion, now: Date = Date(),
                                  timeZone: TimeZone = .current) -> String {
        var prefs = OrderedJSONObject()
        prefs.put("units", p.units.rawValue)
        prefs.put("voicePrompts", p.voiceOn)
        prefs.put("showNextStop", p.showNextStop)
        prefs.put("autoFinishArrive", p.autoFinish)
        prefs.put("chrome", p.chrome.rawValue)
        prefs.put("buildings3d", buildings3d)
        prefs.put("mapTheme", p.theme.rawValue)
        prefs.put("routeMode", p.routeMode.rawValue)
        prefs.put("avoidTolls", p.avoidTolls)
        prefs.put("avoidHighways", p.avoidHighways)
        prefs.put("funCircuitKm", p.circuitKm)
        var root = OrderedJSONObject()
        root.put("format", format)
        root.put("version", version)
        root.put("exportedAt", isoTimestamp(now, timeZone: timeZone))
        root.put("appVersion", appVersion)
        root.put("prefs", prefs)
        root.put("favorites", .array(places.favorites().map { .object(PlacesStore.placeJSON($0)) }))
        root.put("markers", .array(places.markers().map { .object(PlacesStore.placeJSON($0)) }))
        root.put("history", .array(places.history().map { .object(PlacesStore.placeJSON($0)) }))
        if let parked = places.parked() { root.put("parked", PlacesStore.placeJSON(parked)) }
        if let home = places.home() { root.put("home", PlacesStore.placeJSON(home)) }
        return OrgJSONPretty.format(.object(root), indent: 2)
    }

    /// Imports a map file: strips a UTF-8 BOM, checks format and version, applies preferences
    /// key by key (unknown enum values ignored) and REPLACES all places (caps 100 / 50 / 30;
    /// places without numeric lat/lon dropped; a file without parked / home clears them).
    public static func importJSON(_ json: String, into places: PlacesStore, preferences current: MapPreferences) -> ImportResult {
        var text = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let root: NavJSON
        do {
            root = try NavJSON.parse(Data(text.utf8))
            guard root.object != nil else { throw NavServiceError.invalidJSON("not a JSON object") }
        } catch {
            return ImportResult(ok: false, message: "Not valid JSON: \(NavServiceError.message(for: error, fallback: "error"))")
        }
        if root["format"].string("") != format {
            return ImportResult(ok: false, message: "Not an OpenCfMoto map file")
        }
        let ver = root["version"].int(0)
        if ver < 1 || ver > version {
            return ImportResult(ok: false, message: "Unsupported map backup version \(ver)")
        }
        var prefs = current
        var b3d: Bool?
        let p = root["prefs"]
        if p.object != nil {
            if let u = MapUnits(rawValue: p["units"].string("")) { prefs.units = u }
            if p.has("voicePrompts") { prefs.voiceOn = p["voicePrompts"].bool(false) }
            if p.has("showNextStop") { prefs.showNextStop = p["showNextStop"].bool(false) }
            if p.has("autoFinishArrive") { prefs.autoFinish = p["autoFinishArrive"].bool(false) }
            if let c = MapChrome(rawValue: p["chrome"].string("")) { prefs.chrome = c }
            if p.has("buildings3d") { b3d = p["buildings3d"].bool(false) }
            if let t = MapTheme(rawValue: p["mapTheme"].string("")) { prefs.theme = t }
            if let m = RouteMode(rawValue: p["routeMode"].string("")) { prefs.routeMode = m }
            if p.has("avoidTolls") { prefs.avoidTolls = p["avoidTolls"].bool(false) }
            if p.has("avoidHighways") { prefs.avoidHighways = p["avoidHighways"].bool(false) }
            if p.has("funCircuitKm") { prefs.circuitKm = min(max(p["funCircuitKm"].int(60), 20), 150) }
        }
        // org.json getJSONObject(i) throws for a non-object element → "Import failed".
        for key in ["favorites", "markers", "history"] {
            if root[key].elements.contains(where: { $0.object == nil }) {
                return ImportResult(ok: false, message: "Import failed: \(key) contains a non-object entry")
            }
        }
        places.replaceAll(favorites: root["favorites"].elements.compactMap(PlacesStore.parsePlace),
                          markers: root["markers"].elements.compactMap(PlacesStore.parsePlace),
                          history: root["history"].elements.compactMap(PlacesStore.parsePlace),
                          parked: PlacesStore.parsePlace(root["parked"]),
                          home: PlacesStore.parsePlace(root["home"]))
        return ImportResult(ok: true, message: "Map data imported", preferences: prefs, buildings3d: b3d)
    }

    /// `OpenCfMoto-map-yyyyMMdd.json`.
    public static func suggestedFileName(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd"
        return "OpenCfMoto-map-\(f.string(from: now)).json"
    }

    static func isoTimestamp(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
        return f.string(from: date)
    }
}

/// Android (AOSP) org.json `toString(indentSpaces)` layout: `"key": value`, one entry per line,
/// empty containers as `{}` / `[]`, strings escaped like the compact writer ("/" → "\/").
public enum OrgJSONPretty {
    public static func format(_ value: JSONValue, indent: Int = 2) -> String {
        var out = ""
        write(value, depth: 0, indent: String(repeating: " ", count: indent), into: &out)
        return out
    }

    private static func write(_ v: JSONValue, depth: Int, indent: String, into out: inout String) {
        switch v {
        case let .object(o):
            if o.entries.isEmpty { out += "{}"; return }
            out += "{"
            for (i, e) in o.entries.enumerated() {
                if i > 0 { out += "," }
                out += "\n" + String(repeating: indent, count: depth + 1)
                out += JSONValue.string(e.key).jsonString + ": "
                write(e.value, depth: depth + 1, indent: indent, into: &out)
            }
            out += "\n" + String(repeating: indent, count: depth) + "}"
        case let .array(items):
            if items.isEmpty { out += "[]"; return }
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                out += "\n" + String(repeating: indent, count: depth + 1)
                write(item, depth: depth + 1, indent: indent, into: &out)
            }
            out += "\n" + String(repeating: indent, count: depth) + "]"
        default:
            out += v.jsonString
        }
    }
}

/// Handlebar saved-place slots (`SavedPlaces.kt`): three (name, query) pairs stored as
/// `name0…name2` / `query0…query2`. A slot is set when its query is not blank. On iOS the query is
/// geocoded (or parsed as "lat,lon") and navigation starts in-app (no Google Maps hand-off).
public final class SavedPlaceSlots: @unchecked Sendable {
    public static let count = 3
    private let store: KeyValueStore
    private let keyPrefix: String

    public init(store: KeyValueStore, keyPrefix: String = "saved_places.") {
        self.store = store
        self.keyPrefix = keyPrefix
    }

    /// 0-based slot name ("" when unset).
    public func name(_ slot: Int) -> String { store.string(forKey: keyPrefix + "name\(slot)") ?? "" }
    /// 0-based slot query ("" when unset).
    public func query(_ slot: Int) -> String { store.string(forKey: keyPrefix + "query\(slot)") ?? "" }

    public func set(_ slot: Int, name: String, query: String) {
        store.set(name.trimmingCharacters(in: .whitespacesAndNewlines), forKey: keyPrefix + "name\(slot)")
        store.set(query.trimmingCharacters(in: .whitespacesAndNewlines), forKey: keyPrefix + "query\(slot)")
    }

    public func isSet(_ slot: Int) -> Bool { !query(slot).isNavBlank }

    /// Picker label: "Navigate: <name | query>" or "Navigate to saved place <n> (not set yet)".
    public func actionLabel(_ slot: Int, language: NavLanguage = .en) -> String {
        if !isSet(slot) {
            return language == .es ? "Navegar al lugar guardado \(slot + 1) (sin configurar)"
                : "Navigate to saved place \(slot + 1) (not set yet)"
        }
        let n = name(slot)
        let label = n.isNavBlank ? query(slot) : n
        return language == .es ? "Navegar: \(label)" : "Navigate: \(label)"
    }

    /// "lat,lon" (optionally with spaces) → coordinate, else nil.
    public static func parseCoordinate(_ query: String) -> GeoPoint? {
        let parts = query.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let lat = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let lon = Double(parts[1].trimmingCharacters(in: .whitespaces)),
              (-90 ... 90).contains(lat), (-180 ... 180).contains(lon) else { return nil }
        return GeoPoint(lat: lat, lon: lon)
    }
}
