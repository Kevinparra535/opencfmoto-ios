// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Writes a track / road route as GPX 1.1 in the same style as the Android trip export
// (`TripGpx.kt`, docs/spec/app-features.md §5.9): two-space indentation, "\n" line ends, trailing
// newline, coordinates `%.6f` with a POSIX "." decimal, minimal escaping (& < > ").
// Waypoints are written before the track (GPX 1.1 schema order: metadata, wpt, rte, trk).

import Foundation

public enum GpxWriter {
    /// GPX for a track (`<trk><trkseg>`) or, with `asRoute`, a route (`<rte><rtept>`).
    /// - Parameters:
    ///   - time: optional `<metadata><time>` (UTC, seconds precision).
    public static func write(_ track: GpxTrack, asRoute: Bool = false, time: Date? = nil) -> String {
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        s += "<gpx version=\"1.1\" creator=\"OpenCfMoto\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n"
        s += "  <metadata>\n"
        s += "    <name>\(escape(track.name))</name>\n"
        if let time { s += "    <time>\(utcTimestamp(time))</time>\n" }
        s += "  </metadata>\n"
        for w in track.waypoints {
            s += point("wpt", w, indent: "  ")
        }
        if asRoute {
            s += "  <rte>\n"
            s += "    <name>\(escape(track.name))</name>\n"
            for p in track.points { s += point("rtept", p, indent: "    ") }
            s += "  </rte>\n"
        } else {
            s += "  <trk>\n"
            s += "    <name>\(escape(track.name))</name>\n"
            s += "    <trkseg>\n"
            for p in track.points { s += point("trkpt", p, indent: "      ") }
            s += "    </trkseg>\n"
            s += "  </trk>\n"
        }
        s += "</gpx>\n"
        return s
    }

    /// GPX for a road route (geometry only; steps are not representable in plain GPX).
    public static func write(route: Route, name: String, asRoute: Bool = false, time: Date? = nil) -> String {
        write(GpxTrack(name: name, points: route.points, waypoints: []), asRoute: asRoute, time: time)
    }

    /// Suggested file name: "<sanitised name>.gpx" (fallback "route.gpx").
    public static func suggestedFileName(for name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
            .trimmingCharacters(in: .whitespaces)
        return (cleaned.isEmpty ? "route" : cleaned) + ".gpx"
    }

    private static func point(_ tag: String, _ p: TrackPoint, indent: String) -> String {
        let attrs = "lat=\"\(NavNumberFormat.fixed(p.lat, decimals: 6))\" lon=\"\(NavNumberFormat.fixed(p.lon, decimals: 6))\""
        var children: [String] = []
        if let ele = p.ele, ele.isFinite { children.append("<ele>\(NavNumberFormat.fixed(ele, decimals: 1))</ele>") }
        if let name = p.name, !name.isEmpty { children.append("<name>\(escape(name))</name>") }
        if children.isEmpty { return "\(indent)<\(tag) \(attrs)/>\n" }
        var s = "\(indent)<\(tag) \(attrs)>\n"
        for c in children { s += "\(indent)  \(c)\n" }
        s += "\(indent)</\(tag)>\n"
        return s
    }

    /// `&`→`&amp;`, `<`→`&lt;`, `>`→`&gt;`, `"`→`&quot;` (in that order).
    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func utcTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: date)
    }
}
