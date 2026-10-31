// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) TripModel.kt, TripActivity.kt (formatting)
//
// Recorded rides (app-features.md §5.1–§5.2). Speeds in m/s (Float, like Android), distance in
// metres, times in epoch milliseconds. All number formatting is Java-exact and locale-independent
// (`String.format(Locale.US, …)`); dates use the caller's locale / time zone like Android's device
// locale.

import Foundation

/// One GPS sample of a ride (Android `TrackPoint` of TripModel.kt — distinct from the GPX `TrackPoint`).
public struct TripPoint: Sendable, Equatable, Codable {
    public var lat: Double
    public var lon: Double
    /// Epoch ms. Android stores the wall clock at reception; iOS stores the fix timestamp.
    public var timeMs: Int64
    /// m/s.
    public var speedMs: Float

    public init(lat: Double, lon: Double, timeMs: Int64, speedMs: Float) {
        self.lat = lat
        self.lon = lon
        self.timeMs = timeMs
        self.speedMs = speedMs
    }
}

/// A recorded ride: summary stats plus the full track.
public struct Trip: Sendable, Equatable, Codable, Identifiable {
    /// The start time in ms as a decimal string (also the file name stem).
    public var id: String
    /// Epoch ms when the leg began.
    public var start: Int64
    /// Epoch ms when the leg was finalised (includes idle time; only `movingTimeMs` is riding time).
    public var end: Int64
    public var distanceMeters: Double
    public var movingTimeMs: Int64
    public var maxSpeedMs: Float
    public var points: [TripPoint]

    public init(id: String, start: Int64, end: Int64, distanceMeters: Double, movingTimeMs: Int64,
                maxSpeedMs: Float, points: [TripPoint]) {
        self.id = id
        self.start = start
        self.end = end
        self.distanceMeters = distanceMeters
        self.movingTimeMs = movingTimeMs
        self.maxSpeedMs = maxSpeedMs
        self.points = points
    }

    /// `distanceMeters / 1000`.
    public var distanceKm: Double { distanceMeters / 1000.0 }

    /// `(maxSpeedMs * 3.6f).toInt()` — Float multiply, truncation.
    public var maxKmh: Int { Int(AppJavaNumber.f2i(maxSpeedMs * Float(3.6))) }

    /// Moving average, truncated: `(distance / (movingMs/1000)) * 3.6` (0 when no moving time).
    public var avgKmh: Int {
        guard movingTimeMs > 0 else { return 0 }
        return Int(AppJavaNumber.d2i((distanceMeters / (Double(movingTimeMs) / 1000.0)) * 3.6))
    }

    /// Moving time as `%02d:%02d:%02d` (hours not wrapped).
    public var durationText: String { TripFormat.durationText(movingTimeMs: movingTimeMs) }

    /// `"%.2f km"` (Java HALF_UP, always a dot).
    public var distanceText: String { TripFormat.distanceText(meters: distanceMeters) }

    /// `EEE d MMM yyyy` of `start` (e.g. `Tue 14 Nov 2023`).
    public func dateText(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        TripFormat.dateText(epochMs: start, locale: locale, timeZone: timeZone)
    }

    /// `HH:mm – HH:mm` (U+2013 with spaces) of start and end.
    public func timeRangeText(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        TripFormat.timeText(epochMs: start, locale: locale, timeZone: timeZone) + " \u{2013} "
            + TripFormat.timeText(epochMs: end, locale: locale, timeZone: timeZone)
    }
}

/// Trip formatting helpers (TripModel.kt / TripActivity.kt).
public enum TripFormat {
    /// `sec = max(movingMs/1000, 0)` → `"%02d:%02d:%02d"` of `sec/3600`, `(sec%3600)/60`, `sec%60`.
    /// 90 061 s → `25:01:01`.
    public static func durationText(movingTimeMs: Int64) -> String {
        let sec = max(movingTimeMs / 1000, 0)
        return pad2(sec / 3600) + ":" + pad2((sec % 3600) / 60) + ":" + pad2(sec % 60)
    }

    private static func pad2(_ v: Int64) -> String {
        v < 10 ? "0\(v)" : "\(v)"
    }

    /// `String.format(Locale.US, "%.2f km", meters / 1000)` (Java HALF_UP on the shortest decimal).
    public static func distanceText(meters: Double) -> String {
        AppJavaNumber.formatFixed(meters / 1000.0, precision: 2) + " km"
    }

    /// `"<n> km/h"`.
    public static func kmhText(_ kmh: Int) -> String { "\(kmh) km/h" }

    /// Live speed: `(speedMs * 3.6f).coerceAtLeast(0f).toInt()`.
    public static func liveSpeedKmh(speedMs: Float) -> Int {
        Int(AppJavaNumber.f2i(max(speedMs * Float(3.6), 0)))
    }

    /// iOS extra (Android trips are metric-only): `"%.2f mi"` of the distance.
    public static func distanceTextImperial(meters: Double) -> String {
        AppJavaNumber.formatFixed(meters / 1609.344, precision: 2) + " mi"
    }

    /// iOS extra: speed in whole mph, truncated like the km/h values.
    public static func mph(speedMs: Float) -> Int {
        Int(AppJavaNumber.f2i(max(speedMs * Float(2.2369363), 0)))
    }

    private static func formatter(_ pattern: String, locale: Locale, timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateFormat = pattern
        return f
    }

    /// `EEE d MMM yyyy` (device locale on Android).
    public static func dateText(epochMs: Int64, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        formatter("EEE d MMM yyyy", locale: locale, timeZone: timeZone).string(from: date(epochMs))
    }

    /// `HH:mm`.
    public static func timeText(epochMs: Int64, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        formatter("HH:mm", locale: locale, timeZone: timeZone).string(from: date(epochMs))
    }

    static func date(_ epochMs: Int64) -> Date { Date(timeIntervalSince1970: Double(epochMs) / 1000.0) }
}
