// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) OverpassClient.kt (maxspeedNear / maxspeedAsync / cache) and
// GpxDashUi.kt (12 s refresh gate)
//
// docs/spec/navigation-dash.md §8: lookups at most every 12 s (time-based, any mode), results
// cached 10 minutes per "%.3f,%.3f" cell (≈ 110 m), every failure → (nil, "—") (sign hidden).

import Foundation

/// Speed-limit lookups with Android's refresh gate and cache. Thread-safe (`NSLock`).
public final class SpeedLimitService: @unchecked Sendable {
    /// Minimum time between lookups triggered by GPS fixes.
    public static let refreshInterval: TimeInterval = 12
    /// Cache lifetime per cell.
    public static let cacheTTL: TimeInterval = 10 * 60

    private let overpass: OverpassClient
    private let clock: MonotonicClock
    private let lock = NSLock()
    private var lastRefreshAt: TimeInterval?
    private var cache: [String: (at: TimeInterval, value: SpeedLimit)] = [:]

    public init(overpass: OverpassClient, clock: MonotonicClock = SystemMonotonicClock()) {
        self.overpass = overpass
        self.clock = clock
    }

    public convenience init(http: HTTPClient, clock: MonotonicClock = SystemMonotonicClock()) {
        self.init(overpass: OverpassClient(http: http), clock: clock)
    }

    /// Cache key `"%.3f,%.3f"` of the position.
    public static func cacheKey(lat: Double, lon: Double) -> String {
        NavNumberFormat.fixed(lat, decimals: 3) + "," + NavNumberFormat.fixed(lon, decimals: 3)
    }

    /// Per-fix gate: true (and stamps the time) when more than 12 s passed since the last lookup.
    public func shouldRefresh() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = clock.now()
        if let last = lastRefreshAt, now - last <= Self.refreshInterval { return false }
        lastRefreshAt = now
        return true
    }

    /// Forgets the refresh stamp (e.g. after a long pause).
    public func resetRefreshGate() {
        lock.lock(); lastRefreshAt = nil; lock.unlock()
    }

    /// Cached lookup; never throws (errors → `SpeedLimit(kmh: nil, label: "—")`, not cached).
    public func lookup(lat: Double, lon: Double) async -> SpeedLimit {
        let key = Self.cacheKey(lat: lat, lon: lon)
        if let hit = cached(key) { return hit }
        do {
            let v = try await overpass.maxspeed(lat: lat, lon: lon)
            store(key, v)
            return v
        } catch {
            Log.d("NAV", "[speed] maxspeed lookup failed: \(NavServiceError.message(for: error, fallback: "error"))")
            return SpeedLimit(kmh: nil, label: "—")
        }
    }

    private func cached(_ key: String) -> SpeedLimit? {
        lock.lock(); defer { lock.unlock() }
        guard let hit = cache[key], clock.now() - hit.at < Self.cacheTTL else { return nil }
        return hit.value
    }

    private func store(_ key: String, _ value: SpeedLimit) {
        lock.lock(); defer { lock.unlock() }
        let now = clock.now()
        cache[key] = (now, value)
        if cache.count > 512 { cache = cache.filter { now - $0.value.at < Self.cacheTTL } }
    }

    /// Display-ready limit for the dash sign: `label` = formatted number in `units` (or "—" when
    /// the sign must be hidden), `kmh` = km/h value (nil when hidden). With `keepNativeUnit`, an
    /// OSM "NN mph" limit shows NN in imperial (iOS fix of the §8 double-conversion pitfall).
    public static func displayLimit(_ raw: SpeedLimit, units: MapUnits, keepNativeUnit: Bool = true) -> SpeedLimit {
        let label = NavFormat.formatLimit(raw, units: units, keepNativeUnit: keepNativeUnit)
        return SpeedLimit(kmh: label == "—" ? nil : raw.kmh, label: label)
    }

    /// Sign visible iff the label is not blank and not "—".
    public static func isVisible(_ limit: SpeedLimit?) -> Bool {
        guard let l = limit else { return false }
        return !l.label.isNavBlank && l.label != "—"
    }
}
