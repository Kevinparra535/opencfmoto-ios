// SPDX-License-Identifier: AGPL-3.0-or-later
// Garage (BikeMemory.kt port with the iOS SSID-identity fix) and BikeScope vectors
// (session-network.md §8.1/§8.3, app-features.md §2.1/§4).

import XCTest
@testable import OpenCfMotoCore

final class GarageTests: XCTestCase {

    static let docQR = "http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37416&sn=peTz&action=9&ssid=CFMOTO-f46457&pwd=59a9cddc94&auth=wpa2-psk&mac=6C:09:4A:0F:6C:F8&name=CFMOTO-f46457"
    static let qr4288 = "http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37426&sn=Vasr&action=1&ssid=CFMOTO4288&pwd=e278450c&uid=abc"

    private func makeGarage() -> (Garage, InMemoryKeyValueStore, InMemorySecretStore) {
        let kv = InMemoryKeyValueStore()
        let sec = InMemorySecretStore()
        return (Garage(store: kv, secrets: sec), kv, sec)
    }

    // MARK: BikeScope vectors

    func testBikeScopeIds() {
        XCTAssertEqual(BikeScope.id(forRaw: Self.docQR), "b58cde373")
        XCTAssertEqual(BikeScope.id(forRaw: Self.qr4288), "bae532b19")
        XCTAssertEqual(BikeScope.id(forRaw: "CARBITDC0D3024876D"), "b2c2476f8")
        XCTAssertEqual(BikeScope.id(forRaw: "http://g.thinkerride.com?CQKY_5e1c6cb10&81316044&ap=1"), "bcd8769cf")
        XCTAssertEqual(BikeScope.id(forRaw: "http://manual.opencfmoto.local/?ssid=CFMOTO-123&pwd=pass%20word&auth=wpa2-psk&action=1&name=CFMOTO-123"), "b71cb90bd")
        XCTAssertEqual(BikeScope.id(forRaw: "CARBIT0123456789AB"), "ba194841f")
        XCTAssertEqual(BikeScope.id(forRaw: "a"), "b61")
        XCTAssertEqual(BikeScope.id(forRaw: ""), "b0")
        XCTAssertEqual(BikeScope.javaHashCode(Self.docQR), 1_489_888_115)
    }

    func testScopedKey() {
        XCTAssertEqual(BikeScope.scopedKey("video_quality", bikeId: "b58cde373"), "video_quality#b58cde373")
        XCTAssertEqual(BikeScope.scopedKey("video_quality", bikeId: nil), "video_quality")
        XCTAssertEqual(BikeScope.scopedKey("video_quality", bikeId: ""), "video_quality")
        XCTAssertTrue(BikeScope.isKey("button_map.navBack#b61", scopedTo: "b61"))
        XCTAssertFalse(BikeScope.isKey("button_map.navBack#b610", scopedTo: "b61"))
    }

    // MARK: Garage

    func testSaveCreatesSelectsAndStoresRawAsSecret() {
        let (g, kv, sec) = makeGarage()
        XCTAssertNil(g.selected)
        let bike = g.save(BikeQR.parse(Self.docQR)!)
        XCTAssertEqual(bike.id, "b58cde373")
        XCTAssertEqual(bike.ssid, "CFMOTO-f46457")
        XCTAssertEqual(bike.mac, "6c:09:4a:0f:6c:f8")
        XCTAssertEqual(bike.name, "CFMOTO-f46457")   // qr.name
        XCTAssertEqual(g.selected, bike)
        XCTAssertEqual(g.raw(for: bike.id), Self.docQR)
        XCTAssertEqual(sec.secret(forKey: "garage.raw.b58cde373"), Self.docQR)
        // the password never lands in the key-value store
        for key in kv.allKeys() {
            if let s = kv.string(forKey: key) { XCTAssertFalse(s.contains("59a9cddc94")) }
            if let d = kv.data(forKey: key) { XCTAssertFalse(String(decoding: d, as: UTF8.self).contains("59a9cddc94")) }
        }
        XCTAssertEqual(g.qr(for: bike.id)?.password, "59a9cddc94")
    }

