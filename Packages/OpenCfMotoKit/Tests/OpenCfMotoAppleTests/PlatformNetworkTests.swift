// SPDX-License-Identifier: AGPL-3.0-or-later
// NWNetworkProvider / NWByteStream / NWStreamListener over loopback (Apple platforms), the
// cellular HTTP client against a loopback server, plus the platform-neutral error helpers.

import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoApple

final class PlatformTransportErrorTests: XCTestCase {
    func testClassifiers() {
        XCTAssertTrue(PlatformTransportErrors.isAddressInUse(PlatformTransportErrors.addressInUse(port: 10922)))
        XCTAssertEqual(PlatformTransportErrors.addressInUse(port: 10922),
                       .failed("EADDRINUSE: address already in use (port 10922)"))
        XCTAssertTrue(PlatformTransportErrors.isLocalNetworkDenied(TransportError.failed("localNetworkDenied")))
        XCTAssertEqual(PlatformTransportErrors.localNetworkDeniedError, .failed("localNetworkDenied"))
        XCTAssertTrue(PlatformTransportErrors.isConnectionRefused(TransportError.failed("ECONNREFUSED: connection refused")))
        XCTAssertFalse(PlatformTransportErrors.isAddressInUse(TransportError.closed))
        XCTAssertFalse(PlatformTransportErrors.isLocalNetworkDenied(TransportError.timeout))
        XCTAssertFalse(PlatformTransportErrors.isConnectionRefused(CancellationError()))
    }

    func testOnceFlag() {
        let f = OCMOnceFlag()
        XCTAssertFalse(f.isClaimed)
        XCTAssertTrue(f.claim())
        XCTAssertFalse(f.claim())
        XCTAssertTrue(f.isClaimed)
    }

    func testOnceFlagUnderContention() {
        let f = OCMOnceFlag()
        let wins = Locked(0)
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if f.claim() { wins.withLock { $0 += 1 } }
        }
        XCTAssertEqual(wins.current, 1)
    }
}

#if canImport(Network)
import Network

final class PlatformNetworkTests: XCTestCase {
    private let provider = NWNetworkProvider(options: .anyInterface)

    /// Listener on an ephemeral loopback port + connected client/server stream pair.
    private func makePair() async throws -> (listener: NWStreamListener, client: NWByteStream, server: any ByteStream) {
        let listener = try await provider.openListener(port: 0)
        XCTAssertNotEqual(listener.port, 0)
        async let accepted = listener.accept()
        let client = try await provider.openStream(host: "127.0.0.1", port: listener.port, timeout: 5)
        let server = try await accepted
        return (listener, client, server)
    }

    func testLoopbackEchoAndEndpoints() async throws {
        let (listener, client, server) = try await makePair()
        defer { client.close(); server.close(); listener.close() }

        try await server.write(Data("hello".utf8))
        let got = try await withTimeout(5) { try await client.read(exactly: 5) }
        XCTAssertEqual(String(decoding: got, as: UTF8.self), "hello")

        try await client.write(Data("ping".utf8))
        let ping = try await withTimeout(5) { try await server.read(exactly: 4) }
        XCTAssertEqual(ping, Data("ping".utf8))

        XCTAssertEqual(server.localPort, listener.port)
        XCTAssertEqual(server.remoteHost, "127.0.0.1")
        XCTAssertEqual(client.remoteHost, "127.0.0.1")
        XCTAssertEqual(client.localHost, "127.0.0.1")
        XCTAssertNotEqual(client.localPort, 0)
        XCTAssertTrue(client.remoteEndpoint.hasSuffix(":\(listener.port)"))
        XCTAssertEqual(listener.acceptedConnections, 1)
    }

    func testExactLengthReadAcrossPartialWrites() async throws {
        let (listener, client, server) = try await makePair()
        defer { client.close(); server.close(); listener.close() }

        async let eight = withTimeout(5) { try await server.read(exactly: 8) }
        try await client.write(Data([1, 2, 3]))
        try await Task.sleep(nanoseconds: 80_000_000)
        try await client.write(Data([4, 5]))
        try await Task.sleep(nanoseconds: 80_000_000)
        try await client.write(Data([6, 7, 8, 9, 10]))
        let firstEight = try await eight
        XCTAssertEqual(firstEight, Data([1, 2, 3, 4, 5, 6, 7, 8]))
        // The surplus bytes stay buffered for the next read.
        let rest = try await withTimeout(5) { try await server.read(exactly: 2) }
        XCTAssertEqual(rest, Data([9, 10]))
    }

    func testReadSomeReturnsAtMostMaxCount() async throws {
        let (listener, client, server) = try await makePair()
        defer { client.close(); server.close(); listener.close() }
        try await client.write(Data(repeating: 7, count: 100))
        var total = 0
        while total < 100 {
            let chunk = try await withTimeout(5) { try await server.readSome(maxCount: 30) }
            XCTAssertGreaterThan(chunk.count, 0)
            XCTAssertLessThanOrEqual(chunk.count, 30)
            total += chunk.count
        }
        XCTAssertEqual(total, 100)
    }

