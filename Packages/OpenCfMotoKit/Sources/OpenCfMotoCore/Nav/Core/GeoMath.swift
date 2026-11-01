// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) GpxNav.kt, FunRoutePlanner.kt, OverpassClient.kt, OfflineRouter.kt
//
// Geodesy helpers shared by the navigation engine. Formulas, constants and evaluation order are
// copied from the Android code (docs/spec/navigation-dash.md §4.1, §6.5) so golden vectors from the
// Kotlin implementation reproduce bit-for-bit where possible:
//  - `Math.toRadians` / `Math.toDegrees` use the JDK 9+ multiplication constants;
//  - bearings that Android keeps as `Float` are exposed as `Float` variants (`bearingDegF`,
//    `normalizeDeltaF`) because turn detection compares them in single precision.

import Foundation

/// Spherical / planar geometry used by route following, routing and search.
public enum GeoMath {
    /// Mean Earth radius used by every Android haversine (m).
    public static let earthRadiusM = 6_371_000.0
    /// Metres per degree of latitude in the local equirectangular projection (Android `111_320`).
    public static let metresPerDegree = 111_320.0

    /// A coordinate every consumer (tile math, map projection, routing) can take: finite, latitude in
    /// [-90, 90], longitude in [-180, 180]. Used at every untrusted boundary (GPX, imported places and
    /// map data, search / POI / router responses): NaN, ±inf or 1e300 from a crafted file or server
    /// used to reach `Int(...)` conversions and trap (review SEC-1).
    public static func isValidCoordinate(lat: Double, lon: Double) -> Bool {
        lat.isFinite && lon.isFinite && (-90.0 ... 90.0).contains(lat) && (-180.0 ... 180.0).contains(lon)
    }

    /// `Math.toRadians` (JDK 9+: `deg * DEGREES_TO_RADIANS`).
    @inline(__always) public static func toRadians(_ deg: Double) -> Double { deg * 0.017453292519943295 }
    /// `Math.toDegrees` (JDK 9+: `rad * RADIANS_TO_DEGREES`).
    @inline(__always) public static func toDegrees(_ rad: Double) -> Double { rad * 57.29577951308232 }

    /// Great-circle distance in metres (`GpxNav.haversineM`):
    /// `2·R·asin(min(1, sqrt(sin²(Δφ/2) + cosφ1·cosφ2·sin²(Δλ/2))))`, R = 6 371 000 m.
    public static func haversineM(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let p1 = toRadians(lat1)
        let p2 = toRadians(lat2)
        let dLat = toRadians(lat2 - lat1)
        let dLon = toRadians(lon2 - lon1)
        let s1 = sin(dLat / 2)
        let s2 = sin(dLon / 2)
        // Kotlin: sin(dLat/2).pow(2) + cos(p1) * cos(p2) * sin(dLon/2).pow(2)  (same association)
        let a = s1 * s1 + cos(p1) * cos(p2) * (s2 * s2)
        return 2 * earthRadiusM * asin(min(1.0, sqrt(a)))
    }

    /// Haversine between two points (metres).
    public static func haversineM(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        haversineM(a.lat, a.lon, b.lat, b.lon)
    }

