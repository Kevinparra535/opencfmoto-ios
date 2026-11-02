// SPDX-License-Identifier: AGPL-3.0-or-later
// InterfaceAddresses (session-network.md §4.2 gatewayForSubnet vectors, ios-platform-facts (j)),
// the :10930 probe client, ProbeGate / firstTrue, and the in-memory transport used by the
// end-to-end tests.
import XCTest
@testable import OpenCfMotoCore

final class LinkInterfaceAddressesTests: XCTestCase {
    func testGatewayForSubnetVectors() {
        XCTAssertEqual(InterfaceAddresses.subnetGateway(ip: "192.168.0.50", prefixLength: 24), "192.168.0.1")
        XCTAssertEqual(InterfaceAddresses.subnetGateway(ip: "192.168.49.132", prefixLength: 24), "192.168.49.1")
        XCTAssertEqual(InterfaceAddresses.subnetGateway(ip: "192.168.4.2", prefixLength: 24), "192.168.4.1")
        XCTAssertEqual(InterfaceAddresses.subnetGateway(ip: "172.20.10.2", prefixLength: 28), "172.20.10.1")
        XCTAssertEqual(InterfaceAddresses.subnetGateway(ip: "10.0.0.7", prefixLength: 8), "10.0.0.1")
        XCTAssertNil(InterfaceAddresses.subnetGateway(ip: "192.168.49.1", prefixLength: 24)) // we are .1
        XCTAssertNil(InterfaceAddresses.subnetGateway(ip: "192.168.0.50", prefixLength: 32))
        XCTAssertNil(InterfaceAddresses.subnetGateway(ip: "192.168.0.50", prefixLength: 0))
        XCTAssertNil(InterfaceAddresses.subnetGateway(ip: "nope", prefixLength: 24))
    }

    func testParseFormatAndPrefix() {
        XCTAssertEqual(InterfaceAddresses.parseIPv4("192.168.0.1"), 0xC0A8_0001)
        XCTAssertEqual(InterfaceAddresses.format(0xC0A8_0001), "192.168.0.1")
        XCTAssertNil(InterfaceAddresses.parseIPv4("192.168.0"))
        XCTAssertNil(InterfaceAddresses.parseIPv4("192.168.0.256"))
        XCTAssertNil(InterfaceAddresses.parseIPv4("a.b.c.d"))
        XCTAssertNil(InterfaceAddresses.parseIPv4("1..2.3"))
        XCTAssertEqual(InterfaceAddress(name: "en0", ipv4: "1.2.3.4", netmask: "255.255.255.0").prefixLength, 24)
        XCTAssertEqual(InterfaceAddress(name: "en0", ipv4: "1.2.3.4", netmask: "255.255.255.240").prefixLength, 28)
        XCTAssertEqual(InterfaceAddress(name: "en0", ipv4: "1.2.3.4", netmask: "255.255.255.255").prefixLength, 32)
        XCTAssertNil(InterfaceAddress(name: "en0", ipv4: "1.2.3.4", netmask: "255.0.255.0").prefixLength)
        XCTAssertTrue(InterfaceAddress(name: "x", ipv4: "169.254.3.4", netmask: "255.255.0.0").isLinkLocal)
    }

    private let addrs = [
        InterfaceAddress(name: "lo0", ipv4: "127.0.0.1", netmask: "255.0.0.0", isLoopback: true),
        InterfaceAddress(name: "pdp_ip0", ipv4: "10.33.2.7", netmask: "255.255.255.255"),
        InterfaceAddress(name: "en2", ipv4: "169.254.10.1", netmask: "255.255.0.0"),
        InterfaceAddress(name: "en0", ipv4: "192.168.0.50", netmask: "255.255.255.0"),
        InterfaceAddress(name: "en5", ipv4: "192.168.49.132", netmask: "255.255.255.0", isUp: false),
    ]