    func testNameFallsBackToSsid() {
        let (g, _, _) = makeGarage()
        let b = g.save(BikeQR.parse(Self.qr4288)!)
        XCTAssertEqual(b.name, "CFMOTO4288")
        XCTAssertEqual(b.id, "bae532b19")
    }

    func testRescanWithNewNonceUpdatesSameBike() {
        let (g, _, _) = makeGarage()
        let first = g.save(BikeQR.parse(Self.qr4288)!)
        g.rename(first.id, to: "  My 800MT  ")
        g.setPhoto(first.id, fileName: "bae532b19.jpg")
        _ = g.save(BikeQR.parse(Self.docQR)!)   // another bike in front
        let rescan = Self.qr4288.replacingOccurrences(of: "sn=Vasr", with: "sn=Zq9X")
        let again = g.save(BikeQR.parse(rescan)!)
        XCTAssertEqual(g.bikes.count, 2)
        XCTAssertEqual(again.id, first.id)               // stable scope id
        XCTAssertEqual(again.name, "My 800MT")           // custom name kept (trimmed)
        XCTAssertEqual(again.photoFileName, "bae532b19.jpg")
        XCTAssertEqual(g.bikes.first?.id, first.id)      // moved to front
        XCTAssertEqual(g.selected?.id, first.id)
        XCTAssertEqual(g.raw(for: first.id), rescan)     // latest raw kept
    }

    func testMacConflictMeansDifferentBike() {
        let (g, _, _) = makeGarage()
        let a = g.save(BikeQR.parse("http://x/?ssid=SAME&pwd=p1&mac=aa:bb:cc:dd:ee:01")!)
        let b = g.save(BikeQR.parse("http://x/?ssid=SAME&pwd=p2&mac=aa:bb:cc:dd:ee:02")!)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(g.bikes.count, 2)
        // a scan without MAC matches the most recent same-SSID bike; a learned MAC is filled in
        let c = g.save(BikeQR.parse("http://x/?ssid=SOLO&pwd=p")!)
        XCTAssertNil(c.mac)
        let d = g.save(BikeQR.parse("http://x/?ssid=SOLO&pwd=p&sn=2&mac=AABBCCDDEEFF")!)
        XCTAssertEqual(d.id, c.id)
        XCTAssertEqual(d.mac, "aa:bb:cc:dd:ee:ff")
    }

    func testSelectRenamePhotoProfileHint() {
        let (g, _, _) = makeGarage()
        let a = g.save(BikeQR.parse(Self.docQR)!)
        let b = g.save(BikeQR.parse(Self.qr4288)!)
        XCTAssertEqual(g.selected?.id, b.id)
        g.select(a.id)
        XCTAssertEqual(g.selected?.id, a.id)
        XCTAssertEqual(g.bikes.map(\.id), [b.id, a.id])  // select does not reorder
        g.rename(a.id, to: "   ")                       // blank keeps
        XCTAssertEqual(g.bike(id: a.id)?.name, "CFMOTO-f46457")
        g.setProfileHint(a.id, .legacy)
        XCTAssertEqual(g.bike(id: a.id)?.profileHint, .legacy)
        g.setPhoto(a.id, fileName: "")
        XCTAssertNil(g.bike(id: a.id)?.photoFileName)
        g.select("nope")                                 // stale selection → first bike
        XCTAssertEqual(g.selected?.id, b.id)
    }

    func testPersistenceAcrossInstances() {
        let kv = InMemoryKeyValueStore()
        let sec = InMemorySecretStore()
        let g1 = Garage(store: kv, secrets: sec)
        let a = g1.save(BikeQR.parse(Self.docQR)!)
        g1.setProfileHint(a.id, .nkAdvanced)
        _ = g1.save(BikeQR.parse(Self.qr4288)!)
        g1.select(a.id)
        let g2 = Garage(store: kv, secrets: sec)
        XCTAssertEqual(g2.bikes, g1.bikes)
        XCTAssertEqual(g2.selected?.id, a.id)
        XCTAssertEqual(g2.bike(id: a.id)?.profileHint, .nkAdvanced)
        XCTAssertEqual(g2.qr(for: a.id)?.ssid, "CFMOTO-f46457")
        // another instance (process) changes the list → reload picks it up
        g1.rename(a.id, to: "Renamed")
        XCTAssertNotEqual(g2.bike(id: a.id)?.name, "Renamed")
        g2.reload()
        XCTAssertEqual(g2.bike(id: a.id)?.name, "Renamed")
    }

