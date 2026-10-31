// SPDX-License-Identifier: AGPL-3.0-or-later
// "opencfmoto.settings" v1 pack (app-features.md §3, SettingsBackupTest.kt).

import XCTest
@testable import OpenCfMotoCore

final class SettingsBackupTests: XCTestCase {

    // §3.3 (a) — fresh install, 800NK Advanced connected once, everything default.
    static let exampleA = """
    {
      "format": "opencfmoto.settings",
      "version": 1,
      "exportedAt": "2026-10-31T15:42:07+01:00",
      "appVersion": "2.0.18",
      "bikeHint": {
        "profile": "CFDL26 \\/ 800NK Advanced (touch, 720\u{00D7}712)",
        "profileOverride": "auto"
      },
      "settings": {
        "videoQuality": "BALANCED",
        "screenFit": "FILL",
        "mirrorOrientation": "MATCH_DASH",
        "powerMode": "BALANCED",
        "resolutionMode": "AUTO",
        "aaDpiOverride": 0,
        "remotePad": true,
        "profileOverride": "auto",
        "controlAa": true,
        "forceNonTouch": false,
        "forceTouch": false,
        "wifiTransport": "auto",
        "screenMargins": {
          "customised": false,
          "top": 0,
          "bottom": 0,
          "left": 0,
          "right": 0
        },
        "buttons": {
          "navBack": "knobBack",
          "navFwd": "knobFwd",
          "selectPress": "select",
          "navBackLong": "none",
          "navFwdLong": "none",
          "selectLong": "home",
          "navBackDouble": "left",
          "navFwdDouble": "right",
          "selectDouble": "back"
        }
      }
    }
    """

    // §3.3 (b) — tuned 1000 MT-X pack (BACK/SET preset, forced portrait, custom margins).
    static let exampleB = """
    {
      "format": "opencfmoto.settings",
      "version": 1,
      "exportedAt": "2026-10-31T09:05:11Z",
      "appVersion": "2.0.18",
      "bikeHint": {
        "profile": "CFDL26 \\/ MotoPlay Portrait (1000 MT-X)",
        "profileOverride": "cfdl26_port"
      },
      "settings": {
        "videoQuality": "SHARP",
        "screenFit": "FIT",
        "mirrorOrientation": "MATCH_DASH",
        "powerMode": "AUTO",
        "resolutionMode": "PORTRAIT_SD",
        "aaDpiOverride": 240,
        "remotePad": true,
        "profileOverride": "cfdl26_port",
        "controlAa": true,
        "forceNonTouch": false,
        "forceTouch": true,
        "wifiTransport": "ap",
        "screenMargins": {
          "customised": true,
          "top": 12,
          "bottom": 0,
          "left": 4,
          "right": 4
        },
        "buttons": {
          "navBack": "knobBack",
          "navFwd": "knobFwd",
          "selectPress": "select",
          "navBackLong": "none",
          "navFwdLong": "none",
          "selectLong": "none",
          "navBackDouble": "back",
          "navFwdDouble": "home",
          "selectDouble": "none"
        }
      }
    }
    """

    private let bike = "b58cde373"
    private let plusOne = TimeZone(secondsFromGMT: 3600)!
    private let utc = TimeZone(identifier: "UTC")!

    /// The pack text with the iOS-only key appended to `settings` (as exported by iOS).
    private func withIOSKey(_ text: String, keepScreenOn: Bool = true) -> String {
        text.replacingOccurrences(of: "      \"selectDouble\": \"back\"\n    }\n  }\n}",
                                  with: "      \"selectDouble\": \"back\"\n    },\n    \"iosKeepScreenOn\": \(keepScreenOn)\n  }\n}")
            .replacingOccurrences(of: "      \"selectDouble\": \"none\"\n    }\n  }\n}",
                                  with: "      \"selectDouble\": \"none\"\n    },\n    \"iosKeepScreenOn\": \(keepScreenOn)\n  }\n}")
    }

    func testFormatAndVersionAreStable() {
        XCTAssertEqual(SettingsBackup.format, "opencfmoto.settings")
        XCTAssertEqual(SettingsBackup.version, 1)
    }

    func testIdsRoundTrip() {
        for a in ButtonAction.allCases { XCTAssertEqual(ButtonAction(rawValue: a.rawValue), a) }
        for g in ButtonGesture.allCases { XCTAssertEqual(ButtonAction(rawValue: g.defaultAction.rawValue), g.defaultAction) }
        for p in BikeProfileID.allCases { XCTAssertEqual(BikeProfileID(rawValue: p.rawValue), p) }
        XCTAssertEqual(BikeProfileID(rawValue: "cfdl26_land"), .cfdl26Landscape)
    }

