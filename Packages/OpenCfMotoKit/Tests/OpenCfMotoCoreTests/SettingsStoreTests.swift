// SPDX-License-Identifier: AGPL-3.0-or-later
// SettingsStore: scoped → global → default resolution with Android key names and setter couplings
// (app-features.md §2, session-network.md §8.3, input-controls.md §7.12).

import XCTest
@testable import OpenCfMotoCore

final class SettingsStoreTests: XCTestCase {

    private let bike = "b58cde373"
    private let other = "bae532b19"

    private func make() -> (SettingsStore, InMemoryKeyValueStore) {
        let kv = InMemoryKeyValueStore()
        return (SettingsStore(store: kv), kv)
    }

    func testDefaults() {
        let (s, _) = make()
        let v = s.settings(forBike: nil)
        var expected = BikeSettings()
        expected.buttonMap = HandlebarPresets.iosDefaultMapping
        XCTAssertEqual(v, expected)
        XCTAssertEqual(v.videoQuality, .balanced)
        XCTAssertEqual(v.powerMode, .balanced)
        XCTAssertEqual(v.screenFit, .fill)
        XCTAssertNil(v.profileOverride)
        XCTAssertTrue(v.handlebarControl)
        XCTAssertEqual(v.buttonTiming, ButtonTiming())
        XCTAssertEqual(s.androidOnlySettings(forBike: nil), AndroidOnlySettings())
        XCTAssertEqual(s.presence(forBike: bike), HandlebarPresence())
        XCTAssertTrue(s.snappySingles)
        // Android defaults can be requested explicitly
        let android = SettingsStore(store: InMemoryKeyValueStore(), defaultButtonMap: HandlebarPresets.androidDefaults)
        XCTAssertEqual(android.settings(forBike: nil), BikeSettings())
    }

    func testScopedFallbackChain() {
        let (s, kv) = make()
        s.setVideoQuality(.sharp, forBike: nil)                  // global (no bike selected)
        XCTAssertEqual(kv.string(forKey: "video_quality"), "SHARP")
        XCTAssertEqual(s.settings(forBike: bike).videoQuality, .sharp) // inherited
        s.setVideoQuality(.smooth, forBike: bike)
        XCTAssertEqual(kv.string(forKey: "video_quality#b58cde373"), "SMOOTH")
        XCTAssertEqual(s.settings(forBike: bike).videoQuality, .smooth)
        XCTAssertEqual(s.settings(forBike: other).videoQuality, .sharp)
        XCTAssertEqual(s.settings(forBike: nil).videoQuality, .sharp)
        // an invalid scoped value reads as the DEFAULT (Android valueOf fails), not the global value
        kv.set("ULTRA", forKey: "video_quality#\(other)")
        XCTAssertEqual(s.settings(forBike: other).videoQuality, .balanced)
        // exact-case enum names
        kv.set("sharp", forKey: "screen_fit")
        XCTAssertEqual(s.settings(forBike: nil).screenFit, .fill)
    }

    func testUpdateWritesOnlyChangedFields() {
        let (s, kv) = make()
        let r = s.update(forBike: bike) { $0.powerMode = .saver }
        XCTAssertEqual(r.powerMode, .saver)
        XCTAssertEqual(kv.allKeys(), ["power_mode#b58cde373"])
        s.update(forBike: bike) { $0.buttonMap[.selectDouble] = .assistant }
        XCTAssertEqual(kv.string(forKey: "button_map.selectDouble#b58cde373"), "assistant")
        XCTAssertEqual(Set(kv.allKeys()), ["power_mode#b58cde373", "button_map.selectDouble#b58cde373"])
        XCTAssertEqual(s.settings(forBike: bike).buttonMap[.selectDouble], .assistant)
        XCTAssertEqual(s.settings(forBike: other).buttonMap[.selectDouble], ButtonAction.none) // P0 (D02) default
    }

