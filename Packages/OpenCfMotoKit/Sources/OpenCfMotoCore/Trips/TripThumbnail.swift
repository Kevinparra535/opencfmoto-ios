// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) TripRouteThumb.kt
//
// Route thumbnail GEOMETRY for the trip list (app-features.md §5.10): the subsampled track mapped
// into a `widthPx × heightPx` bitmap (top-left origin, y down) exactly as Android computes it
// (equirectangular with cos(mid-latitude), 14 % padding, Float32 where Android uses Float). No
// drawing here — the app strokes `polyline` and fills the two dots.

import Foundation

public struct TripThumbnailGeometry: Sendable, Equatable {
    public var widthPx: Int
    public var heightPx: Int
    /// Polyline in bitmap pixels (empty when fewer than 2 points: background only).
    public var polyline: [DashPoint]
    public var start: DashPoint? { polyline.first }
    public var end: DashPoint? { polyline.count > 1 ? polyline.last : nil }
    /// `max(4, min(w,h)·0.035)` px, round cap + join.
    public var strokeWidth: Double
    /// `max(5, min(w,h)·0.045)` px; start dot drawn first, end dot last.
    public var dotRadius: Double

    /// The polyline normalised to the unit square (x / width, y / height), for renderers that draw
    /// at a different scale (e.g. points × screen scale).
    public var normalizedPolyline: [DashPoint] {
        polyline.map { DashPoint($0.x / Double(widthPx), $0.y / Double(heightPx)) }
    }
}

public enum TripThumbnail {
    public static let maxPoints = 180
    /// Colours used by the Android list: stroke brand orange, background `surface_high`,
    /// start `status_live`, end `status_error`.
    public static let strokeColor = DashColor(rgb: 0xFF6A2C)
    public static let backgroundColor = DashColor(rgb: 0x1F242E)
    public static let startColor = DashColor(rgb: 0x34C759)
    public static let endColor = DashColor(rgb: 0xFF5A52)

    /// Indices kept when subsampling `count` points to `maxPoints`
    /// (`clamp(int(i · (n−1)/(max−1)), 0, n−1)`); all indices when `count ≤ maxPoints`.
    public static func subsampleIndices(count: Int, maxPoints: Int = maxPoints) -> [Int] {
        if count <= maxPoints { return Array(0 ..< count) }
        let step = Double(count - 1) / Double(maxPoints - 1)
        return (0 ..< maxPoints).map { i in min(max(Int(AppJavaNumber.d2i(Double(i) * step)), 0), count - 1) }
    }

    public static func subsample(_ points: [TripPoint], maxPoints: Int = maxPoints) -> [TripPoint] {
        subsampleIndices(count: points.count, maxPoints: maxPoints).map { points[$0] }
    }

    /// Thumbnail geometry for `points` in a bitmap of `widthPx × heightPx` (each at least 1).
    public static func geometry(points: [TripPoint], widthPx: Int, heightPx: Int) -> TripThumbnailGeometry {
        let w = max(widthPx, 1), h = max(heightPx, 1)
        let minSide = Float(min(widthPx, heightPx))
        let stroke = max(Float(4), minSide * Float(0.035))
        let radius = max(Float(5), minSide * Float(0.045))
        var g = TripThumbnailGeometry(widthPx: w, heightPx: h, polyline: [], strokeWidth: Double(stroke), dotRadius: Double(radius))
        let pts = subsample(points)
        guard pts.count >= 2 else { return g }

        var minLat = pts[0].lat, maxLat = pts[0].lat, minLon = pts[0].lon, maxLon = pts[0].lon
        for p in pts {
            minLat = min(minLat, p.lat); maxLat = max(maxLat, p.lat)
            minLon = min(minLon, p.lon); maxLon = max(maxLon, p.lon)
        }
        let midLat = (minLat + maxLat) * 0.5
        let cosLat = max(cos(midLat * 0.017453292519943295), 0.2)   // Math.toRadians (JDK 9+ / current Android)
        var spanX = (maxLon - minLon) * cosLat
        var spanY = maxLat - minLat
        if spanX < 1e-7 { spanX = 1e-7 }
        if spanY < 1e-7 { spanY = 1e-7 }

        // Kotlin: pad / drawW / drawH are Float; scale, ox, oy are Double.
        let pad: Float = minSide * Float(0.14)
        let drawW: Float = Float(widthPx) - pad * 2
        let drawH: Float = Float(heightPx) - pad * 2
        let scale = min(Double(drawW) / spanX, Double(drawH) / spanY)
        let usedW = spanX * scale
        let usedH = spanY * scale
        let ox = Double(pad) + (Double(drawW) - usedW) / 2.0
        let oy = Double(pad) + (Double(drawH) - usedH) / 2.0

        g.polyline = pts.map { p in
            DashPoint(Double(Float(ox + ((p.lon - minLon) * cosLat) * scale)),
                      Double(Float(oy + (maxLat - p.lat) * scale)))
        }
        return g
    }
}
