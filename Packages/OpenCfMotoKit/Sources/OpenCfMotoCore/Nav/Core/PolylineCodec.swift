// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) ValhallaRouter.kt (decodePolyline6) and ValhallaRouterTest.kt
//
// Google encoded-polyline algorithm (5-bit chunks + 63, continuation bit 0x20, zig-zag sign).
// Valhalla uses precision 6 (1e-6); Google / OSRM `polyline` use precision 5. Using 5 on Valhalla
// data yields coordinates 10× too small (docs/spec/navigation-dash.md §6.6).

import Foundation

public enum PolylineCodec {
    /// Decodes an encoded polyline. Truncated input stops at the last complete coordinate pair
    /// (Android would throw); empty input → [].
    public static func decode(_ encoded: String, precision: Int = 5) -> [GeoPoint] {
        let bytes = Array(encoded.utf8)
        if bytes.isEmpty { return [] }
        let factor = pow(10.0, Double(precision))
        var out: [GeoPoint] = []
        var index = 0
        var lat = 0
        var lon = 0

        func next() -> Int? {
            var result = 0
            var shift = 0
            var b = 0
            repeat {
                guard index < bytes.count, shift <= 60 else { return nil }
                b = Int(bytes[index]) - 63
                index += 1
                result |= (b & 0x1F) << shift
                shift += 5
            } while b >= 0x20
            return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
        }

        while index < bytes.count {
            guard let dlat = next() else { break }
            guard let dlon = next() else { break }
            lat += dlat
            lon += dlon
            out.append(GeoPoint(lat: Double(lat) / factor, lon: Double(lon) / factor))
        }
        return out
    }

    /// Decodes into `TrackPoint`s (no elevation).
    public static func decodeTrackPoints(_ encoded: String, precision: Int = 5) -> [TrackPoint] {
        decode(encoded, precision: precision).map { TrackPoint(lat: $0.lat, lon: $0.lon) }
    }

    /// Encodes points (rounding half away from zero like `Math.round` for these magnitudes).
    public static func encode(_ points: [GeoPoint], precision: Int = 5) -> String {
        let factor = pow(10.0, Double(precision))
        var out = ""
        var prevLat = 0
        var prevLon = 0
        for p in points {
            let iLat = NavNumberFormat.roundHalfUp(p.lat * factor)
            let iLon = NavNumberFormat.roundHalfUp(p.lon * factor)
            encodeSigned(iLat - prevLat, into: &out)
            encodeSigned(iLon - prevLon, into: &out)
            prevLat = iLat
            prevLon = iLon
        }
        return out
    }

    private static func encodeSigned(_ value: Int, into out: inout String) {
        var v = value < 0 ? ~(value << 1) : (value << 1)
        while v >= 0x20 {
            out.unicodeScalars.append(Unicode.Scalar(UInt8((0x20 | (v & 0x1F)) + 63)))
            v >>= 5
        }
        out.unicodeScalars.append(Unicode.Scalar(UInt8(v + 63)))
    }
}
