// SPDX-License-Identifier: AGPL-3.0-or-later
// Demo GPS for the simulator / `-demo` launch argument / tests: replays a polyline at a constant
// speed (default 45 km/h) through `PreviewLocation.emit`, one fix per interval (default 1 s), with
// speed, course and accuracy like CoreLocation, plus a compass sample along the course. Fixes are
// emitted only while the location "service" is updating, like the real one.

import Foundation
import OpenCfMotoCore

@MainActor
public final class DemoRoutePlayer {
    /// A ~3.7 km loop around Parque Simón Bolívar, Bogotá (counter-clockwise).
    public nonisolated static let defaultRoute: [GeoPoint] = [
        GeoPoint(lat: 4.65845, lon: -74.10003),
        GeoPoint(lat: 4.66244, lon: -74.09720),
        GeoPoint(lat: 4.66570, lon: -74.09380),
        GeoPoint(lat: 4.66520, lon: -74.08905),
        GeoPoint(lat: 4.66190, lon: -74.08610),
        GeoPoint(lat: 4.65730, lon: -74.08560),
        GeoPoint(lat: 4.65330, lon: -74.08790),
        GeoPoint(lat: 4.65150, lon: -74.09240),
        GeoPoint(lat: 4.65300, lon: -74.09700),
        GeoPoint(lat: 4.65845, lon: -74.10003),
    ]

    public let route: [GeoPoint]
    public let speedMps: Double
    public let interval: TimeInterval
    /// Metres travelled along the route (wraps around for closed loops).
    public private(set) var distance: Double = 0
    public private(set) var isPlaying = false
    /// Fixes emitted so far.
    public private(set) var emittedFixes = 0

    private let location: PreviewLocation
    private let now: @Sendable () -> Date
    private let cumulative: [Double]
    private var task: Task<Void, Never>?

    public init(location: PreviewLocation, route: [GeoPoint] = DemoRoutePlayer.defaultRoute, speedKmh: Double = 45,
                interval: TimeInterval = 1, now: @escaping @Sendable () -> Date = { Date() }) {
        self.location = location
        self.route = route.count >= 2 ? route : DemoRoutePlayer.defaultRoute
        speedMps = max(0.5, speedKmh / 3.6)
        self.interval = max(0.05, interval)
        self.now = now
        var acc: [Double] = [0]
        for i in 1 ..< self.route.count {
            acc.append(acc[i - 1] + Self.haversine(self.route[i - 1], self.route[i]))
        }
        cumulative = acc
    }

    /// Total length of the polyline (m).
    public var length: Double { cumulative.last ?? 0 }

    /// The current position on the route.
    public var position: GeoPoint { point(at: distance).point }

    public func start() {
        guard !isPlaying else { return }
        isPlaying = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.step()
                let wait = self.interval
                await sleepSeconds(wait)
            }
        }
    }

    public func stop() {
        isPlaying = false
        task?.cancel()
        task = nil
    }

    /// Advances one interval and emits a fix (when the location service is updating).
    public func step() {
        guard length > 0 else { return }
        distance += speedMps * interval
        if distance > length { distance = distance.truncatingRemainder(dividingBy: length) }
        guard location.isUpdating else { return }
        let p = point(at: distance)
        let fix = LocationFix(lat: p.point.lat, lon: p.point.lon, speedMps: speedMps, courseDeg: p.bearing,
                              accuracyM: 5, altitudeM: 2600,
                              timeMs: Int64((now().timeIntervalSince1970 * 1000).rounded()))
        location.emit(fix)
        location.emitHeading(p.bearing)
        emittedFixes += 1
    }

    // MARK: - Geometry

    private func point(at d: Double) -> (point: GeoPoint, bearing: Double) {
        var i = 1
        while i < cumulative.count - 1, cumulative[i] < d { i += 1 }
        let a = route[i - 1]
        let b = route[i]
        let seg = cumulative[i] - cumulative[i - 1]
        let t = seg > 0 ? min(1, max(0, (d - cumulative[i - 1]) / seg)) : 0
        let p = GeoPoint(lat: a.lat + (b.lat - a.lat) * t, lon: a.lon + (b.lon - a.lon) * t)
        return (p, Self.bearing(a, b))
    }

    static func haversine(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let r = 6_371_000.0
        let p1 = a.lat * .pi / 180
        let p2 = b.lat * .pi / 180
        let dp = (b.lat - a.lat) * .pi / 180
        let dl = (b.lon - a.lon) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    static func bearing(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let p1 = a.lat * .pi / 180
        let p2 = b.lat * .pi / 180
        let dl = (b.lon - a.lon) * .pi / 180
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        let deg = atan2(y, x) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }
}