    func testRemoveDeletesScopedSettingsAndSsidData() {
        let (g, kv, sec) = makeGarage()
        let a = g.save(BikeQR.parse(Self.docQR)!)
        let b = g.save(BikeQR.parse(Self.qr4288)!)
        kv.set("SHARP", forKey: "video_quality#\(a.id)")
        kv.set("SMOOTH", forKey: "video_quality#\(b.id)")
        kv.set("FIT", forKey: "screen_fit")
        kv.set("800x386", forKey: "dash_geo_CFMOTO-f46457")
        kv.set("AP", forKey: "transport_CFMOTO-f46457")
        g.select(a.id)
        let removed = g.remove(a.id)
        XCTAssertEqual(removed?.id, a.id)
        XCTAssertNil(g.bike(id: a.id))
        XCTAssertEqual(g.selected?.id, b.id)
        XCTAssertNil(kv.string(forKey: "video_quality#\(a.id)"))
        XCTAssertEqual(kv.string(forKey: "video_quality#\(b.id)"), "SMOOTH")
        XCTAssertEqual(kv.string(forKey: "screen_fit"), "FIT")
        XCTAssertNil(kv.string(forKey: "dash_geo_CFMOTO-f46457"))
        XCTAssertNil(kv.string(forKey: "transport_CFMOTO-f46457"))
        XCTAssertNil(sec.secret(forKey: "garage.raw.\(a.id)"))
        XCTAssertNil(g.remove("unknown"))
    }

    func testRemoveKeepsSsidDataSharedWithAnotherBike() {
        let (g, kv, _) = makeGarage()
        let a = g.save(BikeQR.parse("http://x/?ssid=SAME&pwd=p1&mac=aa:bb:cc:dd:ee:01")!)
        _ = g.save(BikeQR.parse("http://x/?ssid=SAME&pwd=p2&mac=aa:bb:cc:dd:ee:02")!)
        kv.set("800x386", forKey: "dash_geo_SAME")
        g.remove(a.id)
        XCTAssertEqual(kv.string(forKey: "dash_geo_SAME"), "800x386")
    }

    func testClear() {
        let (g, kv, sec) = makeGarage()
        let a = g.save(BikeQR.parse(Self.docQR)!)
        kv.set("SHARP", forKey: "video_quality#\(a.id)")
        g.clear()
        XCTAssertTrue(g.bikes.isEmpty)
        XCTAssertNil(g.selected)
        XCTAssertNil(sec.secret(forKey: "garage.raw.\(a.id)"))
        XCTAssertNil(kv.string(forKey: "video_quality#\(a.id)"))
    }

    func testWinningTransport() {
        let (g, _, _) = makeGarage()
        XCTAssertNil(g.winningTransport(ssid: "CFMOTO4288"))
        g.setWinningTransport(ssid: "CFMOTO4288", transport: "AP")
        XCTAssertEqual(g.winningTransport(ssid: "CFMOTO4288"), "AP")
        g.setWinningTransport(ssid: "  ", transport: "P2P")
        XCTAssertNil(g.winningTransport(ssid: "  "))
    }

    // MARK: Android bikes_json import (app-features §4.1)

