// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) TripMapActivity.kt, TripsListActivity.kt (Export GPX, delete)
//
// One saved trip (docs/spec/app-features.md §5.8, §5.9): MapKit polyline of the track (brand
// orange, green "start" and red "end" markers, framed on the bounding box), the stats
// (distance · moving time · avg · max, date and time range), GPX export through ShareLink (the
// file is written by TripsModel.exportGPX only when a share target is picked; failures are shown)
// and delete with confirmation.

import SwiftUI
import MapKit
import OpenCfMotoCore
import OpenCfMotoAppModel

@MainActor
struct TripsDetailScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let trip: Trip
    @State private var confirmDelete = false
    @State private var shareErrors = FeatureShareErrors()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if trip.points.isEmpty {
                    ContentUnavailableView("Trip has no GPS points", systemImage: "location.slash")
                        .frame(maxWidth: .infinity)
                        .cardStyle()
                } else {
                    TripsTrackMap(trip: trip)
                        .frame(height: 320)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                            .strokeBorder(Theme.outline, lineWidth: 1))
                }

                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: trip.dateText())
                            .font(.headline)
                            .foregroundStyle(Theme.text)
                        Text(verbatim: trip.timeRangeText())
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                        GridRow {
                            FeatureStatCell(title: "Distance", value: trip.distanceText)
                            FeatureStatCell(title: "Moving time", value: trip.durationText)
                        }
                        GridRow {
                            FeatureStatCell(title: "Avg speed", value: TripFormat.kmhText(trip.avgKmh))
                            FeatureStatCell(title: "Max speed", value: TripFormat.kmhText(trip.maxKmh))
                        }
                    }
                }
                .cardStyle()

                if trip.points.isEmpty {
                    FeatureNote("Trip has no GPS points")
                } else {
                    ShareLink(item: gpxFile, preview: SharePreview(TripGpx.suggestedFileName(trip))) {
                        Label("Export GPX", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }

                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete trip", systemImage: "trash")
                        .foregroundStyle(Theme.error)
                }
                .buttonStyle(TonalButtonStyle())
            }
            .padding(Theme.padding)
        }
        .navigationTitle(Text(verbatim: trip.dateText()))
        .navigationBarTitleDisplayMode(.inline)
        .featureScreenChrome()
        .confirmationDialog("Delete trip?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                model.trips.delete(trip)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: TripsText.deleteMessage(trip))
        }
        .alert("Export failed", isPresented: $shareErrors.isPresented) {
        } message: {
            Text(verbatim: shareErrors.message ?? "")
        }
    }

    /// GPX written by `TripsModel.exportGPX` when the rider picks a share target.
    private var gpxFile: FeatureLazyFile<FeatureGPXKind> {
        let trips = model.trips
        let trip = self.trip
        return FeatureLazyFile(make: shareErrors.guarded { try trips.exportGPX(trip) })
    }
}

/// MapKit view of a recorded track (Android osmdroid trip map).
@MainActor
struct TripsTrackMap: View {
    let trip: Trip

    var body: some View {
        let coordinates = NavigateGeometry.coordinates(trip.points)
        let initial: MapCameraPosition = NavigateGeometry.framingRect(coordinates, minimumSideMeters: 400, bottomPadding: 0.18)
            .map { MapCameraPosition.rect($0) } ?? .automatic
        Map(initialPosition: initial) {
            if coordinates.count > 1 {
                MapPolyline(coordinates: coordinates)
                    .stroke(Theme.brand, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if let first = coordinates.first {
                Marker("Trip start", systemImage: "flag", coordinate: first)
                    .tint(Theme.live)
            }
            if coordinates.count > 1, let last = coordinates.last {
                Marker("Trip end", systemImage: "flag.checkered", coordinate: last)
                    .tint(Theme.error)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .environment(\.colorScheme, .dark)
    }
}

#Preview("Trip detail") {
    NavigationStack {
        TripsDetailScreen(trip: Trip(id: "1700000000000", start: 1_700_000_000_000, end: 1_700_000_360_000,
                                    distanceMeters: 12_500, movingTimeMs: 360_000, maxSpeedMs: 25,
                                    points: [TripPoint(lat: 45, lon: 25, timeMs: 1_700_000_000_000, speedMs: 10),
                                             TripPoint(lat: 45.01, lon: 25.01, timeMs: 1_700_000_180_000, speedMs: 12)]))
    }
    .environment(AppModel.preview())
}
