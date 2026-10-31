// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) GpxParser.kt (GpxTrack.orientedForRider), GpxNav.kt
// (GpxRideStats) and GpxDashUi.kt (rotation-vector compass smoothing).

import Foundation

public extension GpxTrack {
    /// Flips the track when the rider is clearly going the other way (docs/spec §3.2).
    ///
    /// Applied once, on the first GPS fix in GPX mode. `headingDeg` = GPS course only when the fix
    /// has one and speed > 1.0 m/s, else nil. With a heading: reverse when the reverse bearing is
    /// better aligned by more than 25°. Without: reverse when the nearest vertex lies beyond 65 % of
    /// the track. Tracks with < 3 points are never flipped.
    func orientedForRider(lat: Double, lon: Double, headingDeg: Double?) -> (track: GpxTrack, flipped: Bool) {
        if points.count < 3 { return (self, false) }
        var nearest = 0
        var best = Double.greatestFiniteMagnitude
        for i in points.indices {
            let d = GeoMath.haversineM(lat, lon, points[i].lat, points[i].lon)
            if d < best { best = d; nearest = i }
        }
        let last = points.count - 1
        let i = min(max(nearest, 0), last - 1)
        let fwd = GeoMath.bearingDegF(points[i].lat, points[i].lon, points[i + 1].lat, points[i + 1].lon)
        let rev = (fwd + 180).truncatingRemainder(dividingBy: 360)
        var reverse = false
        if let h = headingDeg {
            let hf = Float(h)
            let alignFwd = abs(GeoMath.normalizeDeltaF(hf - fwd))
            let alignRev = abs(GeoMath.normalizeDeltaF(hf - rev))
            if alignRev + 25 < alignFwd { reverse = true }
        }
        let frac = Double(nearest) / Double(last)
        if !reverse && frac > 0.65 && headingDeg == nil { reverse = true }
        if !reverse { return (self, false) }
        var copy = self
        copy.points = points.reversed()
        return (copy, true)
    }
}

/// Rolling average moving speed for the status line (Android `GpxRideStats`).
///
/// Ignores the first fix, samples with `dt ≤ 0` or `dt > 10 s`, speed < 1.0 m/s and jumps > 80 m.
/// `avgKmh` stays 0 until 5 s of moving time have accumulated.
public struct RideStats: Sendable, Equatable {
    public private(set) var movingDistM: Double = 0
    public private(set) var movingTimeMs: Int64 = 0
    private var last: (lat: Double, lon: Double, ms: Int64)?

    public init() {}

    public static func == (a: RideStats, b: RideStats) -> Bool {
        a.movingDistM == b.movingDistM && a.movingTimeMs == b.movingTimeMs
            && a.last?.lat == b.last?.lat && a.last?.lon == b.last?.lon && a.last?.ms == b.last?.ms
    }

    public mutating func onLocation(lat: Double, lon: Double, speedMps: Double, nowMs: Int64) {
        let prev = last
        last = (lat, lon, nowMs)
        guard let prev else { return }
        let dt = nowMs - prev.ms
        if dt <= 0 || dt > 10_000 { return }
        if Float(speedMps) < 1.0 { return } // stopped — don't dilute the average
        let d = GeoMath.haversineM(prev.lat, prev.lon, lat, lon)
        if d > 80 { return } // GPS jump
        movingDistM += d
        movingTimeMs += dt
    }

    /// Average moving speed (km/h, Float precision like Android).
    public func avgKmh() -> Double {
        if movingTimeMs < 5_000 { return 0 }
        let mps = movingDistM / (Double(movingTimeMs) / 1000.0)
        return Double(Float(mps * 3.6))
    }
}

/// Compass smoothing of `GpxDashUi`: the azimuth is filtered as a unit vector with α = 0.15
/// (`s += 0.15·(sin r − s)`, `c += 0.15·(cos r − c)`, heading = atan2(s, c) in 0..<360).
public struct HeadingSmoother: Sendable, Equatable {
    public static let alpha = 0.15
    private var s = 0.0
    private var c = 0.0
    private var have = false
    /// Last smoothed heading (degrees 0..<360), nil before the first sample.
    public private(set) var heading: Double?

    public init() {}

    /// Adds a raw heading sample (degrees) and returns the smoothed heading.
    @discardableResult
    public mutating func add(_ rawDeg: Double) -> Double {
        let r = GeoMath.toRadians(rawDeg)
        if !have {
            s = sin(r); c = cos(r); have = true
        } else {
            s += Self.alpha * (sin(r) - s)
            c += Self.alpha * (cos(r) - c)
        }
        var az = Float(GeoMath.toDegrees(atan2(s, c)))
        if az < 0 { az += 360 }
        heading = Double(az)
        return Double(az)
    }

    public mutating func reset() { self = HeadingSmoother() }
}