    func testExportExampleAExactly() {
        let date = Date(timeIntervalSince1970: 1_793_457_727) // 2026-10-31T14:42:07Z
        let text = SettingsBackup.exportJSON(settings: BikeSettings(), androidOnly: AndroidOnlySettings(),
                                             profileName: SettingsBackup.androidProfileName(.nkAdvanced),
                                             appVersion: "2.0.18", date: date, timeZone: plusOne)
        XCTAssertEqual(text, withIOSKey(Self.exampleA))
    }

    func testExportExampleBExactly() {
        var s = BikeSettings()
        s.videoQuality = .sharp
        s.screenFit = .fit
        s.powerMode = .auto
        s.profileOverride = .cfdl26Portrait
        s.forceTouch = true
        s.wifiTransport = .ap
        s.screenMargins = ScreenMargins(customised: true, top: 12, bottom: 0, left: 4, right: 4)
        s.buttonMap = HandlebarPresets.androidMapping(for: .backSet)
        let a = AndroidOnlySettings(resolutionMode: .portraitSD, aaDpiOverride: 240, remotePad: true)
        let date = Date(timeIntervalSince1970: 1_793_437_511) // 2026-10-31T09:05:11Z
        let text = SettingsBackup.exportJSON(settings: s, androidOnly: a,
                                             profileName: SettingsBackup.androidProfileName(.cfdl26Portrait),
                                             appVersion: "2.0.18", date: date, timeZone: utc)
        XCTAssertEqual(text, withIOSKey(Self.exampleB))
    }

    func testExportZeroesEdgesWhenNotCustomised() {
        var s = BikeSettings()
        s.screenMargins = ScreenMargins(customised: false, top: 22, bottom: 1, left: 2, right: 3)
        let text = SettingsBackup.exportJSON(settings: s, androidOnly: AndroidOnlySettings(), profileName: "x", appVersion: "1")
        XCTAssertTrue(text.contains("\"customised\": false,\n      \"top\": 0,\n      \"bottom\": 0"))
    }

    func testExportedAtFormat() {
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(SettingsBackup.exportedAtString(d, timeZone: utc), "2023-11-14T22:13:20Z")
        XCTAssertEqual(SettingsBackup.exportedAtString(d, timeZone: TimeZone(secondsFromGMT: -5 * 3600)!), "2023-11-14T17:13:20-05:00")
        XCTAssertEqual(SettingsBackup.exportedAtString(d, timeZone: TimeZone(secondsFromGMT: 5 * 3600 + 1800)!), "2023-11-15T03:43:20+05:30")
    }

    func testProfileNames() {
        XCTAssertEqual(SettingsBackup.androidProfileName(nil), "CFDL16 / legacy (BIKE A)")
        XCTAssertEqual(SettingsBackup.androidProfileName(.nk800), "CFMoto 800NK (CRCP / sdk 0.9.23.x)")
        XCTAssertEqual(SettingsBackup.androidProfileName(.cfdl26Landscape), "CFDL26 / MotoPlay Landscape (800MT)")
        XCTAssertEqual(SettingsBackup.androidProfileName(.clc450), "CL\u{2011}C450 (544\u{00D7}512)")
        XCTAssertEqual(SettingsBackup.androidProfileName(.morini), "Morini SoftAP / Alltrhike (MLN)")
        XCTAssertEqual(SettingsBackup.androidProfileName(.motoplayLandscape), "CFDL16 / MotoPlay Landscape (modelId 66660742)")
        XCTAssertEqual(SettingsBackup.androidProfileName(.legacy, learned: LearnedDashSize(width: 800, height: 386)),
                       "CFDL16 / legacy (BIKE A) + measured 800x386")
        XCTAssertEqual(SettingsBackup.suggestedFileName(profileOverride: nil), "OpenCfMoto-auto-settings.json")
        XCTAssertEqual(SettingsBackup.suggestedFileName(profileOverride: .cfdl26Portrait), "OpenCfMoto-cfdl26_port-settings.json")
        XCTAssertEqual(SettingsBackup.shareSubject(profileOverride: .nkAdvanced), "OpenCfMoto bike tuning \u{2014} 800NK Adv")
    }

    // MARK: Import

