// SPDX-License-Identifier: AGPL-3.0-or-later
// RideModel wiring: fix → NavigationSession + TripRecorder + HUD texts, raw heading → session,
// dash touches on hit regions → intents executed, NavEffect.speak → speech (voice on/off),
// toasts on the dash, Ride Mode idle timer, scene phases → projection, trip auto-log policy,
// AUTO power mode ticks, preview / negotiated canvas, the demo route player.
import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class RideModelTests: XCTestCase {
    private func fix(lat: Double = 4.6584, lon: Double = -74.0930, speed: Double? = 0, course: Double? = nil,
                     accuracy: Double? = 5, t: Int64 = 1_790_000_000_000) -> LocationFix {
        LocationFix(lat: lat, lon: lon, speedMps: speed, courseDeg: course, accuracyM: accuracy, altitudeM: 2600, timeMs: t)
    }

    @MainActor
    private func tap(_ h: AppTestHarness, region id: String, file: StaticString = #filePath, line: UInt = #line) {
        h.ride.flushModel()
        let now = h.core.services.clock.now()
        guard let r = h.ride.displayList(now: now).hitRegions.last(where: { $0.id == id }) else {
            XCTFail("no hit region \(id)", file: file, line: line)
            return
        }
        let x = Int(r.rect.midX)
        let y = Int(r.rect.midY)
        h.ride.handleDashTouch(DashTouch(action: .down, x: x, y: y, time: now))
        h.ride.handleDashTouch(DashTouch(action: .up, x: x, y: y, time: now + 0.05))
    }

    private func texts(_ list: DashDisplayList) -> [String] {
        list.commands.compactMap { if case let .text(s, _, _) = $0 { return s }; return nil }
    }

    // MARK: Location

    @MainActor
    func testPhoneOnlyGuidanceKeepsGPSAfterTheMapHubCloses() async {
        let h = AppTestHarness()
        // The Map hub holds GPS while visible; the rider starts a free ride from it.
        h.ride.startLocationPreview()
        XCTAssertTrue(h.location.isUpdating)
        h.location.emit(fix(speed: 10, course: 0))
        h.core.navigation.navigate(to: Place(name: "Dest", lat: 4.70, lon: -74.04))
        let guiding = await eventually { h.core.navigation.snapshot.mode.isNavigating }
        XCTAssertTrue(guiding)
        _ = await eventually { RideModel.needsGuidanceFixes(h.core.navigation.snapshot) }
        // Leaving the Map hub must not cut the guidance off…
        h.ride.stopLocationPreview()
        let stillOn = await eventually { h.location.isUpdating && h.location.isRideActive }
        XCTAssertTrue(stillOn, "navigation keeps GPS (and background updates) without any screen")
        // …and ending it turns GPS off.
        h.core.navigation.endNavigation()
        let off = await eventually { !h.location.isUpdating }
        XCTAssertTrue(off)
    }

    @MainActor
    func testFixFeedsNavigationRecorderAndTheHomeCard() async {
        let h = AppTestHarness()
        XCTAssertFalse(h.location.isUpdating)
        XCTAssertEqual(h.ride.gpsStatus, SessionText.gpsOff(h.language))
        h.ride.startLocationPreview()
        XCTAssertTrue(h.location.isUpdating)
        XCTAssertFalse(h.location.isRideActive) // no background location for a phone preview
        XCTAssertEqual(h.ride.gpsStatus, SessionText.waitingForGps(h.language))

        let f = fix(speed: 13.0556, course: 90)
        h.location.emit(f)
        XCTAssertEqual(h.core.navigation.currentFix, f)
        XCTAssertEqual(h.ride.lastFix, f)
        XCTAssertEqual(h.ride.speedText, "47 km/h")
        XCTAssertEqual(h.ride.gpsStatus, SessionText.gpsFix(accuracyM: 5, h.language))

        // The recorder gets every fix while recording; GPS stays on for it after the preview.
        XCTAssertTrue(h.core.tripRecorder.start())
        h.location.emit(fix(lat: 4.6590, speed: 10, t: 1_790_000_001_000))
        XCTAssertTrue(h.core.tripRecorder.snapshot().hasFix)
        h.ride.stopLocationPreview()
        XCTAssertTrue(h.location.isUpdating)
        XCTAssertTrue(h.location.isRideActive) // a recording keeps the ride alive in the background
        h.core.tripRecorder.discard()
        h.ride.runHousekeeping()
        XCTAssertFalse(h.location.isUpdating)
    }

    @MainActor
    func testImperialUnitsChangeTheSpeedText() async {
        let h = AppTestHarness()
        h.ride.perform([.setUnits(.imperial)], fromDash: true)
        h.location.emit(fix(speed: 13.0556))
        XCTAssertEqual(h.ride.speedText, "29 mph")
    }

    @MainActor
    func testRawHeadingReachesTheNavigationSession() async {
        let h = AppTestHarness()
        h.location.emit(fix(speed: 0))
        h.location.emitHeading(90)
        let followed = await eventually { abs(h.core.navigation.snapshot.puckBearingDeg - 90) < 0.5 }
        XCTAssertTrue(followed, "puck \(h.core.navigation.snapshot.puckBearingDeg)")
    }

    @MainActor
    func testLocationPermissionGatesGPS() async {
        let h = AppTestHarness()
        h.location.permission = .denied
        h.ride.startLocationPreview()
        XCTAssertFalse(h.location.isUpdating)
        XCTAssertEqual(h.ride.gpsStatus, SessionText.locationPermissionNeeded(h.language))
        h.location.permission = .whenInUse
        h.ride.locationPermissionChanged(.whenInUse)
        XCTAssertTrue(h.location.isUpdating)
    }

    // MARK: Dash touches → intents

    @MainActor
    func testDashTouchOnAHitRegionPerformsTheIntent() async {
        let h = AppTestHarness()
        h.location.emit(fix())
        await settle()
        tap(h, region: "pill.lap")
        XCTAssertTrue(h.core.navigation.isLapTimerOn)
        // The lap card is on the dash.
        let card = await eventually { self.texts(h.ride.displayList(now: h.core.services.clock.now())).contains { $0.contains(NavStrings(language: h.language).lapPassStartFinish) } }
        XCTAssertTrue(card)
        tap(h, region: "fab.menu")
        XCTAssertEqual(h.ride.ui.state.sheet, .menu)
    }

    @MainActor
    func testPhonePreviewInputUsesTheSameController() async {
        let h = AppTestHarness()
        h.ride.flushModel()
        let r = h.ride.displayList(now: h.core.services.clock.now()).hitRegions.last { $0.id == "fab.menu" }
        XCTAssertNotNil(r)
        if let r {
            let now = h.core.services.clock.now()
            h.ride.sendPreviewInput(.touch(DashTouch(action: .down, pointerId: 1000, x: Int(r.rect.midX), y: Int(r.rect.midY), time: now)))
            h.ride.sendPreviewInput(.touch(DashTouch(action: .up, pointerId: 1000, x: Int(r.rect.midX), y: Int(r.rect.midY), time: now + 0.05)))
        }
        XCTAssertEqual(h.ride.ui.state.sheet, .menu)
        h.ride.sendPreviewInput(.key(.back))
        XCTAssertEqual(h.ride.ui.state.sheet, .none)
    }

    @MainActor
    func testTypeOnPhoneFromTheDashFocusesThePhoneSearch() async {
        let h = AppTestHarness()
        h.ride.perform([.typeOnPhone], fromDash: true)
        XCTAssertTrue(h.model.navigation.typeOnPhoneRequested)
        XCTAssertEqual(h.system.hapticCount, 1)
        XCTAssertEqual(h.speech.spoken, [NavStrings(language: h.language).phrase(.typeSearchOnPhone)])
        h.model.navigation.acknowledgeTypeOnPhone()
        // From the phone preview: focus the field, no buzz / voice.
        h.ride.perform([.typeOnPhone], fromDash: false)
        XCTAssertTrue(h.model.navigation.typeOnPhoneRequested)
        XCTAssertEqual(h.system.hapticCount, 1)
        XCTAssertEqual(h.speech.spoken.count, 1)
    }

    @MainActor
    func testChipSearchWithoutGPSShowsTheStatusOnTheDash() async {
        let h = AppTestHarness()
        _ = h.ride.ui.perform(.openSearch, now: h.core.services.clock.now())
        h.ride.perform([.searchChip("Fuel")], fromDash: true)
        let status = NavStrings(language: h.language).phrase(.needGpsForPoi)
        let shown = await eventually { self.texts(h.ride.displayList(now: h.core.services.clock.now())).contains(status) }
        XCTAssertTrue(shown)
    }

    // MARK: Navigation effects → speech / dash toasts

    @MainActor
    func testNavEffectsSpeakAndToastUnlessVoiceIsOff() async {
        let h = AppTestHarness()
        let strings = NavStrings(language: h.language)
        h.location.emit(fix())
        h.ride.perform([.setHomeHere], fromDash: true)
        let spoken = await eventually { h.speech.spoken.contains(strings.phrase(.homeSet)) }
        XCTAssertTrue(spoken)
        let toast = await eventually { h.ride.ui.state.toast == strings.phrase(.homeSetHere) }
        XCTAssertTrue(toast)

        // Voice off from the dash menu: muted, nothing more is spoken.
        h.ride.perform([.toggleVoice], fromDash: true)
        XCTAssertTrue(h.speech.isMuted)
        XCTAssertFalse(h.core.navigation.preferences.voiceOn)
        let count = h.speech.spoken.count
        h.ride.perform([.parkHere], fromDash: true)
        await settle(0.1)
        XCTAssertEqual(h.speech.spoken.count, count)
        h.ride.perform([.setVoice(true)], fromDash: true)
        XCTAssertFalse(h.speech.isMuted)
        XCTAssertTrue(h.core.navigation.preferences.voiceOn)
    }

    @MainActor
    func testRecordToggleFromTheDash() async {
        let h = AppTestHarness()
        h.location.emit(fix())
        h.core.tripRecorder.start() // e.g. started by the trip computer
        h.ride.perform([.toggleRecording], fromDash: true)
        // TripsModel.stopRecording belongs to logic-data; the toast / voice are ours.
        let toast = await eventually {
            h.ride.ui.state.toast == SessionText.recordingSavedToast(h.language)
        }
        XCTAssertTrue(toast)
        XCTAssertEqual(h.speech.spoken.last, SessionText.recordingSavedVoice(h.language))
    }

    // MARK: Ride Mode, scene phases, projection providers

    @MainActor
    func testRideModeKeepsTheScreenAwake() async {
        let h = AppTestHarness()
        h.ride.enterRideMode()
        XCTAssertTrue(h.ride.isRideModeActive)
        XCTAssertTrue(h.system.isIdleTimerDisabled)
        h.ride.exitRideMode()
        XCTAssertFalse(h.system.isIdleTimerDisabled)
        // While linked (keepScreenOn on by default) the screen stays awake after Ride Mode.
        h.ride.sessionChanged(active: true, mirror: false)
        h.ride.enterRideMode()
        h.ride.exitRideMode()
        XCTAssertTrue(h.system.isIdleTimerDisabled)
        h.ride.sessionChanged(active: false, mirror: false)
        XCTAssertFalse(h.system.isIdleTimerDisabled)
        // keepScreenOn off: only Ride Mode keeps it awake.
        h.core.settings.update(forBike: nil) { $0.keepScreenOn = false }
        await settle()
        h.ride.sessionChanged(active: true, mirror: false)
        XCTAssertFalse(h.system.isIdleTimerDisabled)
        h.ride.sessionChanged(active: false, mirror: false)
    }

    @MainActor
    func testScenePhasesDriveTheProjection() async {
        let h = AppTestHarness()
        h.ride.scenePhaseChanged(.background)
        XCTAssertEqual(h.projection.stats.mode, "hold")
        h.ride.scenePhaseChanged(.active)
        XCTAssertEqual(h.projection.stats.mode, "foreground")
    }

    @MainActor
    func testProjectionProvidersDrawTheDashUIAndTheHoldPicture() async {
        let h = AppTestHarness()
        h.ride.flushModel()
        let now = h.core.services.clock.now()
        XCTAssertEqual(h.projection.currentDisplayList(now: now), h.ride.displayList(now: now))
        let hold = h.projection.currentHoldDisplayList(now: now)
        XCTAssertNotNil(hold)
        // P0 (D17): the dash's own hold card — "Map paused" / «Mapa en pausa», no map, no numbers.
        let holdTexts = texts(hold ?? h.ride.displayList(now: now))
        XCTAssertTrue(holdTexts.contains(DashText.holdTitle.en) || holdTexts.contains(DashText.holdTitle.es), "\(holdTexts)")
        XCTAssertGreaterThan(h.projection.invalidations, 0)
    }

    /// P0 (D17): while the projection serves the hold picture the dash shows no live controls, so its keys,
    /// the knob and touches act on nothing — back in the foreground they act again.
    @MainActor
    func testDashInputIsIgnoredWhileTheHoldPictureShows() async {
        let h = AppTestHarness()
        h.ride.flushModel()
        let clock = h.core.services.clock
        let before = h.ride.dashUIState
        XCTAssertEqual(before.sheet, .none)
        h.projection.enterBackground()
        XCTAssertTrue(h.ride.dashShowsHoldPicture)
        h.ride.handleDashInput(.knob(1))
        h.ride.handleDashInput(.key(.enter))
        h.ride.handleDashInput(.key(.home))
        let p = h.ride.displayList(now: clock.now()).hitRegions.first { $0.focusable }?.rect.center ?? DashPoint(10, 10)
        h.ride.handleDashTouch(DashTouch(action: .down, x: Int(p.x), y: Int(p.y), time: clock.now()))
        h.ride.handleDashTouch(DashTouch(action: .up, x: Int(p.x), y: Int(p.y), time: clock.now() + 0.05))
        XCTAssertEqual(h.ride.dashUIState.sheet, .none, "nothing opened")
        XCTAssertEqual(h.ride.dashUIState.focusedId, before.focusedId, "the focus did not move")
        h.projection.enterForeground()
        XCTAssertFalse(h.ride.dashShowsHoldPicture)
        h.ride.handleDashInput(.key(.home))
        XCTAssertEqual(h.ride.dashUIState.sheet, .menu, "in the foreground the keys act again")
    }

    @MainActor
    func testPreviewCanvasAndNegotiatedCanvas() async {
        let h = AppTestHarness()
        let now = h.core.services.clock.now()
        XCTAssertEqual(h.ride.displayList(now: now).size, DashSize(width: 800, height: 384))
        h.ride.previewCanvas = .portrait800x944
        XCTAssertEqual(h.ride.canvasSize, DashSize(width: 800, height: 944))
        XCTAssertEqual(h.ride.displayList(now: now).size, DashSize(width: 800, height: 944))
        h.ride.canvasNegotiated(VideoCanvas(width: 1280, height: 576))
        XCTAssertEqual(h.ride.canvasSize, DashSize(width: 1280, height: 576))
        h.ride.projectionChanged(active: true)
        h.ride.projectionChanged(active: false) // link ended → back to the preview canvas
        XCTAssertEqual(h.ride.canvasSize, DashSize(width: 800, height: 944))
    }

    @MainActor
    func testRevisionBumpsWhenThePictureChanges() async {
        let h = AppTestHarness()
        let r0 = h.ride.revision
        h.location.emit(fix(speed: 5))
        let bumped = await eventually { h.ride.revision != r0 }
        XCTAssertTrue(bumped)
    }

    // MARK: Trip auto-log (app-features §5.4)

    @MainActor
    func testTripAutoLogFollowsTheLinkButNeverStopsAManualRecording() async {
        let h = AppTestHarness()
        let recorder = h.core.tripRecorder
        h.ride.sessionChanged(active: true, mirror: false)
        XCTAssertFalse(recorder.isRecording)
        h.ride.linkPhaseChanged(.streaming)
        h.ride.projectionChanged(active: true)
        XCTAssertTrue(recorder.isRecording)
        // A reconnect keeps logging (the own UI is still the dash content).
        h.ride.linkPhaseChanged(.reconnecting)
        XCTAssertTrue(recorder.isRecording)
        h.ride.projectionChanged(active: false)
        h.ride.linkPhaseChanged(.stopped)
        h.ride.sessionChanged(active: false, mirror: false)
        XCTAssertFalse(recorder.isRecording)

        // A recording the auto-log did not start is never stopped by it.
        recorder.start()
        h.ride.sessionChanged(active: true, mirror: false)
        h.ride.linkPhaseChanged(.streaming)
        h.ride.projectionChanged(active: true)
        h.ride.projectionChanged(active: false)
        h.ride.linkPhaseChanged(.stopped)
        h.ride.sessionChanged(active: false, mirror: false)
        XCTAssertTrue(recorder.isRecording)
        recorder.discard()

        // "Log trips automatically" off → nothing starts.
        h.core.settings.update(forBike: nil) { $0.logTrips = false }
        await settle()
        h.ride.sessionChanged(active: true, mirror: false)
        h.ride.linkPhaseChanged(.streaming)
        h.ride.projectionChanged(active: true)
        XCTAssertFalse(recorder.isRecording)
    }

    @MainActor
    func testStoppingTheAutoLogFromTheDashSuppressesItUntilTheSessionEnds() async {
        let h = AppTestHarness()
        let recorder = h.core.tripRecorder
        h.ride.sessionChanged(active: true, mirror: false)
        h.ride.linkPhaseChanged(.streaming)
        h.ride.projectionChanged(active: true)
        XCTAssertTrue(recorder.isRecording)
        h.ride.perform([.toggleRecording], fromDash: true)
        XCTAssertFalse(recorder.isRecording)
        h.ride.runHousekeeping()
        XCTAssertFalse(recorder.isRecording)
        // Next session: auto-logging again.
        h.ride.projectionChanged(active: false)
        h.ride.linkPhaseChanged(.stopped)
        h.ride.sessionChanged(active: false, mirror: false)
        h.ride.sessionChanged(active: true, mirror: false)
        h.ride.linkPhaseChanged(.streaming)
        h.ride.projectionChanged(active: true)
        XCTAssertTrue(recorder.isRecording)
    }

    // MARK: AUTO power mode (AdaptivePolicy every 5 s)

    @MainActor
    func testAutoPowerModeAdaptsToHeat() async {
        let h = AppTestHarness()
        h.core.settings.update(forBike: nil) { $0.powerMode = .auto }
        await settle()
        h.ride.sessionChanged(active: true, mirror: false)
        h.ride.projectionChanged(active: true)
        let base = EncoderPlanner.plan(profile: RideEncoderPlan.values(.legacy), quality: .balanced, powerMode: .auto, ownUI: true)
        XCTAssertEqual(h.projection.parameters, base)
        h.system.thermalLevel = .severe
        h.ride.runHousekeeping()
        let hot = h.projection.parameters
        XCTAssertEqual(hot?.frameRate, 15)
        XCTAssertEqual(hot?.bitrate, Int(Float(base.bitrate) * 0.6))
        // Back to BALANCED: the plan follows the mode's frame cap.
        h.core.settings.update(forBike: nil) { $0.powerMode = .balanced }
        await settle()
        h.ride.runHousekeeping()
        XCTAssertEqual(h.projection.parameters?.frameRate, 24)
    }

    @MainActor
    func testLowPowerModeCapsTheFrameRate() async {
        let h = AppTestHarness()
        h.core.settings.update(forBike: nil) { $0.powerMode = .smooth }
        await settle()
        h.ride.sessionChanged(active: true, mirror: false)
        h.ride.projectionChanged(active: true)
        XCTAssertEqual(h.projection.parameters?.frameRate, 30)
        h.system.isLowPowerModeEnabled = true
        h.system.onPowerStateChange?()
        XCTAssertEqual(h.projection.parameters?.frameRate, 15)
    }

    // MARK: Demo route player

    @MainActor
    func testDemoRoutePlayerReplaysTheRouteAtTheConfiguredSpeed() async {
        let location = PreviewLocation()
        let player = DemoRoutePlayer(location: location, speedKmh: 45, interval: 1)
        XCTAssertGreaterThan(player.length, 3000)
        player.step()
        XCTAssertNil(location.lastFix) // not updating → no fix (like CoreLocation)
        location.start(rideActive: false)
        player.step()
        let a = location.lastFix
        player.step()
        let b = location.lastFix
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        if let a, let b {
            XCTAssertEqual(a.speedMps ?? 0, 12.5, accuracy: 1e-9)
            let d = DemoRoutePlayer.haversine(a.point, b.point)
            XCTAssertEqual(d, 12.5, accuracy: 0.5)
            XCTAssertGreaterThan(b.timeMs, 0)
            XCTAssertNotNil(b.courseDeg)
        }
        XCTAssertEqual(player.emittedFixes, 2)
        // Loops around a closed route.
        for _ in 0 ..< 400 { player.step() }
        XCTAssertLessThan(player.distance, player.length)
    }

    @MainActor
    func testDemoRoutePlayerDrivesTheRide() async {
        let h = AppTestHarness()
        let player = DemoRoutePlayer(location: h.location, interval: 0.05)
        h.ride.startLocationPreview()
        player.start()
        let moving = await eventually { (h.ride.lastFix?.speedMps ?? 0) > 12 }
        XCTAssertTrue(moving)
        XCTAssertEqual(h.ride.speedText, "45 km/h")
        player.stop()
        XCTAssertFalse(player.isPlaying)
    }
}
