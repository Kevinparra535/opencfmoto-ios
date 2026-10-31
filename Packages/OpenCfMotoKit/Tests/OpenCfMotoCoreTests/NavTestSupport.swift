// SPDX-License-Identifier: AGPL-3.0-or-later
// Shared helpers for the navigation tests: fixtures, a scriptable fake HTTP client, a manual
// monotonic clock and a manual scheduler.

import Foundation
import XCTest
@testable import OpenCfMotoCore

enum NavFixtures {
    static func url(_ name: String) -> URL {
        let ns = name as NSString
        if let u = Bundle.module.url(forResource: ns.deletingPathExtension, withExtension: ns.pathExtension,
                                     subdirectory: "Fixtures/nav") {
            return u
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/nav").appendingPathComponent(name)
    }

    static func data(_ name: String) -> Data {
        (try? Data(contentsOf: url(name))) ?? Data()
    }

    static func string(_ name: String) -> String { String(decoding: data(name), as: UTF8.self) }

    static func json(_ name: String) -> Any {
        (try? JSONSerialization.jsonObject(with: data(name), options: [.fragmentsAllowed])) ?? NSNull()
    }
}

/// Loose accessors for golden JSON written by the Kotlin harness.
struct NavGJ {
    let v: Any?
    init(_ v: Any?) { self.v = v }
    subscript(_ k: String) -> NavGJ { NavGJ((v as? [String: Any])?[k]) }
    subscript(_ i: Int) -> NavGJ { NavGJ((v as? [Any]).flatMap { i < $0.count ? $0[i] : nil }) }
    var array: [NavGJ] { (v as? [Any])?.map { NavGJ($0) } ?? [] }
    var isNull: Bool { v == nil || v is NSNull }
    var double: Double? { isNull ? nil : (v as? NSNumber)?.doubleValue }
    var int: Int? { isNull ? nil : (v as? NSNumber)?.intValue }
    var string: String? { v as? String }
    var bool: Bool? { (v as? NSNumber)?.boolValue }
    var d: Double { double ?? .nan }
}

/// Scriptable HTTP client: `handler` answers every request; all requests are recorded.
final class NavFakeHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [HTTPRequest] = []
    private let handler: @Sendable (HTTPRequest) throws -> HTTPResponse

    init(_ handler: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse) { self.handler = handler }

    var requests: [HTTPRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        record(request)
        return try handler(request)
    }

    private func record(_ r: HTTPRequest) {
        lock.lock(); _requests.append(r); lock.unlock()
    }

}

extension HTTPResponse {
    static func navOK(_ data: Data) -> HTTPResponse { HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: data) }
    static func navOK(fixture: String) -> HTTPResponse { navOK(NavFixtures.data(fixture)) }
}

struct NavFakeNetworkError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String = "offline") { description = d }
}

extension HTTPRequest {
    var navBodyText: String { body.map { String(decoding: $0, as: UTF8.self) } ?? "" }
    var navURLText: String { url.absoluteString }
}

/// Monotonic clock driven by the test.
final class NavManualClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval
    init(_ start: TimeInterval = 1000) { t = start }
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ dt: TimeInterval) { lock.lock(); t += dt; lock.unlock() }
}

/// Scheduler whose actions run when the test calls `runDue()` after advancing the clock.
final class NavManualScheduler: NavScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private let clock: NavManualClock
    private var items: [(at: TimeInterval, action: @Sendable () -> Void)] = []
    init(clock: NavManualClock) { self.clock = clock }

    func schedule(after seconds: TimeInterval, _ action: @escaping @Sendable () -> Void) {
        lock.lock(); items.append((clock.now() + seconds, action)); lock.unlock()
    }

    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return items.count }

    func runDue() {
        lock.lock()
        let now = clock.now()
        let due = items.filter { $0.at <= now }
        items.removeAll { $0.at <= now }
        lock.unlock()
        for d in due { d.action() }
    }
}

/// Collects effects / snapshots / camera hints delivered by a NavigationSession.
final class NavRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _effects: [NavEffect] = []
    private var _snapshots: [NavSnapshot] = []
    private var _camera: [NavCameraHint] = []

    func attach(_ s: NavigationSession) {
        s.setEffectHandler { [weak self] e in self?.add(e) }
        s.setSnapshotHandler { [weak self] snap in self?.add(snap) }
        s.setCameraHintHandler { [weak self] h in self?.add(h) }
    }

    private func add(_ e: NavEffect) { lock.lock(); _effects.append(e); lock.unlock() }
    private func add(_ s: NavSnapshot) { lock.lock(); _snapshots.append(s); lock.unlock() }
    private func add(_ h: NavCameraHint) { lock.lock(); _camera.append(h); lock.unlock() }

    var effects: [NavEffect] { lock.lock(); defer { lock.unlock() }; return _effects }
    var snapshots: [NavSnapshot] { lock.lock(); defer { lock.unlock() }; return _snapshots }
    var camera: [NavCameraHint] { lock.lock(); defer { lock.unlock() }; return _camera }

    var spoken: [String] { effects.compactMap { if case let .speak(t) = $0 { return t } else { return nil } } }
    var toasts: [String] { effects.compactMap { if case let .toast(t) = $0 { return t } else { return nil } } }

    func clear() { lock.lock(); _effects = []; _snapshots = []; _camera = []; lock.unlock() }
}

func navAssertClose(_ a: Double?, _ b: Double?, _ tol: Double = 1e-9, _ msg: @autoclosure () -> String = "",
                 file: StaticString = #filePath, line: UInt = #line) {
    switch (a, b) {
    case (nil, nil): return
    case let (x?, y?):
        if x.isNaN && y.isNaN { return }
        let scale = max(1.0, abs(y))
        XCTAssertLessThanOrEqual(abs(x - y), tol * scale, "\(x) vs \(y) \(msg())", file: file, line: line)
    default:
        XCTFail("\(String(describing: a)) vs \(String(describing: b)) \(msg())", file: file, line: line)
    }
}

/// HTTP client whose requests wait until the test opens the gate (to observe in-flight states).
final class NavGatedHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var _count = 0
    private let handler: @Sendable (HTTPRequest) throws -> HTTPResponse

    init(_ handler: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse) { self.handler = handler }

    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return _count }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            _count += 1
            if open { lock.unlock(); c.resume(); return }
            waiters.append(c)
            lock.unlock()
        }
        return try handler(request)
    }

    func openGate() {
        lock.lock()
        open = true
        let w = waiters
        waiters = []
        lock.unlock()
        for c in w { c.resume() }
    }

    /// Waits (polling) until `n` requests are parked at the gate.
    func waitForRequests(_ n: Int, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while requestCount < n && Date() < deadline { try? await Task.sleep(nanoseconds: 2_000_000) }
    }
}
