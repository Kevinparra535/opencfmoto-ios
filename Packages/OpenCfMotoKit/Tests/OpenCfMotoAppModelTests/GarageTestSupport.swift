// SPDX-License-Identifier: AGPL-3.0-or-later
// Shared helpers of the logic-data model tests (Garage / Settings / Navigation / Trips / Logs).
// Every top-level name is prefixed `LD` so it cannot clash with the other agents' test helpers.
// NOTE (Linux): main-actor tests must be `async` (see AppModelSmokeTests.swift).

import Foundation
import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoAppModel

/// One isolated core on offline preview services, with its files in a fresh temp directory.
@MainActor
final class LDTestEnv {
    let services: AppServices
    let core: AppCore
    let http: PreviewHTTPClient
    let root: URL

    init(now: Date = LDTest.fixedNow, http: HTTPClient? = nil, flavor: BuildFlavor = .full) {
        var services = AppServices.preview(flavor: flavor)
        let preview = PreviewHTTPClient()
        services.http = http ?? preview
        services.now = { now }
        self.http = preview
        self.services = services
        root = services.files.tripsDirectory.deletingLastPathComponent()
        core = AppCore(services: services)
    }

    var system: PreviewSystem { services.system as! PreviewSystem }
    var projection: PreviewProjection { services.projection as! PreviewProjection }

    /// Removes the temp directory when the test ends.
    func cleanUp(after test: XCTestCase) {
        let root = self.root
        test.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }

    /// Strings of this core's language (the expected texts follow the test machine's language).
    var strings: LogicData.Strings { LogicData.Strings(core.language) }
}

enum LDTest {
    /// 2026-10-31T15:42:07Z.
    static let fixedNow = Date(timeIntervalSince1970: 1_793_461_327)
    /// The doc-01 CFDL16 QR (password `59a9cddc94`, id `b58cde373`).
    static let docQR = "http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37416&sn=peTz&action=9&ssid=CFMOTO-f46457&pwd=59a9cddc94&auth=wpa2-psk&mac=6C:09:4A:0F:6C:F8&name=CFMOTO-f46457"
    static let docPassword = "59a9cddc94"
    /// A CFDL26 QR without name (password `e278450c`, id `bae532b19`).
    static let qr4288 = "http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37426&sn=Vasr&action=1&ssid=CFMOTO4288&pwd=e278450c&uid=abc"
    static let qr4288Password = "e278450c"

    /// Polls `condition` on the main actor (yielding between checks) until it holds or times out.
    @MainActor
    static func wait(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }

    /// Fails the test when `condition` does not hold within `timeout` seconds.
    @MainActor
    static func expect(_ message: @autoclosure () -> String = "", timeout: TimeInterval = 5,
                       file: StaticString = #filePath, line: UInt = #line,
                       _ condition: @MainActor () -> Bool) async {
        let ok = await wait(timeout: timeout, condition)
        if !ok { XCTFail("condition not met within \(timeout) s \(message())", file: file, line: line) }
    }

    /// Lets queued main-actor work run for `seconds`.
    @MainActor
    static func settle(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Every message currently in `Log.shared` (raw, unredacted).
    static func sharedLogMessages() -> [String] {
        Log.shared.lines().map(\.message)
    }

    /// A ride of `count` fixes, 1 s apart, ~10 m apart northwards, moving at 10 m/s.
    static func rideFixes(count: Int, startMs: Int64, lat: Double = 45.0, lon: Double = 25.0) -> [LocationFix] {
        (0 ..< count).map { i in
            LocationFix(lat: lat + Double(i) * 0.00009, lon: lon, speedMps: 10, accuracyM: 5,
                        timeMs: startMs + Int64(i) * 1000)
        }
    }

    static func trip(start: Int64, minutes: Int64 = 10, meters: Double, points: [TripPoint]? = nil) -> Trip {
        let pts = points ?? [TripPoint(lat: 45.0, lon: 25.0, timeMs: start, speedMs: 10),
                             TripPoint(lat: 45.01, lon: 25.01, timeMs: start + minutes * 60_000, speedMs: 12)]
        return Trip(id: String(start), start: start, end: start + minutes * 60_000, distanceMeters: meters,
                    movingTimeMs: minutes * 60_000, maxSpeedMs: 25, points: pts)
    }

    static func epochMs(_ iso: String) -> Int64 {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let d = f.date(from: iso) else { fatalError("bad ISO date \(iso)") }
        return Int64((d.timeIntervalSince1970 * 1000).rounded())
    }

    static func read(_ file: ExportedFile) -> String {
        (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
    }
}

/// HTTP double that answers after a delay (to observe in-flight / stale searches).
final class LDSlowHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [HTTPRequest] = []
    private let delay: TimeInterval
    private let response: @Sendable (HTTPRequest) -> HTTPResponse

    init(delay: TimeInterval, response: @escaping @Sendable (HTTPRequest) -> HTTPResponse) {
        self.delay = delay
        self.response = response
    }

    var requests: [HTTPRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock { _requests.append(request) }
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        return response(request)
    }
}
