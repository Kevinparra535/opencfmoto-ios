// SPDX-License-Identifier: AGPL-3.0-or-later
// Follow-ups to the first field test on the link engine (review of the BSD-socket transport):
// - POSIX-1: a listener that dies mid-session (iOS reclaims the sockets of a suspended app) is closed,
//   forgotten and bound again, every time it happens in a session.
// - POSIX-2: a connect() dropped by the system while the session proved Local Network access works
//   (its Bonjour browse listed the dash, or a probe connected) is a VPN / data rule / filter
//   (`.localNetworkBlocked`), not Local Network privacy (`.localNetworkDenied`).
// - LOG-1: the "EasyConn never answered" line says what actually happened.

import Foundation
import XCTest
@testable import OpenCfMotoCore

final class LinkFieldFollowUpTests: XCTestCase {
    private func makeLink(_ net: NetworkProvider, discovery: DashDiscovery? = nil,
                          gateway: String? = "192.168.0.1") -> EasyConnLink {
        var options = LinkOptions()
        options.timings = LinkEndToEndTests.fastTimings
        options.interfaceProvider = { [] }
        return EasyConnLink(configuration: LinkConfiguration(localHost: "192.168.0.50"), network: net,
                            frameSource: LinkFakeFrameSource(), signer: LinkTestKeys.fixtureSigner,
                            discovery: discovery, gateway: gateway, options: options)
    }

    private func lastLogID() -> UInt64 { Log.shared.lines().last?.id ?? 0 }

    private func messages(since id: UInt64) -> [String] {
        Log.shared.lines().filter { $0.id > id }.map(\.message)
    }

    // MARK: POSIX-1 — a reclaimed listener is replaced

    func testADeadListenerIsClosedAndBoundAgainEveryTimeItDies() async throws {
        let net = LinkMemoryNetwork(phoneHost: "192.168.0.50")
        let link = makeLink(net) // nothing answers the probe: the session stays up with its listeners
        link.start()
        let listening = await linkEventually { net.openListenerPorts == [10920, 10921, 10922] }
        XCTAssertTrue(listening, "\(net.listenLog)")
        // More deaths than the 5 tries one death may use: each successful accept earns a fresh budget.
        for round in 1 ... 7 {
            // The dead listener keeps holding its port (a new bind fails until the link closes it).
            let failed = net.failAccept(port: 10922, with: TransportError.failed("accept :10922 failed: listener reclaimed (EBADF (Bad file descriptor))"))
            XCTAssertTrue(failed, "round \(round)")
            let rebound = await linkEventually { net.listenCount(10922) == round + 1 && net.openListenerPorts.contains(10922) }
            XCTAssertTrue(rebound, "round \(round): \(net.listenLog)")
            // The new listener takes connections (a foreign one: accepted from the socket, then refused).
            let foreign = try net.dial(port: 10922, fromHost: "10.9.9.9")
            do {
                _ = try await linkWithin(2, "foreign connection closed") { try await foreign.read(exactly: 1) }
                XCTFail("round \(round): the session kept a foreign connection")
            } catch {
                XCTAssertEqual(error as? TransportError, .closed, "round \(round)")
            }
        }
        XCTAssertEqual(net.listenCount(10921), 1)
        XCTAssertEqual(net.listenCount(10920), 1)
        link.stop()
        let closed = await linkEventually { net.openListenerPorts.isEmpty }
        XCTAssertTrue(closed, "the replacement listeners close with the session")
    }

    func testAPortThatCannotBeBoundAgainGivesUpAfterFiveTriesAndSaysSo() async throws {
        let net = LinkMemoryNetwork(phoneHost: "192.168.0.50")
        let link = makeLink(net)
        let before = lastLogID()
        link.start()
        let listening = await linkEventually { net.openListenerPorts == [10920, 10921, 10922] }
        XCTAssertTrue(listening)
        net.blockPort(10921) // another app grabbed it meanwhile
        XCTAssertTrue(net.failAccept(port: 10921, with: TransportError.failed("accept :10921 failed: listener reclaimed (EBADF)")))
        let gaveUp = await linkEventually {
            self.messages(since: before).contains { $0.hasPrefix("[:10921] !! cannot listen on this port any more") }
        }
        XCTAssertTrue(gaveUp)
        let lines = messages(since: before)
        XCTAssertEqual(lines.filter { $0.hasPrefix("[:10921] listening again failed (try ") }.count, 5, "\(lines)")
        XCTAssertFalse(net.openListenerPorts.contains(10921), "the dead listener was closed")
        XCTAssertEqual(net.openListenerPorts, [10920, 10922])
        link.stop()
    }

    // MARK: POSIX-2 — privacy or a system policy?

