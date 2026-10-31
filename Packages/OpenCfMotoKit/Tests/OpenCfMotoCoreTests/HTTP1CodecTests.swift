// SPDX-License-Identifier: AGPL-3.0-or-later
// HTTP/1.1 codec (request serializer + incremental response parser) and the per-host throttle.

import XCTest
@testable import OpenCfMotoCore

final class HTTP1CodecTests: XCTestCase {
    private func text(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }

    func testSerializeGetWithQueryAndDefaults() {
        let url = URL(string: "https://router.project-osrm.org/route/v1/driving/26.1,44.43;26.115,44.44?overview=full&alternatives=2")!
        let req = HTTPRequest(url: url, headers: ["Accept": "application/json", "Connection": "keep-alive", "Host": "evil"])
        XCTAssertEqual(text(HTTP1.serialize(req, userAgent: "UA/1")),
                       "GET /route/v1/driving/26.1,44.43;26.115,44.44?overview=full&alternatives=2 HTTP/1.1\r\n"
                           + "Host: router.project-osrm.org\r\n"
                           + "User-Agent: UA/1\r\n"
                           + "Accept: application/json\r\n"
                           + "Accept-Encoding: identity\r\n"
                           + "Connection: close\r\n\r\n")
    }

    func testSerializePostWithBodyPortAndOwnUserAgent() {
        let url = URL(string: "http://127.0.0.1:8080")!
        let body = Data("data=x".utf8)
        let req = HTTPRequest(url: url, method: "post", headers: ["Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
                                                                   "user-agent": "Mine\r\nX-Injected: 1"], body: body)
        let s = text(HTTP1.serialize(req, userAgent: "UA/1"))
        XCTAssertTrue(s.hasPrefix("POST / HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n"))
        XCTAssertTrue(s.contains("user-agent: MineX-Injected: 1\r\n"))
        XCTAssertFalse(s.contains("User-Agent: UA/1"))
        XCTAssertTrue(s.hasSuffix("Content-Length: 6\r\n\r\ndata=x"))
        XCTAssertEqual(HTTP1.port(for: url), 8080)
        XCTAssertEqual(HTTP1.port(for: URL(string: "https://a.b/c")!), 443)
        XCTAssertEqual(HTTP1.hostHeader(for: URL(string: "https://a.b:443/c")!), "a.b")
        XCTAssertEqual(HTTP1.requestTarget(for: URL(string: "https://a.b")!), "/")
        XCTAssertEqual(HTTP1.requestTarget(for: URL(string: "https://a.b/x%20y?q=C%C3%A2m+p")!), "/x%20y?q=C%C3%A2m+p")
        // Empty POST still carries Content-Length: 0.
        XCTAssertTrue(text(HTTP1.serialize(HTTPRequest(url: url, method: "POST"), userAgent: nil)).hasSuffix("Content-Length: 0\r\n\r\n"))
    }

    func testParseContentLengthInPieces() throws {
        let raw = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\nX-A: 1\r\nx-a: 2\r\n\r\n{\"ok\":true}EXTRA"
        var p = HTTP1.ResponseParser()
        var done = false
        for b in Array(raw.utf8) { done = try p.feed(Data([b])) || done }
        XCTAssertTrue(done)
        let r = try XCTUnwrap(p.response)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.headers["content-type"], "application/json")
        XCTAssertEqual(r.headers["x-a"], "1, 2")
        XCTAssertEqual(r.bodyString, "{\"ok\":true}")
    }

    func testParseChunkedWithExtensionsAndTrailers() throws {
        let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n4;name=x\r\nWiki\r\n5\r\npedia\r\nE\r\n in\r\n\r\nchunks.\r\n0\r\nX-Trailer: yes\r\n\r\n"
        let r = try HTTP1.parseResponse(Data(raw.utf8))
        XCTAssertEqual(r.bodyString, "Wikipedia in\r\n\r\nchunks.")
        XCTAssertEqual(r.headers["x-trailer"], "yes")
        // Split at awkward boundaries.
        var p = HTTP1.ResponseParser()
        let bytes = Array(raw.utf8)
        var i = 0
        while i < bytes.count {
            let n = min(3, bytes.count - i)
            _ = try p.feed(Data(bytes[i ..< i + n]))
            i += n
        }
        XCTAssertEqual(p.response?.bodyString, "Wikipedia in\r\n\r\nchunks.")
    }

