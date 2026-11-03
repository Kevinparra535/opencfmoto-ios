// SPDX-License-Identifier: AGPL-3.0-or-later
// Locked iPhone, Phase 0 (design §2.2 P0-4, P0-10, §6.1; contract §6.2, §9 P): RideModel when the
// phone is locked — the `.inactive` hold picture, then the background-encoder pre-warm (in that order,
// own-UI sessions only); the stored locked-phone policy pushed to the projection at start; GPS that
// already runs for the dash preview restarted with background updates (L17) only while the scene is
// `.active`; `lastHeadingAt`.
// NOTE (Linux): main-actor tests must be `async` (swift-corelibs-xctest).

import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class RideModelLockTests: XCTestCase {
    private let restartLine = "GPS restarted with background updates (it was running for the preview)"

    // MARK: P0-4 — `.inactive`: the hold picture, then the pre-warm

    @MainActor
    func testInactiveRequestsTheHoldPictureThenPrewarmsTheBackgroundEncoder() async {
        let h = AppTestHarness()
        h.addBike()
        h.ride.sessionChanged(active: true, mirror: false)
        XCTAssertEqual(h.projection.lockPreparations, [.holdPicture(.defaultLandscape)],
                       "Connect pre-encodes the hold picture; no pre-warm in the foreground")
        XCTAssertEqual(h.projection.backgroundEncoderPreparations, 0)

        h.ride.scenePhaseChanged(.inactive)
        XCTAssertEqual(h.projection.lockPreparations,
                       [.holdPicture(.defaultLandscape), .holdPicture(.defaultLandscape), .backgroundEncoder],
                       "the hold picture first, then the pre-warm (the engine runs them in this order)")
        XCTAssertEqual(h.projection.backgroundEncoderPreparations, 1)

        // Background, then back through `.inactive`: coming back never pre-warms.
        h.ride.scenePhaseChanged(.background)
        h.ride.scenePhaseChanged(.inactive)
        h.ride.scenePhaseChanged(.active)
        XCTAssertEqual(h.projection.backgroundEncoderPreparations, 1)
        XCTAssertEqual(h.projection.lockPreparations.count, 3)

        // The next lock, at the canvas the dash negotiated meanwhile.
        let wide = VideoCanvas(width: 1280, height: 576)
        h.ride.canvasNegotiated(wide)
        h.ride.scenePhaseChanged(.inactive)
        XCTAssertEqual(Array(h.projection.lockPreparations.suffix(2)), [.holdPicture(wide), .backgroundEncoder])
        XCTAssertEqual(h.projection.backgroundEncoderPreparations, 2)
    }

    @MainActor
    func testNoPrewarmWithoutAnOwnUISession() async {
        let h = AppTestHarness()
        h.addBike()
        h.ride.scenePhaseChanged(.inactive) // no session
        h.ride.scenePhaseChanged(.active)
        h.ride.sessionChanged(active: true, mirror: true)
        h.ride.scenePhaseChanged(.inactive) // mirror: the own UI is not projected
        h.ride.scenePhaseChanged(.active)
        XCTAssertEqual(h.projection.backgroundEncoderPreparations, 0)
        XCTAssertEqual(h.projection.lockPreparations, [])
        // Session over: nothing either.
        h.ride.sessionChanged(active: true, mirror: false)
        h.ride.sessionChanged(active: false, mirror: false)
        let before = h.projection.lockPreparations
        h.ride.scenePhaseChanged(.inactive)
        XCTAssertEqual(h.projection.lockPreparations, before)
        XCTAssertEqual(h.projection.backgroundEncoderPreparations, 0)
    }

    /// The path the app takes (SwiftUI → AppModel → RideModel → the projection port).
    @MainActor
    func testTheAppModelLockSequenceReachesTheProjectionInOrder() async {
        let h = AppTestHarness()
        h.addBike()
        h.connection.connect() // an own-UI session
        XCTAssertTrue(h.connection.isSessionActive)
        let atConnect = h.projection.lockPreparations
        XCTAssertEqual(atConnect, [.holdPicture(.defaultLandscape)])
        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.background)
        XCTAssertEqual(h.projection.lockPreparations, atConnect + [.holdPicture(.defaultLandscape), .backgroundEncoder])
        XCTAssertEqual(h.projection.stats.mode, "hold", "enterBackground after the preparations")
        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.active)
        XCTAssertEqual(h.projection.stats.mode, "foreground")
        XCTAssertEqual(h.projection.backgroundEncoderPreparations, 1)
        h.connection.stop()
    }

    // MARK: The stored locked-phone policy reaches the projection at start

    @MainActor
    func testAStoredPolicyReachesTheProjectionAtStart() async {
        let cases: [(String, LockedStreamPolicy)] = [("auto", .automatic), ("cpu", .cpuOnly), ("vtsw", .videoToolboxSoftwareOnly),
                                                     ("hold", .holdOnly), ("cpu-always", .cpuAlways)]
        for (raw, policy) in cases {
            let log = LogCapture()
            let h = AppTestHarness { $0.keyValueStore.set(raw, forKey: "ios.locked_stream_policy") }
            XCTAssertEqual(h.projection.lockedStreamPolicies, [policy], raw)
            XCTAssertTrue(log.messages(tag: "RIDE").contains("locked-phone policy from the settings: \(raw)"), raw)
            log.stop()
        }
    }

    @MainActor
    func testWithoutAValidStoredPolicyTheProjectionKeepsItsDefault() async {
        let unset = AppTestHarness()
        XCTAssertEqual(unset.projection.lockedStreamPolicies, [], "nothing stored: the build's default stays")
        for raw in ["", "bogus", "HOLD", "vt-sw", " vtsw"] {
            let h = AppTestHarness { $0.keyValueStore.set(raw, forKey: "ios.locked_stream_policy") }
            XCTAssertEqual(h.projection.lockedStreamPolicies, [], "'\(raw)'")
        }
        // The session lifecycle never pushes one either.
        unset.addBike()
        unset.ride.sessionChanged(active: true, mirror: false)
        unset.ride.scenePhaseChanged(.inactive)
        unset.ride.scenePhaseChanged(.background)
        XCTAssertEqual(unset.projection.lockedStreamPolicies, [])
    }

    // MARK: P0-10 — L17: restart GPS with background updates, only in the foreground

    @MainActor
    func testGPSRunningForThePreviewRestartsWithBackgroundUpdatesWhenASessionStartsInTheForeground() async {
        let h = AppTestHarness()
        h.addBike()
        let log = LogCapture()
        defer { log.stop() }
        h.ride.startLocationPreview() // the phone's Dash view: GPS without background updates
        XCTAssertEqual(h.location.calls, [.start(rideActive: false)])

        h.ride.sessionChanged(active: true, mirror: false) // Connect, the app in the foreground
        XCTAssertEqual(h.location.calls, [.start(rideActive: false), .stop, .start(rideActive: true)],
                       "stop, then start with background updates on (Apple's documented order)")
        XCTAssertTrue(h.location.isUpdating)
        XCTAssertTrue(h.location.isRideActive)
        XCTAssertEqual(log.messages(tag: "RIDE").filter { $0 == restartLine }.count, 1)

        // Housekeeping keeps it as it is.
        h.ride.runHousekeeping()
        XCTAssertEqual(h.location.calls.count, 3)

        // The session ends while the preview stays: background updates go off on the running updates.
        h.ride.sessionChanged(active: false, mirror: false)
        XCTAssertEqual(h.location.calls.last, .setRideActive(false))
        XCTAssertFalse(h.location.isRideActive)
        XCTAssertTrue(h.location.isUpdating)
        XCTAssertEqual(log.messages(tag: "RIDE").filter { $0 == restartLine }.count, 1)
    }

    @MainActor
    func testNoGPSRestartFromTheBackgroundOrWhileInactive() async {
        for phase in [AppScenePhase.background, .inactive] {
            let h = AppTestHarness()
            h.addBike()
            let log = LogCapture()
            h.ride.startLocationPreview()
            if phase == .background { h.ride.scenePhaseChanged(.inactive) }
            h.ride.scenePhaseChanged(phase)
            // A recording / navigation / session that turns background updates on while not active.
            h.ride.sessionChanged(active: true, mirror: false)
            XCTAssertEqual(h.location.calls, [.start(rideActive: false), .setRideActive(true)],
                           "\(phase): a When-In-Use app cannot start updates outside the foreground")
            XCTAssertTrue(h.location.isRideActive)
            XCTAssertFalse(log.messages(tag: "RIDE").contains(restartLine), "\(phase)")
            log.stop()
        }
    }

    @MainActor
    func testASessionWithoutGPSRunningStartsItOnceWithBackgroundUpdates() async {
        let h = AppTestHarness()
        h.addBike()
        let log = LogCapture()
        defer { log.stop() }
        h.ride.sessionChanged(active: true, mirror: false)
        XCTAssertEqual(h.location.calls, [.start(rideActive: true)], "no restart: started in the right order already")
        XCTAssertFalse(log.messages(tag: "RIDE").contains(restartLine))
    }

    // MARK: lastHeadingAt

    @MainActor
    func testLastHeadingAtIsTheMonotonicTimeOfTheLastRawHeading() async {
        let clock = MusicTestClock(500)
        let h = AppTestHarness { $0.clock = clock }
        XCTAssertNil(h.ride.lastHeadingAt, "no heading yet")
        h.location.emitHeading(90)
        XCTAssertEqual(h.ride.lastHeadingAt, 500)
        clock.advance(2.5)
        h.location.emitHeading(91)
        XCTAssertEqual(h.ride.lastHeadingAt, 502.5)
        clock.advance(1)
        h.location.emitHeading(.nan) // not a heading
        h.location.emitHeading(.infinity)
        XCTAssertEqual(h.ride.lastHeadingAt, 502.5)
        // Fixes do not count as headings.
        h.location.emit(LocationFix(lat: 45.1, lon: 25.0, timeMs: 1_000))
        XCTAssertEqual(h.ride.lastHeadingAt, 502.5)
    }
}