    /// Connects are dropped the way the POSIX transport reports EHOSTUNREACH straight from connect():
    /// after the first `allowed` ones, while `drop` is true.
    private final class DroppingNetwork: NetworkProvider, @unchecked Sendable {
        let inner = LinkMemoryNetwork(phoneHost: "192.168.0.50")
        let allowed = Locked(0)
        let drop = Locked(true)
        func listen(port: UInt16) async throws -> any StreamListener { try await inner.listen(port: port) }
        func connect(host: String, port: UInt16, timeout: TimeInterval) async throws -> any ByteStream {
            let passes = allowed.withLock { n -> Bool in
                guard n > 0 else { return false }
                n -= 1
                return true
            }
            if !passes, drop.current { throw PlatformTransportErrors.localNetworkDeniedError }
            return try await inner.connect(host: host, port: port, timeout: timeout)
        }
    }

    private struct ListingBonjour: DashDiscovery {
        var endpoints: [DiscoveredDash] = [DiscoveredDash(host: "192.168.0.1", port: 10930)]
        func discover(timeout: TimeInterval) async -> [DiscoveredDash] { endpoints }
    }

    func testADropWhileBonjourListedTheDashIsASystemPolicyNotPrivacy() async {
        let net = DroppingNetwork()
        let link = makeLink(net, discovery: ListingBonjour())
        let before = lastLogID()
        link.start()
        let failed = await linkEventually { link.state == .failed(.localNetworkBlocked) }
        XCTAssertTrue(failed, "\(link.state)")
        let lines = messages(since: before)
        XCTAssertTrue(lines.contains { $0.hasPrefix("!! the system dropped every connection to the dash") && $0.contains("although Local Network access works") },
                      "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains("Local Network access is probably off") }, "\(lines)")
        link.stop()
    }

    func testADropWithoutEvidenceStaysALocalNetworkDenial() async {
        for discovery in [nil, ListingBonjour(endpoints: [])] as [DashDiscovery?] {
            let net = DroppingNetwork()
            let link = makeLink(net, discovery: discovery)
            let before = lastLogID()
            link.start()
            let failed = await linkEventually { link.state == .failed(.localNetworkDenied) }
            XCTAssertTrue(failed, "\(link.state)")
            XCTAssertTrue(messages(since: before).contains { $0.hasPrefix("!! the system dropped every connection to the dash") && $0.contains("Local Network access is probably off") })
            link.stop()
        }
    }

    /// A probe that connected earlier in the session proves access too: a later drop is a policy.
    func testADropAfterAProbeConnectedIsASystemPolicy() async {
        let net = DroppingNetwork()
        net.allowed.set(1) // the first probe connects, then e.g. a VPN comes up
        let dash = LinkFakeDash(network: net.inner, host: "192.168.0.1")
        dash.installProbeServer()
        dash.probeBehavior.set(.reject) // the dash answers, but does not accept
        let link = makeLink(net)
        link.start()
        let failed = await linkEventually(timeout: 8) { link.state == .failed(.localNetworkBlocked) }
        XCTAssertTrue(failed, "\(link.state)")
        XCTAssertEqual(dash.probesReceived.current.count, 1)
        link.stop()
    }

    func testABlockedLinkIsReArmedAndConnectsOnceTheBlockIsGone() async {
        let net = DroppingNetwork()
        let dash = LinkFakeDash(network: net.inner, host: "192.168.0.1")
        dash.installProbeServer()
        let link = makeLink(net, discovery: ListingBonjour())
        link.start()
        let failed = await linkEventually { link.state == .failed(.localNetworkBlocked) }
        XCTAssertTrue(failed, "\(link.state)")
        net.drop.set(false) // the rider turned the VPN off
        let accepted = await linkEventually { dash.acceptedCount.current == 1 }
        XCTAssertTrue(accepted, "the watchdog re-arms a blocked link like a denied one")
        link.stop()
    }

    // MARK: LOG-1 — the failure summary says what happened

    /// The first "EasyConn never answered" summary logged since `id`, waiting for the line itself:
    /// LinkSession publishes `.failed(.dashNotFound)` and writes the summary just after it, outside its
    /// lock, so a test that waited for the state could read the log before the line was there (flaky
    /// test, music fix round F9). The fast timings re-arm the link 0.4 s later, so the state is checked
    /// in the recorded events, not live.
    private func notFoundSummary(since id: UInt64) async -> String? {
        func find() -> String? { messages(since: id).first { $0.hasPrefix("!! Wi-Fi is up but EasyConn never answered") } }
        _ = await linkEventually(timeout: 10) { find() != nil }
        return find()
    }

    func testTheNotFoundSummaryDescribesTimeoutsBonjourAndTheScan() async {
        let net = LinkMemoryNetwork(phoneHost: "192.168.0.50")
        net.blackhole(host: "192.168.0.1", port: 10930) // every connect to :10930 times out (field log 1)
        let link = makeLink(net, discovery: ListingBonjour())
        let recorder = LinkEventRecorder(link)
        let before = lastLogID()
        link.start()
        let summary = await notFoundSummary(since: before)
        XCTAssertNotNil(summary, "\(link.state)")
        let failed = await linkEventually { recorder.states.contains(.failed(.dashNotFound)) }
        XCTAssertTrue(failed, "\(recorder.states)")
        let s = summary ?? ""
        XCTAssertTrue(s.contains("Bonjour: listed 192.168.0.1:10930"), s)
        // Gateway ×5 + Bonjour ×3 twice (one re-browse): every one timed out — none was "refused".
        XCTAssertTrue(s.contains("probes: 192.168.0.1:10930 timed out \u{00D7}11"), s)
        XCTAssertTrue(s.contains("port scan 10915\u{2013}10935: none open"), s)
        XCTAssertFalse(s.contains("refused"), s)
        XCTAssertFalse(s.contains("Bonjour empty"), s)
        link.stop()
    }

    func testTheNotFoundSummaryDescribesRefusalsWithoutBonjour() async {
        let net = LinkMemoryNetwork(phoneHost: "192.168.0.50") // nothing registered: every connect is refused
        let link = makeLink(net)
        let recorder = LinkEventRecorder(link)
        let before = lastLogID()
        link.start()
        let summary = await notFoundSummary(since: before)
        XCTAssertNotNil(summary, "\(link.state)")
        let failed = await linkEventually { recorder.states.contains(.failed(.dashNotFound)) }
        XCTAssertTrue(failed, "\(recorder.states)")
        let s = summary ?? ""
        XCTAssertTrue(s.contains("Bonjour: not available"), s)
        XCTAssertTrue(s.contains("192.168.0.1:10930 refused \u{00D7}5"), s)
        XCTAssertTrue(s.contains("port scan 10915\u{2013}10935: none open"), s)
        link.stop()
    }

    func testTheTallyCountsKindsPerTargetAndFormatsTheSummary() {
        var t = DiscoveryTally()
        XCTAssertEqual(t.summary, "Bonjour: not available \u{00B7} probes: none sent \u{00B7} port scan: not reached")
        t.bonjourListed([])
        t.probed("192.168.0.1:10930", "timed out")
        t.probed("192.168.0.1:10930", "refused")
        t.probed("192.168.0.1:10930", "timed out")
        t.probed("192.168.0.1:10931", "connected, no reply")
        t.scan = DiscoveryTally.Scan(range: 10915 ... 10935, open: [10931])
        XCTAssertEqual(t.summary,
                       "Bonjour: nothing listed \u{00B7} probes: 192.168.0.1:10930 timed out \u{00D7}2, refused \u{00D7}1; 192.168.0.1:10931 connected, no reply \u{00D7}1 \u{00B7} port scan 10915\u{2013}10935: open 10931")
        t.bonjourListed(["192.168.0.1:10930"])
        t.bonjourListed(["192.168.0.1:10930", "192.168.0.7:10930"])
        XCTAssertEqual(t.bonjour, ["192.168.0.1:10930", "192.168.0.7:10930"])
    }

    func testProbeOutcomeKinds() {
        typealias O = DashProbeClient.Outcome
        XCTAssertEqual(O.failed("\(TransportError.timeout)").summaryKind, "timed out")
        XCTAssertEqual(O.failed("\(TransportError.failed("ECONNREFUSED: connection refused (192.168.0.1:10930)"))").summaryKind, "refused")
        XCTAssertEqual(O.failed("\(TransportError.failed("connection refused 192.168.0.1:10930"))").summaryKind, "refused")
        XCTAssertEqual(O.failed("\(TransportError.failed("EHOSTUNREACH: No route to host (192.168.0.1:10930)"))").summaryKind, "unreachable")
        XCTAssertEqual(O.failed("\(TransportError.failed("EHOSTDOWN: Host is down (192.168.0.1:10930)"))").summaryKind, "unreachable")
        XCTAssertEqual(O.failed("session stopped").summaryKind, "failed")
        XCTAssertEqual(O.unanswered.summaryKind, "connected, no reply")
        XCTAssertEqual(O.noReply.summaryKind, "closed without a reply")
        XCTAssertEqual(O.rejected("{\"status\":false}").summaryKind, "not accepted")
        XCTAssertEqual(O.localNetworkDenied.summaryKind, "blocked by the system")
        XCTAssertTrue(O.accepted.connected && O.rejected("x").connected && O.noReply.connected && O.unanswered.connected)
        XCTAssertFalse(O.failed("timed out").connected || O.localNetworkDenied.connected)
    }
}
