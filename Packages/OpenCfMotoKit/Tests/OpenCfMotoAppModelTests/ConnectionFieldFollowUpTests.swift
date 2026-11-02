// SPDX-License-Identifier: AGPL-3.0-or-later
// Follow-ups to the first field test on the session model (review of the local-only Wi-Fi fix):
// - POSIX-2: a connect() dropped by the system shows the Local Network dialog only when the evidence
//   says privacy (the Local Network check is refused); proof that access works means a VPN / data rule /
//   filter; no answer gives a neutral hint.
// - SESS-1: "I've joined" while iOS still names another Wi-Fi keeps waiting (no link on that LAN).
// - LOG-2: the "no internet, using the interface directly" note only for a network the app uses.
// - Auto-connect vs the Connect tap: a tap right after auto-connect started the session keeps it.
import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class ConnectionFieldFollowUpTests: XCTestCase {
    private func messages(since before: UInt64) -> [String] {
        Log.shared.lines().filter { $0.id > before }.map(\.message)
    }

    private func lastLogID() -> UInt64 { Log.shared.lines().last?.id ?? 0 }

    /// Every issue value seen while waiting (every 5 ms) for `condition`.
    @MainActor
    private func issuesSeen(_ h: AppTestHarness, timeout: TimeInterval = 5, until condition: () -> Bool) async -> (ok: Bool, seen: [ConnectionIssue]) {
        var seen: [ConnectionIssue] = []
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let i = h.connection.issue, seen.last != i { seen.append(i) }
            if condition() { return (true, seen) }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return (condition(), seen)
    }

    private struct ListingBonjour: DashDiscovery {
        func discover(timeout: TimeInterval) async -> [DiscoveredDash] {
            [DiscoveredDash(host: "192.168.0.1", port: 10930)]
        }
    }

    // MARK: POSIX-2 — the Local Network dialog only on evidence of privacy

    /// The Local Network check says granted: the first drop may have come while the system alert was
    /// still open, so the link is retried at once; dropped again, it is a system policy. The Local
    /// Network dialog never shows.
    @MainActor
    func testADropWithLocalNetworkGrantedRetriesOnceThenBlamesASystemPolicy() async {
        let net = LocalNetworkDeniedNetwork()
        let h = AppTestHarness(network: net)
        h.system.localNetwork = .granted
        h.addBike()
        let before = lastLogID()
        h.connection.connect()
        let policy = ConnectionIssue.other(SessionText.systemBlocksBikeLinkMessage(h.language))
        let (raised, seen) = await issuesSeen(h) { h.connection.issue == policy }
        XCTAssertTrue(raised, "\(String(describing: h.connection.issue))")
        XCTAssertFalse(seen.contains(.localNetworkDenied), "\(seen)")
        XCTAssertEqual(h.connection.blockCause, .systemPolicy)
        XCTAssertTrue(h.connection.retriedAfterGrantedCheck)
        XCTAssertEqual(h.connection.phase, .error)
        XCTAssertEqual(h.connection.detail, SessionText.systemBlocksBikeLink(h.language))
        XCTAssertTrue(h.connection.isSessionActive)
        let lines = messages(since: before)
        XCTAssertEqual(lines.filter { $0 == "Local Network access is on \u{2014} retrying the dash at once" }.count, 1, "\(lines)")
        XCTAssertTrue(lines.contains("[LAN] Local Network check after the dropped connect: granted"), "\(lines)")
        // Once per episode: the re-arms fail the same way, a dismissed dialog stays away.
        h.connection.dismissIssue()
        let attempts = net.connectAttempts
        let rearmed = await eventually { net.connectAttempts >= attempts + 3 }
        XCTAssertTrue(rearmed)
        await settle(0.2)
        XCTAssertNil(h.connection.issue)
        XCTAssertEqual(h.connection.detail, SessionText.systemBlocksBikeLink(h.language))
        h.connection.stop()
    }

    /// The check cannot tell (no answer): a neutral hint naming both causes, not the Local Network dialog.
    @MainActor
    func testADropWithAnUnclearLocalNetworkCheckGivesANeutralHint() async {
        let h = AppTestHarness(network: LocalNetworkDeniedNetwork())
        h.system.localNetwork = .undetermined
        h.addBike()
        h.connection.connect()
        let unclear = ConnectionIssue.other(SessionText.bikeLinkBlockedMessage(h.language))
        let (raised, seen) = await issuesSeen(h) { h.connection.issue == unclear }
        XCTAssertTrue(raised, "\(String(describing: h.connection.issue))")
        XCTAssertFalse(seen.contains(.localNetworkDenied), "\(seen)")
        XCTAssertEqual(h.connection.blockCause, .unclear)
        XCTAssertEqual(h.connection.detail, SessionText.bikeLinkBlocked(h.language))
        XCTAssertFalse(h.connection.retriedAfterGrantedCheck)
        h.connection.stop()
    }

    /// The link's own Bonjour browse listed the dash while every connect was dropped: a system policy at
    /// once, without asking the Local Network check (which would say "denied" here).
    @MainActor
    func testADropWhileTheLinksBonjourListedTheDashIsASystemPolicyWithoutACheck() async {
        let h = AppTestHarness(network: LocalNetworkDeniedNetwork()) { $0.discovery = ListingBonjour() }
        h.system.localNetwork = .denied
        h.addBike()
        let before = lastLogID()
        h.connection.connect()
        let policy = ConnectionIssue.other(SessionText.systemBlocksBikeLinkMessage(h.language))
        let (raised, seen) = await issuesSeen(h) { h.connection.issue == policy }
        XCTAssertTrue(raised, "\(String(describing: h.connection.issue))")
        XCTAssertFalse(seen.contains(.localNetworkDenied), "\(seen)")
        XCTAssertEqual(h.connection.linkState, .failed(.localNetworkBlocked))
        let lines = messages(since: before)
        XCTAssertFalse(lines.contains { $0.hasPrefix("[LAN] Local Network check after the dropped connect") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("the system blocks the dash connection although Local Network access works") }, "\(lines)")
        h.connection.stop()
    }

    /// Auto-recovery off: the session ends once the cause is known, with that cause's dialog.
    @MainActor
    func testWithoutAutoRecoveryTheSessionEndsWithTheDialogOfTheCause() async {
        let h = AppTestHarness(network: LocalNetworkDeniedNetwork())
        h.system.localNetwork = .denied
        h.addBike()
        h.core.settings.update(forBike: h.core.garage.selected?.id) { $0.autoRecovery = false }
        h.connection.connect()
        let ended = await eventually { !h.connection.isSessionActive && h.connection.issue == .localNetworkDenied }
        XCTAssertTrue(ended, "\(h.connection.phase) \(String(describing: h.connection.issue))")
        XCTAssertEqual(h.connection.phase, .error)
        XCTAssertEqual(h.connection.detail, SessionText.localNetworkDenied(h.language))
    }

    /// The dialog of a block goes away once the dash streams (a new episode).
    @MainActor
    func testTheBlockDialogIsClearedWhenTheDashStreams() async throws {
        let net = LinkMemoryNetwork(phoneHost: "192.168.0.2")
        let dash = LinkFakeDash(network: net, host: "192.168.0.1")
        dash.installProbeServer()
        let dropping = DroppingNetwork(inner: net)
        let h = AppTestHarness(network: dropping, frameSource: TestFrameSource())
        h.system.localNetwork = .undetermined
        h.addBike()
        h.connection.connect()
        let unclear = ConnectionIssue.other(SessionText.bikeLinkBlockedMessage(h.language))
        let raised = await eventually { h.connection.issue == unclear }
        XCTAssertTrue(raised)
        dropping.drop.set(false) // e.g. the rider turned the VPN off: the next re-arm reaches the dash
        let probed = await eventually { dash.acceptedCount.current >= 1 }
        XCTAssertTrue(probed)
        let ctrl = try dash.openControl()
        try await ctrl.send(PxcFrame(cmd: 0x10000))
        _ = try await ctrl.nextRaw()
        try await ctrl.send(cmd: 0x10010, json: LinkDashSamples.cfdl16ClientInfo)
        _ = try await ctrl.next()
        let mctl = try dash.openMedia(port: 10921)
        try await mctl.send(cmd: 16, body: LinkDashSamples.configCaptureBody(width: 800, height: 386))
        _ = try await mctl.reply()
        try await mctl.send(cmd: 112)
        _ = try await mctl.reply()
        let mdata = try dash.openMedia(port: 10920)
        for _ in 1 ... 3 {
            try await mdata.send(cmd: 114)
            _ = try await mdata.frame()
        }
        let streaming = await eventually { h.connection.phase == .streaming }
        XCTAssertTrue(streaming)
        XCTAssertNil(h.connection.issue)
        XCTAssertNil(h.connection.blockCause)
        h.connection.stop()
        ctrl.close()
        mctl.close()
        mdata.close()
    }

    func testBlockTextsExistInBothLanguagesAndDiffer() {
        let pairs: [(String, String)] = [
            (SessionText.systemBlocksBikeLink(.en), SessionText.systemBlocksBikeLink(.es)),
            (SessionText.systemBlocksBikeLinkMessage(.en), SessionText.systemBlocksBikeLinkMessage(.es)),
            (SessionText.bikeLinkBlocked(.en), SessionText.bikeLinkBlocked(.es)),
            (SessionText.bikeLinkBlockedMessage(.en), SessionText.bikeLinkBlockedMessage(.es)),
            (SessionText.manualJoinStillOnOtherWifi(other: "HomeWiFi", ssid: "CFMOTO-1", .en),
             SessionText.manualJoinStillOnOtherWifi(other: "HomeWiFi", ssid: "CFMOTO-1", .es)),
        ]
        for (en, es) in pairs {
            XCTAssertFalse(en.isEmpty)
            XCTAssertFalse(es.isEmpty)
            XCTAssertNotEqual(en, es)
        }
        XCTAssertEqual(ConnectionModel.blockDetail(.privacy, .en), SessionText.localNetworkDenied(.en))
        XCTAssertEqual(ConnectionModel.blockDetail(.systemPolicy, .es), SessionText.systemBlocksBikeLink(.es))
        XCTAssertEqual(ConnectionModel.blockDetail(.unclear, .en), SessionText.bikeLinkBlocked(.en))
        XCTAssertTrue(SessionText.manualJoinStillOnOtherWifi(other: "HomeWiFi", ssid: "CFMOTO-1", .es).contains("«HomeWiFi»"))
    }

    // MARK: SESS-1 — "I've joined" on a Wi-Fi whose known SSID is not the bike's

    @MainActor
    func testIveJoinedWhileIOSStillNamesTheHomeWifiKeepsWaiting() async {
        let h = AppTestHarness()
        let (_, qr) = h.addBike()
        h.wifi.setNetwork(FieldWifi.home)
        h.wifi.nextJoinResult = .failure(WifiJoinFailure(message: "The phone did not join the bike.", suggestsManualJoin: true))
        let before = lastLogID()
        h.connection.connect()
        let prompted = await eventually { h.connection.manualJoin != nil }
        XCTAssertTrue(prompted)
        h.connection.confirmManualJoin()
        let still = SessionText.manualJoinStillOnOtherWifi(other: "HomeWiFi", ssid: qr.ssid, h.language)
        let answered = await eventually { h.connection.manualJoin?.message == still }
        XCTAssertTrue(answered, "\(String(describing: h.connection.manualJoin))")
        await settle(0.2)
        XCTAssertNil(h.connection.link, "no link (probes, port scan) on the home LAN")
        XCTAssertEqual(h.connection.phase, .joiningWifi)
        var lines = messages(since: before)
        XCTAssertTrue(lines.contains("[wifi] rider confirmed the manual join, but iOS reports HomeWiFi \u{2014} still waiting for \(qr.ssid)"), "\(lines)")
        XCTAssertFalse(lines.contains { $0.hasPrefix("Wi-Fi joined: \(qr.ssid) (manual") }, "\(lines)")
        // The phone reaches the bike Wi-Fi: the session goes on by itself.
        h.wifi.setNetwork(FieldWifi.bike(ssid: qr.ssid))
        let linked = await eventually { h.connection.link != nil }
        XCTAssertTrue(linked)
        XCTAssertNil(h.connection.manualJoin)
        lines = messages(since: before)
        XCTAssertTrue(lines.contains { $0.hasPrefix("Wi-Fi joined: \(qr.ssid) (manual, wifi=up(local-only") }, "\(lines)")
        h.connection.stop()
    }

    func testOnlyAKnownOtherSSIDCountsAsAnotherWifi() {
        let ssid = "CFMOTO-f46457"
        XCTAssertEqual(ConnectionModel.otherKnownSSID(FieldWifi.home, than: ssid), "HomeWiFi")
        XCTAssertNil(ConnectionModel.otherKnownSSID(FieldWifi.bike(ssid: ssid), than: ssid))
        XCTAssertNil(ConnectionModel.otherKnownSSID(FieldWifi.bike(ssid: nil), than: ssid), "SSID unreadable: the rider's word")
        XCTAssertNil(ConnectionModel.otherKnownSSID(FieldWifi.down, than: ssid))
    }

    // MARK: LOG-2 — the "no internet" note only for a network the app uses

    @MainActor
    func testNoNoInternetNoteForAnotherAccessPointAtLaunch() async {
        let h = AppTestHarness()
        let (bike, _) = h.addBike()
        h.wifi.setNetwork(Self.goPro)
        let before = lastLogID()
        h.connection.maybeAutoConnect()
        let idle = await eventually { self.messages(since: before).contains { $0.hasPrefix("\u{2192} Auto-connect idle: '\(bike.name)'") } }
        XCTAssertTrue(idle)
        XCTAssertFalse(messages(since: before).contains { $0.hasPrefix(ConnectionLocalOnlyWifiTests.noInternetNote) })
    }

    @MainActor
    func testNoNoInternetNoteForAnotherAccessPointDuringASession() async {
        let wifi = ScriptedWifi(network: FieldWifi.down)
        let h = AppTestHarness { $0.wifi = wifi }
        let (_, qr) = h.addBike()
        h.connection.tuning.wifiParkGrace = 30
        wifi.networkAfterJoin = FieldWifi.bike(ssid: qr.ssid)
        let before = lastLogID()
        h.connection.connect()
        _ = await eventually { h.connection.link != nil }
        wifi.setNetwork(Self.goPro)
        let lost = await eventually { h.connection.phase == .reconnecting }
        XCTAssertTrue(lost)
        let notes = messages(since: before).filter { $0.hasPrefix(ConnectionLocalOnlyWifiTests.noInternetNote) }
        XCTAssertEqual(notes.count, 1, "\(notes)")
        XCTAssertFalse(notes.contains { $0.contains("GoPro") }, "\(notes)")
        h.connection.stop()
    }

    nonisolated static let goPro = WifiNetworkInfo(isWifiAvailable: true, ssid: "GoPro-1234", interfaceName: "en0",
                                                   phoneIPv4: "10.5.5.100", gateway: "10.5.5.9", isLocalOnly: true,
                                                   pathUnsatisfiedReason: "notAvailable")

    // MARK: Auto-connect vs the Connect tap

    func testTheTapGuardIsTwoSecondsByDefault() {
        XCTAssertEqual(ConnectionTuning().autoConnectTapGuard, 2)
    }

    /// Field log 1: the rider tapped Connect 0.44 s after the auto-connect check. The button had just
    /// become Stop; the tap must not end the session auto-connect started. A second tap still stops.
    @MainActor
    func testATapRightAfterAutoConnectStartedTheSessionKeepsIt() async {
        let h = AppTestHarness()
        let (bike, qr) = h.addBike()
        h.wifi.setNetwork(FieldWifi.bike(ssid: qr.ssid))
        let before = lastLogID()
        h.connection.maybeAutoConnect()
        let started = await eventually { h.connection.session != nil }
        XCTAssertTrue(started)
        XCTAssertEqual(h.connection.session?.trigger, .auto)
        h.connection.toggle()
        XCTAssertTrue(h.connection.isSessionActive, "the tap kept the session")
        XCTAssertNotEqual(h.connection.phase, .stopped)
        XCTAssertEqual(h.connection.session?.trigger, .user, "now the rider's own Connect")
        XCTAssertTrue(messages(since: before).contains { $0.hasPrefix("\u{2192} Connect: '\(bike.name)' \u{2014} auto-connect started it ") })
        h.connection.toggle()
        XCTAssertFalse(h.connection.isSessionActive)
        XCTAssertEqual(h.connection.phase, .stopped)
        XCTAssertNil(h.connection.session)
    }

    @MainActor
    func testATapAfterTheGuardStopsAnAutoConnectSession() async {
        let h = AppTestHarness()
        h.connection.tuning.autoConnectTapGuard = 0.2
        let (_, qr) = h.addBike()
        h.wifi.setNetwork(FieldWifi.bike(ssid: qr.ssid))
        h.connection.maybeAutoConnect()
        let started = await eventually { h.connection.session != nil }
        XCTAssertTrue(started)
        await settle(0.3)
        h.connection.toggle()
        XCTAssertFalse(h.connection.isSessionActive)
        XCTAssertEqual(h.connection.phase, .stopped)
    }

    @MainActor
    func testARidersOwnConnectSessionStopsAtTheFirstTap() async {
        let h = AppTestHarness()
        let (_, qr) = h.addBike()
        h.wifi.setNetwork(FieldWifi.bike(ssid: qr.ssid))
        h.connection.connect()
        XCTAssertEqual(h.connection.session?.trigger, .user)
        h.connection.toggle()
        XCTAssertFalse(h.connection.isSessionActive)
        XCTAssertEqual(h.connection.phase, .stopped)
    }
}

/// Connects go to `inner`, except while `drop` is set: then the transport's "dropped by the system".
final class DroppingNetwork: NetworkProvider, @unchecked Sendable {
    let inner: LinkMemoryNetwork
    let drop = Locked(true)
    init(inner: LinkMemoryNetwork) { self.inner = inner }
    func listen(port: UInt16) async throws -> any StreamListener { try await inner.listen(port: port) }
    func connect(host: String, port: UInt16, timeout: TimeInterval) async throws -> any ByteStream {
        if drop.current { throw PlatformTransportErrors.localNetworkDeniedError }
        return try await inner.connect(host: host, port: port, timeout: timeout)
    }
}
