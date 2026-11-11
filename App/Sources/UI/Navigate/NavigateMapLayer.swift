// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) GpxDashUi.kt (route / preview lines, pins, destination)
//
// The phone map of the Map hub (MapKit for SwiftUI). It draws what the ONE navigation session
// publishes (docs/spec/navigation-dash.md §11.8): the active route (brand orange), the preview
// candidates (selected green, alternatives grey), the dashed rider → destination line while no
// road route exists, the destination / previewed place, saved pins, search results and the
// snapped puck. Pins, results and the destination are selectable (they open the place card).
// UI/UX P0 (UX-17): an opened GPX track waiting as a preview is drawn dashed green over the rest,
// with its end flagged; the route being followed stays visible under it.

import SwiftUI
import MapKit
import OpenCfMotoCore
import OpenCfMotoAppModel

struct NavigateMapLayer: View {
    let snapshot: NavSnapshot
    /// Search results to show as markers (empty when the result list is closed).
    let results: [Place]
    /// Home and the parked bike (always pinned).
    let saved: [Place]
    /// An opened GPX track waiting for «Seguir este track» / «Cancelar» (nil when none).
    var gpxPreview: GpxPreview? = nil
    @Binding var camera: MapCameraPosition
    @Binding var selection: Place?

    var body: some View {
        Map(position: $camera, selection: $selection) {
            UserAnnotation()

            // Active route (navigating / GPX) — hidden under a preview, like the dash.
            if let route = snapshot.route, snapshot.preview == nil, route.points.count > 1 {
                MapPolyline(coordinates: NavigateGeometry.coordinates(route.points))
                    .stroke(Theme.brand, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }

            // Preview candidates: alternatives grey, the selected one green on top.
            if let preview = snapshot.preview {
                ForEach(NavigateGeometry.alternativeIndices(preview), id: \.self) { index in
                    MapPolyline(coordinates: NavigateGeometry.coordinates(preview.routes[index].points))
                        .stroke(NavigateColors.alternative.opacity(0.85),
                                style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
                if let selected = preview.selectedRoute, selected.points.count > 1 {
                    MapPolyline(coordinates: NavigateGeometry.coordinates(selected.points))
                        .stroke(Theme.live, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                }
                Marker(preview.place.name, systemImage: NavigateIcons.place(preview.place.category),
                       coordinate: NavigateGeometry.coordinate(preview.place))
                    .tint(Theme.brand)
                    .tag(preview.place)
            }

            // An opened GPX track shown as a preview (nothing replaced yet): dashed green, end flagged.
            if let gpx = gpxPreview {
                let outline = gpx.outline
                if outline.count > 1 {
                    MapPolyline(coordinates: NavigateGeometry.coordinates(outline))
                        .stroke(Theme.live, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round,
                                                               dash: [12, 8]))
                }
                if let last = outline.last {
                    Marker(gpx.name, systemImage: "flag.checkered",
                           coordinate: CLLocationCoordinate2D(latitude: last.lat, longitude: last.lon))
                        .tint(Theme.live)
                }
            }

            // NAV_TO without a road route yet: dashed yellow rider → destination line.
            if snapshot.showStraightLineToDestination, let destination = snapshot.destination,
               let rider = snapshot.puck {
                MapPolyline(coordinates: [NavigateGeometry.coordinate(rider), NavigateGeometry.coordinate(destination)])
                    .stroke(NavigateColors.straightLine, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
            }

            if let destination = snapshot.destination, snapshot.preview == nil {
                Marker(destination.name, systemImage: "flag.checkered",
                       coordinate: NavigateGeometry.coordinate(destination))
                    .tint(Theme.error)
                    .tag(destination)
            }

            ForEach(NavigateGeometry.pins(snapshot, extra: saved), id: \.self) { place in
                Marker(place.name, systemImage: NavigateIcons.place(place.category),
                       coordinate: NavigateGeometry.coordinate(place))
                    .tint(Theme.idle)
                    .tag(place)
            }

            ForEach(results, id: \.self) { place in
                Marker(place.name, systemImage: NavigateIcons.place(place.category),
                       coordinate: NavigateGeometry.coordinate(place))
                    .tint(Theme.busy)
                    .tag(place)
            }

            // The navigation engine's (snapped) position + bearing, i.e. where the dash puts the puck.
            if let puck = snapshot.puck, snapshot.mode.isNavigating {
                Annotation("Your position", coordinate: NavigateGeometry.coordinate(puck), anchor: .center) {
                    NavigatePuck(bearing: snapshot.puckBearingDeg)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
    }
}

/// Orange arrow of the navigation puck.
struct NavigatePuck: View {
    let bearing: Double

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.background.opacity(0.85))
                .frame(width: 30, height: 30)
            Image(systemName: "location.north.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.brand)
                .rotationEffect(.degrees(bearing))
        }
        .overlay(Circle().strokeBorder(Theme.brand, lineWidth: 2))
        .accessibilityHidden(true)
    }
}
