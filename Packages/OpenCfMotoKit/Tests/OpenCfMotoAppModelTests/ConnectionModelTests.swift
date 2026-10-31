// SPDX-License-Identifier: AGPL-3.0-or-later
// ConnectionModel state machine over the preview fakes (docs/spec/app-features.md §7.2–§7.5,
// session-network.md §3, §6): pairing gate, Wi-Fi join (automatic, manual, failures), Stop,
// auto-connect latch, Wi-Fi supervision (grace → waiting for bike → resume), mirror relay.
import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class ConnectionModelTests: XCTestCase {
    // MARK: Pairing gate

    @MainActor
    func testConnectWithoutABikeAsksForPairing() async {
        let h = AppTestHarness()
        h.connection.connect()
        XCTAssertEqual(h.connection.issue, .noBikePaired)
        XCTAssertEqual(h.connection.phase, .idle)
        XCTAssertNil(h.connection.session)
        XCTAssertTrue(h.wifi.joinedSSIDs.isEmpty)
        h.connection.dismissIssue()
        XCTAssertNil(h.connection.issue)
    }

    // MARK: Connect → join → link, Stop

    @MainActor
    func testConnectJoinsTheBikeWifiStartsTheLinkAndStopReleasesEverything() async {
        let h = AppTestHarness()
        let (bike, qr) = h.addBike()
        h.connection.connect()
        XCTAssertEqual(h.connection.phase, .joiningWifi)
        XCTAssertEqual(h.connection.detail, bike.name)
        XCTAssertEqual(h.connection.mode, .dashUI)
        XCTAssertTrue(h.connection.phase.showsStop)
        let linked = await eventually { h.connection.link != nil }
        XCTAssertTrue(linked)
        XCTAssertEqual(h.wifi.joinedSSIDs, [qr.ssid])
        XCTAssertEqual(h.cellular.current, [true])
        // A ride is active: GPS on with background updates.
        XCTAssertTrue(h.location.isUpdating)
        XCTAssertTrue(h.location.isRideActive)
        XCTAssertTrue(h.system.isIdleTimerDisabled) // keepScreenOn (default) while a session runs

        // PreviewNetwork never answers the probe: the dash is not found, the session stays armed.
        let notFound = await eventually { h.connection.phase == .error }
        XCTAssertTrue(notFound)
        XCTAssertEqual(h.connection.detail, SessionText.easyConnOffline(h.language))
        XCTAssertNil(h.connection.issue)
        XCTAssertNotNil(h.connection.session)
        XCTAssertFalse(h.connection.phase.showsStop)

        h.connection.stop()
        XCTAssertEqual(h.connection.phase, .stopped)
        XCTAssertEqual(h.connection.detail, "")
        XCTAssertEqual(h.connection.mode, .none)
        XCTAssertNil(h.connection.link)
        XCTAssertNil(h.connection.session)
        XCTAssertEqual(h.wifi.forgottenSSIDs, [qr.ssid])
        XCTAssertEqual(h.cellular.current.last, false)
        XCTAssertFalse(h.location.isUpdating)
        XCTAssertFalse(h.system.isIdleTimerDisabled)
        XCTAssertEqual(h.projection.stats.mode, "stopped")
        // Late link events of the stopped session never change the phase again.
        await settle(0.6)
        XCTAssertEqual(h.connection.phase, .stopped)
    }

    @MainActor
    func testToggleConnectsThenStops() async {
        let h = AppTestHarness()
        h.addBike()
        h.connection.toggle()
        XCTAssertTrue(h.connection.phase.showsStop)
        h.connection.toggle()
        XCTAssertEqual(h.connection.phase, .stopped)
    }

    @MainActor
    func testAutoRecoveryOffEndsTheSessionWhenTheDashIsNotFound() async {
        let h = AppTestHarness()
        h.addBike()
        h.core.settings.update(forBike: h.core.garage.selected?.id) { $0.autoRecovery = false }
        h.connection.connect()
        let failed = await eventually { h.connection.issue == .dashNotFound }
        XCTAssertTrue(failed)
        XCTAssertEqual(h.connection.phase, .error)
        XCTAssertNil(h.connection.session)
        XCTAssertNil(h.connection.link)
        XCTAssertEqual(h.connection.mode, .none)
        XCTAssertFalse(h.location.isUpdating)
    }

    // MARK: Manual join (free flavor)

    @MainActor
    func testFreeFlavorManualJoinWaitsForTheBikeNetwork() async {
        let h = AppTestHarness(flavor: .free)
        h.wifi.nextJoinResult = .success(.manualJoinRequired)
        let (bike, qr) = h.addBike()
        h.connection.connect()
        let prompted = await eventually { h.connection.manualJoin != nil }
        XCTAssertTrue(prompted)
        XCTAssertEqual(h.connection.manualJoin?.ssid, qr.ssid)
        XCTAssertEqual(h.connection.manualJoin?.password, qr.password)
        XCTAssertEqual(h.connection.manualJoin?.message, SessionText.manualJoinMessage(ssid: qr.ssid, h.language))
        XCTAssertEqual(h.connection.phase, .joiningWifi)
        XCTAssertEqual(h.connection.detail, SessionText.joinInSettings(ssid: qr.ssid, h.language))
        XCTAssertNil(h.connection.link)

        // Another Wi-Fi is not the bike.
        h.wifi.setNetwork(WifiNetworkInfo(isWifiAvailable: true, ssid: "HomeWiFi", interfaceName: "en0",
                                          phoneIPv4: "10.0.0.5", gateway: "10.0.0.1"))
        await settle()
        XCTAssertNotNil(h.connection.manualJoin)
        XCTAssertNil(h.connection.link)

        // The rider joins the bike in Settings.
        h.wifi.setNetwork(AppTestHarness.bikeNetwork(ssid: qr.ssid))
        let linked = await eventually { h.connection.link != nil }
        XCTAssertTrue(linked)
        XCTAssertNil(h.connection.manualJoin)
        XCTAssertEqual(h.cellular.current, [true])
        XCTAssertEqual(h.connection.session?.bike.id, bike.id)
        h.connection.stop()
        XCTAssertTrue(h.wifi.forgottenSSIDs.isEmpty) // nothing of ours to forget in the free flavor
    }

    @MainActor
    func testManualJoinDetectsADashSubnetWhenTheSSIDIsUnknown() async {
        let h = AppTestHarness(flavor: .free)
        h.wifi.nextJoinResult = .success(.manualJoinRequired)
        h.addBike()
        h.connection.connect()
        _ = await eventually { h.connection.manualJoin != nil }
        h.wifi.setNetwork(AppTestHarness.bikeNetwork(ssid: nil))
        let linked = await eventually { h.connection.link != nil }
        XCTAssertTrue(linked)
        h.connection.stop()
    }

    @MainActor
    func testConfirmManualJoinProceedsWithTheCurrentNetwork() async {
        let h = AppTestHarness(flavor: .free)
        h.wifi.nextJoinResult = .success(.manualJoinRequired)
        h.wifi.setNetwork(AppTestHarness.bikeNetwork(ssid: nil)) // already there, nothing will change
        h.addBike()
        h.connection.connect()
        let prompted = await eventually { h.connection.manualJoin != nil }
        XCTAssertTrue(prompted)
        await settle()
        XCTAssertNil(h.connection.link)
        h.connection.confirmManualJoin()
        let linked = await eventually { h.connection.link != nil }
        XCTAssertTrue(linked)
        XCTAssertNil(h.connection.manualJoin)
        h.connection.stop()
    }

    @MainActor
    func testCancelManualJoinStops() async {
        let h = AppTestHarness(flavor: .free)
        h.wifi.nextJoinResult = .success(.manualJoinRequired)
        h.addBike()
        h.connection.connect()
        _ = await eventually { h.connection.manualJoin != nil }
        h.connection.cancelManualJoin()
        XCTAssertNil(h.connection.manualJoin)
        XCTAssertEqual(h.connection.phase, .stopped)
        // A late network change does not resurrect the session.
        h.wifi.setNetwork(AppTestHarness.bikeNetwork(ssid: nil))
        await settle(0.1)
        XCTAssertNil(h.connection.link)
        XCTAssertEqual(h.connection.phase, .stopped)
    }

    // MARK: Join failures

    @MainActor
    func testJoinFailureShowsTheLocalizedMessage() async {
        let h = AppTestHarness()
        let failure = WifiJoinFailure(message: "Another Wi-Fi join is still in progress.", suggestsManualJoin: false)
        h.wifi.nextJoinResult = .failure(failure)
        h.addBike()
        h.connection.connect()
        let failed = await eventually { h.connection.phase == .error }
        XCTAssertTrue(failed)
        XCTAssertEqual(h.connection.detail, failure.message)
        XCTAssertEqual(h.connection.issue, .wifiJoinFailed(message: failure.message))
        XCTAssertNil(h.connection.session)
        XCTAssertNil(h.connection.link)
        XCTAssertFalse(h.location.isUpdating)
    }

    @MainActor
    func testJoinFailureSuggestingManualJoinShowsThePrompt() async {
        let h = AppTestHarness()
        let failure = WifiJoinFailure(message: "The phone did not join the bike.", suggestsManualJoin: true)
        h.wifi.nextJoinResult = .failure(failure)
        let (_, qr) = h.addBike()
        h.connection.connect()
        let prompted = await eventually { h.connection.manualJoin != nil }
        XCTAssertTrue(prompted)
        XCTAssertEqual(h.connection.manualJoin?.message, failure.message)
        XCTAssertEqual(h.connection.phase, .joiningWifi)
        XCTAssertNil(h.connection.issue)
        h.wifi.setNetwork(AppTestHarness.bikeNetwork(ssid: qr.ssid))
        let linked = await eventually { h.connection.link != nil }
        XCTAssertTrue(linked)
        h.connection.stop()
    }

    @MainActor
    func testCancelledJoinPromptIsAnErrorWithoutDialog() async {
        let h = AppTestHarness()
        let failure = WifiJoinFailure(message: "Joining the bike's Wi-Fi was not approved.", suggestsManualJoin: true,
                                      userCancelled: true)
        h.wifi.nextJoinResult = .failure(failure)
        h.addBike()
        h.connection.connect()
        let failed = await eventually { h.connection.phase == .error }
        XCTAssertTrue(failed)
        XCTAssertEqual(h.connection.detail, failure.message)
        XCTAssertNil(h.connection.issue)
        XCTAssertNil(h.connection.manualJoin)
    }

    // MARK: Auto-connect (§7.5.3)

    @MainActor
    func testAutoConnectRunsOncePerProcess() async {
        let h = AppTestHarness()
        h.addBike()
        h.connection.maybeAutoConnect()
        XCTAssertTrue(h.connection.autoConnectLatched)
        XCTAssertNil(h.connection.session) // only after the delay
        let started = await eventually { h.connection.session != nil }
        XCTAssertTrue(started)
        XCTAssertEqual(h.connection.session?.trigger, .auto)
        h.connection.stop()
        h.connection.maybeAutoConnect()
        await settle(0.2)
        XCTAssertNil(h.connection.session)
        XCTAssertEqual(h.connection.phase, .stopped)
    }

    @MainActor
    func testAutoConnectWaitsForABikeAndRespectsTheSetting() async {
        let h = AppTestHarness()
        h.connection.maybeAutoConnect()
        XCTAssertFalse(h.connection.autoConnectLatched) // no bike: not latched, retried on the next foreground
        h.addBike()
        h.core.settings.update(forBike: h.core.garage.selected?.id) { $0.autoConnect = false }
        h.connection.maybeAutoConnect()
        XCTAssertFalse(h.connection.autoConnectLatched)
        h.core.settings.update(forBike: h.core.garage.selected?.id) { $0.autoConnect = true }
        h.connection.maybeAutoConnect()
        XCTAssertTrue(h.connection.autoConnectLatched)
        let started = await eventually { h.connection.session != nil }
        XCTAssertTrue(started)
        h.connection.stop()
    }

    @MainActor
    func testAutoConnectIsPostponedWhenTheAppLeavesTheForeground() async {
        let h = AppTestHarness()
        h.addBike()
        h.connection.tuning.autoConnectDelay = 0.3
        h.connection.maybeAutoConnect()
        h.connection.scenePhaseChanged(.background)
        XCTAssertFalse(h.connection.autoConnectLatched)
        await settle(0.5)
        XCTAssertNil(h.connection.session)
        h.connection.scenePhaseChanged(.active)
        h.connection.maybeAutoConnect()
        let started = await eventually { h.connection.session != nil }
        XCTAssertTrue(started)
        h.connection.stop()
    }

    @MainActor
    func testAutoConnectNeverPromptsForAManualJoin() async {
        let h = AppTestHarness(flavor: .free)
        h.wifi.nextJoinResult = .success(.manualJoinRequired)
        h.addBike()
        h.connection.maybeAutoConnect()
        let ended = await eventually { h.connection.autoConnectLatched && h.connection.session == nil && h.connection.phase == .idle }
        XCTAssertTrue(ended)
        XCTAssertNil(h.connection.manualJoin)
        XCTAssertNil(h.connection.issue)
    }

    @MainActor
    func testUserConnectDuringTheAutoConnectDelayWins() async {
        let h = AppTestHarness()
        h.addBike()
        h.connection.tuning.autoConnectDelay = 0.2
        h.connection.maybeAutoConnect()
        h.connection.connect()
        XCTAssertEqual(h.connection.session?.trigger, .user)
        await settle(0.4)
        XCTAssertEqual(h.connection.session?.trigger, .user)
        XCTAssertEqual(h.wifi.joinedSSIDs.count, 1)
        h.connection.stop()
    }

    // MARK: Ports held by another app

    @MainActor
    func testPortsHeldByTheOfficialAppEndTheSessionWithADialog() async {
        let net = LinkMemoryNetwork(phoneHost: "192.168.0.2")
        net.blockPort(10921)
        let h = AppTestHarness(network: net)
        h.addBike()
        h.connection.connect()
        let failed = await eventually { h.connection.issue == .portsInUse }
        XCTAssertTrue(failed)
        XCTAssertEqual(h.connection.phase, .error)
        XCTAssertEqual(h.connection.detail, SessionText.officialAppInTheWay(h.language))
        XCTAssertNil(h.connection.session)
        let released = await linkEventually { net.openListenerPorts.isEmpty }
        XCTAssertTrue(released)
    }

    @MainActor
    func testConnectingAnotherBikeForgetsThePreviousBikeWifi() async {
        let h = AppTestHarness()
        let (_, qrA) = h.addBike()
        h.connection.connect()
        _ = await eventually { h.connection.link != nil }
        let (_, qrB) = h.addBike(raw: "http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37426&action=9&ssid=DIRECT-CF-CFMOTO-805120&pwd=12345678&auth=wpa2-psk&name=CFMOTO-805120")
        h.connection.connect()
        XCTAssertEqual(h.wifi.forgottenSSIDs, [qrA.ssid])
        XCTAssertEqual(h.connection.session?.qr.ssid, qrB.ssid)
        h.connection.stop()
        XCTAssertEqual(h.wifi.forgottenSSIDs, [qrA.ssid, qrB.ssid])
    }

    @MainActor
    func testAFailedSessionForgetsItsBikeWifiOnStopOrWhenTheAppLeaves() async {
        let net = LinkMemoryNetwork(phoneHost: "192.168.0.2")
        net.blockPort(10921)
        let h = AppTestHarness(network: net)
        let (_, qr) = h.addBike()
        h.connection.connect()
        _ = await eventually { h.connection.issue == .portsInUse }
        XCTAssertTrue(h.wifi.forgottenSSIDs.isEmpty) // kept for a quick retry
        XCTAssertEqual(h.connection.lingeringWifiSSID, qr.ssid)
        h.connection.scenePhaseChanged(.background)
        XCTAssertEqual(h.wifi.forgottenSSIDs, [qr.ssid])
        XCTAssertNil(h.connection.lingeringWifiSSID)

        // Same after Stop.
        h.connection.connect()
        _ = await eventually { h.connection.issue == .portsInUse && h.connection.session == nil }
        XCTAssertEqual(h.connection.lingeringWifiSSID, qr.ssid)
        h.connection.stop()
        XCTAssertEqual(h.wifi.forgottenSSIDs, [qr.ssid, qr.ssid])
    }

    // MARK: Wi-Fi supervision (180 s grace → waiting for bike → resume)

    @MainActor
    func testBikeWifiLossWaitsThenParksThenResumesOnAFreshLink() async {
        let h = AppTestHarness()
        let (_, qr) = h.addBike()
        h.connection.connect()
        _ = await eventually { h.connection.link != nil }
        let firstLink = h.connection.link

        h.wifi.setNetwork(.unavailable)
        let lost = await eventually { h.connection.phase == .reconnecting }
        XCTAssertTrue(lost)
        XCTAssertEqual(h.connection.detail, SessionText.waitingForBikeWifi(h.language))

        let parked = await eventually { h.connection.phase == .waitingForBike }
        XCTAssertTrue(parked)
        XCTAssertEqual(h.connection.detail, SessionText.willResume(h.language))
        XCTAssertTrue(h.connection.isParked)
        XCTAssertNil(h.connection.link)
        XCTAssertEqual(h.projection.stats.mode, "stopped")
        XCTAssertTrue(h.location.isUpdating) // the process keeps watching for the bike
        XCTAssertTrue(h.connection.phase.showsStop)

        h.wifi.setNetwork(AppTestHarness.bikeNetwork(ssid: qr.ssid))
        let resumed = await eventually { h.connection.link != nil }
        XCTAssertTrue(resumed)
        XCTAssertFalse(h.connection.isParked)
        XCTAssertFalse(h.connection.link === firstLink)
        h.connection.stop()
    }

    @MainActor
    func testBikeWifiLossWithAutoRecoveryOffStopsAfterTheGrace() async {
        let h = AppTestHarness()
        h.addBike()
        h.core.settings.update(forBike: h.core.garage.selected?.id) { $0.autoRecovery = false }
        h.connection.connect()
        _ = await eventually { h.connection.link != nil }
        h.wifi.setNetwork(.unavailable)
        let stopped = await eventually { h.connection.phase == .stopped }
        XCTAssertTrue(stopped)
        XCTAssertNil(h.connection.session)
    }

    // MARK: Mirror

    @MainActor
    func testMirrorStartsTheRelayAndTracksTheExtension() async {
        let mirror = TestMirrorHost()
        let h = AppTestHarness(mirror: mirror)
        let (bike, _) = h.addBike()
        h.connection.startMirror()
        XCTAssertTrue(mirror.isRunning)
        XCTAssertEqual(h.connection.mode, .mirror)
        XCTAssertEqual(h.connection.detail, bike.name)
        XCTAssertEqual(mirror.fits.first?.0, h.core.currentSettings.screenFit)
        mirror.setExtensionConnected(true)
        let connected = await eventually { h.connection.isMirrorExtensionConnected }
        XCTAssertTrue(connected)
        let linked = await eventually { h.connection.link != nil }
        XCTAssertTrue(linked)
        XCTAssertTrue(h.location.isRideActive)

        h.connection.stop()
        XCTAssertFalse(mirror.isRunning)
        XCTAssertFalse(h.connection.isMirrorExtensionConnected)
        XCTAssertEqual(h.connection.mode, .none)
    }

    @MainActor
    func testSwitchingFromMirrorToConnectStopsTheRelay() async {
        let mirror = TestMirrorHost()
        let h = AppTestHarness(mirror: mirror)
        h.addBike()
        h.connection.startMirror()
        XCTAssertTrue(mirror.isRunning)
        h.connection.connect()
        XCTAssertFalse(mirror.isRunning)
        XCTAssertEqual(h.connection.mode, .dashUI)
        XCTAssertTrue(h.wifi.forgottenSSIDs.isEmpty) // a mode switch keeps the Wi-Fi
        h.connection.stop()
    }

    @MainActor
    func testMirrorRelayFailureIsReported() async {
        let h = AppTestHarness(mirror: FailingMirrorHost())
        h.addBike()
        h.connection.startMirror()
        XCTAssertEqual(h.connection.phase, .error)
        XCTAssertEqual(h.connection.issue, .other(SessionText.mirrorUnavailable(h.language)))
        XCTAssertNil(h.connection.session)
        XCTAssertEqual(h.connection.mode, .none)
    }

    // MARK: Helpers

    func testBikeNetworkRules() {
        let ssid = "CFMOTO-1"
        XCTAssertTrue(ConnectionModel.isOnBikeNetwork(AppTestHarness.bikeNetwork(ssid: ssid), ssid: ssid))
        XCTAssertTrue(ConnectionModel.isOnBikeNetwork(AppTestHarness.bikeNetwork(ssid: nil), ssid: ssid))
        XCTAssertFalse(ConnectionModel.isOnBikeNetwork(AppTestHarness.bikeNetwork(ssid: "Home"), ssid: ssid))
        XCTAssertFalse(ConnectionModel.isOnBikeNetwork(.unavailable, ssid: ssid))
        XCTAssertFalse(ConnectionModel.isConfirmedBikeNetwork(AppTestHarness.bikeNetwork(ssid: nil), ssid: ssid))
        let home = WifiNetworkInfo(isWifiAvailable: true, phoneIPv4: "10.0.0.5", gateway: "10.0.0.1")
        XCTAssertFalse(ConnectionModel.matchesManualJoin(home, ssid: ssid, baseline: .unavailable))
        let dash = AppTestHarness.bikeNetwork(ssid: nil)
        XCTAssertTrue(ConnectionModel.matchesManualJoin(dash, ssid: ssid, baseline: home))
        XCTAssertFalse(ConnectionModel.matchesManualJoin(dash, ssid: ssid, baseline: dash)) // nothing changed
        let wd = WifiNetworkInfo(isWifiAvailable: true, phoneIPv4: "192.168.49.132", gateway: "192.168.49.1")
        XCTAssertTrue(ConnectionModel.isOnDashSubnet(wd))
    }
}