    func testAPreP0DefaultMapReadsAsTodaysDefaultAndStaysSoAfterAnEdit() {
        // P0 (D02): applying 5-way on an earlier build wrote the nine gestures of the old iOS default
        // (★★ Back, ▶▶ Home, ◀◀ D-pad left); that map now reads as today's default (doubles unmapped).
        let (s, kv) = make()
        for (g, a) in HandlebarPresets.iosDefaultMappingBeforeP0 { kv.set(a.rawValue, forKey: "button_map.\(g.rawValue)#b58cde373") }
        kv.set("five_way", forKey: "button_cluster_preset.active#b58cde373")
        XCTAssertEqual(s.settings(forBike: bike).buttonMap, HandlebarPresets.iosDefaultMapping)
        XCTAssertTrue(s.isButtonMapDefault(forBike: bike))
        XCTAssertEqual(s.settings(forBike: bike).clusterPreset, .fiveWay)
        // one gesture changed later: the other doubles stay as today's default (the migrated map is pinned first)
        s.setButtonAction(.home, for: .navFwdLong, forBike: bike)
        var m = s.settings(forBike: bike).buttonMap
        XCTAssertEqual(m[.navFwdLong], .home)
        for g in [ButtonGesture.selectDouble, .navFwdDouble, .navBackDouble] { XCTAssertEqual(m[g], HandlebarPresets.iosDefaultMapping[g], "\(g)") }
        XCTAssertEqual(kv.string(forKey: "button_map.selectDouble#b58cde373"), "none")
        // the same through update(forBike:)
        let (s2, kv2) = make()
        for (g, a) in HandlebarPresets.iosDefaultMappingBeforeP0 { kv2.set(a.rawValue, forKey: "button_map.\(g.rawValue)#b58cde373") }
        s2.update(forBike: bike) { $0.buttonMap[.navBackLong] = .assistant }
        m = s2.settings(forBike: bike).buttonMap
        XCTAssertEqual(m[.navBackLong], .assistant)
        for g in [ButtonGesture.selectDouble, .navFwdDouble, .navBackDouble] { XCTAssertEqual(m[g], HandlebarPresets.iosDefaultMapping[g], "\(g)") }
        // a map the rider changed (or any other map) is never rewritten
        let (s3, kv3) = make()
        var custom = HandlebarPresets.iosDefaultMappingBeforeP0
        custom[.navBackLong] = .assistant
        for (g, a) in custom { kv3.set(a.rawValue, forKey: "button_map.\(g.rawValue)#b58cde373") }
        XCTAssertEqual(s3.settings(forBike: bike).buttonMap, custom)
        XCTAssertEqual(HandlebarPresets.migratingLegacyDefault(HandlebarPresets.androidDefaults), HandlebarPresets.androidDefaults)
        XCTAssertEqual(HandlebarPresets.migratingLegacyDefault(HandlebarPresets.iosSingleButtonMapping), HandlebarPresets.iosSingleButtonMapping)
        XCTAssertEqual(HandlebarPresets.migratingLegacyDefault(HandlebarPresets.iosMapping(for: .backSet)), HandlebarPresets.iosMapping(for: .backSet))
    }

    func testProfileOverrideAutoRemovesScopedKey() {
        let (s, kv) = make()
        s.setProfileOverride(.cfdl26Portrait, forBike: nil)      // a global override
        s.setProfileOverride(.nkAdvanced, forBike: bike)
        XCTAssertEqual(kv.string(forKey: "profile_override#b58cde373"), "nk_adv")
        XCTAssertEqual(s.settings(forBike: bike).profileOverride, .nkAdvanced)
        s.update(forBike: bike) { $0.profileOverride = nil }   // AUTO
        XCTAssertNil(kv.string(forKey: "profile_override#b58cde373"))
        // Android quirk: the bike now falls back to the global override
        XCTAssertEqual(s.settings(forBike: bike).profileOverride, .cfdl26Portrait)
        kv.set("bogus", forKey: "profile_override#b58cde373")
        XCTAssertNil(s.settings(forBike: bike).profileOverride)
    }

