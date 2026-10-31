// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) TripRouteThumb.kt, TripsListActivity.kt (cards), TripActivity.kt
//
// Pieces of the trip screens (docs/spec/app-features.md §5.6–§5.10): the route thumbnail drawn
// from `TripsModel.thumbnail(for:width:height:)` (brand-orange stroke on surface-high, green start
// dot, red end dot, stroke max(4, min·0.035) and dot radius max(5, min·0.045) in points), the
// saved-trip card (time range + DISTANCE / TIME / AVG / MAX) and the trip formatting helpers.
// Trip screens are metric like Android (`TripActivity.kt:111-115`).

import SwiftUI
import OpenCfMotoCore
import OpenCfMotoAppModel

/// Route thumbnail of a saved trip (needs ≥ 2 points, else just the background).
@MainActor
struct TripsThumbnailView: View {
    @Environment(AppModel.self) private var model
    let trip: Trip

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let points = model.trips.thumbnail(for: trip, width: Double(size.width), height: Double(size.height))
            let minSide = Double(min(size.width, size.height))
            let stroke = max(1.5, minSide * 0.035)
            let radius = max(2.5, minSide * 0.045)
            ZStack {
                Rectangle().fill(Theme.surfaceHigh)
                if points.count >= 2 {
                    Path { path in
                        path.addLines(points.map { CGPoint(x: $0.x, y: $0.y) })
                    }
                    .stroke(Theme.brand, style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))
                    if let first = points.first {
                        Circle()
                            .fill(Theme.live)
                            .frame(width: radius * 2, height: radius * 2)
                            .position(x: first.x, y: first.y)
                    }
                    if let last = points.last {
                        Circle()
                            .fill(Theme.error)
                            .frame(width: radius * 2, height: radius * 2)
                            .position(x: last.x, y: last.y)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Route preview"))
    }
}

/// One saved trip in the day list (Android trip card).
@MainActor
struct TripsRowView: View {
    let trip: Trip

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if trip.points.count >= 2 {
                TripsThumbnailView(trip: trip)
                    .frame(height: 112)
            }
            Text(verbatim: trip.timeRangeText())
                .font(.headline)
                .foregroundStyle(Theme.text)
            HStack(alignment: .top, spacing: 8) {
                FeatureStatCell(title: "Distance", value: trip.distanceText)
                FeatureStatCell(title: "Time", value: trip.durationText)
                FeatureStatCell(title: "Avg", value: TripFormat.kmhText(trip.avgKmh))
                FeatureStatCell(title: "Max", value: TripFormat.kmhText(trip.maxKmh))
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// Day header: localized day title + "n rides · x km".
struct TripsDayHeader: View {
    let section: TripDaySection

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: section.title)
                .font(.headline)
                .foregroundStyle(Theme.text)
                .textCase(nil)
            Text(verbatim: section.summary)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .textCase(nil)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

enum TripsText {
    /// Live trip computer line (`TripActivity.kt:104-117`): permission, GPS fix and accuracy.
    static func gpsLine(recording: Bool, live: TripRecorder.Stats, lastFix: LocationFix?,
                        authorized: Bool) -> Text {
        if !authorized {
            return Text("Location permission is required for the trip computer")
        }
        if recording {
            if !live.hasFix { return Text("Acquiring GPS…") }
            if live.accuracyM > 0 { return Text("GPS fix ±\(String(live.accuracyM)) m") }
            return Text("GPS fix")
        }
        guard let fix = lastFix else { return Text("Waiting for GPS…") }
        if let accuracy = fix.accuracyM, accuracy > 0, accuracy.isFinite {
            return Text("GPS fix ±\(String(Int(accuracy.rounded()))) m")
        }
        return Text("GPS fix")
    }

    /// A delete confirmation line: "<date> · <distance>".
    static func deleteMessage(_ trip: Trip) -> String {
        trip.dateText() + " · " + trip.distanceText
    }

    /// Trip-computer numbers for a live recording (same truncations as a saved `Trip`).
    static func liveTrip(_ live: TripRecorder.Stats) -> Trip {
        Trip(id: "live", start: 0, end: 0, distanceMeters: live.distanceMeters, movingTimeMs: live.movingTimeMs,
             maxSpeedMs: live.maxSpeedMs, points: [])
    }
}
