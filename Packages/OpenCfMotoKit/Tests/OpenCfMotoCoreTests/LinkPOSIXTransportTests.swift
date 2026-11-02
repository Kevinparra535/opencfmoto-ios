// SPDX-License-Identifier: AGPL-3.0-or-later
// POSIXNetworkProvider (Link/POSIXTransport.swift) against the ByteStream / StreamListener /
// NetworkProvider contract on loopback with kernel-chosen ports (the former `linkrunner --selftest`
// checks), the outbound-interface chooser, the errno mapping and the Local Network denial retry.
// Runs on Linux and macOS.

import XCTest
@testable import OpenCfMotoCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(Darwin)
private let rawSockStream = SOCK_STREAM
#else
private let rawSockStream = Int32(SOCK_STREAM.rawValue)
#endif

private func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

/// Open descriptors of this process (nil where neither directory exists).
private func openDescriptorCount() -> Int? {
    for dir in ["/proc/self/fd", "/dev/fd"] {
        if let n = try? FileManager.default.contentsOfDirectory(atPath: dir).count { return n }
    }
    return nil
}

/// A raw listening socket that never accepts (backlog 0) on a kernel-chosen loopback port: once its
/// queue is full, further SYNs are dropped and connects time out.
private final class NeverAcceptingListener {
    let fd: Int32
    let port: UInt16

    init() {
        let fd = socket(AF_INET, rawSockStream, 0)
        var addr = posixIPv4Address(host: "127.0.0.1", port: 0)!
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        _ = listen(fd, 0)
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        self.fd = fd
        port = UInt16(bigEndian: bound.sin_port)
    }

    deinit { close(fd) }

    /// Fills the accept queue; returns the connections to close afterwards.
    func fill(with net: POSIXNetworkProvider) async -> [any ByteStream] {
        var fillers: [any ByteStream] = []
        for _ in 0 ..< 8 {
            guard let s = try? await net.connect(host: "127.0.0.1", port: port, timeout: 0.3) else { break }
            fillers.append(s)
        }
        return fillers
    }
}

final class LinkPOSIXTransportTests: XCTestCase {
    private let net = POSIXNetworkProvider()

    /// Listener on an ephemeral loopback port + a connected client/server pair.
    private func pair() async throws -> (listener: POSIXStreamListener, client: POSIXByteStream, server: any ByteStream) {
        let listener = try net.openListener(port: 0)
        async let accepted = listener.accept()
        let client = try await net.openStream(host: "127.0.0.1", port: listener.port, timeout: 2)
        let server = try await accepted
        return (listener, client, server)
    }

    func testConnectAcceptReportsEndpointsAndListenerPort() async throws {
        let (l, c, s) = try await pair()
        defer { c.close(); s.close(); l.close() }
        XCTAssertNotEqual(l.port, 0)
        XCTAssertEqual(s.localPort, l.port, "accepted streams report the listener port")
        XCTAssertEqual(s.remoteHost, "127.0.0.1")
        XCTAssertNotEqual(c.localPort, 0)
        XCTAssertNotEqual(c.localPort, l.port)
        XCTAssertEqual(c.localHost, "127.0.0.1")
        XCTAssertEqual(c.remoteEndpoint, "127.0.0.1:\(l.port)")
        try await c.write(Data("ping".utf8))
        let got = try await s.read(exactly: 4)
        XCTAssertEqual(got, Data("ping".utf8))
        try await s.write(Data("pong".utf8))
        let back = try await c.read(exactly: 4)
        XCTAssertEqual(back, Data("pong".utf8))
    }

    func testReadExactlyAcrossManySmallWrites() async throws {
        let (l, c, s) = try await pair()
        defer { c.close(); s.close(); l.close() }
        let writer = Task {
            for i in 0 ..< 100 {
                try await c.write(Data([UInt8(i)]))
                if i % 10 == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
            }
        }
        let got = try await s.read(exactly: 100)
        try await writer.value
        XCTAssertEqual(got, Data((0 ..< 100).map { UInt8($0) }))
    }

