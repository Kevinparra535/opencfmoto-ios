// SPDX-License-Identifier: AGPL-3.0-or-later
// ControlsModel: opt-in media remote → HandlebarGestureEngine → DashInput → the dash UI
// (input-controls.md §7–§10): tester texts, focus moves, Select, doubles, presence learning and
// teaching, session claim / release, mirror mode, the observed ▲/▼ volume-path option.
import Foundation
import Observation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

/// A handlebar port whose experimental volume path cannot be switched on.
@MainActor
private final class ControlsRefusingVolumeHandlebar: HandlebarRemoteProviding {
    var isAvailable = true
    private(set) var isEnabled = false
    var volumeButtonsEnabled: Bool {
        get { false }
        set { _ = newValue }
    }
    var onSignal: ((HandlebarSignal) -> Void)?
    func enable() { isEnabled = true }
    func disable() { isEnabled = false }
}

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
    func testQuickDoubleForwardIsOnlyOneStep() async {
        // P0 (D02): ▶▶ is unmapped on iOS (was Home → menu). The first ▶ moves the focus at once; the quick
        // second press is swallowed: no menu, no second step — a mistimed double never means something else.
        let h = AppTestHarness()
        h.controls.setRemoteEnabled(true)
        h.ride.flushModel()
        XCTAssertEqual(h.ride.ui.state.focusedId, "pill")
        signal(h, .forward)
        let afterOne = h.ride.ui.state.focusedId
        XCTAssertNotEqual(afterOne, "pill")
        signal(h, .forward, after: 0.1) // inside the 300 ms window → ▶▶ = Nothing
        XCTAssertEqual(h.ride.ui.state.sheet, .none)
        XCTAssertEqual(h.ride.ui.state.focusedId, afterOne)
        XCTAssertEqual(h.controls.lastCommand,
                       "\(SessionText.gestureLabel(.navFwdDouble, h.language)) \u{2192} \(SessionText.actionLabel(.none, h.language))")
    }

    /// input-controls §7.9: capture off = the bars control media normally. The remote is not even
    /// claimed (its silent non-mixable audio would keep the music paused while the engine drops every
    /// press) — review SPEC:CL-9.
    @MainActor
    func testHandlebarControlOffLeavesTheButtonsToMusic() async {
        let h = AppTestHarness()
        h.core.settings.setHandlebarControl(false, forBike: nil)
        await settle()
        h.controls.setRemoteEnabled(true)
        XCTAssertTrue(h.controls.isRemoteEnabled) // the opt-in is remembered
        XCTAssertFalse(h.handlebar.isEnabled)
        h.ride.flushModel()
        let before = h.ride.ui.state.focusedId
        signal(h, .forward)
        XCTAssertNil(h.controls.lastRawEvent)
        XCTAssertNil(h.controls.lastCommand)
        XCTAssertEqual(h.ride.ui.state.focusedId, before)
        // Capture back on (Controls screen): the rider's explicit claim takes effect (via the store
        // subscription here: the store write above bypassed SettingsModel, so `current` did not change).
        h.model.settings.setHandlebarControl(true)
        let claimed = await eventually { h.handlebar.isEnabled }
        XCTAssertTrue(claimed)
        signal(h, .forward)
        XCTAssertEqual(h.controls.lastRawEvent, "forward")
    }

    @MainActor
    func testARememberedOptInDoesNotClaimTheRemoteForABikeWithCaptureOff() async {
        let h = AppTestHarness { services in
            services.keyValueStore.set(true, forKey: ControlsModel.remoteOptInKey)
        }
        h.addBike()
        h.model.settings.setHandlebarControl(false) // per bike: a touch dash
        h.connection.connect()
        XCTAssertFalse(h.handlebar.isEnabled)
        h.connection.stop()
        XCTAssertFalse(h.handlebar.isEnabled)
    }

    @MainActor
    func testTogglingCaptureMidRideReleasesAndReclaimsTheRemote() async {
        let h = AppTestHarness { services in
            services.keyValueStore.set(true, forKey: ControlsModel.remoteOptInKey)
        }
        h.addBike()
        h.connection.connect()
        XCTAssertTrue(h.handlebar.isEnabled)
        h.model.settings.setHandlebarControl(false)
        XCTAssertFalse(h.handlebar.isEnabled) // the bars control music again
        h.model.settings.setHandlebarControl(true)
        XCTAssertTrue(h.handlebar.isEnabled)
        // A write straight to the store (e.g. a settings pack) is followed too.
        h.core.settings.setHandlebarControl(false, forBike: h.core.garage.selected?.id)
        let released = await eventually { !h.handlebar.isEnabled }
        XCTAssertTrue(released)
        h.connection.stop()
        XCTAssertFalse(h.handlebar.isEnabled)
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
    func testVolumeButtonsStateIsObservedAndFollowsThePort() async {
        // Restored from the rider's persisted choice at launch.
        let h = AppTestHarness { services in
            services.keyValueStore.set(true, forKey: ControlsModel.volumeButtonsKey)
        }
        XCTAssertTrue(h.controls.volumeButtonsEnabled)
        XCTAssertTrue(h.handlebar.volumeButtonsEnabled)

        // A stored, observed property: a view reading it is told about the change.
        let changes = Locked(0)
        withObservationTracking {
            _ = h.controls.volumeButtonsEnabled
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        h.controls.setVolumeButtonsEnabled(false)
        XCTAssertEqual(changes.current, 1)
        XCTAssertFalse(h.controls.volumeButtonsEnabled)
        XCTAssertFalse(h.handlebar.volumeButtonsEnabled)
        XCTAssertEqual(h.core.services.keyValueStore.bool(forKey: ControlsModel.volumeButtonsKey), false)

        // The model shows what the port really does; the rider's choice is still remembered.
        let refusing = AppTestHarness { services in
            services.keyValueStore.set(true, forKey: ControlsModel.volumeButtonsKey)
            services.handlebar = ControlsRefusingVolumeHandlebar()
        }
        XCTAssertFalse(refusing.controls.volumeButtonsEnabled)
        refusing.controls.setVolumeButtonsEnabled(true)
        XCTAssertFalse(refusing.controls.volumeButtonsEnabled)
        XCTAssertEqual(refusing.core.services.keyValueStore.bool(forKey: ControlsModel.volumeButtonsKey), true)
    }

    @MainActor
    func testTaughtPresenceDrivesTheLiveEngine() async {
        let h = AppTestHarness()
        let (bike, _) = h.addBike()
        await settle()
        let settings = h.model.settings
        let engine = h.controls.engine
        XCTAssertEqual(engine.presence, HandlebarPresence())

        // Teach my handlebar (Present / Absent / Unknown per source): the live engine follows.
        settings.setVolumeRockerPresence(.absent)
        XCTAssertEqual(settings.presence.volumeRocker, .absent)
        var synced = await eventually { engine.presence.volumeRocker == .absent }
        XCTAssertTrue(synced, "rocker taught absent")
        settings.setTrackKeysPresence(.present)
        let taught = HandlebarPresence(volumeRocker: .absent, trackKeys: .present)
        synced = await eventually { engine.presence == taught }
        XCTAssertTrue(synced, "track keys taught present")
        XCTAssertEqual(h.core.settings.presence(forBike: bike.id), taught)

        // Streaming with the rocker marked absent: no probe. Back to Unknown: a fresh ~90 s window.
        h.controls.setRemoteEnabled(true)
        h.controls.linkStreamingChanged(true, mirror: false)
        XCTAssertNil(engine.nextDeadlineMs())
        await settle(0.2)
        let taughtAtMs = Int64((h.core.services.clock.now() * 1000).rounded())
        settings.setVolumeRockerPresence(.unknown)
        synced = await eventually { engine.presence.volumeRocker == .unknown }
        XCTAssertTrue(synced, "rocker back to unknown")
        let probe = engine.nextDeadlineMs()
        XCTAssertNotNil(probe)
        XCTAssertGreaterThanOrEqual(probe ?? 0, taughtAtMs + HandlebarGestureEngine.absentVolumeProbeMs)

        // Reset to untested: both sources unknown in the engine too.
        settings.resetHandlebarPresence()
        synced = await eventually { engine.presence == HandlebarPresence() }
        XCTAssertTrue(synced, "reset")

        // Taught while the engine's own learning is still being persisted (both hops queued):
        // the engine, the store and the screen end up agreeing.
        settings.setVolumeRockerPresence(.absent)
        signal(h, .volumeDown, steps: 3)
        await settle(0.1)
        let agreed = h.core.settings.presence(forBike: bike.id)
        XCTAssertEqual(engine.presence, agreed)
        XCTAssertEqual(settings.presence, agreed)

        // What the engine learns by itself is persisted, never "taught" back to it.
        settings.setVolumeRockerPresence(.absent)
        synced = await eventually { engine.presence.volumeRocker == .absent }
        XCTAssertTrue(synced, "absent again")
        await settle()
        let echoed = Locked(false)
        let subscription = Log.shared.subscribe { line in
            if line.message.contains("handlebar sources taught") { echoed.withLock { $0 = true } }
        }
        defer { Log.shared.unsubscribe(subscription) }
        signal(h, .volumeDown, steps: 3)
        let learned = await eventually { h.core.settings.presence(forBike: bike.id).volumeRocker == .present }
        XCTAssertTrue(learned)
        await settle()
        XCTAssertEqual(engine.presence.volumeRocker, .present)
        XCTAssertEqual(settings.presence.volumeRocker, .present)
        XCTAssertFalse(echoed.current, "the learned value was sent back to the engine as if taught")
        h.controls.sessionChanged(active: false, mirror: false)
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
