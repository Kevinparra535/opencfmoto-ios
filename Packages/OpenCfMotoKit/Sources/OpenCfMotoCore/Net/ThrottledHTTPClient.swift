// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) AppHttp.kt (throttle, User-Agent, size caps)
//
// Android sleeps inside ONE global lock, so concurrent requests to different hosts serialise
// (docs/spec/navigation-dash.md §9). Here every host has its own slot reservation: a request waits
// only for earlier requests to the SAME host, never for other hosts.

import Foundation

/// Wraps any `HTTPClient` with the polite-client policy of the public OSM services:
/// per-host minimum spacing, an identifying User-Agent and response-size caps.
///
/// Thread-safe (`NSLock`); the spacing wait is an async sleep outside the lock.
public final class ThrottledHTTPClient: HTTPClient, @unchecked Sendable {
    /// Spacing and size cap for one host.
    public struct HostRule: Sendable, Equatable {
        public var minInterval: TimeInterval
        public var maxBytes: Int
        public init(minInterval: TimeInterval, maxBytes: Int = NavHTTPPolicy.defaultMaxBytes) {
            self.minInterval = minInterval
            self.maxBytes = maxBytes
        }
    }

    /// Android values: photon 300 ms, nominatim 1 100 ms, OSRM 600 ms, valhalla 500 ms,
    /// ORS 400 ms, overpass 1 000 ms; route hosts accept 24 MiB bodies.
    public static let defaultRules: [String: HostRule] = [
        "photon.komoot.io": HostRule(minInterval: 0.3),
        "nominatim.openstreetmap.org": HostRule(minInterval: 1.1),
        "router.project-osrm.org": HostRule(minInterval: 0.6, maxBytes: NavHTTPPolicy.maxRouteBytes),
        "valhalla1.openstreetmap.de": HostRule(minInterval: 0.5, maxBytes: NavHTTPPolicy.maxRouteBytes),
        "api.openrouteservice.org": HostRule(minInterval: 0.4),
        "overpass-api.de": HostRule(minInterval: 1.0),
    ]

    private let base: HTTPClient
    private let rules: [String: HostRule]
    private let defaultMaxBytes: Int?
    private let userAgent: @Sendable () -> String
    private let clock: MonotonicClock
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let lock = NSLock()
    private var nextSlot: [String: TimeInterval] = [:]

    /// - Parameters:
    ///   - base: the transport (URLSession / cellular client on iOS).
    ///   - rules: per-host spacing and caps (host compared lower-cased).
    ///   - defaultMaxBytes: cap for hosts without a rule (nil = unlimited, e.g. for tiles).
    ///   - userAgent: added when the request has no User-Agent header.
    ///   - clock / sleep: injectable for deterministic tests.
    public init(base: HTTPClient,
                rules: [String: HostRule] = ThrottledHTTPClient.defaultRules,
                defaultMaxBytes: Int? = NavHTTPPolicy.defaultMaxBytes,
                userAgent: @escaping @Sendable () -> String = { AppHTTPIdentity.userAgent },
                clock: MonotonicClock = SystemMonotonicClock(),
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { await sleepSeconds($0) }) {
        self.base = base
        self.rules = rules
        self.defaultMaxBytes = defaultMaxBytes
        self.userAgent = userAgent
        self.clock = clock
        self.sleep = sleep
    }

    /// Reserves the next send slot for `host` and returns how long the caller must wait (s).
    /// Exposed for tests and diagnostics.
    public func reserveSlot(host: String) -> TimeInterval {
        let key = host.lowercased()
        guard let rule = rules[key], rule.minInterval > 0 else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        let now = clock.now()
        var slot = now
        if let next = nextSlot[key], next > now { slot = next }
        nextSlot[key] = slot + rule.minInterval
        return slot - now
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var req = request
        if !req.headers.keys.contains(where: { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }) {
            req.headers["User-Agent"] = userAgent()
        }
        let host = (req.url.host ?? "").lowercased()
        let wait = reserveSlot(host: host)
        if wait > 0 {
            await sleep(wait)
            try Task.checkCancellation()
        }
        let response = try await base.send(req)
        let cap = rules[host]?.maxBytes ?? defaultMaxBytes
        if let cap, response.body.count > cap { throw NavServiceError.responseTooLarge }
        return response
    }
}
