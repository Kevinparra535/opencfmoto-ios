// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) TripGpx.kt
//
// GPX 1.1 export of a recorded trip (app-features.md §5.9), byte-exact template: two-space
// indentation, `\n` line ends, trailing newline, lat/lon `%.6f` (Java HALF_UP, POSIX dot),
// `<time>` in UTC with seconds precision (only when the point time > 0), no elevation/speed.

import Foundation

public enum TripGpx {
    /// MIME type of the export.
    public static let mimeType = "application/gpx+xml"

    /// `opencfmoto_trip_<yyyyMMdd_HHmm>.gpx` of the trip start (device time zone).
    public static func suggestedFileName(_ trip: Trip, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd_HHmm"
        return "opencfmoto_trip_\(f.string(from: TripFormat.date(trip.start))).gpx"
    }

    /// The GPX document. `locale` / `timeZone` only affect the track name
    /// (`OpenCfMoto <EEE d MMM yyyy> <HH:mm – HH:mm>`, like Android's device locale).
    public static func toXML(_ trip: Trip, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let name = escape("OpenCfMoto \(trip.dateText(locale: locale, timeZone: timeZone)) \(trip.timeRangeText(locale: locale, timeZone: timeZone))")
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.timeZone = TimeZone(identifier: "UTC")
        iso.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        var sb = ""
        sb += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        sb += "<gpx version=\"1.1\" creator=\"OpenCfMoto\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n"
        sb += "  <metadata>\n"
        sb += "    <name>\(name)</name>\n"
        sb += "    <time>\(iso.string(from: TripFormat.date(trip.start)))</time>\n"
        sb += "  </metadata>\n"
        sb += "  <trk>\n"
        sb += "    <name>\(name)</name>\n"
        sb += "    <type>motorcycle</type>\n"
        sb += "    <trkseg>\n"
        for p in trip.points {
            sb += "      <trkpt lat=\"\(AppJavaNumber.formatFixed(p.lat, precision: 6))\" lon=\"\(AppJavaNumber.formatFixed(p.lon, precision: 6))\">\n"
            if p.timeMs > 0 {
                sb += "        <time>\(iso.string(from: TripFormat.date(p.timeMs)))</time>\n"
            }
            sb += "      </trkpt>\n"
        }
        sb += "    </trkseg>\n"
        sb += "  </trk>\n"
        sb += "</gpx>\n"
        return sb
    }

    /// Android's escape: `&`, `<`, `>`, `"` (in that order); `'` is left alone.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
