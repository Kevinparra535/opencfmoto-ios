// SPDX-License-Identifier: AGPL-3.0-or-later
// ConnectionModel regressions from the wave-3 review (uids in each test's comment): stale link
// events, the manual-join baseline race, Stop / Local Network issue in a re-arming error, parking,
// the bike-network fingerprint (SSID unknown), auto-connect gating and retry, phone-hotspot QRs,
// mirror location / fit / margins, dash serial redaction.
import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class ConnectionReviewFixTests: XCTestCase {
    // MARK: CON:CL-6 — stale events of a replaced link

    @MainActor
    func testAStaleEventOfTheReplacedLinkIsIgnoredAfterAWifiBackRestart() async {
        let h = AppTestHarness()
        let (_, qr) = h.addBike()
        h.connection.connect()
        _ = await eventually { h.connection.link != nil }
        let oldSerial = h.connection.linkSerial
        let gen = h.connection.generation
        h.wifi.setNetwork(.unavailable)
        _ = await eventually { h.connection.phase == .reconnecting }
        h.wifi.setNetwork(AppTestHarness.bikeNetwork(ssid: qr.ssid))
        let restarted = await eventually { h.connection.link != nil && h.connection.linkSerial != oldSerial }
        XCTAssertTrue(restarted)
        XCTAssertEqual(h.connection.generation, gen) // a Wi-Fi-back restart keeps the session generation

        // Events the old link's consumer had already dequeued: no effect on the new link's session.
        let phase = h.connection.phase
        let state = h.connection.linkState
        h.connection.handleLinkEvent(.state(.failed(.lostLink)), gen: gen, serial: oldSerial)
        h.connection.handleLinkEvent(.state(.streaming), gen: gen, serial: oldSerial)
        XCTAssertEqual(h.connection.phase, phase)
        XCTAssertEqual(h.connection.linkState, state)
        XCTAssertFalse(h.ride.isProjecting)
        XCTAssertNotNil(h.connection.session)

        // The current link's events still pass.
        h.connection.handleLinkEvent(.state(.reconnecting(attempt: 1)), gen: gen, serial: h.connection.linkSerial)
        XCTAssertEqual(h.connection.phase, .reconnecting)
        h.connection.stop()
    }

    @MainActor
    func testStopLinkInvalidatesTheSerial() async {
        let h = AppTestHarness()
        h.addBike()
        h.connection.connect()
        _ = await eventually { h.connection.link != nil }
        let serial = h.connection.linkSerial
        let gen = h.connection.generation
        h.connection.stop()
        XCTAssertNotEqual(h.connection.linkSerial, serial)
        h.connection.handleLinkEvent(.state(.streaming), gen: gen, serial: serial)
        XCTAssertEqual(h.connection.phase, .stopped)
    }

    // MARK: Manual join (free flavor) — baseline race seen in the E2E run

    @MainActor
    func testManualJoinCountsASwitchThatLandsRightAfterThePromptAppears() async {
        let wifi = RacyManualJoinWifi()
        let h = AppTestHarness(flavor: .free) { $0.wifi = wifi }
        h.addBike()
        h.connection.connect()
        // The network flips to the bike (SSID unknown) at the 2nd network access after the join: the
        // old code read its baseline there, AFTER publishing the prompt, and then waited forever.
        let linked = await eventually { h.connection.link != nil }
        XCTAssertTrue(linked)
        XCTAssertNil(h.connection.manualJoin)
        h.connection.stop()
    }

    // MARK: CON:CL-1 / SPEC:CL-1 — a re-arming .error keeps a session that the big button must stop

    @MainActor
    func testTheBigButtonStopsAReArmingErrorSessionInsteadOfRestartingIt() async {
        let h = AppTestHarness()
        let (_, qr) = h.addBike()
        h.connection.connect()
        XCTAssertTrue(h.connection.isSessionActive)
        // PreviewNetwork never answers: dash not found → .error, the session stays armed.
        let armed = await eventually { h.connection.phase == .error }
        XCTAssertTrue(armed)
        XCTAssertFalse(h.connection.phase.showsStop) // frozen contract: the UI keys on isSessionActive
        XCTAssertTrue(h.connection.isSessionActive)
        XCTAssertNotNil(h.connection.session)

        h.connection.toggle()
        XCTAssertEqual(h.connection.phase, .stopped)
        XCTAssertFalse(h.connection.isSessionActive)
        XCTAssertNil(h.connection.session)
        XCTAssertEqual(h.wifi.joinedSSIDs, [qr.ssid]) // no second join
        XCTAssertFalse(h.location.isUpdating)
        XCTAssertFalse(h.system.isIdleTimerDisabled)
    }

    @MainActor
    func testTheLocalNetworkIssueIsRaisedOncePerEpisodeSoDismissSticks() async {
        let net = LocalNetworkDeniedNetwork()
        let h = AppTestHarness(network: net)
        h.addBike()
        h.connection.connect()
        let raised = await eventually { h.connection.issue == .localNetworkDenied }
        XCTAssertTrue(raised)
        XCTAssertEqual(h.connection.phase, .error)
        XCTAssertTrue(h.connection.isSessionActive) // auto-recovery keeps re-arming
        h.connection.dismissIssue()
        let attempts = net.connectAttempts
        // Several watchdog re-arms (0.4 s in the test timings), each failing the same way.
        let rearmed = await eventually { net.connectAttempts >= attempts + 3 }
        XCTAssertTrue(rearmed)
        await settle(0.2)
        XCTAssertNil(h.connection.issue)
        XCTAssertEqual(h.connection.phase, .error)
        XCTAssertEqual(h.connection.detail, SessionText.localNetworkDenied(h.language))

        // A new session is a new episode: the dialog comes back once.
        h.connection.stop()
        h.connection.connect()
        let again = await eventually { h.connection.issue == .localNetworkDenied }
        XCTAssertTrue(again)
        h.connection.stop()
    }

    // MARK: CON:CL-2 — parking ends the own-UI projection (trip auto-log, Live label)

    /// CFDL16 handshake + media channels, then three frame pulls (the link reaches STREAMING).
    private func streamFromFakeDash(_ dash: LinkFakeDash) async throws -> [() -> Void] {
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
        return [ctrl.close, mctl.close, mdata.close]
    }

    @MainActor
    func testParkingAfterTheWifiGraceEndsTheProjectionAndTheAutoLoggedTrip() async throws {
        let net = LinkMemoryNetwork(phoneHost: "192.168.0.2")
        let dash = LinkFakeDash(network: net, host: "192.168.0.1")
        dash.installProbeServer()
        let h = AppTestHarness(network: net, frameSource: TestFrameSource())
        let (_, qr) = h.addBike()
        h.connection.connect()
        _ = await eventually { dash.acceptedCount.current == 1 }
        let first = try await streamFromFakeDash(dash)
        let streaming = await eventually { h.connection.phase == .streaming }
        XCTAssertTrue(streaming)
        XCTAssertTrue(h.ride.isProjecting)
        XCTAssertTrue(h.core.tripRecorder.isRecording) // "Log trips automatically" (default)

        // The bike is switched off: the Wi-Fi goes, the grace runs out, the session parks.
        h.wifi.setNetwork(.unavailable)
        first.forEach { $0() }
        let parked = await eventually { h.connection.phase == .waitingForBike }
        XCTAssertTrue(parked)
        XCTAssertEqual(h.projection.stats.mode, "stopped")
        XCTAssertFalse(h.ride.isProjecting)
        XCTAssertFalse(h.core.tripRecorder.isRecording) // the leg was saved at park
        h.ride.runHousekeeping()
        XCTAssertFalse(h.core.tripRecorder.isRecording)
        XCTAssertTrue(h.connection.isSessionActive)

        // The bike is back: a fresh link streams again, the projection and a new leg start.
        let accepted = dash.acceptedCount.current
        h.wifi.setNetwork(AppTestHarness.bikeNetwork(ssid: qr.ssid))
        _ = await eventually { dash.acceptedCount.current > accepted }
        let second = try await streamFromFakeDash(dash)
        let back = await eventually { h.connection.phase == .streaming }
        XCTAssertTrue(back)
        XCTAssertTrue(h.ride.isProjecting)
        XCTAssertTrue(h.core.tripRecorder.isRecording)
        h.connection.stop()
        second.forEach { $0() }
    }
}

