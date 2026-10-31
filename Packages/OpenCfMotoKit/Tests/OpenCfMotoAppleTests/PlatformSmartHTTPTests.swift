// SPDX-License-Identifier: AGPL-3.0-or-later
// SmartHTTPClient routing / fallback rules and the URLError mapping (Foundation-only: runs on Linux).

import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoApple
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class FakeHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private let handler: @Sendable (HTTPRequest) async throws -> HTTPResponse

    init(_ handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) {
        self.handler = handler
    }

    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }

    private func countCall() { lock.lock(); _calls += 1; lock.unlock() }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        countCall()
        return try await handler(request)
    }

    static func ok(_ tag: String) -> FakeHTTPClient {
        FakeHTTPClient { _ in HTTPResponse(status: 200, body: Data(tag.utf8)) }
    }

    static func failing(_ error: Error) -> FakeHTTPClient {
        FakeHTTPClient { _ in throw error }
    }
}

private final class ManualClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 1000
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t += s; lock.unlock() }
}

final class PlatformSmartHTTPTests: XCTestCase {
    private let request = HTTPRequest(url: URL(string: "https://tile.openstreetmap.org/1/0/0.png")!)

    func testSystemOnlyWhenNotPreferringCellular() async throws {
        let cell = FakeHTTPClient.ok("cell"), sys = FakeHTTPClient.ok("sys")
        let smart = SmartHTTPClient(cellular: cell, system: sys)
        let r = try await smart.send(request)
        XCTAssertEqual(r.bodyString, "sys")
        XCTAssertEqual(cell.calls, 0)
        XCTAssertEqual(sys.calls, 1)
    }

    func testCellularFirstWhenPreferred() async throws {
        let cell = FakeHTTPClient.ok("cell"), sys = FakeHTTPClient.ok("sys")
        let smart = SmartHTTPClient(cellular: cell, system: sys, preferCellular: true)
        let r = try await smart.send(request)
        XCTAssertEqual(r.bodyString, "cell")
        XCTAssertEqual(sys.calls, 0)
    }

    func testNon2xxFromCellularIsReturnedNotRetried() async throws {
        let cell = FakeHTTPClient { _ in HTTPResponse(status: 429, body: Data("busy".utf8)) }
        let sys = FakeHTTPClient.ok("sys")
        let smart = SmartHTTPClient(cellular: cell, system: sys, preferCellular: true)
        let r = try await smart.send(request)
        XCTAssertEqual(r.status, 429)
        XCTAssertEqual(sys.calls, 0)
    }

    func testFallsBackToSystemAndBacksOffAfterNoNetwork() async throws {
        let clock = ManualClock()
        let cell = FakeHTTPClient.failing(HTTPClientError.noNetwork), sys = FakeHTTPClient.ok("sys")
        let smart = SmartHTTPClient(cellular: cell, system: sys, preferCellular: true, cellularRetryInterval: 10, clock: clock)
        let body = try await smart.send(request).bodyString
        XCTAssertEqual(body, "sys")
        XCTAssertEqual(cell.calls, 1)
        XCTAssertTrue(smart.isCellularBackingOff)
        // Within the back-off window the cellular path is skipped.
        clock.advance(5)
        let second = try await smart.send(request).bodyString
        XCTAssertEqual(second, "sys")
        XCTAssertEqual(cell.calls, 1)
        XCTAssertEqual(sys.calls, 2)
        // After it, cellular is tried again.
        clock.advance(5.1)
        XCTAssertFalse(smart.isCellularBackingOff)
        _ = try await smart.send(request)
        XCTAssertEqual(cell.calls, 2)
    }

    func testTogglingPreferenceResetsBackOff() async throws {
        let clock = ManualClock()
        let cell = FakeHTTPClient.failing(HTTPClientError.noNetwork), sys = FakeHTTPClient.ok("sys")
        let smart = SmartHTTPClient(cellular: cell, system: sys, preferCellular: true, clock: clock)
        _ = try await smart.send(request)
        XCTAssertTrue(smart.isCellularBackingOff)
        smart.preferCellular = false
        smart.preferCellular = true
        XCTAssertFalse(smart.isCellularBackingOff)
        _ = try await smart.send(request)
        XCTAssertEqual(cell.calls, 2)
    }

