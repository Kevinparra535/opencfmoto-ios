// SPDX-License-Identifier: AGPL-3.0-or-later
// «Modo bolsillo» offered by itself (UI/UX P0, UX-01): the countdown arithmetic, the pure rules, and
// RideModel's countdown — offered when the own dash UI goes live (also through a real Connect) or
// guidance starts, «Quedarme aquí» cancels, pocket mode when it runs out, and never over a dialog,
// an opened file, the keyboard, a dash typing request, out of the foreground, without a live dash,
// or in the E2E / screenshot launch modes.
import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class PocketModeOfferTests: XCTestCase {
    // MARK: Countdown value

    func testCountdownArithmetic() {
        let c = PocketCountdown(trigger: .connected, startedAt: 100, duration: 5)
        XCTAssertEqual(c.deadline, 105)
        XCTAssertEqual(c.remaining(at: 100), 5)
        XCTAssertEqual(c.secondsLeft(at: 100), 5)
        XCTAssertEqual(c.progress(at: 100), 0)
        XCTAssertEqual(c.secondsLeft(at: 100.2), 5)
        XCTAssertEqual(c.secondsLeft(at: 101), 4)
        XCTAssertEqual(c.secondsLeft(at: 102.5), 3)
        XCTAssertEqual(c.secondsLeft(at: 104.9), 1)
        XCTAssertEqual(c.secondsLeft(at: 105), 1, "never 0 while the card is up")
        XCTAssertEqual(c.remaining(at: 105), 0)
        XCTAssertEqual(c.progress(at: 105), 1)
        XCTAssertEqual(c.progress(at: 102.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.remaining(at: 200), 0)
        XCTAssertEqual(c.remaining(at: 50), 5, "a clock before the start shows the full countdown")
        XCTAssertEqual(c.remaining(at: .nan), 5)
        XCTAssertEqual(PocketCountdown(trigger: .guidance, startedAt: 0, duration: -3).duration, 0)
        XCTAssertEqual(PocketCountdown(trigger: .guidance, startedAt: 0, duration: .infinity).duration, 0)
        XCTAssertEqual(PocketCountdown(trigger: .guidance, startedAt: 0, duration: 0).progress(at: 0), 1)
        XCTAssertEqual(PocketModePolicy.countdownSeconds, 5)
        XCTAssertEqual(RideTuning().pocketCountdown, 5)
    }

    // MARK: Rules

    func testPolicyBlocksEverythingButAFreeForegroundLiveDash() {
        let free = PocketModePolicy.Context(isEnabled: true, isProjecting: true, isSceneActive: true,
                                            isPocketModeActive: false, busyReason: nil)
        XCTAssertNil(PocketModePolicy.blocker(free))
        var c = free
        c.isEnabled = false
        XCTAssertNotNil(PocketModePolicy.blocker(c))
        c = free
        c.isProjecting = false
        XCTAssertNotNil(PocketModePolicy.blocker(c), "no dash UI on the dash (connecting, mirror, stopped)")
        c = free
        c.isSceneActive = false
        XCTAssertNotNil(PocketModePolicy.blocker(c))
        c = free
        c.isPocketModeActive = true
        XCTAssertNotNil(PocketModePolicy.blocker(c))
        c = free
        c.busyReason = "a dialog"
        XCTAssertEqual(PocketModePolicy.blocker(c), "a dialog")
    }

    func testGuidanceStartIsAModeChangeIntoNavigation() {
        let a = Place(name: "A", lat: 4.6, lon: -74.0)
        let b = Place(name: "B", lat: 4.7, lon: -74.1)
        XCTAssertTrue(PocketModePolicy.guidanceStarted(from: .freeRide, to: .navTo(a)))
        XCTAssertTrue(PocketModePolicy.guidanceStarted(from: .freeRide, to: .gpx(name: "Loop")))
        XCTAssertTrue(PocketModePolicy.guidanceStarted(from: .navTo(a), to: .navTo(b)), "Go to another place")
        XCTAssertTrue(PocketModePolicy.guidanceStarted(from: .navTo(a), to: .gpx(name: "Loop")))
        XCTAssertTrue(PocketModePolicy.guidanceStarted(from: .gpx(name: "Loop"), to: .navTo(a)))
        XCTAssertFalse(PocketModePolicy.guidanceStarted(from: .navTo(a), to: .navTo(a)), "a reroute")
        XCTAssertFalse(PocketModePolicy.guidanceStarted(from: .gpx(name: "Loop"), to: .gpx(name: "Loop")))
        XCTAssertFalse(PocketModePolicy.guidanceStarted(from: .navTo(a), to: .freeRide), "an arrival / End")
        XCTAssertFalse(PocketModePolicy.guidanceStarted(from: .freeRide, to: .freeRide))
    }

    // MARK: RideModel

    @MainActor
    private func harness(countdown: TimeInterval = 0.15) -> AppTestHarness {
        let h = AppTestHarness()
        h.ride.tuning.pocketCountdown = countdown
        return h
    }

    @MainActor
    func testTheDashGoingLiveOffersPocketModeThatStartsWhenTheCountdownRunsOut() async {
        let h = harness()
        XCTAssertNil(h.ride.pocketCountdown)
        h.ride.projectionChanged(active: true)
        let countdown = h.ride.pocketCountdown
        XCTAssertEqual(countdown?.trigger, .connected)
        XCTAssertEqual(countdown?.duration, 0.15)
        XCTAssertFalse(h.ride.isRideModeActive, "nothing happens before the countdown runs out")
        let pocket = await eventually { h.ride.isRideModeActive }
        XCTAssertTrue(pocket)
        XCTAssertNil(h.ride.pocketCountdown)
        XCTAssertTrue(h.system.isIdleTimerDisabled, "pocket mode keeps the screen awake")
        h.ride.exitRideMode()
        XCTAssertFalse(h.ride.isRideModeActive)
    }

    @MainActor
    func testStayHereEndsTheCountdownAndNothingElseChanges() async {
        let h = harness()
        h.ride.projectionChanged(active: true)
        XCTAssertNotNil(h.ride.pocketCountdown)
        h.ride.cancelPocketCountdown()
        XCTAssertNil(h.ride.pocketCountdown)
        await settle(0.4)
        XCTAssertFalse(h.ride.isRideModeActive)
        XCTAssertTrue(h.ride.isProjecting, "the dash keeps the map")
        // One offer per trigger: staying is not undone by a reroute or a repeated live report.
        h.ride.projectionChanged(active: true)
        XCTAssertNil(h.ride.pocketCountdown)
    }

    @MainActor
    func testARealConnectThatReachesTheDashOffersPocketMode() async {
        let h = harness(countdown: 30)
        h.addBike()
        h.connection.connect()
        _ = await eventually { h.connection.link != nil }
        XCTAssertNil(h.ride.pocketCountdown, "connecting is not the dash being live")
        h.connection.handleLinkEvent(.state(.streaming), gen: h.connection.generation, serial: h.connection.linkSerial)
        XCTAssertEqual(h.connection.phase, .streaming)
        XCTAssertEqual(h.ride.pocketCountdown?.trigger, .connected)
        // Stop ends the dash link, and with it the offer.
        h.connection.stop()
        XCTAssertNil(h.ride.pocketCountdown)
        XCTAssertFalse(h.ride.isRideModeActive)
    }

    @MainActor
    func testAMirrorSessionNeverOffersPocketMode() async {
        let h = harness(countdown: 30)
        h.addBike()
        h.connection.startMirror()
        _ = await eventually { h.connection.link != nil }
        h.connection.handleLinkEvent(.state(.streaming), gen: h.connection.generation, serial: h.connection.linkSerial)
        XCTAssertEqual(h.connection.phase, .mirroring)
        XCTAssertFalse(h.ride.isProjecting)
        XCTAssertNil(h.ride.pocketCountdown, "a black pocket screen would be mirrored to the dash")
        h.connection.stop()
    }

    @MainActor
    func testGuidanceStartOffersPocketModeOnlyWhileTheDashIsLive() async {
        let h = harness(countdown: 30)
        let nav = h.core.navigation
        h.location.emit(LocationFix(lat: 4.6584, lon: -74.0930, speedMps: 0, timeMs: 1_790_000_000_000))
        // No dash: planning at home starts no countdown.
        nav.navigate(to: Place(name: "Café", lat: 4.70, lon: -74.04))
        _ = await eventually { nav.snapshot.mode.isNavigating }
        await settle(0.1)
        XCTAssertNil(h.ride.pocketCountdown)
        nav.endNavigation()
        _ = await eventually { !nav.snapshot.mode.isNavigating }
        await settle(0.1)

        h.ride.projectionChanged(active: true)
        h.ride.cancelPocketCountdown() // the rider stayed after Connect
        nav.navigate(to: Place(name: "Mirador", lat: 4.72, lon: -73.97))
        let offered = await eventually { h.ride.pocketCountdown != nil }
        XCTAssertTrue(offered)
        XCTAssertEqual(h.ride.pocketCountdown?.trigger, .guidance)
        h.ride.cancelPocketCountdown()
        // A reroute of the same route is not a start.
        nav.recalc()
        await settle(0.15)
        XCTAssertNil(h.ride.pocketCountdown)
    }

    @MainActor
    func testNoOfferOutOfTheForegroundAndLeavingItEndsTheCountdown() async {
        let h = harness()
        h.ride.scenePhaseChanged(.background)
        h.ride.projectionChanged(active: true)
        XCTAssertNil(h.ride.pocketCountdown)
        h.ride.projectionChanged(active: false)
        h.ride.scenePhaseChanged(.active)
        h.ride.projectionChanged(active: true)
        XCTAssertNotNil(h.ride.pocketCountdown)
        h.ride.scenePhaseChanged(.inactive) // lock, app switcher, a call
        XCTAssertNil(h.ride.pocketCountdown)
        await settle(0.4)
        XCTAssertFalse(h.ride.isRideModeActive)
    }

    @MainActor
    func testTheDashLinkEndingEndsTheCountdown() async {
        let h = harness()
        h.ride.projectionChanged(active: true)
        h.ride.projectionChanged(active: false)
        XCTAssertNil(h.ride.pocketCountdown)
        await settle(0.4)
        XCTAssertFalse(h.ride.isRideModeActive)
    }

    @MainActor
    func testNeverOverADialogOrAnOpenedFileWaitingForAnAnswer() async {
        let h = harness()
        // An opened settings pack waits for its confirmation: no offer.
        h.model.requestImportConfirmation(PendingImport(kind: .settings, fileName: "pack.json", text: "{}"))
        h.ride.projectionChanged(active: true)
        XCTAssertNil(h.ride.pocketCountdown)
        h.model.cancelPendingImport()
        h.ride.projectionChanged(active: false)

        // A countdown running when an opened GPX track arrives ends without pocket mode.
        h.ride.projectionChanged(active: true)
        XCTAssertNotNil(h.ride.pocketCountdown)
        h.model.navigation.previewGpx(data: Data(GpxPreviewTests.loop.utf8), fileName: "Loop.gpx")
        XCTAssertNotNil(h.model.navigation.pendingGpx)
        let ended = await eventually { h.ride.pocketCountdown == nil }
        XCTAssertTrue(ended)
        XCTAssertFalse(h.ride.isRideModeActive, "pocket mode never covers a question")
        XCTAssertEqual(h.model.pocketOfferBusyReason(), "an opened GPX track waits for an answer")
        h.model.navigation.cancelPendingGpx()
        XCTAssertNil(h.model.pocketOfferBusyReason())
    }

    @MainActor
    func testThePhoneInUseEndsTheCountdownAndBlocksNewOffers() async {
        let h = harness()
        h.ride.projectionChanged(active: true)
        XCTAssertNotNil(h.ride.pocketCountdown)
        h.ride.isPhoneInUse = true // the keyboard came up
        XCTAssertNil(h.ride.pocketCountdown)
        h.ride.projectionChanged(active: false)
        h.ride.projectionChanged(active: true)
        XCTAssertNil(h.ride.pocketCountdown)
        h.ride.isPhoneInUse = false
        await settle(0.4)
        XCTAssertFalse(h.ride.isRideModeActive)
    }

    @MainActor
    func testNeverPresentedOverSomethingOpenOnThePhone() async {
        // The UI's own look at the screen (a file picker or share sheet opened by a screen, an alert):
        // asked when the offer starts and again when it runs out.
        let h = harness()
        var sheetUp = true
        h.ride.isPhoneBusyNow = { sheetUp }
        h.ride.projectionChanged(active: true)
        XCTAssertNil(h.ride.pocketCountdown)
        h.ride.projectionChanged(active: false)
        sheetUp = false
        h.ride.projectionChanged(active: true)
        XCTAssertNotNil(h.ride.pocketCountdown)
        sheetUp = true // a sheet came up during the countdown
        let ended = await eventually { h.ride.pocketCountdown == nil }
        XCTAssertTrue(ended)
        await settle(0.1)
        XCTAssertFalse(h.ride.isRideModeActive, "the pocket cover never goes over a sheet")
    }

    @MainActor
    func testTheDashTypingRequestEndsTheCountdown() async {
        let h = harness(countdown: 30)
        h.ride.projectionChanged(active: true)
        XCTAssertNotNil(h.ride.pocketCountdown)
        h.ride.performDashIntent(.typeOnPhone)
        XCTAssertTrue(h.model.navigation.typeOnPhoneRequested)
        XCTAssertNil(h.ride.pocketCountdown, "the rider is about to type on the phone")
        XCTAssertEqual(h.model.pocketOfferBusyReason(), "the dash asks to type on the phone")
    }

    @MainActor
    func testPocketModeByHandOrTheLaunchModesEndTheOffer() async {
        let h = harness()
        h.ride.projectionChanged(active: true)
        h.ride.enterRideMode() // the Home / Dash view button during the countdown
        XCTAssertNil(h.ride.pocketCountdown)
        XCTAssertTrue(h.ride.isRideModeActive)
        h.ride.exitRideMode()
        h.ride.projectionChanged(active: false)

        // E2E / screenshot launch modes: no offer at all, and a running one ends.
        h.ride.projectionChanged(active: true)
        XCTAssertNotNil(h.ride.pocketCountdown)
        h.ride.offersPocketMode = false
        XCTAssertNil(h.ride.pocketCountdown)
        h.ride.projectionChanged(active: false)
        h.ride.projectionChanged(active: true)
        XCTAssertNil(h.ride.pocketCountdown)
        await settle(0.4)
        XCTAssertFalse(h.ride.isRideModeActive)
    }
}