    func testReadUntilCloseInterimAndNoBodyStatuses() throws {
        var p = HTTP1.ResponseParser()
        XCTAssertFalse(try p.feed(Data("HTTP/1.0 200 OK\r\nServer: x\r\n\r\nhello ".utf8)))
        XCTAssertFalse(try p.feed(Data("world".utf8)))
        XCTAssertEqual(try p.finish().bodyString, "hello world")
        let interim = try HTTP1.parseResponse(Data("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 404 Not Found\r\nContent-Length: 2\r\n\r\nno".utf8))
        XCTAssertEqual(interim.status, 404)
        XCTAssertEqual(interim.bodyString, "no")
        XCTAssertEqual(try HTTP1.parseResponse(Data("HTTP/1.1 204 No Content\r\n\r\n".utf8)).body, Data())
        XCTAssertEqual(try HTTP1.parseResponse(Data("HTTP/1.1 304 Not Modified\r\nContent-Length: 50\r\n\r\n".utf8)).status, 304)
        XCTAssertEqual(try HTTP1.parseResponse(Data("HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\n".utf8), isHeadRequest: true).body, Data())
        // LF-only line endings are tolerated.
        XCTAssertEqual(try HTTP1.parseResponse(Data("HTTP/1.1 200 OK\nContent-Length: 1\n\nx".utf8)).bodyString, "x")
    }

