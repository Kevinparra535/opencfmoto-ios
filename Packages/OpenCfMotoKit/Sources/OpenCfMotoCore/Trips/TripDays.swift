// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) TripsListActivity.kt (day pager logic)
//
// Saved trips grouped by calendar day (app-features.md §5.7). iOS fix: day boundaries come from
// `Calendar.startOfDay` and `date(byAdding: .day, value: 1)` instead of Android's fixed 24 h, so
// DST-change days are correct (Android is off by ±1 h on those days).

import Foundation

/// Rides and total distance of one day (for the plural "N ride(s) · X.X km" line).
public struct TripDaySummary: Sendable, Equatable {
    public var count: Int
    /// Σ `distanceKm` of the day's trips.
    public var distanceKm: Double
    public init(count: Int, distanceKm: Double) { self.count = count; self.distanceKm = distanceKm }
}

public enum TripDays {
    /// Local midnight (epoch ms) of the day containing `epochMs`.
    public static func startOfDay(_ epochMs: Int64, calendar: Calendar = .current) -> Int64 {
        toEpochMs(calendar.startOfDay(for: TripFormat.date(epochMs)))
    }

    /// Start of the day `days` calendar days after/before the day starting at `dayStart`.
    public static func shiftDay(_ dayStart: Int64, by days: Int, calendar: Calendar = .current) -> Int64 {
        let base = calendar.startOfDay(for: TripFormat.date(dayStart))
        let shifted = calendar.date(byAdding: .day, value: days, to: base) ?? base
        return toEpochMs(calendar.startOfDay(for: shifted))
    }

    /// Trips that start on the day beginning at `dayStart` (`dayStart ≤ start < next midnight`),
    /// most recent first.
    public static func trips(_ trips: [Trip], onDay dayStart: Int64, calendar: Calendar = .current) -> [Trip] {
        let start = startOfDay(dayStart, calendar: calendar)
        let end = shiftDay(start, by: 1, calendar: calendar)
        return trips.filter { $0.start >= start && $0.start < end }.sorted { $0.start > $1.start }
    }

    /// The day the list opens on: today, or — if today has no rides — the day of the most recent trip.
    public static func initialDay(trips: [Trip], nowMs: Int64, calendar: Calendar = .current) -> Int64 {
        let today = startOfDay(nowMs, calendar: calendar)
        if trips.contains(where: { startOfDay($0.start, calendar: calendar) == today }) { return today }
        guard let latest = trips.max(by: { $0.start < $1.start }) else { return today }
        return startOfDay(latest.start, calendar: calendar)
    }

    public static func summary(_ trips: [Trip]) -> TripDaySummary {
        TripDaySummary(count: trips.count, distanceKm: trips.reduce(0) { $0 + $1.distanceKm })
    }

    private static func toEpochMs(_ d: Date) -> Int64 {
        Int64((d.timeIntervalSince1970 * 1000).rounded())
    }
}
