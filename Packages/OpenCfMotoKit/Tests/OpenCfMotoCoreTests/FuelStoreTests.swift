// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: fuel data lives only under `<base>#<bikeId>` keys, with no global fallback; removal of a Garage
// bike deletes it; nothing reaches the settings export.
import Foundation
import XCTest
@testable import OpenCfMotoCore

final class FuelStoreTests: XCTestCase {
    private var kv: InMemoryKeyValueStore!
    private var store: FuelStore!

    override func setUp() {
        super.setUp()
        kv = InMemoryKeyValueStore()
        store = FuelStore(store: kv)
    }

    private var profile: FuelProfile { FuelT.mt450() }

    private func sampleLog() -> RefuelLog {
        RefuelLog(entries: [FuelT.full("a", odo: 1000), FuelT.full("b", odo: 1300, litres: 15, per: 4.25)])
    }

    func testKeys() {
        XCTAssertEqual(FuelStore.key(FuelStore.Keys.profile, bikeId: "b58cde373"), "fuel_profile_v1#b58cde373")
        XCTAssertEqual(FuelStore.key(FuelStore.Keys.log, bikeId: "b58cde373x2"), "fuel_log_v1#b58cde373x2")
        for bad in ["", "b1#x", "../a", "b 1", "b1/2", "bñ"] {
            XCTAssertNil(FuelStore.key(FuelStore.Keys.profile, bikeId: bad), bad)
            store.setProfile(profile, bikeId: bad)
            store.setLog(sampleLog(), bikeId: bad)
            store.setAlertLevel(.low, bikeId: bad)
            store.setSetupDeferred(true, bikeId: bad)
            store.setOdometer(FuelT.odometer(5), bikeId: bad)
            XCTAssertNil(store.profile(bikeId: bad))
        }
        XCTAssertEqual(kv.allKeys(), [], "nothing written for an odd id — never the bare base")
        XCTAssertEqual(FuelStore.Keys.all, ["fuel_profile_v1", "fuel_log_v1", "fuel_odo_v1", "fuel_alert_v1", "fuel_setup_later_v1"])
    }