/// Free-flavor Wi-Fi whose network switches to the bike (SSID unknown, dash subnet) at the second
/// network access after `join` — the rider's switch landing just after the manual-join sheet appeared.
final class RacyManualJoinWifi: WifiJoining, @unchecked Sendable {
    private let inner = PreviewWifi(supportsAutomaticJoin: false)
    private let lock = NSLock()
    private var joined = false
    private var accesses = 0

    var supportsAutomaticJoin: Bool { false }

    init() { inner.nextJoinResult = .success(.manualJoinRequired) }

    private func touch() {
        let n: Int = lock.withLock {
            guard joined else { return 0 }
            accesses += 1
            return accesses
        }
        if n == 2 { inner.setNetwork(AppTestHarness.bikeNetwork(ssid: nil)) }
    }

    func join(ssid: String, passphrase: String?) async throws -> WifiJoinResult {
        lock.withLock { joined = true }
        return try await inner.join(ssid: ssid, passphrase: passphrase)
    }

    func forget(ssid: String) { inner.forget(ssid: ssid) }

    func currentNetwork() async -> WifiNetworkInfo {
        touch()
        return await inner.currentNetwork()
    }

    func networkUpdates() -> AsyncStream<WifiNetworkInfo> {
        touch()
        return inner.networkUpdates()
    }
}

/// Listens fine, but every outbound connection reports the Local Network privacy denial.
final class LocalNetworkDeniedNetwork: NetworkProvider, @unchecked Sendable {
    private let attempts = Locked(0)
    var connectAttempts: Int { attempts.current }

    func listen(port: UInt16) async throws -> any StreamListener { PreviewListener(port: port) }

    func connect(host: String, port: UInt16, timeout: TimeInterval) async throws -> any ByteStream {
        attempts.withLock { $0 += 1 }
        throw LinkFailure.localNetworkDenied
    }
}