    static let androidJSON = #"[{"raw":"http:\/\/www.carbit.com.cn\/downsdk\/657\/658\/_sdk?modelid=37416&sn=peTz&action=9&ssid=CFMOTO-f46457&pwd=59a9cddc94&auth=wpa2-psk&mac=6C:09:4A:0F:6C:F8&name=CFMOTO-f46457","name":"CFMOTO-f46457","photo":"\/data\/user\/0\/dev.zanderp.opencfmoto\/files\/bike_photos\/b58cde373.jpg"},{"raw":"http:\/\/manual.opencfmoto.local\/?ssid=TRK702X-1A2B&pwd=12345678&auth=wpa2-psk&action=1&name=My%20TRK","name":"My TRK"}]"#

    func testParseAndroidBikesJSON() {
        let bikes = Garage.parseAndroidBikesJSON(Self.androidJSON)
        XCTAssertEqual(bikes.count, 2)
        XCTAssertEqual(bikes[0].raw, Self.docQR)
        XCTAssertEqual(bikes[0].name, "CFMOTO-f46457")
        XCTAssertEqual(bikes[0].photoPath, "/data/user/0/dev.zanderp.opencfmoto/files/bike_photos/b58cde373.jpg")
        XCTAssertEqual(bikes[1].raw, "http://manual.opencfmoto.local/?ssid=TRK702X-1A2B&pwd=12345678&auth=wpa2-psk&action=1&name=My%20TRK")
        XCTAssertEqual(bikes[1].name, "My TRK")
        XCTAssertNil(bikes[1].photoPath)
    }

    func testParseAndroidBikesJSONLeniency() {
        XCTAssertEqual(Garage.parseAndroidBikesJSON("not json"), [])
        XCTAssertEqual(Garage.parseAndroidBikesJSON(#"{"raw":"x"}"#), [])            // not an array
        let bikes = Garage.parseAndroidBikesJSON(#"[1, null, {"raw":"  "}, {"raw":"R","name":" ","photo":" "}, {"raw":"S"}]"#)
        XCTAssertEqual(bikes, [AndroidSavedBike(raw: "R", name: "R", photoPath: nil), AndroidSavedBike(raw: "S", name: "S")])
    }

    func testImportAndroidBikesJSON() {
        let (g, _, _) = makeGarage()
        let r = g.importAndroidBikesJSON(Self.androidJSON)
        XCTAssertEqual(r, GarageImportResult(added: 2, updated: 0, skippedUnparsable: 0, droppedPhotos: 1))
        XCTAssertEqual(g.bikes.map(\.name), ["CFMOTO-f46457", "My TRK"])      // Android order kept
        XCTAssertEqual(g.bikes.map(\.id), ["b58cde373", BikeScope.id(forRaw: "http://manual.opencfmoto.local/?ssid=TRK702X-1A2B&pwd=12345678&auth=wpa2-psk&action=1&name=My%20TRK")])
        XCTAssertEqual(g.selected?.id, "b58cde373")                        // Android default: first
        XCTAssertNil(g.bikes[0].photoFileName)
        XCTAssertEqual(g.qr(for: g.bikes[1].id)?.ssid, "TRK702X-1A2B")
    }

    func testImportHonoursSelectedRawAndExistingBikes() {
        let (g, _, _) = makeGarage()
        let existing = g.save(BikeQR.parse(Self.docQR.replacingOccurrences(of: "sn=peTz", with: "sn=AAAA"))!)
        g.rename(existing.id, to: "Naranja")
        let manual = "http://manual.opencfmoto.local/?ssid=TRK702X-1A2B&pwd=12345678&auth=wpa2-psk&action=1&name=My%20TRK"
        let r = g.importAndroidBikesJSON(Self.androidJSON + "", selectedRaw: manual)
        XCTAssertEqual(r.added, 1)
        XCTAssertEqual(r.updated, 1)
        XCTAssertEqual(g.bike(id: existing.id)?.name, "Naranja")              // iOS name kept
        XCTAssertEqual(g.raw(for: existing.id), Self.docQR)                  // raw refreshed
        XCTAssertEqual(g.selected?.ssid, "TRK702X-1A2B")
        let skipped = g.importAndroidBikesJSON(#"[{"raw":"not a qr"}]"#)
        XCTAssertEqual(skipped.skippedUnparsable, 1)
    }
}