    func testImportExampleBAppliesEverything() {
        let kv = InMemoryKeyValueStore()
        let store = SettingsStore(store: kv)
        let r = SettingsBackup.importJSON(Self.exampleB, into: store, bikeId: bike, bikeName: "My MT-X")
        XCTAssertEqual(r, .init(ok: true, message: "Imported bike tuning (CFDL26 / MotoPlay Portrait (1000 MT-X)) onto My MT-X"))
        let v = store.settings(forBike: bike)
        XCTAssertEqual(v.videoQuality, .sharp)
        XCTAssertEqual(v.screenFit, .fit)
        XCTAssertEqual(v.powerMode, .auto)
        XCTAssertEqual(v.profileOverride, .cfdl26Portrait)
        XCTAssertTrue(v.forceTouch)
        XCTAssertFalse(v.forceNonTouch)
        XCTAssertEqual(v.wifiTransport, .ap)
        XCTAssertEqual(v.screenMargins, ScreenMargins(customised: true, top: 12, bottom: 0, left: 4, right: 4))
        XCTAssertEqual(v.buttonMap, HandlebarPresets.androidMapping(for: .backSet))
        XCTAssertEqual(store.androidOnlySettings(forBike: bike), AndroidOnlySettings(resolutionMode: .portraitSD, aaDpiOverride: 240, remotePad: true))
        // per-bike values went to the scoped keys, globals to global keys
        XCTAssertEqual(kv.string(forKey: "video_quality#b58cde373"), "SHARP")
        XCTAssertEqual(kv.string(forKey: "button_map.navFwdDouble#b58cde373"), "home")
        XCTAssertEqual(kv.bool(forKey: "force_touch"), true)
        XCTAssertNil(kv.string(forKey: "video_quality"))
        // another bike keeps defaults for per-bike values but sees the globals
        XCTAssertEqual(store.settings(forBike: "bother").videoQuality, .balanced)
        XCTAssertEqual(store.settings(forBike: "bother").wifiTransport, .ap)
    }

    func testImportExportImportIsStable() {
        let store = SettingsStore(store: InMemoryKeyValueStore())
        XCTAssertTrue(SettingsBackup.importJSON(Self.exampleB, into: store, bikeId: bike, bikeName: nil).ok)
        let date = Date(timeIntervalSince1970: 1_793_437_511)
        let exported = SettingsBackup.exportJSON(from: store, bikeId: bike, profileName: SettingsBackup.androidProfileName(.cfdl26Portrait),
                                                 appVersion: "2.0.18", date: date, timeZone: utc)
        XCTAssertEqual(exported, withIOSKey(Self.exampleB))
        let store2 = SettingsStore(store: InMemoryKeyValueStore())
        XCTAssertTrue(SettingsBackup.importJSON(exported, into: store2, bikeId: "bx", bikeName: nil).ok)
        XCTAssertEqual(store2.settings(forBike: "bx"), store.settings(forBike: bike))
        XCTAssertEqual(store2.androidOnlySettings(forBike: "bx"), store.androidOnlySettings(forBike: bike))
    }

    func testImportExampleAResetsMarginsAndAutoProfile() {
        let store = SettingsStore(store: InMemoryKeyValueStore())
        store.setProfileOverride(.legacy, forBike: bike)
        store.setScreenMargins(top: 5, bottom: 5, left: 5, right: 5)
        let r = SettingsBackup.importJSON(Self.exampleA, into: store, bikeId: bike, bikeName: nil)
        XCTAssertEqual(r.message, "Imported bike tuning (CFDL26 / 800NK Advanced (touch, 720\u{00D7}712)) onto selected bike")
        let v = store.settings(forBike: bike)
        XCTAssertNil(v.profileOverride)                     // "auto" removed the override
        XCTAssertFalse(v.screenMargins.customised)          // reset to profile default
        XCTAssertEqual(v.buttonMap, HandlebarPresets.androidDefaults)
    }

