// SPDX-License-Identifier: AGPL-3.0-or-later
// Cluster presets (ButtonClusterPreset.kt, BikeProfileSelectTest.kt), iOS defaults (input-controls §9),
// verbatim labels (§7.3/§7.4/§7.10) and timing choices.

import XCTest
@testable import OpenCfMotoCore

final class HandlebarPresetTests: XCTestCase {

    func testShippedDefaultsMatchHandlebarLayout() {
        let d = HandlebarPresets.androidDefaults
        XCTAssertEqual(d[.navBack], .knobBack)
        XCTAssertEqual(d[.navFwd], .knobFwd)
        XCTAssertEqual(d[.selectPress], .select)
        XCTAssertEqual(d[.navBackLong], ButtonAction.none)
        XCTAssertEqual(d[.navFwdLong], ButtonAction.none)
        XCTAssertEqual(d[.selectLong], .home)
        XCTAssertEqual(d[.navBackDouble], .left)
        XCTAssertEqual(d[.navFwdDouble], .right)
        XCTAssertEqual(d[.selectDouble], .back)
    }

    func testBackSetPresetUsesVolumeDoublesForBackHome() {
        let m = HandlebarPresets.androidMapping(for: .backSet)
        XCTAssertEqual(m[.navBack], .knobBack)
        XCTAssertEqual(m[.navFwd], .knobFwd)
        XCTAssertEqual(m[.selectPress], .select)
        XCTAssertEqual(m[.selectLong], ButtonAction.none)
        XCTAssertEqual(m[.navBackLong], ButtonAction.none)
        XCTAssertEqual(m[.navFwdLong], ButtonAction.none)
        XCTAssertEqual(m[.selectDouble], ButtonAction.none)
        XCTAssertEqual(m[.navBackDouble], .back)
        XCTAssertEqual(m[.navFwdDouble], .home)
        XCTAssertEqual(m.count, 9)
        XCTAssertTrue(ButtonClusterPreset.backSet.instantSingles)
        XCTAssertTrue(ButtonClusterPreset.fiveWay.instantSingles)
        XCTAssertEqual(HandlebarPresets.iosMapping(for: .backSet), m)
    }

    func testFiveWayAndModeEntMatchShippedDefaultsOnAndroid() {
        for g in ButtonGesture.allCases {
            XCTAssertEqual(HandlebarPresets.androidMapping(for: .fiveWay)[g], g.defaultAction)
            XCTAssertEqual(HandlebarPresets.androidMapping(for: .modeEnt)[g], g.defaultAction)
        }
    }

    func testIOSDefaultMapping() {
        let m = HandlebarPresets.iosDefaultMapping
        XCTAssertEqual(m.count, 9)
        // P0 (D02): no double of its own (were ▶▶ Home, ◀◀ D-pad left, ★★ Back): ◀◀ / ▶▶ are their own knob
        // step (two presses = two steps at any tempo, review DASH-REG-3), ★★ is unmapped (a stuttered ★ is one)
        XCTAssertEqual(m[.navFwdDouble], .knobFwd)
        XCTAssertEqual(m[.navBackDouble], .knobBack)
        XCTAssertEqual(m[.selectDouble], ButtonAction.none)
        XCTAssertEqual(m[.selectLong], ButtonAction.none)
        XCTAssertEqual(m[.navBack], .knobBack)
        XCTAssertEqual(m[.navFwd], .knobFwd)
        XCTAssertEqual(m[.selectPress], .select)
        XCTAssertEqual(HandlebarPresets.iosMapping(for: .fiveWay), m)
        XCTAssertEqual(HandlebarPresets.iosMapping(for: .modeEnt), m)
        let single = HandlebarPresets.iosSingleButtonMapping
        XCTAssertEqual(single[.selectPress], .knobFwd)
        XCTAssertEqual(single[.selectDouble], .select)
        XCTAssertEqual(HandlebarPresets.completed([.navBack: .up])[.navFwd], m[.navFwd])
        XCTAssertEqual(HandlebarPresets.completed([.navBack: .up])[.navBack], .up)
    }

    func testIdsRoundTripAndPresetIds() {
        for a in ButtonAction.allCases { XCTAssertEqual(ButtonAction(rawValue: a.rawValue), a) }
        XCTAssertEqual(ButtonClusterPreset(rawValue: "five_way"), .fiveWay)
        XCTAssertEqual(ButtonClusterPreset(rawValue: "mode_ent"), .modeEnt)
        XCTAssertEqual(ButtonClusterPreset(rawValue: "back_set"), .backSet)
    }

    func testVerbatimLabels() {
        XCTAssertEqual(ButtonGesture.navBack.englishLabel, "Backward  \u{25C0} / \u{25B2}")
        XCTAssertEqual(ButtonGesture.selectLong.englishLabel, "Select (hold)  Enter / \u{2605}")
        XCTAssertEqual(ButtonGesture.navFwdDouble.englishLabel, "Forward \u{00D7}2")
        XCTAssertEqual(ButtonGesture.navFwdLong.englishHint, "press and hold \u{25B6} (track-key dashes only)")
        XCTAssertEqual(ButtonAction.knobFwd.englishLabel, "Knob forward (next item)")
        XCTAssertEqual(ButtonAction.nav3.englishLabel, "Navigate to saved place 3")
        XCTAssertEqual(ButtonClusterPreset.backSet.englishTitle, "BACK / SET diamond (limited)")
        XCTAssertEqual(ButtonClusterPreset.fiveWay.englishTitle, "5-way Explore (Fn / \u{2605} / voice)")
        XCTAssertTrue(ButtonClusterPreset.modeEnt.englishSummary.hasPrefix("Same AA navigation as 5-way"))
        XCTAssertTrue(ButtonClusterPreset.backSet.englishSummary.contains("\u{25B2}\u{25B2} / \u{25BC}\u{25BC} volume flick"))
        for g in ButtonGesture.allCases { XCTAssertFalse(g.englishLabel.isEmpty) }
    }

    func testPresenceSummary() {
        XCTAssertEqual(HandlebarPresence().summary, "\u{25B2}/\u{25BC} untested \u{00B7} \u{25C0}/\u{25B6} untested")
        XCTAssertTrue(HandlebarPresence().shouldUseVolumePath)
        XCTAssertFalse(HandlebarPresence(volumeRocker: .absent).shouldUseVolumePath)
        XCTAssertEqual(ButtonPresence(rawValue: "PRESENT"), .present)
    }

    func testTimingChoices() {
        XCTAssertEqual(ButtonTiming.doubleTapChoices, [200, 300, 450, 1000])
        XCTAssertEqual(ButtonTiming.holdChoices, [500, 600, 800])
        XCTAssertEqual(ButtonTiming.normalizedDoubleTapMs(200), 200)
        XCTAssertEqual(ButtonTiming.normalizedDoubleTapMs(201), 300)
        XCTAssertEqual(ButtonTiming.normalizedHoldMs(800), 800)
        XCTAssertEqual(ButtonTiming.normalizedHoldMs(0), 600)
    }
}