    func testErrors() {
        XCTAssertThrowsError(try HTTP1.parseResponse(Data("FTP 200 OK\r\n\r\n".utf8))) { e in
            XCTAssertEqual(e as? HTTP1.ParseError, .malformedStatusLine("FTP 200 OK"))
        }
        XCTAssertThrowsError(try HTTP1.parseResponse(Data("HTTP/1.1 200 OK\r\nBad header\r\n\r\n".utf8)))
        XCTAssertThrowsError(try HTTP1.parseResponse(Data("HTTP/1.1 200 OK\r\nContent-Length: 1, 2\r\n\r\nab".utf8))) { e in
            XCTAssertEqual(e as? HTTP1.ParseError, .invalidContentLength("1, 2"))
        }
        XCTAssertThrowsError(try HTTP1.parseResponse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n".utf8)))
        XCTAssertThrowsError(try HTTP1.parseResponse(Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc".utf8))) { e in
            XCTAssertEqual(e as? HTTP1.ParseError, .unexpectedEOF)
        }
        XCTAssertThrowsError(try HTTP1.parseResponse(Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n0123456789".utf8), maxBodyBytes: 5)) { e in
            XCTAssertEqual(e as? HTTP1.ParseError, .bodyTooLarge(5))
        }
        var p = HTTP1.ResponseParser(maxHeaderBytes: 32)
        XCTAssertThrowsError(try p.feed(Data(("HTTP/1.1 200 OK\r\nX: " + String(repeating: "a", count: 64)).utf8)))
        XCTAssertEqual(HTTP1.ParseError.bodyTooLarge(5).description, "Response too large (> 5 bytes)")
    }

    // MARK: Throttle

    func testThrottledClientSpacingPerHostAndUserAgent() async throws {
        let clock = NavManualClock(100)
        let slept = Locked<[Double]>([])
        let base = NavFakeHTTPClient { _ in .navOK(Data("{}".utf8)) }
        let client = ThrottledHTTPClient(base: base, userAgent: { "TestUA/1" }, clock: clock,
                                         sleep: { s in slept.withLock { $0.append(s) } })
        let osrm = URL(string: "https://router.project-osrm.org/route/v1/driving/1,2;3,4")!
        let photon = URL(string: "https://photon.komoot.io/api/?q=x")!
        _ = try await client.send(HTTPRequest(url: osrm))
        _ = try await client.send(HTTPRequest(url: osrm))   // +0.6 s
        _ = try await client.send(HTTPRequest(url: photon)) // other host: no wait
        clock.advance(0.2)
        _ = try await client.send(HTTPRequest(url: osrm))   // slot 101.2 → wait 1.0 s from 100.2
        XCTAssertEqual(slept.current.count, 2)
        XCTAssertEqual(slept.current[0], 0.6, accuracy: 1e-9)
        XCTAssertEqual(slept.current[1], 1.0, accuracy: 1e-9)
        XCTAssertEqual(base.requests.map { $0.headers["User-Agent"] }, Array(repeating: "TestUA/1", count: 4))
        // An explicit User-Agent is kept; unknown hosts are not throttled.
        _ = try await client.send(HTTPRequest(url: URL(string: "https://tile.openstreetmap.org/1/2/3.png")!, headers: ["user-agent": "Mine"]))
        XCTAssertEqual(base.requests.last?.headers["user-agent"], "Mine")
        XCTAssertNil(base.requests.last?.headers["User-Agent"])
        XCTAssertEqual(client.reserveSlot(host: "tile.openstreetmap.org"), 0)
        // Nominatim 1.1 s, Overpass 1.0 s, Valhalla 0.5 s, ORS 0.4 s.
        XCTAssertEqual(client.reserveSlot(host: "nominatim.openstreetmap.org"), 0)
        XCTAssertEqual(client.reserveSlot(host: "NOMINATIM.openstreetmap.org"), 1.1, accuracy: 1e-9)
        XCTAssertEqual(client.reserveSlot(host: "overpass-api.de"), 0)
        XCTAssertEqual(client.reserveSlot(host: "overpass-api.de"), 1.0, accuracy: 1e-9)
        XCTAssertEqual(client.reserveSlot(host: "valhalla1.openstreetmap.de"), 0)
        XCTAssertEqual(client.reserveSlot(host: "valhalla1.openstreetmap.de"), 0.5, accuracy: 1e-9)
        XCTAssertEqual(client.reserveSlot(host: "api.openrouteservice.org"), 0)
        XCTAssertEqual(client.reserveSlot(host: "api.openrouteservice.org"), 0.4, accuracy: 1e-9)
    }

    func testThrottledClientSizeCaps() async throws {
        let big = Data(count: 9 * 1024 * 1024)
        let base = NavFakeHTTPClient { _ in HTTPResponse(status: 200, body: big) }
        let client = ThrottledHTTPClient(base: base, clock: NavManualClock(), sleep: { _ in })
        do {
            _ = try await client.send(HTTPRequest(url: URL(string: "https://photon.komoot.io/api/?q=x")!))
            XCTFail("expected cap")
        } catch {
            XCTAssertEqual(error as? NavServiceError, .responseTooLarge)
            XCTAssertEqual(NavServiceError.message(for: error, fallback: ""), "Response too large")
        }
        // Route hosts accept 24 MiB; unknown hosts use the default cap unless disabled.
        let r = try await client.send(HTTPRequest(url: URL(string: "https://valhalla1.openstreetmap.de/route")!))
        XCTAssertEqual(r.body.count, big.count)
        let unlimited = ThrottledHTTPClient(base: base, defaultMaxBytes: nil, clock: NavManualClock(), sleep: { _ in })
        let t = try await unlimited.send(HTTPRequest(url: URL(string: "https://tile.openstreetmap.org/1/1/1.png")!))
        XCTAssertEqual(t.body.count, big.count)
    }

    func testNavHTTPRequestBuilders() {
        let g = NavHTTP.getRequest(URL(string: "https://x.y/z")!)
        XCTAssertEqual(g.headers, ["Accept": "application/json"])
        XCTAssertEqual(g.timeout, 20)
        let f = NavHTTP.postFormRequest(URL(string: "https://x.y/z")!, formBody: "data=1")
        XCTAssertEqual(f.headers["Content-Type"], "application/x-www-form-urlencoded; charset=UTF-8")
        XCTAssertEqual(f.timeout, 45)
        let j = NavHTTP.postJSONRequest(URL(string: "https://x.y/z")!, json: "{}", policy: .ors, extraHeaders: ["Authorization": "k"])
        XCTAssertEqual(j.headers["Accept"], "application/json, application/geo+json")
        XCTAssertEqual(j.headers["Content-Type"], "application/json; charset=UTF-8")
        XCTAssertEqual(j.headers["Authorization"], "k")
        XCTAssertEqual(j.timeout, 55)
        XCTAssertEqual(NavHTTPPolicy.osrmFull.maxBytes, 24 * 1024 * 1024)
        XCTAssertEqual(NavHTTPPolicy.osrmSimplified.totalTimeout, 70)
    }
}