    func testTouchOverridesAreMutuallyExclusive() {
        let (s, kv) = make()
        s.setForceTouch(true)
        XCTAssertEqual(kv.bool(forKey: "force_touch"), true)
        XCTAssertEqual(kv.bool(forKey: "force_non_touch"), false)
        s.setForceNonTouch(true)
        XCTAssertEqual(s.settings(forBike: bike).forceNonTouch, true)
        XCTAssertEqual(s.settings(forBike: bike).forceTouch, false)
        s.setForceNonTouch(false)                             // false touches only its own key
        XCTAssertEqual(kv.bool(forKey: "force_touch"), false)
        let both = s.update(forBike: nil) { $0.forceNonTouch = true; $0.forceTouch = true }
        XCTAssertFalse(both.forceNonTouch)                   // forceTouch applied last wins
        XCTAssertTrue(both.forceTouch)
    }

    func testScreenMargins() {
        let (s, kv) = make()
        XCTAssertEqual(s.settings(forBike: nil).screenMargins, ScreenMargins())
        s.setScreenMargins(top: 250, bottom: -5, left: 4, right: 4)
        XCTAssertEqual(s.settings(forBike: bike).screenMargins, ScreenMargins(customised: true, top: 200, bottom: 0, left: 4, right: 4))
        XCTAssertEqual(kv.int(forKey: "screen_margins.top"), 200)
        s.resetScreenMargins()
        // reset only clears the flag: edges stay on disk
        XCTAssertEqual(s.settings(forBike: bike).screenMargins, ScreenMargins(customised: false, top: 200, bottom: 0, left: 4, right: 4))
        // legacy file without the flag: customised iff an edge key exists
        let kv2 = InMemoryKeyValueStore()
        kv2.set(12, forKey: "screen_margins.left")
        XCTAssertEqual(SettingsStore(store: kv2).settings(forBike: nil).screenMargins,
                       ScreenMargins(customised: true, top: 0, bottom: 0, left: 12, right: 0))
        // update(): customised false only resets the flag
        s.setScreenMargins(top: 22, bottom: 0, left: 0, right: 0)
        s.update(forBike: nil) { $0.screenMargins = ScreenMargins(customised: false) }
        XCTAssertEqual(kv.bool(forKey: "screen_margins.customised"), false)
        XCTAssertEqual(kv.int(forKey: "screen_margins.top"), 22)
    }

    func testButtonTimingNormalisation() {
        let (s, kv) = make()
        kv.set(250, forKey: "opencfmoto_btn_timing.double_tap_ms")
        kv.set(700, forKey: "opencfmoto_btn_timing.long_press_ms")
        XCTAssertEqual(s.settings(forBike: nil).buttonTiming.doubleTapMs, 300)
        XCTAssertEqual(s.settings(forBike: nil).buttonTiming.holdMs, 600)
        s.update(forBike: nil) { $0.buttonTiming.doubleTapMs = 450; $0.buttonTiming.holdMs = 800; $0.buttonTiming.holdsEnabled = false }
        let t = s.settings(forBike: bike).buttonTiming
        XCTAssertEqual(t.doubleTapMs, 450)
        XCTAssertEqual(t.holdMs, 800)
        XCTAssertFalse(t.holdsEnabled)
        XCTAssertEqual(ButtonTiming.normalizedDoubleTapMs(1000), 1000)
        XCTAssertEqual(ButtonTiming.normalizedHoldMs(nil), 600)
    }

    func testMapPreferencesPersisted() {
        let (s, kv) = make()
        s.update(forBike: bike) {
            $0.map.units = .imperial
            $0.map.theme = .night
            $0.map.chrome = .forest
            $0.map.voiceOn = false
            $0.map.routeMode = .fun
            $0.map.avoidTolls = true
            $0.map.circuitKm = 500
        }
        XCTAssertEqual(kv.string(forKey: "opencfmoto_map.units"), "IMPERIAL")
        XCTAssertEqual(kv.string(forKey: "map_theme"), "NIGHT")
        XCTAssertEqual(kv.string(forKey: "opencfmoto_map.chrome"), "FOREST")
        XCTAssertEqual(kv.bool(forKey: "opencfmoto_map.voice_prompts"), false)
        XCTAssertEqual(kv.int(forKey: "opencfmoto_map.fun_circuit_km"), 150)
        let m = s.settings(forBike: other).map            // global
        XCTAssertEqual(m.units, .imperial)
        XCTAssertEqual(m.routeOptions, RouteOptions(mode: .fun, avoidTolls: true, avoidHighways: false, maxAlternatives: 4, circuitKm: 150))
        kv.set(5, forKey: "opencfmoto_map.fun_circuit_km")
        XCTAssertEqual(s.settings(forBike: nil).map.circuitKm, 20)
    }

