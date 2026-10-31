// SPDX-License-Identifier: AGPL-3.0-or-later
// Tests of the private HTTP/1.1 codec used by CellularHTTPClient (Foundation-only: runs on Linux too).

import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoApple

final class PlatformHTTP1Tests: XCTestCase {
    private typealias Parser = CellularHTTP1.ResponseParser

    private func parse(_ text: String, head: Bool = false, max: Int = 1 << 20, byteByByte: Bool = false,
                       eof: Bool = false) throws -> HTTPResponse {
        var p = Parser(isHeadRequest: head, maxBodyBytes: max)
        let bytes = Data(text.utf8)
        var complete = false
        if byteByByte {
            for b in bytes { complete = try p.feed(Data([b])) || complete }
        } else {
            complete = try p.feed(bytes)
        }
        if eof { return try p.finishAtEOF() }
        XCTAssertTrue(complete, "response should be complete")
        return try XCTUnwrap(p.response)
    }

    // MARK: Response parsing

    func testContentLengthBody() throws {
        let r = try parse("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"ok\":true}")
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.headers["content-type"], "application/json")
        XCTAssertEqual(r.bodyString, "{\"ok\":true}")
    }

    func testChunkedWikipediaExampleWholeAndByteByByte() throws {
        let raw = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "4\r\nWiki\r\n6\r\npedia \r\nE\r\nin \r\n\r\nchunks.\r\n0\r\n\r\n"
        let expected = "Wikipedia in \r\n\r\nchunks."
        XCTAssertEqual(try parse(raw).bodyString, expected)
        XCTAssertEqual(try parse(raw, byteByByte: true).bodyString, expected)
    }

    func testChunkedSplitAtEveryBoundary() throws {
        let raw = Data(("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "5\r\nhello\r\n1;ext=1\r\n \r\n5\r\nworld\r\n0\r\n\r\n").utf8)
        for cut in 1 ..< raw.count {
            var p = Parser()
            _ = try p.feed(raw.prefix(cut))
            let done = try p.feed(raw.suffix(from: cut))
            XCTAssertTrue(done, "cut \(cut)")
            XCTAssertEqual(p.response?.bodyString, "hello world", "cut \(cut)")
        }
    }

    func testChunkExtensionsTrailersAndUppercaseHex() throws {
        let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "A;name=value\r\n0123456789\r\n0\r\nX-Checksum: abc\r\nX-Other: 1\r\n\r\n"
        let r = try parse(raw)
        XCTAssertEqual(r.bodyString, "0123456789")
        XCTAssertNil(r.headers["x-checksum"], "trailer fields are ignored")
    }

    func testTransferEncodingWinsOverContentLength() throws {
        let raw = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n"
        XCTAssertEqual(try parse(raw).bodyString, "abc")
    }

    func testCloseDelimitedBodyCompletesAtEOF() throws {
        let raw = "HTTP/1.0 200 OK\r\nServer: x\r\n\r\nline1\nline2"
        var p = Parser()
        XCTAssertFalse(try p.feed(Data(raw.utf8)))
        XCTAssertFalse(p.isComplete)
        let r = try p.finishAtEOF()
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.bodyString, "line1\nline2")
    }

    func testHeadAnd204And304HaveNoBody() throws {
        let head = try parse("HTTP/1.1 200 OK\r\nContent-Length: 1234\r\n\r\n", head: true)
        XCTAssertEqual(head.body.count, 0)
        XCTAssertEqual(head.headers["content-length"], "1234")
        XCTAssertEqual(try parse("HTTP/1.1 204 No Content\r\nContent-Length: 5\r\n\r\n").status, 204)
        XCTAssertEqual(try parse("HTTP/1.1 304 Not Modified\r\nETag: \"x\"\r\n\r\n").body.count, 0)
    }

    func testZeroContentLengthCompletesImmediately() throws {
        let r = try parse("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
        XCTAssertEqual(r.status, 404)
        XCTAssertFalse(r.isSuccess)
        XCTAssertTrue(r.body.isEmpty)
    }

    func testInformationalResponsesAreSkipped() throws {
        var p = Parser()
        let raw = "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 103 Early Hints\r\nLink: </a>\r\n\r\n"
            + "HTTP/1.1 201 Created\r\nContent-Length: 2\r\n\r\nok"
        XCTAssertTrue(try p.feed(Data(raw.utf8)))
        XCTAssertEqual(p.informationalResponsesSkipped, 2)
        XCTAssertEqual(p.response?.status, 201)
        XCTAssertNil(p.response?.headers["link"])
        XCTAssertEqual(p.response?.bodyString, "ok")
    }

    func test101IsRejected() {
        XCTAssertThrowsError(try parse("HTTP/1.1 101 Switching Protocols\r\nUpgrade: h2c\r\n\r\n"))
    }

    func testHeadersLowercasedDuplicatesJoinedAndObsFold() throws {
        let raw = "HTTP/1.1 200 OK\r\nX-A: one\r\nx-a: two\r\nX-Long: part1\r\n  part2\r\nCache-Control:  max-age=60  \r\n"
            + "Content-Length: 0\r\n\r\n"
        let r = try parse(raw)
        XCTAssertEqual(r.headers["x-a"], "one, two")
        XCTAssertEqual(r.headers["x-long"], "part1 part2")
        XCTAssertEqual(r.headers["cache-control"], "max-age=60")
        XCTAssertNil(r.headers["Cache-Control"], "names are lower-cased")
    }

    func testHeaderNameWithWhitespaceIsMalformed() {
        // RFC 9112 §5.1: no whitespace between the field name and the colon.
        XCTAssertThrowsError(try parse("HTTP/1.1 200 OK\r\nBad Name: x\r\n\r\n"))
        XCTAssertThrowsError(try parse("HTTP/1.1 200 OK\r\nCache-Control : x\r\n\r\n"))
    }

    func testLFOnlyLineEndingsAreTolerated() throws {
        let r = try parse("HTTP/1.1 200 OK\nContent-Length: 3\n\nabc")
        XCTAssertEqual(r.bodyString, "abc")
    }

    func testLeadingEmptyLineBeforeStatusIsTolerated() throws {
        XCTAssertEqual(try parse("\r\nHTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nx").bodyString, "x")
    }

    func testBytesAfterCompleteResponseAreIgnored() throws {
        var p = Parser()
        XCTAssertTrue(try p.feed(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nokEXTRA".utf8)))
        XCTAssertTrue(try p.feed(Data("more".utf8)))
        XCTAssertEqual(p.response?.bodyString, "ok")
    }

    func testRepeatedIdenticalContentLengthIsAccepted() throws {
        XCTAssertEqual(try parse("HTTP/1.1 200 OK\r\nContent-Length: 3, 3\r\n\r\nabc").bodyString, "abc")
    }

    func testConflictingOrInvalidContentLengthIsRejected() {
        XCTAssertThrowsError(try parse("HTTP/1.1 200 OK\r\nContent-Length: 3, 4\r\n\r\nabc"))
        XCTAssertThrowsError(try parse("HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n"))
        XCTAssertThrowsError(try parse("HTTP/1.1 200 OK\r\nContent-Length: 1x\r\n\r\n"))
    }

    func testMalformedStatusLines() {
        XCTAssertThrowsError(try parse("HTTX/1.1 200 OK\r\n\r\n"))
        XCTAssertThrowsError(try parse("HTTP/1.1 20 OK\r\n\r\n"))
        XCTAssertThrowsError(try parse("HTTP/1.1 abc OK\r\n\r\n"))
        XCTAssertThrowsError(try parse("HTTP/1.1\r\n\r\n"))
    }

    func testStatusWithoutReasonPhrase() throws {
        var p = Parser()
        XCTAssertTrue(try p.feed(Data("HTTP/1.1 200\r\nContent-Length: 0\r\n\r\n".utf8)))
        XCTAssertEqual(p.response?.status, 200)
        XCTAssertEqual(p.reason, "")
    }

    func testBadChunkSizeAndMissingChunkCRLF() {
        XCTAssertThrowsError(try parse("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n"))
        XCTAssertThrowsError(try parse("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n+3\r\nabc\r\n0\r\n\r\n"))
        XCTAssertThrowsError(try parse("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabcX\r\n0\r\n\r\n"))
    }

    func testTruncationAtEOFThrows() {
        var a = Parser()
        XCTAssertThrowsError(try a.finishAtEOF()) { e in
            XCTAssertEqual(e as? CellularHTTP1.Failure, .truncated("connection closed before any response"))
        }
        var b = Parser()
        _ = try? b.feed(Data("HTTP/1.1 200 OK\r\nContent-Le".utf8))
        XCTAssertThrowsError(try b.finishAtEOF())
        var c = Parser()
        _ = try? c.feed(Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc".utf8))
        XCTAssertThrowsError(try c.finishAtEOF()) { e in
            XCTAssertEqual(e as? CellularHTTP1.Failure, .truncated("connection closed with 7 body byte(s) missing"))
        }
        var d = Parser()
        _ = try? d.feed(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nab".utf8))
        XCTAssertThrowsError(try d.finishAtEOF())
    }

    func testMissingFinalCRLFAfterLastChunkIsAcceptedAtEOF() throws {
        var p = Parser()
        XCTAssertFalse(try p.feed(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok\r\n0\r\n".utf8)))
        XCTAssertEqual(try p.finishAtEOF().bodyString, "ok")
    }

    func testSizeCaps() {
        XCTAssertThrowsError(try parse("HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n", max: 10)) { e in
            XCTAssertEqual(e as? CellularHTTP1.Failure, .tooLarge(10))
        }
        XCTAssertThrowsError(try parse("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n6\r\nabcdef\r\n6\r\nghijkl\r\n0\r\n\r\n", max: 10))
        var p = Parser(maxBodyBytes: 4)
        XCTAssertThrowsError(try p.feed(Data("HTTP/1.1 200 OK\r\n\r\nabcde".utf8)))
        XCTAssertEqual(try parse("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n0123456789", max: 10).body.count, 10)
    }

    func testHeaderSizeCap() {
        var p = Parser(maxHeaderBytes: 256)
        let big = "HTTP/1.1 200 OK\r\nX-Big: " + String(repeating: "a", count: 300) + "\r\n\r\n"
        XCTAssertThrowsError(try p.feed(Data(big.utf8)))
    }

    func testBinaryBodyIsPreserved() throws {
        var p = Parser()
        var raw = Data("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 6\r\n\r\n".utf8)
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x0D, 0x0A, 0x00]
        raw.append(contentsOf: png)
        XCTAssertTrue(try p.feed(raw))
        XCTAssertEqual([UInt8](p.response!.body), png)
    }

    // MARK: Target / request serialisation

    func testTargetForHTTPSDefaultPort() throws {
        let t = try CellularHTTP1.target(for: URL(string: "https://tile.openstreetmap.org/12/3/4.png")!)
        XCTAssertEqual(t, CellularHTTP1.Target(isTLS: true, host: "tile.openstreetmap.org", port: 443,
                                               requestTarget: "/12/3/4.png", hostHeader: "tile.openstreetmap.org"))
    }

    func testTargetKeepsPercentEncodedQueryAndNonDefaultPort() throws {
        let t = try CellularHTTP1.target(for: URL(string: "http://example.com:8080/search?q=Calle%2080&format=json")!)
        XCTAssertFalse(t.isTLS)
        XCTAssertEqual(t.port, 8080)
        XCTAssertEqual(t.requestTarget, "/search?q=Calle%2080&format=json")
        XCTAssertEqual(t.hostHeader, "example.com:8080")
    }

    func testTargetIPv6LiteralAndEmptyPath() throws {
        let t = try CellularHTTP1.target(for: URL(string: "http://[::1]:8080")!)
        XCTAssertEqual(t.host, "::1")
        XCTAssertEqual(t.hostHeader, "[::1]:8080")
        XCTAssertEqual(t.requestTarget, "/")
        let u = try CellularHTTP1.target(for: URL(string: "http://example.com:80?x=1")!)
        XCTAssertEqual(u.hostHeader, "example.com")
        XCTAssertEqual(u.requestTarget, "/?x=1")
    }

    func testTargetRejectsUnsupportedSchemes() {
        XCTAssertThrowsError(try CellularHTTP1.target(for: URL(string: "ftp://example.com/x")!))
        XCTAssertThrowsError(try CellularHTTP1.target(for: URL(string: "file:///tmp/x")!))
    }

    func testSerializeSimpleGet() throws {
        let url = URL(string: "https://tile.openstreetmap.org/12/3/4.png")!
        let t = try CellularHTTP1.target(for: url)
        let bytes = CellularHTTP1.serializeRequest(HTTPRequest(url: url), target: t, userAgent: "UA/1")
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self),
                       "GET /12/3/4.png HTTP/1.1\r\nHost: tile.openstreetmap.org\r\nUser-Agent: UA/1\r\n"
                       + "Accept-Encoding: identity\r\nConnection: close\r\n\r\n")
    }

    func testSerializeHeadersOrderControlledHeadersAndCallerUserAgent() throws {
        let url = URL(string: "https://router.example/route?x=1")!
        let req = HTTPRequest(url: url, method: "get", headers: [
            "Accept": "application/json", "Host": "evil", "Connection": "keep-alive", "Accept-Encoding": "gzip",
            "user-agent": "Caller/2", "X-Api-Key": "k",
        ])
        let s = String(decoding: CellularHTTP1.serializeRequest(req, target: try CellularHTTP1.target(for: url), userAgent: "UA/1"),
                       as: UTF8.self)
        XCTAssertEqual(s, "GET /route?x=1 HTTP/1.1\r\nHost: router.example\r\nAccept: application/json\r\n"
                       + "user-agent: Caller/2\r\nX-Api-Key: k\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n")
    }

    func testSerializePostWithAndWithoutBody() throws {
        let url = URL(string: "https://api.example/v1/route")!
        let t = try CellularHTTP1.target(for: url)
        let body = Data("{\"a\":1}".utf8)
        let s = String(decoding: CellularHTTP1.serializeRequest(
            HTTPRequest(url: url, method: "POST", headers: ["Content-Type": "application/json; charset=UTF-8"], body: body),
            target: t, userAgent: nil), as: UTF8.self)
        XCTAssertEqual(s, "POST /v1/route HTTP/1.1\r\nHost: api.example\r\nContent-Type: application/json; charset=UTF-8\r\n"
                       + "Accept-Encoding: identity\r\nConnection: close\r\nContent-Length: 7\r\n\r\n{\"a\":1}")
        let empty = String(decoding: CellularHTTP1.serializeRequest(HTTPRequest(url: url, method: "POST"), target: t, userAgent: nil),
                           as: UTF8.self)
        XCTAssertTrue(empty.hasSuffix("Content-Length: 0\r\n\r\n"))
    }

    func testSerializeStripsHeaderInjection() throws {
        let url = URL(string: "http://x.example/")!
        let req = HTTPRequest(url: url, headers: ["X-Ok": "a\r\nX-Evil: 1", "Bad Name": "v", "X\nY": "z"])
        let s = String(decoding: CellularHTTP1.serializeRequest(req, target: try CellularHTTP1.target(for: url), userAgent: nil),
                       as: UTF8.self)
        XCTAssertTrue(s.contains("X-Ok: aX-Evil: 1\r\n"))
        XCTAssertFalse(s.contains("Bad Name"))
        XCTAssertFalse(s.contains("X\nY"))
        XCTAssertEqual(s.components(separatedBy: "\r\n").filter { $0.hasPrefix("X-Evil") }.count, 0)
    }

    func testFailureDescriptions() {
        XCTAssertEqual(CellularHTTP1.Failure.tooLarge(5).description, "Response too large (> 5 bytes)")
        XCTAssertTrue(CellularHTTP1.Failure.truncated("x").description.contains("truncated"))
    }
}