    func testValidationMessages() {
        let store = SettingsStore(store: InMemoryKeyValueStore())
        func msg(_ t: String) -> String { SettingsBackup.importJSON(t, into: store, bikeId: nil, bikeName: nil).message }
        XCTAssertEqual(msg(""), "Not valid JSON: End of input at character 0 of ")
        XCTAssertEqual(msg("not json"), "Not valid JSON: Value not of type java.lang.String cannot be converted to JSONObject")
        XCTAssertEqual(msg("[1]"), "Not valid JSON: Value [1] of type org.json.JSONArray cannot be converted to JSONObject")
        XCTAssertEqual(msg(#"{"format":"x"}"#), "Not an OpenCfMoto settings file (format=x)")
        XCTAssertEqual(msg("{}"), "Not an OpenCfMoto settings file (format=)")
        XCTAssertEqual(msg(#"{"format":"opencfmoto.settings"}"#), "Unsupported settings version 0 (this app reads 1\u{2026}1)")
        XCTAssertEqual(msg(#"{"format":"opencfmoto.settings","version":2}"#), "Unsupported settings version 2 (this app reads 1\u{2026}1)")
        XCTAssertEqual(msg(#"{"format":"opencfmoto.settings","version":"1"}"#), "Missing settings object")
        XCTAssertEqual(msg(#"{"format":"opencfmoto.settings","version":1.9,"settings":[]}"#), "Missing settings object")
        XCTAssertFalse(SettingsBackup.importJSON("{}", into: store, bikeId: nil, bikeName: nil).ok)
        // Android ignores the format of a JSON null → "null"
        XCTAssertEqual(msg(#"{"format":null}"#), "Not an OpenCfMoto settings file (format=null)")
    }

    func testBomWhitespaceCommentsAndUnquotedKeysAccepted() {
        let store = SettingsStore(store: InMemoryKeyValueStore())
        let text = "  \u{FEFF}{format: 'opencfmoto.settings', version: 1, // comment\n settings: {videoQuality: SHARP}} trailing  "
        let r = SettingsBackup.importJSON(text, into: store, bikeId: bike, bikeName: "B")
        XCTAssertEqual(r, .init(ok: true, message: "Bike tuning imported onto B"))
        XCTAssertEqual(store.settings(forBike: bike).videoQuality, .sharp)
    }

    func testLeniencyAndApplyOrder() {
        let kv = InMemoryKeyValueStore()
        let store = SettingsStore(store: kv)
        store.setVideoQuality(.smooth, forBike: bike)
        store.setProfileOverride(.legacy, forBike: bike)
        store.setButtonAction(.assistant, for: .selectLong, forBike: bike)
        let text = """
        {"format":"opencfmoto.settings","version":1,"bikeHint":{"profile":"null","profileOverride":"nk800"},
         "settings":{"videoQuality":"ultra","screenFit":"fit","powerMode":5,"profileOverride":"zzz",
          "aaDpiOverride":-7,"remotePad":1,"controlAa":"FALSE","forceNonTouch":true,"forceTouch":true,
          "wifiTransport":"p2p2","screenMargins":{"customised":"true","top":250,"left":"9"},
          "buttons":{"navBack":"warp","selectLong":"up","mapTheme":"NIGHT"},
          "mapTheme":"NIGHT","autoConnect":false,"iosKeepScreenOn":"false"}}
        """
        let r = SettingsBackup.importJSON(text, into: store, bikeId: bike, bikeName: nil)
        XCTAssertEqual(r.message, "Imported bike tuning (nk800) onto selected bike")
        let v = store.settings(forBike: bike)
        XCTAssertEqual(v.videoQuality, .smooth)          // invalid name skipped
        XCTAssertEqual(v.screenFit, .fill)               // exact case required
        XCTAssertEqual(v.powerMode, .balanced)           // "5" is not an enum name
        XCTAssertNil(v.profileOverride)                  // unknown id resets to auto
        XCTAssertEqual(kv.int(forKey: "aa_dpi_override#b58cde373"), 0)
        XCTAssertFalse(store.androidOnlySettings(forBike: bike).remotePad) // optBoolean(1) → false
        XCTAssertFalse(v.handlebarControl)               // "FALSE" string accepted
        XCTAssertTrue(v.forceTouch)                      // later forceTouch wins
        XCTAssertFalse(v.forceNonTouch)
        XCTAssertEqual(v.wifiTransport, .auto)           // unknown → auto
        XCTAssertEqual(v.screenMargins, ScreenMargins(customised: true, top: 200, bottom: 0, left: 9, right: 0))
        XCTAssertEqual(v.buttonMap[.navBack], HandlebarPresets.iosDefaultMapping[.navBack]) // unknown action skipped
        XCTAssertEqual(v.buttonMap[.selectLong], .up)
        XCTAssertEqual(v.map.theme, .auto)               // personal prefs ignored
        XCTAssertTrue(v.autoConnect)
        XCTAssertFalse(v.keepScreenOn)                   // iOS key
    }

    func testForceNonTouchWinsWhenForceTouchFalse() {
        let store = SettingsStore(store: InMemoryKeyValueStore())
        let text = #"{"format":"opencfmoto.settings","version":1,"settings":{"forceNonTouch":true,"forceTouch":false}}"#
        XCTAssertTrue(SettingsBackup.importJSON(text, into: store, bikeId: nil, bikeName: nil).ok)
        XCTAssertTrue(store.settings(forBike: nil).forceNonTouch)
        XCTAssertFalse(store.settings(forBike: nil).forceTouch)
    }
}