    func testGlobalsAndIOSOnly() {
        let (s, kv) = make()
        s.update(forBike: bike) {
            $0.autoConnect = false
            $0.autoRecovery = false
            $0.logTrips = false
            $0.includeSecretsInLogs = true
            $0.wifiTransport = .ap
            $0.keepScreenOn = false
            $0.tileURLTemplate = "https://tiles.example/{z}/{x}/{y}.png"
            $0.orsApiKey = "  key123  "
        }
        XCTAssertEqual(kv.bool(forKey: "auto_connect"), false)
        XCTAssertEqual(kv.string(forKey: "wifi_transport"), "ap")
        XCTAssertEqual(kv.string(forKey: "opencfmoto_map.ors_api_key"), "key123")
        let v = s.settings(forBike: nil)
        XCTAssertFalse(v.autoConnect)
        XCTAssertFalse(v.autoRecovery)
        XCTAssertFalse(v.logTrips)
        XCTAssertTrue(v.includeSecretsInLogs)
        XCTAssertEqual(v.wifiTransport, .ap)
        XCTAssertFalse(v.keepScreenOn)
        XCTAssertEqual(v.tileURLTemplate, "https://tiles.example/{z}/{x}/{y}.png")
        XCTAssertEqual(v.orsApiKey, "key123")
        kv.set("wifi-direct", forKey: "wifi_transport")
        XCTAssertEqual(s.settings(forBike: nil).wifiTransport, .auto)   // unknown → auto
    }

    func testClusterPresetApplyAndClear() {
        let (s, kv) = make()
        s.setHandlebarControl(false, forBike: bike)
        s.setButtonAction(.assistant, for: .selectLong, forBike: bike)
        s.applyClusterPreset(.backSet, forBike: bike)
        let v = s.settings(forBike: bike)
        XCTAssertEqual(v.clusterPreset, .backSet)
        XCTAssertTrue(v.handlebarControl)                                  // forced on
        XCTAssertEqual(v.buttonMap, HandlebarPresets.iosMapping(for: .backSet))
        XCTAssertEqual(kv.string(forKey: "button_cluster_preset.active#b58cde373"), "back_set")
        XCTAssertEqual(kv.string(forKey: "button_map.navFwdDouble#b58cde373"), "home")
        XCTAssertEqual(kv.string(forKey: "button_map.selectLong#b58cde373"), "none")
        XCTAssertEqual(s.settings(forBike: other).clusterPreset, nil)
        s.applyClusterPreset(.fiveWay, forBike: bike)
        XCTAssertEqual(s.settings(forBike: bike).buttonMap, HandlebarPresets.iosDefaultMapping)
        s.applyClusterPreset(.fiveWay, forBike: bike, mapping: HandlebarPresets.androidMapping(for: .fiveWay))
        XCTAssertEqual(s.settings(forBike: bike).buttonMap, HandlebarPresets.androidDefaults)
        s.clearClusterPreset(forBike: bike)
        XCTAssertNil(s.settings(forBike: bike).clusterPreset)
        XCTAssertTrue(s.isButtonMapDefault(forBike: bike))
        XCTAssertNil(kv.string(forKey: "button_map.navBack#b58cde373"))
    }