    func testRoundTrips() {
        store.setProfile(profile, bikeId: "b1")
        XCTAssertEqual(store.profile(bikeId: "b1"), profile)
        store.setLog(sampleLog(), bikeId: "b1")
        XCTAssertEqual(store.log(bikeId: "b1"), sampleLog())
        var odo = FuelT.odometer(1402.37)
        odo.gapsMs = [7]
        store.setOdometer(odo, bikeId: "b1")
        XCTAssertEqual(store.odometer(bikeId: "b1"), odo)
        store.setAlertLevel(.reserve, bikeId: "b1")
        XCTAssertEqual(store.alertLevel(bikeId: "b1"), .reserve)
        XCTAssertEqual(kv.string(forKey: "fuel_alert_v1#b1"), "reserve")
        store.setAlertLevel(nil, bikeId: "b1")
        XCTAssertNil(kv.string(forKey: "fuel_alert_v1#b1"))
        store.setSetupDeferred(true, bikeId: "b1")
        XCTAssertTrue(store.isSetupDeferred(bikeId: "b1"))
        XCTAssertEqual(kv.bool(forKey: "fuel_setup_later_v1#b1"), true)
        store.setSetupDeferred(false, bikeId: "b1")
        XCTAssertNil(kv.bool(forKey: "fuel_setup_later_v1#b1"))
        // an empty log removes the key; nil profile removes it
        store.setLog(RefuelLog(), bikeId: "b1")
        XCTAssertNil(kv.data(forKey: "fuel_log_v1#b1"))
        XCTAssertEqual(store.log(bikeId: "b1"), RefuelLog())
        store.setProfile(nil, bikeId: "b1")
        XCTAssertNil(kv.data(forKey: "fuel_profile_v1#b1"))
        XCTAssertEqual(store.odometer(bikeId: "b2"), FuelOdometerState(), "fresh when absent")
        // the stored JSON is the documented shape
        store.setProfile(profile, bikeId: "b1")
        let text = String(decoding: kv.data(forKey: "fuel_profile_v1#b1")!, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix(#"{"catalogId":"cfmoto-450mt""#), text)
    }

    func testNoFallbackAndNoLeakBetweenBikes() {
        // a value under the bare base is never returned
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        kv.set(try! e.encode(profile), forKey: FuelStore.Keys.profile)
        kv.set(try! e.encode(sampleLog()), forKey: FuelStore.Keys.log)
        kv.set("low", forKey: FuelStore.Keys.alert)
        kv.set(true, forKey: FuelStore.Keys.setupDeferred)
        XCTAssertNil(store.profile(bikeId: "b1"))
        XCTAssertEqual(store.log(bikeId: "b1"), RefuelLog())
        XCTAssertNil(store.alertLevel(bikeId: "b1"))
        XCTAssertFalse(store.isSetupDeferred(bikeId: "b1"))
        // bike A's data is invisible to bike B
        store.setProfile(profile, bikeId: "bA")
        store.setLog(sampleLog(), bikeId: "bA")
        XCTAssertNil(store.profile(bikeId: "bB"))
        XCTAssertEqual(store.log(bikeId: "bB").entries, [])
    }

    func testUnreadableAndNewerDocumentsReadAsAbsentAndStay() {
        kv.set(Data("garbage".utf8), forKey: "fuel_profile_v1#b1")
        kv.set(Data(#"{"entries":[],"v":2}"#.utf8), forKey: "fuel_log_v1#b1")
        kv.set(Data(#"{"totalKm":3,"v":2}"#.utf8), forKey: "fuel_odo_v1#b1")
        let lines = Locked<[String]>([])
        let sub = Log.shared.subscribe { line in if line.tag == "fuel" { lines.withLock { $0.append(line.message) } } }
        defer { Log.shared.unsubscribe(sub) }
        XCTAssertNil(store.profile(bikeId: "b1"))
        XCTAssertNil(store.profile(bikeId: "b1"))
        XCTAssertEqual(store.log(bikeId: "b1"), RefuelLog())
        XCTAssertEqual(store.odometer(bikeId: "b1"), FuelOdometerState())
        XCTAssertTrue(store.isUnreadable(FuelStore.Keys.profile, bikeId: "b1"))
        XCTAssertTrue(store.isUnreadable(FuelStore.Keys.log, bikeId: "b1"))
        XCTAssertTrue(store.isUnreadable(FuelStore.Keys.odometer, bikeId: "b1"))
        XCTAssertFalse(store.isUnreadable(FuelStore.Keys.profile, bikeId: "b2"))
        XCTAssertEqual(String(decoding: kv.data(forKey: "fuel_profile_v1#b1")!, as: UTF8.self), "garbage", "left in place")
        XCTAssertNotNil(kv.data(forKey: "fuel_log_v1#b1"))
        let warned = lines.withLock { $0 }
        XCTAssertEqual(warned.filter { $0 == "ignoring stored fuel_profile_v1 (unreadable or newer)" }.count, 1, "once: \(warned)")
        XCTAssertTrue(warned.contains("ignoring stored fuel_log_v1 (unreadable or newer)"))
        // an explicit write replaces it
        store.setProfile(profile, bikeId: "b1")
        XCTAssertEqual(store.profile(bikeId: "b1"), profile)
        XCTAssertFalse(store.isUnreadable(FuelStore.Keys.profile, bikeId: "b1"))
    }

    func testGarageRemovalDeletesTheFuelKeysOfThatBikeOnly() throws {
        let garage = Garage(store: kv, secrets: InMemorySecretStore())
        let a = garage.save(try XCTUnwrap(BikeQR.parse("http://www.carbit.com.cn/downsdk/1/2/_sdk?modelid=37416&sn=a&action=1&ssid=CFMOTO-aaaa01&pwd=demo1234&auth=wpa2-psk")))
        let b = garage.save(try XCTUnwrap(BikeQR.parse("http://www.carbit.com.cn/downsdk/1/2/_sdk?modelid=37416&sn=b&action=1&ssid=CFMOTO-bbbb02&pwd=demo1234&auth=wpa2-psk")))
        for id in [a.id, b.id] {
            store.setProfile(profile, bikeId: id)
            store.setLog(sampleLog(), bikeId: id)
            store.setOdometer(FuelT.odometer(10), bikeId: id)
            store.setAlertLevel(.low, bikeId: id)
            store.setSetupDeferred(true, bikeId: id)
        }
        store.setVolumeUnit(.usGallon)
        for base in FuelStore.Keys.all {
            XCTAssertTrue(BikeScope.isKey(FuelStore.key(base, bikeId: a.id)!, scopedTo: a.id), base)
        }
        garage.remove(a.id)
        for base in FuelStore.Keys.all {
            XCTAssertNil(kv.data(forKey: base + "#" + a.id) ?? kv.string(forKey: base + "#" + a.id).map { Data($0.utf8) }, base)
            XCTAssertNil(kv.bool(forKey: base + "#" + a.id), base)
        }
        XCTAssertFalse(kv.allKeys().contains { $0.hasSuffix("#" + a.id) })
        XCTAssertEqual(store.profile(bikeId: b.id), profile, "the other bike keeps its data")
        XCTAssertEqual(store.alertLevel(bikeId: b.id), .low)
        XCTAssertEqual(store.volumeUnit(), .usGallon, "the pump's unit is not bike data")
        garage.clear()
        XCTAssertFalse(kv.allKeys().contains { $0.hasPrefix("fuel_") })
        XCTAssertEqual(store.volumeUnit(), .usGallon)
        XCTAssertEqual(kv.string(forKey: "ios_fuel_volume_unit_v1"), "gal")
    }

    func testRemoveAll() {
        for base in FuelStore.Keys.all { kv.set("x", forKey: base + "#b1") }
        kv.set("x", forKey: "fuel_profile_v1#b2")
        store.removeAll(bikeId: "b1")
        XCTAssertEqual(kv.allKeys(), ["fuel_profile_v1#b2"])
    }

    func testVolumeUnitPreference() {
        XCTAssertNil(store.volumeUnit())
        store.setVolumeUnit(.litre)
        XCTAssertEqual(store.volumeUnit(), .litre)
        XCTAssertEqual(kv.string(forKey: FuelStore.volumeUnitKey), "L")
        kv.set("pints", forKey: FuelStore.volumeUnitKey)
        XCTAssertNil(store.volumeUnit())
        XCTAssertFalse(FuelStore.Keys.all.contains(FuelStore.volumeUnitKey))
    }

    func testTheSettingsExportCarriesNoFuelData() {
        let settings = SettingsStore(store: kv)
        store.setProfile(profile, bikeId: "b1")
        store.setLog(sampleLog(), bikeId: "b1")
        store.setOdometer(FuelT.odometer(10), bikeId: "b1")
        store.setVolumeUnit(.usGallon)
        for bike in [Optional("b1"), nil] {
            let text = SettingsBackup.exportJSON(from: settings, bikeId: bike, profileName: "Test", appVersion: "1.0").lowercased()
            for word in ["fuel", "tank", "litre", "refuel", "odo", "gal\""] { XCTAssertFalse(text.contains(word), "\(word) in the export") }
        }
    }
}