    func testLargePayloadRoundTripAndOrderedWrites() async throws {
        let (listener, client, server) = try await makePair()
        defer { client.close(); server.close(); listener.close() }
        let big = Data((0 ..< 1_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        async let received = withTimeout(20) { try await server.read(exactly: big.count + 6) }
        // Concurrent writers: each frame must arrive whole (one send per write, in call order).
        try await client.write(big)
        try await client.write(Data("tail".utf8))
        try await client.write(Data("!!".utf8))
        let all = try await received
        XCTAssertEqual(all.prefix(big.count), big)
        XCTAssertEqual(all.suffix(6), Data("tail!!".utf8))
    }

    func testCloseWakesPendingReadExactlyOnce() async throws {
        let (listener, client, server) = try await makePair()
        defer { client.close(); listener.close() }
        let started = Date()
        let reader = Task { () -> Error? in
            do {
                _ = try await server.read(exactly: 10)
                return nil
            } catch {
                return error
            }
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        server.close()
        server.close() // idempotent
        let error = await reader.value
        XCTAssertEqual(error as? TransportError, .closed)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        do {
            _ = try await server.read(exactly: 1)
            XCTFail("read after close must throw")
        } catch {
            XCTAssertEqual(error as? TransportError, .closed)
        }
        do {
            try await server.write(Data([1]))
            XCTFail("write after close must throw")
        } catch {
            XCTAssertEqual(error as? TransportError, .closed)
        }
    }

    func testPeerCloseIsEOF() async throws {
        let (listener, client, server) = try await makePair()
        defer { server.close(); listener.close() }
        try await client.write(Data("bye".utf8))
        client.close()
        let bye = try await withTimeout(5) { try await server.read(exactly: 3) }
        XCTAssertEqual(bye, Data("bye".utf8))
        do {
            _ = try await withTimeout(5) { try await server.read(exactly: 1) }
            XCTFail("expected EOF")
        } catch {
            XCTAssertEqual(error as? TransportError, .closed)
        }
    }

    func testCancelledReadDoesNotLoseBytes() async throws {
        let (listener, client, server) = try await makePair()
        defer { client.close(); server.close(); listener.close() }
        // withTimeout cancels the read; the stream must stay usable and in sync.
        do {
            _ = try await withTimeout(0.2) { try await server.read(exactly: 4) }
            XCTFail("expected timeout")
        } catch {
            XCTAssertTrue(error is TimeoutError, "\(error)")
        }
        try await client.write(Data("ABCD".utf8))
        let abcd = try await withTimeout(5) { try await server.read(exactly: 4) }
        XCTAssertEqual(abcd, Data("ABCD".utf8))
    }

    func testListenerCloseWakesAccept() async throws {
        let listener = try await provider.openListener(port: 0)
        let waiter = Task { () -> Error? in
            do {
                _ = try await listener.accept()
                return nil
            } catch {
                return error
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        listener.close()
        let error = await waiter.value
        XCTAssertEqual(error as? TransportError, .closed)
    }

    func testAddressInUseIsReported() async throws {
        let strict = NWNetworkProvider(options: .init(requiredInterfaceType: nil, allowLocalEndpointReuse: false))
        let first = try await strict.openListener(port: 0)
        defer { first.close() }
        do {
            let second = try await strict.listen(port: first.port)
            second.close()
            XCTFail("second listener on the same port should fail")
        } catch {
            XCTAssertTrue(PlatformTransportErrors.isAddressInUse(error), "\(error)")
        }
    }

    func testConnectToClosedPortFailsWithinTimeout() async throws {
        // Find a free port, then close it again.
        let l = try await provider.openListener(port: 0)
        let port = l.port
        l.close()
        try await Task.sleep(nanoseconds: 100_000_000)
        let started = Date()
        do {
            let s = try await provider.connect(host: "127.0.0.1", port: port, timeout: 2)
            s.close()
            XCTFail("nothing listens there")
        } catch {
            XCTAssertNotNil(error as? TransportError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    func testConnectHonoursTaskCancellation() async throws {
        let wifiOnly = NWNetworkProvider() // Wi-Fi only: on CI the path is unsatisfied → waits
        let task = Task { () -> Error? in
            do {
                let s = try await wifiOnly.connect(host: "192.0.2.1", port: 10930, timeout: 30)
                s.close()
                return nil
            } catch {
                return error
            }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let started = Date()
        let error = await task.value
        XCTAssertNotNil(error)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    // MARK: Cellular HTTP client against a loopback HTTP server

    /// Serves one request: reads the head, answers with `response`, closes. Returns the request head.
    private func serveOnce(_ listener: NWStreamListener, response: Data, delayResponse: TimeInterval = 0) -> Task<String, Error> {
        Task {
            let conn = try await listener.accept()
            defer { conn.close() }
            var head = Data()
            while !head.contains(Data("\r\n\r\n".utf8)) {
                head.append(try await conn.readSome(maxCount: 4096))
            }
            if delayResponse > 0 { try await Task.sleep(nanoseconds: UInt64(delayResponse * 1_000_000_000)) }
            try await conn.write(response)
            return String(decoding: head, as: UTF8.self)
        }
    }

    func testCellularClientChunkedResponseOverLoopback() async throws {
        let listener = try await provider.openListener(port: 0)
        defer { listener.close() }
        let body = "{\"routes\":[1,2,3]}"
        let chunked = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "7\r\n{\"route\r\nB\r\ns\":[1,2,3]}\r\n0\r\n\r\n"
        let server = serveOnce(listener, response: Data(chunked.utf8))
        let client = CellularHTTPClient(options: .init(requiredInterfaceType: nil, userAgent: "OCM-Test/1"))
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(listener.port)/route/v1?x=1"))
        let r = try await client.send(HTTPRequest(url: url, headers: ["Accept": "application/json"], timeout: 5))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.headers["content-type"], "application/json")
        XCTAssertEqual(r.bodyString, body)
        let head = try await server.value
        XCTAssertTrue(head.hasPrefix("GET /route/v1?x=1 HTTP/1.1\r\n"), head)
        XCTAssertTrue(head.contains("\r\nHost: 127.0.0.1:\(listener.port)\r\n"), head)
        XCTAssertTrue(head.contains("\r\nUser-Agent: OCM-Test/1\r\n"), head)
        XCTAssertTrue(head.contains("\r\nAccept-Encoding: identity\r\n"), head)
        XCTAssertTrue(head.contains("\r\nConnection: close\r\n"), head)
    }

    func testCellularClientCloseDelimitedAndStatusPassthrough() async throws {
        let listener = try await provider.openListener(port: 0)
        defer { listener.close() }
        let server = serveOnce(listener, response: Data("HTTP/1.0 503 Service Unavailable\r\n\r\nbusy".utf8))
        let client = CellularHTTPClient(options: .init(requiredInterfaceType: nil))
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(listener.port)/"))
        let r = try await client.send(HTTPRequest(url: url, timeout: 5))
        XCTAssertEqual(r.status, 503)
        XCTAssertEqual(r.bodyString, "busy")
        _ = try await server.value
    }

    func testCellularClientTimeout() async throws {
        let listener = try await provider.openListener(port: 0)
        defer { listener.close() }
        let server = serveOnce(listener, response: Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8), delayResponse: 4)
        let client = CellularHTTPClient(options: .init(requiredInterfaceType: nil))
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(listener.port)/slow"))
        let started = Date()
        do {
            _ = try await client.send(HTTPRequest(url: url, timeout: 1))
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? HTTPClientError, .timeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3.5)
        server.cancel()
    }

    func testCellularClientWithoutCellularIsNoNetwork() async throws {
        // macOS test hosts have no cellular interface: the pinned path is unsatisfied.
        let client = CellularHTTPClient()
        let started = Date()
        do {
            _ = try await client.send(HTTPRequest(url: URL(string: "https://example.com/")!, timeout: 5))
            XCTFail("expected noNetwork")
        } catch {
            // Expected: the unsatisfied cellular path reports `.waiting` → noNetwork (fast fallback).
            let e = error as? HTTPClientError
            XCTAssertTrue(e == .noNetwork || e == .timeout, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 6.5)
    }

    // MARK: Wi-Fi info / Bonjour (smoke: must return promptly on hosts without Wi-Fi / mDNS)

    func testWiFiSnapshotReturnsPromptly() async {
        let started = Date()
        let s = await WiFiInfo.currentSnapshot(timeout: 1.0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertFalse(s.description.isEmpty)
    }

    func testBonjourDiscoveryFindsAdvertisedTXTEndpoint() async throws {
        // Advertise a fake dash (TXT ip/port) and discover it; skipped when mDNS is unavailable.
        let name = "OCM-Test-\(UInt32.random(in: 0 ... UInt32.max))"
        var txt = Data()
        for entry in ["ip=192.168.0.1", "port=10930", "huname=TestDash"] {
            let bytes = Array(entry.utf8)
            txt.append(UInt8(bytes.count))
            txt.append(contentsOf: bytes)
        }
        let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        let advertiser = try NWListener(using: params)
        advertiser.service = NWListener.Service(name: name, type: EasyConnTXT.serviceType, domain: nil, txtRecord: txt)
        advertiser.newConnectionHandler = { $0.cancel() }
        advertiser.start(queue: DispatchQueue(label: "ocm.test.advertiser"))
        defer { advertiser.cancel() }

        let discovery = BonjourDashDiscovery(requiredInterfaceType: nil, resolveTimeout: 2)
        let started = Date()
        let found = await discovery.discover(timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
        guard !found.isEmpty else {
            throw XCTSkip("Bonjour unavailable on this host (denied: \(discovery.lastBrowseDenied))")
        }
        XCTAssertTrue(found.contains { $0.host == "192.168.0.1" && $0.port == 10930 && $0.txt["huname"] == "TestDash" }, "\(found)")
    }

    func testBonjourDiscoveryTimesOutWithNothing() async {
        let discovery = BonjourDashDiscovery(serviceType: "_ocmnone._tcp", requiredInterfaceType: nil)
        let started = Date()
        let found = await discovery.discover(timeout: 0.5)
        XCTAssertTrue(found.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
}
#endif
