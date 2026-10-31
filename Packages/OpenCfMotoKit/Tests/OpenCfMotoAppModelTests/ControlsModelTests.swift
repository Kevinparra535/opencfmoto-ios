// SPDX-License-Identifier: AGPL-3.0-or-later
// ControlsModel: opt-in media remote → HandlebarGestureEngine → DashInput → the dash UI
// (input-controls.md §7–§10): tester texts, focus moves, Select, doubles, presence learning,
// session claim / release, mirror mode.
import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class ControlsModelTests: XCTestCase {
    @MainActor
    private func signal(_ h: AppTestHarness, _ event: HandlebarRawEvent, steps: Int = 1, after: TimeInterval = 0) {
        h.handlebar.emit(HandlebarSignal(event: event, time: h.core.services.clock.now() + after, steps: steps))
    }

    @MainActor
    func testRemoteIsOptInAndDrivesTheDashFocus() async {
        let h = AppTestHarness()
        XCTAssertFalse(h.controls.isRemoteEnabled)
        XCTAssertTrue(h.controls.isRemoteAvailable)
        signal(h, .forward)
        XCTAssertNil(h.controls.lastRawEvent) // not claimed: nothing arrives

        h.controls.setRemoteEnabled(true)
        XCTAssertTrue(h.controls.isRemoteEnabled)
        XCTAssertTrue(h.handlebar.isEnabled)
        XCTAssertEqual(h.core.services.keyValueStore.bool(forKey: ControlsModel.remoteOptInKey), true)

        h.ride.flushModel()
        let before = h.ride.ui.state.focusedId
        XCTAssertNotNil(before)
        signal(h, .forward) // ▶ = navFwd → knob forward
        XCTAssertEqual(h.controls.lastRawEvent, "forward")
        XCTAssertEqual(h.controls.lastCommand,
                       "\(SessionText.gestureLabel(.navFwd, h.language)) \u{2192} \(SessionText.actionLabel(.knobFwd, h.language))")
        XCTAssertNotEqual(h.ride.ui.state.focusedId, before)

        h.controls.setRemoteEnabled(false)
        XCTAssertFalse(h.handlebar.isEnabled)
        XCTAssertEqual(h.core.services.keyValueStore.bool(forKey: ControlsModel.remoteOptInKey), false)
    }

    @MainActor
    func testSelectActivatesTheFocusedControl() async {
        let h = AppTestHarness()
        h.controls.setRemoteEnabled(true)
        h.ride.flushModel()
        XCTAssertEqual(h.ride.ui.state.focusedId, "pill")
        signal(h, .select) // ★ = Select → ENTER on the search pill
        XCTAssertEqual(h.ride.ui.state.sheet, .search)
        XCTAssertEqual(h.controls.lastCommand,
                       "\(SessionText.gestureLabel(.selectPress, h.language)) \u{2192} \(SessionText.actionLabel(.select, h.language))")
    }

    @MainActor
    func testDoubleForwardOpensTheMenu() async {
        let h = AppTestHarness()
        h.controls.setRemoteEnabled(true)
        h.ride.flushModel()
        signal(h, .forward)
        signal(h, .forward, after: 0.1) // inside the 300 ms window → ▶▶ = Home (iOS default) → menu
        XCTAssertEqual(h.ride.ui.state.sheet, .menu)
        XCTAssertEqual(h.controls.lastCommand,
                       "\(SessionText.gestureLabel(.navFwdDouble, h.language)) \u{2192} \(SessionText.actionLabel(.home, h.language))")
    }

    @MainActor
    func testHandlebarControlOffSwallowsPresses() async {
        let h = AppTestHarness()
        h.core.settings.setHandlebarControl(false, forBike: nil)
        await settle()
        h.controls.setRemoteEnabled(true)
        h.ride.flushModel()
        let before = h.ride.ui.state.focusedId
        signal(h, .forward)
        XCTAssertEqual(h.controls.lastRawEvent, "forward")
        XCTAssertNil(h.controls.lastCommand)
        XCTAssertEqual(h.ride.ui.state.focusedId, before)
    }

    @MainActor
    func testVolumeStepsMarkTheRockerPresentForTheBike() async {
        let h = AppTestHarness()
        let (bike, _) = h.addBike()
        await settle()
        h.controls.setRemoteEnabled(true)
        signal(h, .volumeDown, steps: 3)
        XCTAssertEqual(h.controls.lastRawEvent, "volumeDown \u{00D7}3")
        let learned = await eventually { h.core.settings.presence(forBike: bike.id).volumeRocker == .present }
        XCTAssertTrue(learned)
    }

    @MainActor
    func testVolumeButtonsOptionIsRemembered() async {
        let h = AppTestHarness()
        XCTAssertFalse(h.controls.volumeButtonsEnabled)
        h.controls.setVolumeButtonsEnabled(true)
        XCTAssertTrue(h.handlebar.volumeButtonsEnabled)
        XCTAssertTrue(h.controls.volumeButtonsEnabled)
        XCTAssertEqual(h.core.services.keyValueStore.bool(forKey: ControlsModel.volumeButtonsKey), true)
    }

    @MainActor
    func testRememberedOptInClaimsTheRemoteOnlyDuringARide() async {
        let h = AppTestHarness { services in
            services.keyValueStore.set(true, forKey: ControlsModel.remoteOptInKey)
        }
        XCTAssertTrue(h.controls.isRemoteEnabled)
        XCTAssertFalse(h.handlebar.isEnabled) // never claimed at launch (other apps keep their music)
        h.controls.sessionChanged(active: true, mirror: false)
        XCTAssertTrue(h.handlebar.isEnabled)
        h.controls.sessionChanged(active: false, mirror: false)
        XCTAssertFalse(h.handlebar.isEnabled)
    }

    @MainActor
    func testMirrorModeReleasesTheRemote() async {
        let h = AppTestHarness()
        h.controls.setRemoteEnabled(true)
        XCTAssertTrue(h.handlebar.isEnabled)
        h.controls.sessionChanged(active: true, mirror: true)
        XCTAssertFalse(h.handlebar.isEnabled)
        h.controls.setRemoteEnabled(true) // deferred while mirroring
        XCTAssertFalse(h.handlebar.isEnabled)
        h.controls.sessionChanged(active: false, mirror: false)
        h.controls.setRemoteEnabled(true)
        XCTAssertTrue(h.handlebar.isEnabled)
    }

    @MainActor
    func testConnectAndStopClaimAndReleaseTheRemote() async {
        let h = AppTestHarness { services in
            services.keyValueStore.set(true, forKey: ControlsModel.remoteOptInKey)
        }
        h.addBike()
        h.connection.connect()
        XCTAssertTrue(h.handlebar.isEnabled)
        h.connection.stop()
        XCTAssertFalse(h.handlebar.isEnabled)
        // Mirror sessions leave the bars to the media app.
        h.connection.startMirror()
        XCTAssertFalse(h.handlebar.isEnabled)
        h.connection.stop()
    }
}