    func testLargeWriteGoesThroughPartialWrites() async throws {
        let (l, c, s) = try await pair()
        defer { c.close(); s.close(); l.close() }
        var big = Data(count: 8 << 20)
        big.withUnsafeMutableBytes { p in for i in 0 ..< p.count { p[i] = UInt8(truncatingIfNeeded: i &* 31) } }
        let payload = big
        let writer = Task { try await c.write(payload) }
        try await Task.sleep(nanoseconds: 200_000_000) // let the send buffer fill up first
        var received = Data()
        while received.count < payload.count {
            received.append(try await s.readSome(maxCount: 1 << 16))
        }
        try await writer.value
        XCTAssertEqual(received.count, payload.count)
        XCTAssertTrue(received == payload, "payload differs")
    }

    func testConcurrentWritersKeepFramesWholeAndInCallOrder() async throws {
        let (l, c, s) = try await pair()
        defer { c.close(); s.close(); l.close() }
        let frameSize = 2 << 20
        // Writer k calls write() 30 ms after writer k-1: the first frames fill the socket buffers and
        // the writer parks holding the write lock, the later ones queue behind it in call order.
        let writers = (0 ..< 8).map { k in
            Task {
                try await Task.sleep(nanoseconds: UInt64(k) * 30_000_000)
                try await c.write(Data(repeating: UInt8(k), count: frameSize))
            }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        var order: [UInt8] = []
        for _ in 0 ..< 8 {
            let frame = try await s.read(exactly: frameSize)
            let k = frame[frame.startIndex]
            let whole = stride(from: frame.startIndex, to: frame.endIndex, by: 4096).allSatisfy { frame[$0] == k }
                && frame[frame.endIndex - 1] == k
            XCTAssertTrue(whole, "torn frame")
            order.append(k)
        }
        for w in writers { try await w.value }
        XCTAssertEqual(order, Array(0 ..< 8))
    }

    func testCloseWakesAParkedRead() async throws {
        let (l, c, s) = try await pair()
        defer { c.close(); l.close() }
        let reader = Task { () -> Error? in
            do {
                _ = try await s.read(exactly: 1)
                return nil
            } catch {
                return error
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let t0 = now()
        s.close()
        let error = await reader.value
        XCTAssertEqual(error as? TransportError, .closed)
        XCTAssertLessThan(now() - t0, 1.0)
    }

    func testCloseWakesAParkedWrite() async throws {
        let (l, c, s) = try await pair()
        defer { s.close(); l.close() }
        // Nobody reads: the writer fills both socket buffers and parks.
        let payload = Data(count: 64 << 20)
        let writer = Task { () -> Error? in
            do {
                try await c.write(payload)
                return nil
            } catch {
                return error
            }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let t0 = now()
        c.close()
        let error = await writer.value
        XCTAssertEqual(error as? TransportError, .closed)
        XCTAssertLessThan(now() - t0, 1.0)
    }

    func testPeerCloseDeliversBufferedBytesThenClosed() async throws {
        let (l, c, s) = try await pair()
        defer { s.close(); l.close() }
        try await c.write(Data([1, 2, 3]))
        c.close()
        let first = try await s.read(exactly: 3)
        XCTAssertEqual(first, Data([1, 2, 3]))
        do {
            _ = try await s.read(exactly: 1)
            XCTFail("read after EOF returned data")
        } catch {
            XCTAssertEqual(error as? TransportError, .closed)
        }
        do {
            _ = try await s.readSome(maxCount: 10)
            XCTFail("readSome after EOF returned data")
        } catch {
            XCTAssertEqual(error as? TransportError, .closed)
        }
    }

    func testEOFInTheMiddleOfAnExactReadThrowsClosed() async throws {
        let (l, c, s) = try await pair()
        defer { s.close(); l.close() }
        try await c.write(Data([9, 9]))
        c.close()
        do {
            _ = try await s.read(exactly: 5)
            XCTFail("short read returned data")
        } catch {
            XCTAssertEqual(error as? TransportError, .closed)
        }
    }

    func testCloseWakesAParkedAccept() async throws {
        let l = try net.openListener(port: 0)
        let acceptor = Task { () -> Error? in
            do {
                _ = try await l.accept()
                return nil
            } catch {
                return error
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let t0 = now()
        l.close()
        let error = await acceptor.value
        XCTAssertEqual(error as? TransportError, .closed)
        XCTAssertLessThan(now() - t0, 1.0)
        do {
            _ = try await l.accept()
            XCTFail("accept on a closed listener")
        } catch {
            XCTAssertEqual(error as? TransportError, .closed)
        }
    }

    func testCancelledAcceptThrowsCancelled() async throws {
        let l = try net.openListener(port: 0)
        defer { l.close() }
        let acceptor = Task { () -> Error? in
            do {
                _ = try await l.accept()
                return nil
            } catch {
                return error
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        acceptor.cancel()
        let error = await acceptor.value
        XCTAssertEqual(error as? TransportError, .cancelled)
    }

    func testCancelledReadThrowsCancelledAndTheStreamStaysUsable() async throws {
        let (l, c, s) = try await pair()
        defer { c.close(); s.close(); l.close() }
        let reader = Task { () -> Error? in
            do {
                _ = try await s.read(exactly: 1)
                return nil
            } catch {
                return error
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        reader.cancel()
        let error = await reader.value
        XCTAssertEqual(error as? TransportError, .cancelled)
        try await c.write(Data([42]))
        let after = try await s.read(exactly: 1)
        XCTAssertEqual(after, Data([42]))
    }

    func testCancelledExactReadKeepsTheBytesItAlreadyReceived() async throws {
        let (l, c, s) = try await pair()
        defer { c.close(); s.close(); l.close() }
        try await c.write(Data([1, 2]))
        let reader = Task { () -> Error? in
            do {
                _ = try await s.read(exactly: 4)
                return nil
            } catch {
                return error
            }
        }
        try await Task.sleep(nanoseconds: 200_000_000) // the reader has the first 2 bytes and parks
        reader.cancel()
        let error = await reader.value
        XCTAssertEqual(error as? TransportError, .cancelled)
        try await c.write(Data([3, 4, 5]))
        let frame = try await s.read(exactly: 4)
        XCTAssertEqual(frame, Data([1, 2, 3, 4]), "no byte lost or reordered")
        let rest = try await s.readSome(maxCount: 8)
        XCTAssertEqual(rest, Data([5]))
    }

    func testWritesAndReadsAfterCloseThrowClosed() async throws {
        let (l, c, s) = try await pair()
        defer { s.close(); l.close() }
        c.close()
        c.close() // idempotent
        XCTAssertTrue(c.isClosed)
        do {
            try await c.write(Data([1]))
            XCTFail("write after close")
        } catch {
            XCTAssertEqual(error as? TransportError, .closed)
        }
        do {
            _ = try await c.read(exactly: 1)
            XCTFail("read after close")
        } catch {
            XCTAssertEqual(error as? TransportError, .closed)
        }
    }

    func testConnectToAClosedPortIsRefusedQuickly() async throws {
        let l = try net.openListener(port: 0)
        let port = l.port
        l.close()
        try await Task.sleep(nanoseconds: 50_000_000)
        let t0 = now()
        do {
            let s = try await net.connect(host: "127.0.0.1", port: port, timeout: 2)
            s.close()
            XCTFail("connected to a closed port")
        } catch {
            XCTAssertTrue(PlatformTransportErrors.isConnectionRefused(error), "\(error)")
            XCTAssertFalse(PlatformTransportErrors.isLocalNetworkDenied(error))
        }
        XCTAssertLessThan(now() - t0, 1.0)
    }

    func testConnectTimesOutOnTime() async throws {
        let blackhole = NeverAcceptingListener()
        let fillers = await blackhole.fill(with: net)
        defer { fillers.forEach { $0.close() } }
        let t0 = now()
        do {
            let s = try await net.connect(host: "127.0.0.1", port: blackhole.port, timeout: 0.5)
            s.close()
            XCTFail("connected despite a full backlog (\(fillers.count) queued)")
        } catch {
            let dt = now() - t0
            XCTAssertEqual(error as? TransportError, .timeout)
            XCTAssertGreaterThanOrEqual(dt, 0.45)
            XCTAssertLessThan(dt, 1.5)
        }
        XCTAssertGreaterThanOrEqual(net.snapshot.connectTimeouts, 1)
    }

    func testCancelledConnectThrowsCancelled() async throws {
        let blackhole = NeverAcceptingListener()
        let fillers = await blackhole.fill(with: net)
        defer { fillers.forEach { $0.close() } }
        let port = blackhole.port
        let net = self.net
        let task = Task { () -> Error? in
            do {
                let s = try await net.connect(host: "127.0.0.1", port: port, timeout: 5)
                s.close()
                return nil
            } catch {
                return error
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let t0 = now()
        task.cancel()
        let error = await task.value
        XCTAssertEqual(error as? TransportError, .cancelled)
        XCTAssertLessThan(now() - t0, 1.0)
    }

    func testPortInUseIsReportedAsAddressInUse() async throws {
        let l = try net.openListener(port: 0)
        defer { l.close() }
        do {
            let again = try await net.listen(port: l.port)
            again.close()
            XCTFail("second listen on :\(l.port) succeeded")
        } catch {
            XCTAssertTrue(PlatformTransportErrors.isAddressInUse(error), "\(error)")
            XCTAssertEqual(error as? TransportError, PlatformTransportErrors.addressInUse(port: l.port))
        }
    }

    func testCountersTrackListensConnectsAndAccepts() async throws {
        let provider = POSIXNetworkProvider()
        let l = try provider.openListener(port: 0)
        defer { l.close() }
        async let accepted = l.accept()
        let c = try await provider.connect(host: "127.0.0.1", port: l.port, timeout: 2)
        let s = try await accepted
        c.close()
        s.close()
        let snap = provider.snapshot
        XCTAssertEqual(snap.listens, 1)
        XCTAssertEqual(snap.connectAttempts, 1)
        XCTAssertEqual(snap.connectsOK, 1)
        XCTAssertEqual(snap.accepted, 1)
        XCTAssertEqual(snap.acceptedByPort[l.port], 1)
    }

    func testManyCyclesLeakNoDescriptors() async throws {
        let l = try net.openListener(port: 0)
        defer { l.close() }
        let before = openDescriptorCount()
        for _ in 0 ..< 200 {
            async let accepted = l.accept()
            let c = try await net.connect(host: "127.0.0.1", port: l.port, timeout: 2)
            let s = try await accepted
            try await c.write(Data([7]))
            _ = try await s.read(exactly: 1)
            c.close()
            s.close()
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        if let before, let after = openDescriptorCount() {
            XCTAssertLessThanOrEqual(after, before + 2, "descriptors \(before) → \(after)")
        }
    }

    func testPortZeroFails() async throws {
        do {
            _ = try await net.connect(host: "127.0.0.1", port: 0, timeout: 1)
            XCTFail("connected to port 0")
        } catch {
            XCTAssertNotNil(error as? TransportError)
        }
    }
}

// MARK: - Interface choice

final class LinkOutboundInterfaceTests: XCTestCase {
    private let en0 = InterfaceAddress(name: "en0", ipv4: "192.168.0.51", netmask: "255.255.255.0")
    private let lo0 = InterfaceAddress(name: "lo0", ipv4: "127.0.0.1", netmask: "255.0.0.0", isLoopback: true)
    private let cellular = InterfaceAddress(name: "pdp_ip0", ipv4: "10.33.2.7", netmask: "255.255.255.255")
    private let tunnel = InterfaceAddress(name: "ipsec2", ipv4: "9.9.9.9", netmask: "255.0.0.0")
    private let linkLocal = InterfaceAddress(name: "en2", ipv4: "169.254.10.1", netmask: "255.255.0.0")

    private func choose(_ destination: String, _ addresses: [InterfaceAddress]) -> OutboundInterfaceChoice {
        InterfaceAddresses.outboundInterface(for: destination, among: addresses)
    }

    func testTheInterfaceWhoseSubnetContainsTheDestinationIsChosen() {
        XCTAssertEqual(choose("192.168.0.1", [en0]), .subnet(en0))
        XCTAssertEqual(choose("192.168.0.254", [en0]).interface, en0)
    }

    func testAmongSeveralInterfacesOnlyTheMatchingSubnetIsChosen() {
        let all = [lo0, cellular, tunnel, linkLocal, en0]
        XCTAssertEqual(choose("192.168.0.1", all), .subnet(en0))
        XCTAssertEqual(choose("169.254.200.3", all), .subnet(linkLocal))
        XCTAssertEqual(choose("9.1.2.3", all), .subnet(tunnel))
        XCTAssertEqual(choose("10.33.2.1", all), .noMatch, "a /32 contains only itself")
        XCTAssertEqual(choose("192.168.49.1", all), .noMatch)
    }

    func testTheLongestPrefixWinsAndTiesKeepListOrder() {
        let wide = InterfaceAddress(name: "en0", ipv4: "192.168.0.51", netmask: "255.255.0.0")
        let narrow = InterfaceAddress(name: "bridge100", ipv4: "192.168.0.200", netmask: "255.255.255.0")
        XCTAssertEqual(choose("192.168.0.1", [wide, narrow]), .subnet(narrow))
        XCTAssertEqual(choose("192.168.7.1", [wide, narrow]), .subnet(wide))
        let twin = InterfaceAddress(name: "en5", ipv4: "192.168.0.77", netmask: "255.255.255.0")
        XCTAssertEqual(choose("192.168.0.1", [en0, twin]), .subnet(en0))
        XCTAssertEqual(choose("192.168.0.1", [twin, en0]), .subnet(twin))
    }

    func testLoopbackDestinationsAreNeverPinned() {
        // The e2e override presents the phone as 127.0.0.2 on a non-loopback-flagged lo0.
        let e2e = InterfaceAddress(name: "lo0", ipv4: "127.0.0.2", netmask: "255.0.0.0", isUp: true, isLoopback: false)
        XCTAssertEqual(choose("127.0.0.1", [lo0, e2e, en0]), .loopbackDestination)
        XCTAssertEqual(choose("127.9.8.7", [e2e]), .loopbackDestination)
        XCTAssertNil(choose("127.0.0.1", [e2e]).interface)
    }

    func testOwnAddressNoMatchAndNonIPv4StayUnbound() {
        XCTAssertEqual(choose("192.168.0.51", [lo0, en0]), .ownAddress("en0"))
        XCTAssertEqual(choose("8.8.8.8", [lo0, en0]), .noMatch)
        XCTAssertEqual(choose("dash.local", [en0]), .notIPv4)
        XCTAssertEqual(choose("", [en0]), .notIPv4)
        XCTAssertEqual(choose("192.168.0.1", []), .noMatch)
    }

    func testDownLoopbackAndMaskLessInterfacesAreSkipped() {
        let down = InterfaceAddress(name: "en0", ipv4: "192.168.0.51", netmask: "255.255.255.0", isUp: false)
        let loopFlagged = InterfaceAddress(name: "lo1", ipv4: "192.168.0.60", netmask: "255.255.255.0", isLoopback: true)
        let oddMask = InterfaceAddress(name: "en3", ipv4: "192.168.0.70", netmask: "255.0.255.0")
        let noMask = InterfaceAddress(name: "en4", ipv4: "192.168.0.80", netmask: "0.0.0.0")
        XCTAssertEqual(choose("192.168.0.1", [down, loopFlagged, oddMask, noMask]), .noMatch)
        XCTAssertEqual(choose("192.168.0.1", [down, en0]), .subnet(en0))
    }

    func testDescriptionsForLogs() {
        XCTAssertEqual(OutboundInterfaceChoice.subnet(en0).description, "en0 192.168.0.51/24")
        XCTAssertEqual(OutboundInterfaceChoice.loopbackDestination.description, "unbound (loopback destination)")
        XCTAssertEqual(OutboundInterfaceChoice.ownAddress("en0").description, "unbound (our own address on en0)")
        XCTAssertEqual(OutboundInterfaceChoice.noMatch.description, "unbound (no local interface subnet contains it)")
    }

    func testProviderRouteUsesInjectedInterfacesAndTheInterfaceIndex() {
        let wifi = en0
        let bound = POSIXNetworkProvider(options: .init(interfaceProvider: { [wifi] }))
        let r = bound.route(to: "192.168.0.1")
        XCTAssertEqual(r.choice, .subnet(en0))
        if POSIXInterfaceBinding.isSupported {
            let index = POSIXInterfaceBinding.index(of: "en0")
            XCTAssertEqual(r.index, index == 0 ? nil : index)
        } else {
            XCTAssertNil(r.index, "no IP_BOUND_IF on this platform")
        }
        let unbound = POSIXNetworkProvider(options: .init(bindToInterface: false, interfaceProvider: { [wifi] }))
        XCTAssertNil(unbound.route(to: "192.168.0.1").index)
        XCTAssertEqual(bound.route(to: "127.0.0.1"), POSIXNetworkProvider.Route(choice: .loopbackDestination, index: nil))
        XCTAssertEqual(bound.route(to: "8.8.4.4").choice, .noMatch)
    }

    #if canImport(Darwin)
    /// IP_BOUND_IF plumbing: a socket pinned to lo0 still reaches a loopback listener and reports
    /// the index back.
    func testBoundInterfaceOptionRoundTripsOnLoopback() async throws {
        let index = POSIXInterfaceBinding.index(of: "lo0")
        XCTAssertNotEqual(index, 0)
        let net = POSIXNetworkProvider()
        let l = try net.openListener(port: 0)
        defer { l.close() }
        let fd = socket(AF_INET, rawSockStream, 0)
        defer { close(fd) }
        XCTAssertEqual(POSIXInterfaceBinding.bind(fd, toInterface: index), 0)
        XCTAssertEqual(POSIXInterfaceBinding.boundIndex(fd), index)
        async let accepted = l.accept()
        var addr = posixIPv4Address(host: "127.0.0.1", port: l.port)!
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(rc, 0, POSIXErrno.describe(errno))
        let s = try await accepted
        s.close()
    }
    #endif
}

// MARK: - Errors and Local Network denial

final class LinkPOSIXErrorMappingTests: XCTestCase {
    func testErrnoNames() {
        XCTAssertEqual(POSIXErrno.name(ECONNREFUSED), "ECONNREFUSED")
        XCTAssertEqual(POSIXErrno.name(ETIMEDOUT), "ETIMEDOUT")
        XCTAssertEqual(POSIXErrno.name(EHOSTUNREACH), "EHOSTUNREACH")
        XCTAssertEqual(POSIXErrno.name(ENETUNREACH), "ENETUNREACH")
        XCTAssertEqual(POSIXErrno.name(EADDRINUSE), "EADDRINUSE")
        XCTAssertEqual(POSIXErrno.name(EHOSTDOWN), "EHOSTDOWN")
        XCTAssertEqual(POSIXErrno.name(99_999), "errno 99999")
        XCTAssertTrue(POSIXErrno.describe(ECONNREFUSED).hasPrefix("ECONNREFUSED ("), POSIXErrno.describe(ECONNREFUSED))
    }

    private func connectError(_ code: Int32, synchronous: Bool = true, local: Bool = true, detect: Bool = true) -> TransportError {
        POSIXNetworkProvider.connectError(code, synchronous: synchronous, towardsLocalSubnet: local,
                                          detectLocalNetworkDenial: detect, target: "192.168.0.1:10930")
    }

    func testOnlyASynchronousHostUnreachableTowardsALocalSubnetIsALocalNetworkDenial() {
        XCTAssertEqual(connectError(EHOSTUNREACH), PlatformTransportErrors.localNetworkDeniedError)
        XCTAssertTrue(DashProbeClient.isLocalNetworkDenied(connectError(EHOSTUNREACH)))
        for e in [connectError(EHOSTUNREACH, synchronous: false), connectError(EHOSTUNREACH, local: false),
                  connectError(EHOSTUNREACH, detect: false)] {
            XCTAssertFalse(PlatformTransportErrors.isLocalNetworkDenied(e), "\(e)")
            guard case let .failed(m) = e else { return XCTFail("\(e)") }
            XCTAssertTrue(m.hasPrefix("EHOSTUNREACH: "), m)
            XCTAssertTrue(m.hasSuffix("(192.168.0.1:10930)"), m)
        }
        XCTAssertFalse(PlatformTransportErrors.isLocalNetworkDenied(connectError(ENETUNREACH)))
        XCTAssertFalse(PlatformTransportErrors.isLocalNetworkDenied(connectError(EHOSTDOWN)))
    }

    func testRefusedTimedOutAndOtherConnectErrors() {
        XCTAssertTrue(PlatformTransportErrors.isConnectionRefused(connectError(ECONNREFUSED)))
        XCTAssertEqual(connectError(ETIMEDOUT), .timeout)
        XCTAssertEqual(connectError(ETIMEDOUT, synchronous: false), .timeout)
        guard case let .failed(m) = connectError(ENETUNREACH) else { return XCTFail() }
        XCTAssertTrue(m.hasPrefix("ENETUNREACH: "), m)
    }

    func testStreamErrorsMatchTheNetworkFrameworkTable() {
        for code in [ECONNRESET, EPIPE, ENOTCONN, ESHUTDOWN, ECONNABORTED] {
            XCTAssertEqual(posixStreamError(code, "recv"), .closed, POSIXErrno.name(code))
        }
        XCTAssertEqual(posixStreamError(ETIMEDOUT, "send"), .timeout)
        guard case let .failed(m) = posixStreamError(EIO, "recv") else { return XCTFail() }
        XCTAssertTrue(m.hasPrefix("\(POSIXErrno.name(EIO)): recv failed"), m)
    }

    // MARK: Denial retry (connect(2) replaced by the test seam)

    /// connect(2) that answers EHOSTUNREACH for the first `denials` calls, then connects the socket
    /// to `redirectPort` on loopback.
    private final class ScriptedConnect: @unchecked Sendable {
        let calls = Locked(0)
        let denials: Int
        let redirectPort: UInt16

        init(denials: Int, redirectPort: UInt16 = 0) {
            self.denials = denials
            self.redirectPort = redirectPort
        }

        func call(_ fd: Int32, _ address: sockaddr_in) -> (rc: Int32, errno: Int32) {
            let n = calls.withLock { c -> Int in
                c += 1
                return c
            }
            if n <= denials { return (-1, EHOSTUNREACH) }
            var addr = posixIPv4Address(host: "127.0.0.1", port: redirectPort)!
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            return (rc, rc == 0 ? 0 : errno)
        }
    }

    /// The dash Wi-Fi as the only interface; IP_BOUND_IF off (the seam redirects to loopback).
    private func provider(_ script: ScriptedConnect, detect: Bool = true, interfaces: [InterfaceAddress]? = nil) -> POSIXNetworkProvider {
        let wifi = interfaces ?? [InterfaceAddress(name: "en0", ipv4: "192.0.2.10", netmask: "255.255.255.0")]
        let options = POSIXNetworkProvider.Options(bindToInterface: false, interfaceProvider: { wifi },
                                                   detectLocalNetworkDenial: detect, localNetworkRetryInterval: 0.1)
        return POSIXNetworkProvider(options: options, trace: nil, connectCall: { script.call($0, $1) })
    }

    func testAPersistentDenialIsRetriedUntilTheDeadlineThenReported() async throws {
        let script = ScriptedConnect(denials: .max)
        let net = provider(script)
        let t0 = now()
        do {
            let s = try await net.connect(host: "192.0.2.1", port: 10930, timeout: 0.6)
            s.close()
            XCTFail("connected")
        } catch {
            XCTAssertTrue(PlatformTransportErrors.isLocalNetworkDenied(error), "\(error)")
            XCTAssertTrue(DashProbeClient.isLocalNetworkDenied(error))
        }
        let dt = now() - t0
        XCTAssertGreaterThanOrEqual(dt, 0.4, "kept retrying while the alert may be open")
        XCTAssertLessThan(dt, 2.0)
        XCTAssertGreaterThanOrEqual(script.calls.current, 4)
        XCTAssertEqual(net.snapshot.connectDenied, 1)
    }

    func testADenialThatClearsDuringTheTimeoutConnects() async throws {
        let listener = try POSIXNetworkProvider().openListener(port: 0)
        defer { listener.close() }
        let script = ScriptedConnect(denials: 2, redirectPort: listener.port)
        let net = provider(script)
        async let accepted = listener.accept()
        let c = try await net.connect(host: "192.0.2.1", port: 10930, timeout: 3)
        let s = try await accepted
        defer { c.close(); s.close() }
        XCTAssertEqual(script.calls.current, 3)
        try await c.write(Data([1, 2, 3]))
        let got = try await s.read(exactly: 3)
        XCTAssertEqual(got, Data([1, 2, 3]))
        XCTAssertEqual(net.snapshot.connectDenied, 0)
        XCTAssertEqual(net.snapshot.connectsOK, 1)
    }

    func testHostUnreachableOffTheLocalSubnetsFailsAtOnce() async throws {
        let cases: [(detect: Bool, interfaces: [InterfaceAddress]?)] = [
            (true, [InterfaceAddress(name: "en0", ipv4: "10.0.0.5", netmask: "255.255.255.0")]), // not a local subnet
            (false, nil), // local subnet, detection off (Linux default)
        ]
        for (detect, interfaces) in cases {
            let script = ScriptedConnect(denials: .max)
            let net = provider(script, detect: detect, interfaces: interfaces)
            let t0 = now()
            do {
                let s = try await net.connect(host: "192.0.2.1", port: 10930, timeout: 2)
                s.close()
                XCTFail("connected")
            } catch {
                XCTAssertFalse(PlatformTransportErrors.isLocalNetworkDenied(error), "\(error)")
                guard case let .failed(m)? = error as? TransportError else { return XCTFail("\(error)") }
                XCTAssertTrue(m.hasPrefix("EHOSTUNREACH: "), m)
            }
            XCTAssertLessThan(now() - t0, 0.5)
            XCTAssertEqual(script.calls.current, 1)
        }
    }

    func testCancellationDuringDenialRetriesThrowsCancelled() async throws {
        let script = ScriptedConnect(denials: .max)
        let net = provider(script)
        let task = Task { () -> Error? in
            do {
                let s = try await net.connect(host: "192.0.2.1", port: 10930, timeout: 10)
                s.close()
                return nil
            } catch {
                return error
            }
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        let t0 = now()
        task.cancel()
        let error = await task.value
        XCTAssertEqual(error as? TransportError, .cancelled)
        XCTAssertLessThan(now() - t0, 1.0)
    }
}