    func testPresenceAndAndroidOnlyAndSavedPlaces() {
        let (s, kv) = make()
        s.setVolumeRockerPresence(.absent, forBike: bike)
        s.setTrackKeysPresence(.present, forBike: bike)
        XCTAssertEqual(kv.string(forKey: "button_presence.volume_rocker#b58cde373"), "ABSENT")
        XCTAssertEqual(s.presence(forBike: bike), HandlebarPresence(volumeRocker: .absent, trackKeys: .present))
        XCTAssertEqual(s.presence(forBike: bike).summary, "\u{25B2}/\u{25BC} absent \u{00B7} \u{25C0}/\u{25B6} works")
        XCTAssertEqual(s.presence(forBike: other), HandlebarPresence())
        s.resetPresence(forBike: bike)
        XCTAssertEqual(s.presence(forBike: bike), HandlebarPresence())

        s.setAaDpiOverride(-3, forBike: bike)
        XCTAssertEqual(kv.int(forKey: "aa_dpi_override#b58cde373"), 0)
        s.setAndroidOnlySettings(AndroidOnlySettings(resolutionMode: .portraitSD, aaDpiOverride: 240, remotePad: false), forBike: bike)
        XCTAssertEqual(s.androidOnlySettings(forBike: bike), AndroidOnlySettings(resolutionMode: .portraitSD, aaDpiOverride: 240, remotePad: false))
        XCTAssertEqual(s.androidOnlySettings(forBike: other).resolutionMode, .auto)
        XCTAssertFalse(s.androidOnlySettings(forBike: other).remotePad)        // global

        s.setSavedPlace(0, name: " Home ", query: " 44.43,26.10 ")
        XCTAssertEqual(s.savedPlace(0), SavedPlaceSlot(name: "Home", query: "44.43,26.10"))
        XCTAssertEqual(s.savedPlaces.count, 3)
        XCTAssertEqual(s.savedPlace(0).actionLabel(slot: 0), "Navigate: Home")
        XCTAssertEqual(s.savedPlace(1).actionLabel(slot: 1), "Navigate to saved place 2 (not set yet)")
        XCTAssertEqual(SavedPlaceSlot(name: " ", query: "Calle 80").actionLabel(slot: 2), "Navigate: Calle 80")
        s.setSnappySingles(false)
        XCTAssertFalse(s.snappySingles)
    }

    func testRemoveAllScopedValues() {
        let (s, kv) = make()
        s.setVideoQuality(.sharp, forBike: bike)
        s.setPowerMode(.saver, forBike: other)
        s.removeAllScopedValues(forBike: bike)
        XCTAssertEqual(kv.allKeys(), ["power_mode#bae532b19"])
    }

    func testSubscribersNotified() {
        let (s, _) = make()
        let count = Locked(0)
        let id = s.subscribe { count.withLock { $0 += 1 } }
        s.setPowerMode(.auto, forBike: bike)
        s.update(forBike: bike) { $0.logTrips = false }
        XCTAssertEqual(count.current, 2)
        s.unsubscribe(id)
        s.setPowerMode(.saver, forBike: bike)
        XCTAssertEqual(count.current, 2)
    }

    func testConcurrentAccess() {
        let (s, _) = make()
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            let b = i % 2 == 0 ? bike : other
            s.setVideoQuality(i % 3 == 0 ? .sharp : .smooth, forBike: b)
            _ = s.settings(forBike: b)
            s.update(forBike: b) { $0.powerMode = .auto }
        }
        XCTAssertEqual(s.settings(forBike: bike).powerMode, .auto)
        XCTAssertEqual(s.settings(forBike: other).powerMode, .auto)
    }

    func testHasStoredScreenFit() {
        let s = SettingsStore(store: InMemoryKeyValueStore())
        XCTAssertFalse(s.hasStoredScreenFit(forBike: nil))
        XCTAssertFalse(s.hasStoredScreenFit(forBike: "b1"))
        XCTAssertEqual(s.settings(forBike: "b1").screenFit, .fill) // read default unchanged
        s.setScreenFit(.fill, forBike: "b1")
        XCTAssertTrue(s.hasStoredScreenFit(forBike: "b1"))
        XCTAssertFalse(s.hasStoredScreenFit(forBike: "b2"))
        s.setScreenFit(.stretch, forBike: nil) // global key: every bike inherits it
        XCTAssertTrue(s.hasStoredScreenFit(forBike: "b2"))
        s.store.set("bogus", forKey: "screen_fit#b3")
        // An unreadable scoped value shadows the global one on read too (the read falls back to the
        // FILL default), so nothing valid is stored for that bike.
        XCTAssertFalse(s.hasStoredScreenFit(forBike: "b3"))
        XCTAssertEqual(s.settings(forBike: "b3").screenFit, .fill)
        let fresh = SettingsStore(store: InMemoryKeyValueStore())
        fresh.store.set("bogus", forKey: "screen_fit")
        XCTAssertFalse(fresh.hasStoredScreenFit(forBike: nil))
    }
}
