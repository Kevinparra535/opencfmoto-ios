// SPDX-License-Identifier: AGPL-3.0-or-later
// AppModel + PermissionsModel: launch (auto-connect after onboarding), scene phases, opened files,
// banner, onboarding steps and persistence, permissions, problem-report diagnostics, EN/ES texts.
import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class AppModelTests: XCTestCase {
    // MARK: Launch / foreground

    @MainActor
    func testStartAutoConnectsOnceOnboardingIsDone() async {
        let h = AppTestHarness { services in
            services.keyValueStore.set(true, forKey: PermissionsModel.onboardingDoneKey)
        }
        h.addBike()
        XCTAssertTrue(h.model.permissions.hasCompletedOnboarding)
        h.model.start()
        h.model.start() // idempotent
        let started = await eventually { h.connection.session != nil }
        XCTAssertTrue(started)
        XCTAssertEqual(h.connection.session?.trigger, .auto)
        h.connection.stop()
    }

    @MainActor
    func testStartDoesNotAutoConnectBeforeOnboarding() async {
        let h = AppTestHarness()
        h.addBike()
        h.model.start()
        await settle(0.2)
        XCTAssertNil(h.connection.session)
        XCTAssertFalse(h.connection.autoConnectLatched)
        // Finishing onboarding retries auto-connect (Android: back from Setup → onResume).
        h.model.permissions.completeOnboarding()
        let started = await eventually { h.connection.session != nil }
        XCTAssertTrue(started)
        h.connection.stop()
    }

    @MainActor
    func testForegroundRetriesAutoConnectAndForwardsScenePhases() async {
        let h = AppTestHarness { services in
            services.keyValueStore.set(true, forKey: PermissionsModel.onboardingDoneKey)
        }
        h.model.start() // no bike yet → not latched
        await settle(0.1)
        XCTAssertNil(h.connection.session)
        h.addBike()
        h.model.scenePhaseChanged(.background)
        XCTAssertEqual(h.projection.stats.mode, "hold")
        h.model.scenePhaseChanged(.active)
        XCTAssertEqual(h.projection.stats.mode, "foreground")
        let started = await eventually { h.connection.session != nil }
        XCTAssertTrue(started)
        h.connection.stop()
    }

    // MARK: Lifetime

    /// No retain cycle keeps the model graph (and its timers / link tasks) alive.
    @MainActor
    func testTheModelGraphIsReleasedAfterUse() async {
        weak var weakModel: AppModel?
        weak var weakRide: RideModel?
        weak var weakConnection: ConnectionModel?
        weak var weakControls: ControlsModel?
        do {
            let h = AppTestHarness()
            h.addBike()
            h.ride.startLocationPreview()
            h.ride.enterRideMode()
            h.controls.setRemoteEnabled(true)
            h.connection.connect()
            _ = await eventually { h.connection.link != nil }
            h.location.emit(LocationFix(lat: 4.65, lon: -74.09, speedMps: 5, timeMs: 1_790_000_000_000))
            await settle(0.1)
            h.connection.stop()
            weakModel = h.model
            weakRide = h.ride
            weakConnection = h.connection
            weakControls = h.controls
        }
        let released = await eventually(timeout: 3) {
            weakModel == nil && weakRide == nil && weakConnection == nil && weakControls == nil
        }
        XCTAssertTrue(released, "model=\(weakModel != nil) ride=\(weakRide != nil) connection=\(weakConnection != nil) controls=\(weakControls != nil)")
    }

    // MARK: Opened files

    private func tempFile(_ name: String, _ text: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ocm-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    @MainActor
    func testOpeningAnUnsupportedFileShowsABannerThatClears() async throws {
        let h = AppTestHarness()
        let url = try tempFile("notes.bin", "hello")
        let message = h.model.handleOpenURL(url)
        XCTAssertEqual(message, SessionText.cannotOpenFile(h.language))
        XCTAssertEqual(h.model.banner, message)
        let cleared = await eventually { h.model.banner == nil }
        XCTAssertTrue(cleared)
    }

    @MainActor
    func testOpeningAMissingFileReportsIt() async {
        let h = AppTestHarness()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).gpx")
        XCTAssertEqual(h.model.handleOpenURL(url), SessionText.cannotReadFile(h.language))
    }

    @MainActor
    func testOpeningAGPXHandsItToNavigation() async throws {
        let h = AppTestHarness()
        let gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="test"><trk><name>Loop</name><trkseg>
        <trkpt lat="4.6584" lon="-74.0930"></trkpt><trkpt lat="4.6600" lon="-74.0900"></trkpt>
        </trkseg></trk></gpx>
        """
        let url = try tempFile("Loop.gpx", gpx)
        let message = h.model.handleOpenURL(url)
        XCTAssertEqual(message, h.model.navigation.lastError ?? SessionText.gpxLoaded("Loop", h.language))
    }

    @MainActor
    func testBannerCanBeDismissed() async {
        let h = AppTestHarness()
        h.model.showBanner("Hi")
        XCTAssertEqual(h.model.banner, "Hi")
        h.model.dismissBanner()
        XCTAssertNil(h.model.banner)
    }

    // MARK: Onboarding & permissions

    @MainActor
    func testOnboardingStepsArePersisted() async {
        let h = AppTestHarness()
        let p = h.model.permissions
        XCTAssertFalse(p.hasCompletedOnboarding)
        XCTAssertEqual(p.step, .welcome)
        p.advance()
        XCTAssertEqual(p.step, .location)
        p.advance()
        XCTAssertEqual(p.step, .localNetwork)
        p.advance()
        XCTAssertEqual(p.step, .pairBike)
        p.advance()
        XCTAssertEqual(p.step, .done)
        XCTAssertTrue(p.hasCompletedOnboarding)
        XCTAssertEqual(h.core.services.keyValueStore.bool(forKey: PermissionsModel.onboardingDoneKey), true)
        p.resetOnboarding()
        XCTAssertFalse(p.hasCompletedOnboarding)
        XCTAssertEqual(p.step, .welcome)
        XCTAssertEqual(h.core.services.keyValueStore.bool(forKey: PermissionsModel.onboardingDoneKey), false)
    }

    @MainActor
    func testLocationPermissionRequestAndRefresh() async {
        let h = AppTestHarness()
        let p = h.model.permissions
        XCTAssertEqual(p.location, .whenInUse)
        h.location.permission = .notDetermined
        await p.refresh()
        XCTAssertEqual(p.location, .notDetermined)
        h.ride.startLocationPreview() // asks for the permission, then starts GPS once granted
        XCTAssertEqual(p.location, .whenInUse)
        XCTAssertTrue(h.location.isUpdating)
        p.openAppSettings()
        XCTAssertEqual(h.system.openedSettingsCount, 1)
    }

    @MainActor
    func testLocalNetworkPermission() async {
        let h = AppTestHarness()
        let p = h.model.permissions
        XCTAssertEqual(p.localNetwork, .undetermined)
        h.system.localNetwork = .denied
        await p.requestLocalNetwork()
        XCTAssertEqual(p.localNetwork, .denied)
        h.system.localNetwork = .unavailable // nothing to test against: keep the decisive answer
        await p.refresh()
        XCTAssertEqual(p.localNetwork, .denied)
        h.system.localNetwork = .granted
        await p.refresh()
        XCTAssertEqual(p.localNetwork, .granted)
    }

    // MARK: Problem report diagnostics

    @MainActor
    func testProblemReportDiagnosticsDescribeTheSession() async {
        let h = AppTestHarness()
        let (bike, _) = h.addBike()
        let d = h.model.logs.diagnostics()
        XCTAssertEqual(d["phase"], "IDLE")
        XCTAssertEqual(d["ssid"], bike.ssid)
        XCTAssertEqual(d["appVersion"], h.system.appVersion)
        XCTAssertEqual(d["profileOverride"], "auto")
        XCTAssertEqual(d["forceTouch"], "false")
        XCTAssertNotNil(d["marginsSummary"])
    }

    // MARK: EN / ES texts

    func testSessionTextsAreTranslated() {
        XCTAssertEqual(SessionText.attempt(3, .en), "attempt 3")
        XCTAssertEqual(SessionText.attempt(3, .es), "intento 3")
        XCTAssertEqual(SessionText.officialAppInTheWay(.en), "close the official CFMoto app, then reconnect")
        XCTAssertEqual(SessionText.lostLink(.en), "lost bike link")
        XCTAssertEqual(SessionText.waitingForBikeWifi(.en), "waiting for bike Wi-Fi")
        XCTAssertEqual(SessionText.willResume(.en), "will resume when the bike is back")
        XCTAssertEqual(SessionText.alreadyMirroring(.en), "Already mirroring \u{2014} wait for the dash, or tap Stop first")
        XCTAssertEqual(SessionText.phaseLogLabel(.streaming), "Connected \u{2014} projecting to dash")
        XCTAssertEqual(SessionText.phaseAndroidName(.linking), "PXC_CONNECTING")
        // Every user-visible text has a Spanish version different from the English one.
        let pairs: [(String, String)] = [
            (SessionText.waitingForBikeWifi(.en), SessionText.waitingForBikeWifi(.es)),
            (SessionText.willResume(.en), SessionText.willResume(.es)),
            (SessionText.reconnecting(.en), SessionText.reconnecting(.es)),
            (SessionText.officialAppInTheWay(.en), SessionText.officialAppInTheWay(.es)),
            (SessionText.easyConnOffline(.en), SessionText.easyConnOffline(.es)),
            (SessionText.lostLink(.en), SessionText.lostLink(.es)),
            (SessionText.connectFailed(.en), SessionText.connectFailed(.es)),
            (SessionText.autoConnectFailed(.en), SessionText.autoConnectFailed(.es)),
            (SessionText.localNetworkDenied(.en), SessionText.localNetworkDenied(.es)),
            (SessionText.noWifiAddress(.en), SessionText.noWifiAddress(.es)),
            (SessionText.joinInSettings(ssid: "X", .en), SessionText.joinInSettings(ssid: "X", .es)),
            (SessionText.manualJoinMessage(ssid: "X", .en), SessionText.manualJoinMessage(ssid: "X", .es)),
            (SessionText.alreadyMirroring(.en), SessionText.alreadyMirroring(.es)),
            (SessionText.mirrorUnavailable(.en), SessionText.mirrorUnavailable(.es)),
            (SessionText.holdMessage(.en), SessionText.holdMessage(.es)),
            (SessionText.reconnectingBanner(.en), SessionText.reconnectingBanner(.es)),
            (SessionText.waitingForWifiBanner(.en), SessionText.waitingForWifiBanner(.es)),
            (SessionText.recordingRide(.en), SessionText.recordingRide(.es)),
            (SessionText.recordingSavedToast(.en), SessionText.recordingSavedToast(.es)),
            (SessionText.cannotRecord(.en), SessionText.cannotRecord(.es)),
            (SessionText.recordingStartedVoice(.en), SessionText.recordingStartedVoice(.es)),
            (SessionText.recordingSavedVoice(.en), SessionText.recordingSavedVoice(.es)),
            (SessionText.placeDeleted(.en), SessionText.placeDeleted(.es)),
            (SessionText.locationPermissionNeeded(.en), SessionText.locationPermissionNeeded(.es)),
            (SessionText.gpsOff(.en), SessionText.gpsOff(.es)),
            (SessionText.waitingForGps(.en), SessionText.waitingForGps(.es)),
            (SessionText.gpsFix(accuracyM: 4, .en), SessionText.gpsFix(accuracyM: 4, .es)),
            (SessionText.approximateLocation(.en), SessionText.approximateLocation(.es)),
            (SessionText.gpxLoaded("a", .en), SessionText.gpxLoaded("a", .es)),
            (SessionText.bikeAdded("a", .en), SessionText.bikeAdded("a", .es)),
            (SessionText.cannotOpenFile(.en), SessionText.cannotOpenFile(.es)),
            (SessionText.cannotReadFile(.en), SessionText.cannotReadFile(.es)),
        ]
        for (en, es) in pairs { XCTAssertNotEqual(en, es) }
        for a in ButtonAction.allCases where a != .none {
            XCTAssertNotEqual(SessionText.actionLabel(a, .en), SessionText.actionLabel(a, .es), a.rawValue)
        }
        for g in [ButtonGesture.navBackLong, .navFwdLong, .selectLong, .navBackDouble, .navFwdDouble, .selectDouble] {
            XCTAssertNotEqual(SessionText.gestureLabel(g, .en), SessionText.gestureLabel(g, .es))
        }
    }
}