    func testPickBikeIPv4() {
        XCTAssertEqual(InterfaceAddresses.pickBikeIPv4(from: addrs, preferredIP: "10.33.2.7")?.name, "pdp_ip0")
        XCTAssertEqual(InterfaceAddresses.pickBikeIPv4(from: addrs, interfaceName: "en0")?.ipv4, "192.168.0.50")
        XCTAssertEqual(InterfaceAddresses.pickBikeIPv4(from: addrs, subnetHint: "192.168.0.1")?.ipv4, "192.168.0.50")
        XCTAssertEqual(InterfaceAddresses.pickBikeIPv4(from: addrs)?.ipv4, "192.168.0.50") // known dash subnet
        XCTAssertNil(InterfaceAddresses.pickBikeIPv4(from: addrs, preferredIP: "192.168.49.132")?.name == "en5" ? "x" : nil)
        XCTAssertNil(InterfaceAddresses.pickBikeIPv4(from: [addrs[0]]))
        let onlyCell = [addrs[1]]
        XCTAssertEqual(InterfaceAddresses.pickBikeIPv4(from: onlyCell)?.ipv4, "10.33.2.7") // Android last resort
    }

    func testGatewayCandidatesLadder() {
        let local = addrs[3]
        XCTAssertEqual(InterfaceAddresses.gatewayCandidates(dashHost: nil, injectedGateway: nil, local: local), ["192.168.0.1"])
        XCTAssertEqual(InterfaceAddresses.gatewayCandidates(dashHost: nil, injectedGateway: "192.168.0.254", local: local),
                       ["192.168.0.254", "192.168.0.1"])
        XCTAssertEqual(InterfaceAddresses.gatewayCandidates(dashHost: "192.168.49.1", injectedGateway: "192.168.0.1", local: local),
                       ["192.168.49.1", "192.168.0.1"]) // explicit ones are kept even off-subnet
        XCTAssertEqual(InterfaceAddresses.gatewayCandidates(dashHost: nil, injectedGateway: nil, local: nil),
                       ["192.168.0.1", "192.168.49.1"])
        let p2p = InterfaceAddress(name: "en0", ipv4: "192.168.49.132", netmask: "255.255.255.0")
        XCTAssertEqual(InterfaceAddresses.gatewayCandidates(dashHost: nil, injectedGateway: nil, local: p2p), ["192.168.49.1"])
        let groupOwner = InterfaceAddress(name: "en0", ipv4: "192.168.49.1", netmask: "255.255.255.0")
        XCTAssertEqual(InterfaceAddresses.gatewayCandidates(dashHost: nil, injectedGateway: nil, local: groupOwner), [])
        XCTAssertEqual(InterfaceAddresses.gatewayCandidates(dashHost: "bogus", injectedGateway: nil, local: nil),
                       ["192.168.0.1", "192.168.49.1"])
    }

    func testCurrentReturnsLoopbackOnThisMachine() {
        let all = InterfaceAddresses.current()
        XCTAssertTrue(all.contains { $0.isLoopback && $0.ipv4 == "127.0.0.1" && $0.isUp }, "\(all)")
        XCTAssertTrue(all.allSatisfy { InterfaceAddresses.isValidIPv4($0.ipv4) })
    }
}

final class LinkProbeTests: XCTestCase {
    private func client(_ net: LinkMemoryNetwork, read: TimeInterval = 1) -> DashProbeClient {
        DashProbeClient(network: net, connectTimeout: 0.2, readTimeout: read, track: { _ in true }, untrack: { _ in })
    }

    func testAcceptedProbeSendsExactBytesAndCloses() async {
        let net = LinkMemoryNetwork()
        let dash = LinkFakeDash(network: net)
        dash.installProbeServer()
        let outcome = await client(net).probeOnce(host: "192.168.0.1", port: 10930, attempt: 1)
        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(dash.probesReceived.current, [PxcProbe.frameBytes])
        XCTAssertEqual(net.connectLog, ["192.168.0.1:10930"])
    }