    func testTimeoutDoesNotBackOffButFallsBack() async throws {
        let cell = FakeHTTPClient.failing(HTTPClientError.timeout), sys = FakeHTTPClient.ok("sys")
        let smart = SmartHTTPClient(cellular: cell, system: sys, preferCellular: true)
        let body = try await smart.send(request).bodyString
        XCTAssertEqual(body, "sys")
        XCTAssertFalse(smart.isCellularBackingOff)
    }

    func testMoreInformativeErrorWins() async {
        // Cellular timed out, system has no internet (bike Wi-Fi): surface the timeout.
        let smart = SmartHTTPClient(cellular: FakeHTTPClient.failing(HTTPClientError.timeout),
                                    system: FakeHTTPClient.failing(HTTPClientError.noNetwork), preferCellular: true)
        do {
            _ = try await smart.send(request)
            XCTFail("both paths fail")
        } catch {
            XCTAssertEqual(error as? HTTPClientError, .timeout)
        }
        // Both noNetwork → noNetwork.
        let none = SmartHTTPClient(cellular: FakeHTTPClient.failing(HTTPClientError.noNetwork),
                                   system: FakeHTTPClient.failing(HTTPClientError.noNetwork), preferCellular: true)
        do {
            _ = try await none.send(request)
            XCTFail("both paths fail")
        } catch {
            XCTAssertEqual(error as? HTTPClientError, .noNetwork)
        }
        // System error that is not noNetwork is reported as is.
        let bad = SmartHTTPClient(cellular: FakeHTTPClient.failing(HTTPClientError.noNetwork),
                                  system: FakeHTTPClient.failing(HTTPClientError.invalidResponse("x")), preferCellular: true)
        do {
            _ = try await bad.send(request)
            XCTFail("both paths fail")
        } catch {
            XCTAssertEqual(error as? HTTPClientError, .invalidResponse("x"))
        }
    }

    func testCancellationIsNotRetriedOnSystem() async {
        let cell = FakeHTTPClient.failing(CancellationError()), sys = FakeHTTPClient.ok("sys")
        let smart = SmartHTTPClient(cellular: cell, system: sys, preferCellular: true)
        do {
            _ = try await smart.send(request)
            XCTFail("cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(sys.calls, 0)
    }

    func testGetHelperThrowsBadStatus() async {
        let smart = SmartHTTPClient(cellular: FakeHTTPClient.ok("x"),
                                    system: FakeHTTPClient { _ in HTTPResponse(status: 500, body: Data("oops".utf8)) })
        do {
            _ = try await smart.get(request.url)
            XCTFail("500 must throw from get()")
        } catch {
            XCTAssertEqual(error as? HTTPClientError, .badStatus(500, "oops"))
        }
    }

    // MARK: URLError mapping (SystemHTTPClient)

    func testURLErrorMapping() {
        XCTAssertNil(SystemHTTPErrorMapping.map(.cancelled, description: ""))
        XCTAssertEqual(SystemHTTPErrorMapping.map(.timedOut, description: ""), .timeout)
        for c in [URLError.Code.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
                  .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .callIsActive] {
            XCTAssertEqual(SystemHTTPErrorMapping.map(c, description: ""), .noNetwork, "\(c)")
        }
        XCTAssertEqual(SystemHTTPErrorMapping.map(.badServerResponse, description: "bad"), .invalidResponse("bad"))
    }

    func testHeaderLowercasing() {
        let h = SystemHTTPErrorMapping.lowercasedHeaders(["Content-Type": "image/png", "X-Count": 3, 7: "ignored"])
        XCTAssertEqual(h, ["content-type": "image/png", "x-count": "3"])
    }
}