    /// Great-circle distance in kilometres (`FunRoutePlanner.haversineKm`, R = 6 371 km).
    public static func haversineKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let dLat = toRadians(lat2 - lat1)
        let dLon = toRadians(lon2 - lon1)
        let s1 = sin(dLat / 2)
        let s2 = sin(dLon / 2)
        let a = s1 * s1 + cos(toRadians(lat1)) * cos(toRadians(lat2)) * (s2 * s2)
        return 2 * 6371.0 * asin(max(-1.0, min(1.0, sqrt(a))))
    }

    /// Initial bearing a→b in degrees 0..<360 (double precision, `FunRoutePlanner.bearingDeg`).
    public static func bearingDeg(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let p1 = toRadians(lat1)
        let p2 = toRadians(lat2)
        let dLon = toRadians(lon2 - lon1)
        let y = sin(dLon) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dLon)
        return (toDegrees(atan2(y, x)) + 360.0).truncatingRemainder(dividingBy: 360.0)
    }

    /// Initial bearing a→b rounded to `Float` exactly like `GpxNav.bearingDeg` (used for turn
    /// detection, join-route arrows and track orientation, which Android evaluates in `Float`).
    public static func bearingDegF(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Float {
        Float(bearingDeg(lat1, lon1, lat2, lon2))
    }

    /// Wraps an angle difference into −180…180 (`GpxNav.normalizeDelta`, `Float` arithmetic).
    public static func normalizeDeltaF(_ deg: Float) -> Float {
        var d = deg
        while d > 180 { d -= 360 }
        while d < -180 { d += 360 }
        return d
    }

    /// Double-precision variant of `normalizeDeltaF`.
    public static func normalizeDelta(_ deg: Double) -> Double {
        var d = deg
        while d > 180 { d -= 360 }
        while d < -180 { d += 360 }
        return d
    }

    /// Spherical destination point (`FunRoutePlanner.destinationPoint`, R = 6 371 km).
    public static func destinationPoint(lat: Double, lon: Double, distanceKm: Double, bearingDeg: Double) -> GeoPoint {
        let r = 6371.0
        let d = distanceKm / r
        let br = toRadians(bearingDeg)
        let lat1 = toRadians(lat)
        let lon1 = toRadians(lon)
        let lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(br))
        let lon2 = lon1 + atan2(sin(br) * sin(d) * cos(lat1), cos(d) - sin(lat1) * sin(lat2))
        return GeoPoint(lat: toDegrees(lat2), lon: toDegrees(lon2))
    }

    /// Rough planar distance (`OverpassClient.approxMetres`): 111 320 m/° with cos(mean latitude).
    public static func approxMetres(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let dLat = abs(lat1 - lat2) * metresPerDegree
        let dLon = abs(lon1 - lon2) * metresPerDegree * cos(toRadians((lat1 + lat2) / 2))
        return hypot(dLat, dLon)
    }

    /// Projection of P onto segment A→B in the local equirectangular frame anchored at A
    /// (`mLat = 111 320`, `mLon = 111 320·cos(latA)`), as used by `GpxNav.snapToRoute`.
    public struct SegmentProjection: Sendable, Equatable {
        /// Parameter along A→B, clamped to 0…1.
        public var t: Double
        /// Distance P → projection (m).
        public var distanceM: Double
        /// Segment length |AB| (m).
        public var segmentLengthM: Double
        public var lat: Double
        public var lon: Double
    }

    public static func projectOntoSegment(lat: Double, lon: Double,
                                          aLat: Double, aLon: Double,
                                          bLat: Double, bLon: Double) -> SegmentProjection {
        let mLat = metresPerDegree
        let mLon = metresPerDegree * cos(toRadians(aLat))
        let bx = (bLon - aLon) * mLon
        let by = (bLat - aLat) * mLat
        let px = (lon - aLon) * mLon
        let py = (lat - aLat) * mLat
        let segLen2 = bx * bx + by * by
        let t = segLen2 <= 0 ? 0.0 : max(0.0, min(1.0, (px * bx + py * by) / segLen2))
        let projx = t * bx
        let projy = t * by
        let dist = hypot(px - projx, py - projy)
        return SegmentProjection(t: t, distanceM: dist, segmentLengthM: segLen2.squareRoot(),
                                 lat: aLat + projy / mLat, lon: aLon + projx / mLon)
    }

    /// Cumulative haversine distance to each vertex (`cumDist[0] = 0`).
    public static func cumulativeDistances(_ points: [TrackPoint]) -> [Double] {
        var out = [Double](repeating: 0, count: points.count)
        var acc = 0.0
        for i in points.indices where i > 0 {
            acc += haversineM(points[i - 1].lat, points[i - 1].lon, points[i].lat, points[i].lon)
            out[i] = acc
        }
        return out
    }

    /// Total haversine length of a polyline (m).
    public static func pathLength(_ points: [TrackPoint]) -> Double {
        cumulativeDistances(points).last ?? 0
    }
}