    func testRejectedNoReplyBadMagicRefusedAndTimeout() async {
        let net = LinkMemoryNetwork()
        let dash = LinkFakeDash(network: net)
        dash.installProbeServer()
        dash.probeBehavior.set(.reject)
        let rejected = await client(net).probeOnce(host: "192.168.0.1", port: 10930, attempt: 1)
        XCTAssertEqual(rejected, .rejected("{\"status\":false}"))
        dash.probeBehavior.set(.closeWithoutReply)
        let noReply = await client(net).probeOnce(host: "192.168.0.1", port: 10930, attempt: 2)
        XCTAssertEqual(noReply, .noReply)
        dash.probeBehavior.set(.badMagic)
        if case .failed = await client(net).probeOnce(host: "192.168.0.1", port: 10930, attempt: 3) {} else { XCTFail("bad magic") }
        if case .failed = await client(net).probeOnce(host: "192.168.0.9", port: 10930, attempt: 1) {} else { XCTFail("refused") }
        // A dash that accepts the connection but never answers → read timeout.
        net.registerEndpoint(host: "192.168.0.2", port: 10930) { _ in }
        let start = Date()
        let silent = await client(net, read: 0.2).probeOnce(host: "192.168.0.2", port: 10930, attempt: 1)
        XCTAssertEqual(silent, .unanswered, "connected, but no reply within the read timeout")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testLocalNetworkDeniedIsReported() async {
        struct DeniedNetwork: NetworkProvider {
            func listen(port: UInt16) async throws -> any StreamListener { throw LinkFailure.localNetworkDenied }
            func connect(host: String, port: UInt16, timeout: TimeInterval) async throws -> any ByteStream {
                throw LinkFailure.localNetworkDenied
            }
        }
        let c = DashProbeClient(network: DeniedNetwork(), connectTimeout: 1, readTimeout: 1, track: { _ in true }, untrack: { _ in })
        let outcome = await c.probeOnce(host: "192.168.0.1", port: 10930, attempt: 1)
        XCTAssertEqual(outcome, .localNetworkDenied)
        // The OpenCfMotoApple NWNetworkProvider form.
        XCTAssertTrue(DashProbeClient.isLocalNetworkDenied(TransportError.failed("localNetworkDenied")))
        XCTAssertFalse(DashProbeClient.isLocalNetworkDenied(TransportError.failed("connection refused")))
        XCTAssertFalse(DashProbeClient.isLocalNetworkDenied(TransportError.timeout))
    }

    func testLocalNetworkDeniedFailsTheSessionAndIsReArmed() async {
        final class DenyingNetwork: NetworkProvider, @unchecked Sendable {
            let inner = LinkMemoryNetwork()
            let deny = Locked(true)
            func listen(port: UInt16) async throws -> any StreamListener { try await inner.listen(port: port) }
            func connect(host: String, port: UInt16, timeout: TimeInterval) async throws -> any ByteStream {
                if deny.current { throw TransportError.failed("localNetworkDenied") }
                return try await inner.connect(host: host, port: port, timeout: timeout)
            }
        }
        let net = DenyingNetwork()
        let dash = LinkFakeDash(network: net.inner)
        dash.installProbeServer()
        var options = LinkOptions()
        options.timings = LinkEndToEndTests.fastTimings
        options.interfaceProvider = { [] }
        let link = EasyConnLink(configuration: LinkConfiguration(localHost: "192.168.0.50"), network: net,
                                frameSource: LinkFakeFrameSource(), signer: LinkTestKeys.fixtureSigner,
                                gateway: "192.168.0.1", options: options)
        link.start()
        let failed = await linkEventually { link.state == .failed(.localNetworkDenied) }
        XCTAssertTrue(failed, "\(link.state)")
        net.deny.set(false) // the rider allows Local Network access
        let accepted = await linkEventually { dash.acceptedCount.current == 1 }
        XCTAssertTrue(accepted)
        link.stop()
    }

    func testPortScanOrdersProbePortFirst() async {
        let net = LinkMemoryNetwork()
        for p: UInt16 in [10931, 10930, 10916] { net.registerEndpoint(host: "192.168.0.1", port: p) { s in s.close() } }
        let open = await client(net).scanOpenPorts(host: "192.168.0.1", ports: 10915 ... 10935, timeout: 0.05, shouldContinue: { true })
        XCTAssertEqual(open, [10930, 10916, 10931])
        XCTAssertEqual(net.connectLog.count, 21)
        let none = await client(net).scanOpenPorts(host: "192.168.0.1", ports: 10915 ... 10935, timeout: 0.05, shouldContinue: { false })
        XCTAssertEqual(none, [])
    }

    func testProbeGateSerializesAndBlocksAfterAcceptance() async {
        let gate = ProbeGate()
        let a = await gate.acquire()
        XCTAssertTrue(a)
        let second = Task { await gate.acquire() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        await gate.release(accepted: true)
        let b = await second.value
        XCTAssertFalse(b) // released to a waiter after acceptance → refused
        let c = await gate.acquire()
        XCTAssertFalse(c)
        let accepted = await gate.accepted
        XCTAssertTrue(accepted)
    }

    func testFirstTrueDoesNotWaitForSlowLosers() async {
        let start = Date()
        let r = await LinkSession.firstTrue([
            { try? await Task.sleep(nanoseconds: 3_000_000_000); return false },
            { try? await Task.sleep(nanoseconds: 20_000_000); return true },
        ])
        XCTAssertTrue(r)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        let none = await LinkSession.firstTrue([{ false }, { false }])
        XCTAssertFalse(none)
        let empty = await LinkSession.firstTrue([])
        XCTAssertFalse(empty)
    }
}

final class LinkMemoryTransportTests: XCTestCase {
    func testPipeOrderingEOFAndClose() async throws {
        let (a, b) = LinkMemoryStream.pair(aHost: "a", aPort: 1, bHost: "b", bPort: 2)
        try await a.write(Data([1, 2, 3]))
        try await a.write(Data([4]))
        let r1 = try await b.read(exactly: 2)
        let r2 = try await b.readSome(maxCount: 10)
        XCTAssertEqual(r1, Data([1, 2]))
        XCTAssertEqual(r2, Data([3, 4]))
        a.close()
        do { _ = try await b.read(exactly: 1); XCTFail() } catch { XCTAssertEqual(error as? TransportError, .closed) }
        do { try await a.write(Data([9])); XCTFail() } catch { XCTAssertEqual(error as? TransportError, .closed) }
        do { try await b.write(Data([9])); XCTFail() } catch { XCTAssertEqual(error as? TransportError, .closed) }
    }

    func testPendingReadThrowsOnLocalCloseAndOnCancellation() async throws {
        let (a, _) = LinkMemoryStream.pair(aHost: "a", aPort: 1, bHost: "b", bPort: 2)
        let reader = Task { try await a.read(exactly: 4) }
        try await Task.sleep(nanoseconds: 20_000_000)
        a.close()
        do { _ = try await reader.value; XCTFail() } catch { XCTAssertEqual(error as? TransportError, .closed) }
        let (c, _) = LinkMemoryStream.pair(aHost: "a", aPort: 1, bHost: "b", bPort: 2)
        do {
            _ = try await withTimeout(0.05) { try await c.read(exactly: 1) }
            XCTFail()
        } catch {
            XCTAssertTrue(error is TimeoutError)
        }
    }

    func testListenerConflictsAndDial() async throws {
        let net = LinkMemoryNetwork()
        let l = try await net.listen(port: 10922)
        do { _ = try await net.listen(port: 10922); XCTFail("EADDRINUSE expected") } catch {}
        let dashSide = try net.dial(port: 10922)
        let phoneSide = try await l.accept()
        XCTAssertEqual(phoneSide.localPort, 10922)
        XCTAssertEqual(phoneSide.remoteHost, "192.168.0.1")
        try await dashSide.write(Data([7]))
        let got = try await phoneSide.read(exactly: 1)
        XCTAssertEqual(got, Data([7]))
        l.close()
        XCTAssertThrowsError(try net.dial(port: 10922))
        _ = try await net.listen(port: 10922) // re-listen after close
        net.blockPort(10921)
        do { _ = try await net.listen(port: 10921); XCTFail() } catch {}
    }
}

final class LinkTimingsTests: XCTestCase {
    func testAndroidDefaults() {
        let t = LinkTimings.standard
        XCTAssertEqual(t.probeConnectTimeout, 3)
        XCTAssertEqual(t.probeReadTimeout, 5)
        XCTAssertEqual(t.probeRetryUnit, 0.75)
        XCTAssertEqual(t.gatewayProbeAttempts, 5)
        XCTAssertEqual(t.bonjourProbeAttempts, 3)
        XCTAssertEqual(t.reconnectProbeAttempts, 2)
        XCTAssertEqual(t.scannedPortProbeAttempts, 2)
        XCTAssertEqual(t.bonjourBrowseTimeout, 12)
        XCTAssertEqual(t.portScanRange, 10915 ... 10935)
        XCTAssertEqual(t.portScanConnectTimeout, 0.35)
        XCTAssertEqual(t.heartbeatInterval, 2)
        XCTAssertEqual(t.reconnectSettle, 2.5)
        XCTAssertEqual(t.watchdogTick, 5)
        XCTAssertEqual(t.errorRearmInterval, 20)
        let c = LinkConfiguration()
        XCTAssertEqual(c.connectBackTimeout, 10)
        XCTAssertEqual(c.stallTimeout, 8)
        XCTAssertEqual(c.stallReconnectCooldown, 20)
        XCTAssertEqual(c.maxReconnectAttempts, 20)
    }

    func testReconnectBackoffTable() {
        // session-network.md §6.4: 1000, 1500, 2000, 2500, 3000, 3500, then 4000 ms; 69.5 s over 20.
        let ms = (1 ... 20).map { Int((LinkTimings.standard.reconnectBackoff(attempt: $0) * 1000).rounded()) }
        XCTAssertEqual(Array(ms.prefix(8)), [1000, 1500, 2000, 2500, 3000, 3500, 4000, 4000])
        XCTAssertEqual(ms.reduce(0, +), 69_500)
    }

    func testProbeRetrySleepTotals() {
        // session-network.md §5.3: 750 ms × attempt, also after the last: 2 → 2250, 3 → 4500, 5 → 11250.
        func total(_ n: Int) -> Int { (1 ... n).map { Int((LinkTimings.standard.probeRetryUnit * Double($0) * 1000).rounded()) }.reduce(0, +) }
        XCTAssertEqual(total(2), 2250)
        XCTAssertEqual(total(3), 4500)
        XCTAssertEqual(total(5), 11_250)
    }

    func testScaledKeepsCountsAndScalesDurations() {
        let t = LinkTimings.standard.scaled(by: 0.01)
        XCTAssertEqual(t.gatewayProbeAttempts, 5)
        XCTAssertEqual(t.portScanRange, 10915 ... 10935)
        XCTAssertEqual(t.heartbeatInterval, 0.02, accuracy: 1e-9)
        XCTAssertEqual(t.reconnectBackoff(attempt: 1), 0.01, accuracy: 1e-9)
        XCTAssertEqual(t.errorRearmInterval ?? 0, 0.2, accuracy: 1e-9)
    }

    func testInitialCanvasFromLearnedGeometry() {
        XCTAssertEqual(LinkSession.initialCanvas(nil), .defaultLandscape)
        XCTAssertEqual(LinkSession.initialCanvas(.rounded(requestedWidth: 800, requestedHeight: 951)),
                       VideoCanvas(width: 800, height: 944, requestedWidth: 800, requestedHeight: 951))
        XCTAssertEqual(LinkSession.initialCanvas(VideoCanvas(width: 0, height: 0)), .defaultLandscape)
    }
}

