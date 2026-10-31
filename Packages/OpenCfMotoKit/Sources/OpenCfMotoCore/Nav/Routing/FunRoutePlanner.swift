// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) FunRoutePlanner.kt
//
// Via-point generators that pull an A→B route off the direct corridor (left/right, near/far) to
// produce "Fun" and "Alt" options, plus the twistiness score (docs/spec/navigation-dash.md §6.5).

import Foundation

public enum FunRoutePlanner {
    /// Scenic detours: offset `clamp(distKm·0.18, 3, 18)` km (distKm ≥ 1):
    /// [midL(0.45,+o)], [midR(0.55,−o)], [earlyL(0.28,+0.7o), lateR(0.72,−0.7o)].
    public static func funViaSets(from: GeoPoint, to: GeoPoint) -> [[GeoPoint]] {
        let distKm = max(GeoMath.haversineKm(from.lat, from.lon, to.lat, to.lon), 1.0)
        let o = min(max(distKm * 0.18, 3.0), 18.0)
        let midL = offsetPoint(from: from, to: to, fraction: 0.45, sideKm: o)
        let midR = offsetPoint(from: from, to: to, fraction: 0.55, sideKm: -o)
        let earlyL = offsetPoint(from: from, to: to, fraction: 0.28, sideKm: o * 0.7)
        let lateR = offsetPoint(from: from, to: to, fraction: 0.72, sideKm: -o * 0.7)
        return [[midL], [midR], [earlyL, lateR]]
    }

    /// Milder corridor alternatives: offset `clamp(distKm·0.10, 1.5, 12)` km:
    /// [midL(0.40,+o)], [midR(0.60,−o)], [farL(0.50,+1.6o)].
    public static func altViaSets(from: GeoPoint, to: GeoPoint) -> [[GeoPoint]] {
        let distKm = max(GeoMath.haversineKm(from.lat, from.lon, to.lat, to.lon), 1.0)
        let o = min(max(distKm * 0.10, 1.5), 12.0)
        let midL = offsetPoint(from: from, to: to, fraction: 0.40, sideKm: o)
        let midR = offsetPoint(from: from, to: to, fraction: 0.60, sideKm: -o)
        let farL = offsetPoint(from: from, to: to, fraction: 0.50, sideKm: o * 1.6)
        return [[midL], [midR], [farL]]
    }

    /// Short hops: offset `clamp(distKm·0.14, 0.35, 2.8)` km (distKm ≥ 0.4):
    /// [midL(0.45,+o)], [midR(0.55,−o)], [midL2(0.35,+1.35o)].
    public static func shortViaSets(from: GeoPoint, to: GeoPoint) -> [[GeoPoint]] {
        let distKm = max(GeoMath.haversineKm(from.lat, from.lon, to.lat, to.lon), 0.4)
        let o = min(max(distKm * 0.14, 0.35), 2.8)
        let midL = offsetPoint(from: from, to: to, fraction: 0.45, sideKm: o)
        let midR = offsetPoint(from: from, to: to, fraction: 0.55, sideKm: -o)
        let midL2 = offsetPoint(from: from, to: to, fraction: 0.35, sideKm: o * 1.35)
        return [[midL], [midR], [midL2]]
    }

    /// Triangle loop around a point (unused by the app — Circuit is there-and-back; kept for the
    /// upstream test vector): radius `clamp(km/2π, 4, 28)` at bearings 30/150/270 + the start.
    public static func circuitWaypoints(lat: Double, lon: Double, targetKm: Int) -> [GeoPoint] {
        let radiusKm = min(max(Double(targetKm) / (2.0 * Double.pi), 4.0), 28.0)
        return [30.0, 150.0, 270.0].map { GeoMath.destinationPoint(lat: lat, lon: lon, distanceKm: radiusKm, bearingDeg: $0) }
            + [GeoPoint(lat: lat, lon: lon)]
    }

    /// Twistiness: `(km / max(min, 1))·8 + steps·0.15 + km·0.05`.
    public static func twistScore(_ route: Route) -> Double {
        let minutes = max(route.durationSec / 60.0, 1.0)
        let km = route.distanceM / 1000.0
        let stepBonus = Double(route.steps.count) * 0.15
        return (km / minutes) * 8.0 + stepBonus + km * 0.05
    }

    /// Point at `fraction` of the straight lat/lon interpolation moved |sideKm| perpendicular
    /// (bearing + 90° for positive `sideKm`, − 90° otherwise).
    public static func offsetPoint(from: GeoPoint, to: GeoPoint, fraction: Double, sideKm: Double) -> GeoPoint {
        let lat = from.lat + (to.lat - from.lat) * fraction
        let lon = from.lon + (to.lon - from.lon) * fraction
        let brg = GeoMath.bearingDeg(from.lat, from.lon, to.lat, to.lon)
        return GeoMath.destinationPoint(lat: lat, lon: lon, distanceKm: abs(sideKm),
                                        bearingDeg: brg + (sideKm >= 0 ? 90.0 : -90.0))
    }
}
