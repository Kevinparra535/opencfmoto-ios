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
        let (_, qr) = h.addBike()
        h.wifi.setNetwork(AppTestHarness.bikeNetwork(ssid: qr.ssid)) // iOS already joined the bike
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
        let (_, qr) = h.addBike()
        h.wifi.setNetwork(AppTestHarness.bikeNetwork(ssid: qr.ssid))
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
        let (_, qr) = h.addBike()
        h.wifi.setNetwork(AppTestHarness.bikeNetwork(ssid: qr.ssid))
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

    /// UI/UX P0 (UX-17) changed this on purpose: an opened GPX used to replace the navigation at once
    /// with a "Loaded GPX" banner; it is now a preview waiting for «Seguir este track» (GpxPreviewTests).
    @MainActor
    func testOpeningAGPXHandsItToNavigationAsAPreview() async throws {
        let h = AppTestHarness()
        let gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="test"><trk><name>Loop</name><trkseg>
        <trkpt lat="4.6584" lon="-74.0930"></trkpt><trkpt lat="4.6600" lon="-74.0900"></trkpt>
        </trkseg></trk></gpx>
        """
        let url = try tempFile("Loop.gpx", gpx)
        let message = h.model.handleOpenURL(url)
        XCTAssertNil(message)
        XCTAssertNil(h.model.navigation.lastError)
        XCTAssertEqual(h.model.navigation.pendingGpx?.name, "Loop")
        XCTAssertEqual(h.core.navigation.snapshot.mode, .freeRide, "nothing replaced before the rider follows it")
    }

    // MARK: Opened packs wait for confirmation (SPEC:CL-11), Inbox copies are deleted (IOS:IOS-6)

    static let settingsPack = #"{"format":"opencfmoto.settings","version":1,"settings":{"powerMode":"SAVER"}}"#

    @MainActor
    func testOpeningASettingsPackWaitsForTheRidersConfirmation() async throws {
        let h = AppTestHarness()
        h.addBike()
        let before = h.core.currentSettings.powerMode
        XCTAssertNotEqual(before, .saver)
        let url = try tempFile("nk_adv-settings.json", Self.settingsPack)
        XCTAssertNil(h.model.handleOpenURL(url)) // no banner: the UI shows the confirmation instead
        XCTAssertNil(h.model.banner)
        XCTAssertEqual(h.model.pendingImport, PendingImport(kind: .settings, fileName: "nk_adv-settings.json", text: Self.settingsPack))
        XCTAssertEqual(h.core.currentSettings.powerMode, before) // nothing applied yet

        h.model.cancelPendingImport()
        XCTAssertNil(h.model.pendingImport)
        XCTAssertEqual(h.core.currentSettings.powerMode, before)

        _ = h.model.handleOpenURL(url)
        h.model.confirmPendingImport()
        XCTAssertNil(h.model.pendingImport)
        XCTAssertEqual(h.core.currentSettings.powerMode, .saver)
        XCTAssertNotNil(h.model.banner) // the import result
    }

    @MainActor
    func testOpeningMapDataWaitsForTheRidersConfirmation() async throws {
        let h = AppTestHarness()
        h.core.places.setHome(Place(name: "Casa", lat: 4.65, lon: -74.05))
        let exported = try h.model.settings.exportMapData()
        let text = try String(contentsOf: exported.url, encoding: .utf8)
        h.core.places.clearHome()
        let url = try tempFile("map.json", text)
        XCTAssertNil(h.model.handleOpenURL(url))
        XCTAssertEqual(h.model.pendingImport?.kind, .mapData)
        XCTAssertNil(h.core.places.home())
        h.model.confirmPendingImport()
        XCTAssertEqual(h.core.places.home()?.name, "Casa")
    }

    @MainActor
    func testOpenedInboxCopiesAreDeletedOnceRead() async throws {
        let h = AppTestHarness()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ocm-inbox-\(UUID().uuidString)")
        let inbox = root.appendingPathComponent("Documents/Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        h.model.inboxDirectory = inbox
        let gpx = #"<?xml version="1.0"?><gpx version="1.1"><trk><trkseg><trkpt lat="4.65" lon="-74.09"/><trkpt lat="4.66" lon="-74.08"/></trkseg></trk></gpx>"#
        let copy = inbox.appendingPathComponent("Route.gpx")
        try Data(gpx.utf8).write(to: copy)
        _ = h.model.handleOpenURL(copy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        let pack = inbox.appendingPathComponent("pack.json")
        try Data(Self.settingsPack.utf8).write(to: pack)
        _ = h.model.handleOpenURL(pack)
        XCTAssertEqual(h.model.pendingImport?.kind, .settings) // the text is kept in memory
        XCTAssertFalse(FileManager.default.fileExists(atPath: pack.path))
        // Files opened in place (outside the Inbox) are never touched.
        let outside = try tempFile("Elsewhere.gpx", gpx)
        _ = h.model.handleOpenURL(outside)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        // Leftovers are purged when the app leaves the foreground.
        let leftover = inbox.appendingPathComponent("old.gpx")
        try Data(gpx.utf8).write(to: leftover)
        h.model.scenePhaseChanged(.background)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertTrue(AppModel.isInboxCopy(URL(fileURLWithPath: "/private/var/x/Documents/Inbox/a.gpx"),
                                           inbox: URL(fileURLWithPath: "/var/x/Documents/Inbox/")))
        XCTAssertFalse(AppModel.isInboxCopy(URL(fileURLWithPath: "/var/x/Documents/a.gpx"),
                                            inbox: URL(fileURLWithPath: "/var/x/Documents/Inbox")))
        XCTAssertFalse(AppModel.isInboxCopy(copy, inbox: nil))
    }

    // MARK: Stale share exports (SEC:SEC-6)

    @MainActor
    func testShareExportsArePurgedAtLaunchAndWhenTheAppLeaves() async throws {
        let h = AppTestHarness()
        let exports = h.core.services.files.exportsDirectory
        let fm = FileManager.default
        func write(_ name: String, age: TimeInterval) throws -> URL {
            let url = exports.appendingPathComponent(name)
            try Data("secret".utf8).write(to: url)
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
            return url
        }
        let fresh = try write("opencfmoto-log-new.txt", age: 0)
        let old = try write("opencfmoto-log-old.txt", age: 3_600)
        h.model.start() // a previous run's exports: all gone
        XCTAssertFalse(fm.fileExists(atPath: fresh.path))
        XCTAssertFalse(fm.fileExists(atPath: old.path))

        let recent = try write("opencfmoto_trip_1.gpx", age: 10)
        let stale = try write("opencfmoto_trip_2.gpx", age: LogicData.backgroundExportAge + 5)
        h.model.scenePhaseChanged(.background)
        XCTAssertTrue(fm.fileExists(atPath: recent.path)) // may still be on its way through a share sheet
        XCTAssertFalse(fm.fileExists(atPath: stale.path))
    }

    func testWritingAnExportDeletesStaleOnes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ocm-exports-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stale = dir.appendingPathComponent("opencfmoto-log-stale.txt")
        let recent = dir.appendingPathComponent("opencfmoto-log-recent.txt")
        for url in [stale, recent] { try Data("x".utf8).write(to: url) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-LogicData.staleExportAge - 1)],
                                              ofItemAtPath: stale.path)
        let file = try LogicData.writeExport("new", fileName: "new.txt", typeIdentifier: "public.plain-text", in: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertEqual(try String(contentsOf: file.url, encoding: .utf8), "new")
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
        // The last page shows; onboarding completes only with its "Start riding" (review UI-3).
        XCTAssertEqual(p.step, .done)
        XCTAssertFalse(p.hasCompletedOnboarding)
        XCTAssertNil(h.core.services.keyValueStore.bool(forKey: PermissionsModel.onboardingDoneKey))
        p.completeOnboarding()
        XCTAssertTrue(p.hasCompletedOnboarding)
        XCTAssertEqual(p.step, .done)
        XCTAssertEqual(h.core.services.keyValueStore.bool(forKey: PermissionsModel.onboardingDoneKey), true)
        p.resetOnboarding()
        XCTAssertFalse(p.hasCompletedOnboarding)
        XCTAssertEqual(p.step, .welcome)
        XCTAssertEqual(h.core.services.keyValueStore.bool(forKey: PermissionsModel.onboardingDoneKey), false)
    }

    @MainActor
    func testReachingTheLastOnboardingPageDoesNotStartAutoConnect() async {
        let h = AppTestHarness()
        let (_, qr) = h.addBike()
        h.wifi.setNetwork(AppTestHarness.bikeNetwork(ssid: qr.ssid))
        h.model.start()
        let p = h.model.permissions
        for _ in 0 ..< 4 { p.advance() }
        XCTAssertEqual(p.step, .done)
        await settle(0.2)
        XCTAssertNil(h.connection.session) // the rider has not confirmed yet
        XCTAssertFalse(h.connection.autoConnectLatched)
        p.advance() // at .done: same as "Start riding"
        XCTAssertTrue(p.hasCompletedOnboarding)
        let started = await eventually { h.connection.session != nil }
        XCTAssertTrue(started)
        h.connection.stop()
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
        XCTAssertEqual(d["detail"], "")
        XCTAssertEqual(d["ssid"], bike.ssid)
        XCTAssertEqual(d["bike"], bike.name)
        XCTAssertEqual(d["mode"], "none")
        XCTAssertEqual(d["localNetwork"], "undetermined")
        XCTAssertNil(d["profile"]) // not identified yet: LogsModel falls back to the override / hint
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
            (SessionText.mirrorNeedsLocation(.en), SessionText.mirrorNeedsLocation(.es)),
            (SessionText.phoneHotspotUnsupported(.en), SessionText.phoneHotspotUnsupported(.es)),
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
