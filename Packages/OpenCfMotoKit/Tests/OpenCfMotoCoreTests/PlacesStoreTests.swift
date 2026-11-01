// SPDX-License-Identifier: AGPL-3.0-or-later
// PlacesStore (MapPlaces port), opencfmoto.map v1 backup and handlebar saved-place slots.

import XCTest
@testable import OpenCfMotoCore

final class PlacesStoreTests: XCTestCase {
    private func store() -> (PlacesStore, InMemoryKeyValueStore) {
        let kv = InMemoryKeyValueStore()
        return (PlacesStore(store: kv), kv)
    }

    func testJSONArrayFormatIsAndroidVerbatim() {
        let (s, kv) = store()
        s.addFavorite(Place(name: "Câmpina \"x\"/y", lat: 45.0, lon: 25.1234567, category: "city", subtitle: "Prahova"))
        XCTAssertEqual(kv.string(forKey: "opencfmoto_map_places.favorites"),
                       #"[{"name":"Câmpina \"x\"\/y","lat":45,"lon":25.1234567,"category":"city","subtitle":"Prahova"}]"#)
        XCTAssertEqual(PlacesStore.decodeList(kv.string(forKey: "opencfmoto_map_places.favorites")),
                       [Place(name: "Câmpina \"x\"/y", lat: 45, lon: 25.1234567, category: "city", subtitle: "Prahova")])
        XCTAssertEqual(PlacesStore.decodeList("not json"), [])
        XCTAssertEqual(PlacesStore.decodeList(nil), [])
        // Elements without numeric lat/lon are skipped; missing strings default to "".
        XCTAssertEqual(PlacesStore.decodeList(#"[{"name":"a","lat":"1.5","lon":2},{"name":"b"},{"lat":3,"lon":4}]"#),
                       [Place(name: "a", lat: 1.5, lon: 2), Place(name: "", lat: 3, lon: 4)])
    }

    func testSamePlaceRuleAndNewestFirstWithCaps() {
        let (s, _) = store()
        // Latitudes −60…59 (valid coordinates: invalid ones are dropped when the list is read back).
        for i in 0 ..< 120 { s.addFavorite(Place(name: "F\(i)", lat: Double(i - 60), lon: 0)) }
        XCTAssertEqual(s.favorites().count, 100)
        XCTAssertEqual(s.favorites().first?.name, "F119")
        // Same location (|Δ| < 1e-5) replaces and moves to the front; names are ignored.
        s.addFavorite(Place(name: "Renamed", lat: 50.000009, lon: 0.000009))
        XCTAssertEqual(s.favorites().count, 100)
        XCTAssertEqual(s.favorites().first?.name, "Renamed")
        XCTAssertFalse(s.favorites().contains { $0.name == "F110" })
        for i in 0 ..< 60 { s.addMarker(Place(name: "M\(i)", lat: Double(i), lon: 1)) }
        XCTAssertEqual(s.markers().count, 50)
        for i in 0 ..< 40 { s.pushHistory(Place(name: "H\(i)", lat: Double(i), lon: 2)) }
        XCTAssertEqual(s.history().count, 30)
        XCTAssertEqual(s.history().first?.name, "H39")
        XCTAssertTrue(PlacesStore.same(Place(name: "a", lat: 1, lon: 1), Place(name: "b", lat: 1.0000099, lon: 0.9999901)))
        XCTAssertFalse(PlacesStore.same(Place(name: "a", lat: 1, lon: 1), Place(name: "a", lat: 1.00001, lon: 1)))
    }

    func testParkedRules() {
        let (s, _) = store()
        s.setParked(Place(name: "", lat: 44.43, lon: 26.1, category: "x", subtitle: "Marked on dash"))
        let p = s.parked()!
        XCTAssertEqual(p.name, "Parked")
        XCTAssertEqual(p.category, "parking")
        XCTAssertEqual(p.subtitle, "Marked on dash")
        XCTAssertEqual(s.markers(), [p])
        XCTAssertEqual(s.history().first?.subtitle, "Parked here")
        XCTAssertTrue(s.isParked(Place(name: "z", lat: 44.43, lon: 26.1)))
        // Replacing removes the previous marker + history row.
        s.setParked(Place(name: "Bike", lat: 44.5, lon: 26.2))
        XCTAssertEqual(s.markers().map(\.name), ["Bike"])
        XCTAssertEqual(s.history().map(\.lat), [44.5])
        s.clearParked()
        XCTAssertNil(s.parked())
        XCTAssertEqual(s.markers(), [])
        XCTAssertEqual(s.history(), [])
        // Ghost "parking" history rows are purged when nothing is parked.
        s.pushHistory(Place(name: "Ghost", lat: 1, lon: 1, category: "parking"))
        s.pushHistory(Place(name: "Keep", lat: 2, lon: 2))
        s.clearParked()
        XCTAssertEqual(s.history().map(\.name), ["Keep"])
    }

    func testHomeAndDelete() {
        let (s, _) = store()
        s.setHome(Place(name: "", lat: 1, lon: 1, category: "pin", subtitle: "x"))
        let h = s.home()!
        XCTAssertEqual(h, Place(name: "Home", lat: 1, lon: 1, category: "home", subtitle: "Home"))
        XCTAssertEqual(s.favorites(), [h])
        XCTAssertEqual(s.markers(), [h])
        XCTAssertEqual(s.history(), [h])
        s.deletePlace(Place(name: "whatever", lat: 1, lon: 1))
        XCTAssertNil(s.home())
        XCTAssertEqual(s.favorites(), [])
        XCTAssertEqual(s.markers(), [])
        XCTAssertEqual(s.history(), [])
        s.setParked(Place(name: "P", lat: 3, lon: 3))
        s.deletePlace(Place(name: "x", lat: 9, lon: 9, category: "parking"))
        XCTAssertNil(s.parked())
    }

    func testRevisionAndListeners() {
        let (s, _) = store()
        let seen = Locked<[UInt64]>([])
        let id = s.addChangeListener { r in seen.withLock { $0.append(r) } }
        XCTAssertEqual(s.revision, 0)
        s.addMarker(Place(name: "a", lat: 1, lon: 1))
        s.setParked(Place(name: "b", lat: 2, lon: 2))
        XCTAssertEqual(s.revision, 2)
        XCTAssertEqual(seen.current, [1, 2])
        s.removeChangeListener(id)
        s.clearHome()
        XCTAssertEqual(seen.current, [1, 2])
    }

    func testIdleSuggestionsAndCanDelete() {
        let (s, _) = store()
        s.pushHistory(Place(name: "Free ride", lat: 0, lon: 0, category: "mode", subtitle: "Started free ride"))
        s.pushHistory(Place(name: "Old park", lat: 5, lon: 5, category: "parking"))
        s.pushHistory(Place(name: "Visited", lat: 6, lon: 6))
        s.addMarker(Place(name: "Visited", lat: 6.00001, lon: 6.00001)) // same name & %.4f → deduped
        s.addFavorite(Place(name: "Fav", lat: 7, lon: 7))
        s.setHome(Place(name: "Home", lat: 8, lon: 8))
        s.setParked(Place(name: "", lat: 9, lon: 9))
        let idle = s.idleSuggestions()
        XCTAssertEqual(idle.map(\.name), ["Home", "Parked", "Fav", "Visited"])
        XCTAssertTrue(s.canDelete(Place(name: "x", lat: 6, lon: 6)))
        XCTAssertTrue(s.canDelete(Place(name: "x", lat: 50, lon: 50, category: "pin")))
        XCTAssertFalse(s.canDelete(Place(name: "x", lat: 50, lon: 50, category: "city")))
    }

    // MARK: Backup

    func testExportImportRoundTripAndFormat() {
        let (s, _) = store()
        s.addFavorite(Place(name: "Fav", lat: 44.4268, lon: 26.1025, category: "city", subtitle: "B"))
        s.setParked(Place(name: "Parked", lat: 45, lon: 25, category: "parking", subtitle: "Marked on dash"))
        var prefs = MapPreferences()
        prefs.units = .imperial
        prefs.avoidTolls = true
        prefs.circuitKm = 100
        let json = MapDataBackup.exportJSON(places: s, preferences: prefs, buildings3d: false, appVersion: "0.1.0",
                                            now: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(identifier: "Europe/Bucharest")!)
        XCTAssertTrue(json.hasPrefix("{\n  \"format\": \"opencfmoto.map\",\n  \"version\": 1,\n  \"exportedAt\": \"2023-11-15T00:13:20+02:00\",\n  \"appVersion\": \"0.1.0\",\n  \"prefs\": {\n    \"units\": \"IMPERIAL\","))
        XCTAssertTrue(json.contains("\n  \"favorites\": [\n    {\n      \"name\": \"Fav\",\n      \"lat\": 44.4268,"))
        XCTAssertTrue(json.contains("\"buildings3d\": false"))
        XCTAssertTrue(json.contains("\"funCircuitKm\": 100\n  },"))
        XCTAssertTrue(json.contains("\"parked\": {"))
        XCTAssertFalse(json.contains("\"home\""))
        XCTAssertFalse(json.contains("ors"))
        // Import into a fresh store: places replaced, prefs applied.
        let (t, _) = store()
        t.setHome(Place(name: "Old home", lat: 1, lon: 1))
        let r = MapDataBackup.importJSON("\u{FEFF}  " + json, into: t, preferences: MapPreferences())
        XCTAssertTrue(r.ok, r.message)
        XCTAssertEqual(r.message, "Map data imported")
        XCTAssertEqual(r.preferences?.units, .imperial)
        XCTAssertEqual(r.preferences?.avoidTolls, true)
        XCTAssertEqual(r.preferences?.circuitKm, 100)
        XCTAssertEqual(r.buildings3d, false)
        XCTAssertEqual(t.favorites(), s.favorites())
        XCTAssertEqual(t.markers(), s.markers())
        XCTAssertEqual(t.history(), s.history())
        XCTAssertEqual(t.parked(), s.parked())
        XCTAssertNil(t.home()) // a file without "home" clears it (Android replaceAll)
    }

    func testImportErrorsAndLeniency() {
        let (s, _) = store()
        XCTAssertTrue(MapDataBackup.importJSON("{", into: s, preferences: MapPreferences()).message.hasPrefix("Not valid JSON: "))
        XCTAssertEqual(MapDataBackup.importJSON(#"{"format":"opencfmoto.settings","version":1}"#, into: s, preferences: MapPreferences()).message,
                       "Not an OpenCfMoto map file")
        XCTAssertEqual(MapDataBackup.importJSON(#"{"format":"opencfmoto.map","version":2}"#, into: s, preferences: MapPreferences()).message,
                       "Unsupported map backup version 2")
        XCTAssertEqual(MapDataBackup.importJSON(#"{"format":"opencfmoto.map"}"#, into: s, preferences: MapPreferences()).message,
                       "Unsupported map backup version 0")
        let r = MapDataBackup.importJSON(#"{"format":"opencfmoto.map","version":"1","prefs":{"units":"FURLONGS","chrome":"SLATE","funCircuitKm":999,"voicePrompts":"false"},"favorites":[{"name":"a","lat":1,"lon":2},{"name":"bad"}],"markers":[],"history":[]}"#,
                                         into: s, preferences: MapPreferences())
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.preferences?.units, .metric)
        XCTAssertEqual(r.preferences?.chrome, .slate)
        XCTAssertEqual(r.preferences?.circuitKm, 150)
        XCTAssertEqual(r.preferences?.voiceOn, false)
        XCTAssertEqual(s.favorites().map(\.name), ["a"])
        let bad = MapDataBackup.importJSON(#"{"format":"opencfmoto.map","version":1,"markers":[1]}"#, into: s, preferences: MapPreferences())
        XCTAssertFalse(bad.ok)
        XCTAssertTrue(bad.message.hasPrefix("Import failed: "))
        XCTAssertEqual(MapDataBackup.suggestedFileName(now: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(identifier: "UTC")!),
                       "OpenCfMoto-map-20231114.json")
    }

    func testOrgJSONPrettyLayout() {
        var inner = OrderedJSONObject()
        inner.put("a", 1)
        var o = OrderedJSONObject()
        o.put("x", "y/z")
        o.put("e", .array([]))
        o.put("eo", OrderedJSONObject())
        o.put("arr", .array([.object(inner), .int(2)]))
        XCTAssertEqual(OrgJSONPretty.format(.object(o)),
                       "{\n  \"x\": \"y\\/z\",\n  \"e\": [],\n  \"eo\": {},\n  \"arr\": [\n    {\n      \"a\": 1\n    },\n    2\n  ]\n}")
    }

    // MARK: Saved slots

    func testSavedPlaceSlots() {
        let kv = InMemoryKeyValueStore()
        let slots = SavedPlaceSlots(store: kv)
        XCTAssertFalse(slots.isSet(0))
        XCTAssertEqual(slots.actionLabel(0), "Navigate to saved place 1 (not set yet)")
        XCTAssertEqual(slots.actionLabel(2, language: .es), "Navegar al lugar guardado 3 (sin configurar)")
        slots.set(1, name: "  Work ", query: " Strada Exemplu 1, București ")
        XCTAssertEqual(kv.string(forKey: "saved_places.name1"), "Work")
        XCTAssertEqual(kv.string(forKey: "saved_places.query1"), "Strada Exemplu 1, București")
        XCTAssertTrue(slots.isSet(1))
        XCTAssertEqual(slots.actionLabel(1), "Navigate: Work")
        slots.set(2, name: "", query: "44.4268, 26.1025")
        XCTAssertEqual(slots.actionLabel(2), "Navigate: 44.4268, 26.1025")
        XCTAssertEqual(SavedPlaceSlots.parseCoordinate("44.4268, 26.1025"), GeoPoint(lat: 44.4268, lon: 26.1025))
        XCTAssertNil(SavedPlaceSlots.parseCoordinate("Strada 1, Bucuresti"))
        XCTAssertNil(SavedPlaceSlots.parseCoordinate("95,10"))
    }
}
