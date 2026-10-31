// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) GpxDashUi.kt (iconResFor, collectPins), GpxActivity.kt (place rows)
//
// Pure helpers of the Map hub: coordinate conversion and decimation for MapKit, camera framing,
// maneuver / place icons and distance labels (docs/spec/navigation-dash.md §11.5, §12.1).

import SwiftUI
import MapKit
import OpenCfMotoCore
import OpenCfMotoAppModel

enum NavigateGeometry {
    /// MapKit polylines get at most this many vertices (long GPX tracks stay smooth on the phone).
    static let maxPolylinePoints = 1500

    static func coordinate(_ point: GeoPoint) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon)
    }

    static func coordinate(_ place: Place) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: place.lat, longitude: place.lon)
    }

    /// Route / track vertices for a `MapPolyline`, decimated to `maxPoints` (first and last kept).
    static func coordinates(_ points: [TrackPoint], maxPoints: Int = maxPolylinePoints) -> [CLLocationCoordinate2D] {
        decimate(points.count, maxPoints: maxPoints).map {
            CLLocationCoordinate2D(latitude: points[$0].lat, longitude: points[$0].lon)
        }
    }

    /// Recorded trip vertices for a `MapPolyline`.
    static func coordinates(_ points: [TripPoint], maxPoints: Int = maxPolylinePoints) -> [CLLocationCoordinate2D] {
        decimate(points.count, maxPoints: maxPoints).map {
            CLLocationCoordinate2D(latitude: points[$0].lat, longitude: points[$0].lon)
        }
    }

    /// Indices kept when thinning `count` vertices to at most `maxPoints` (always first and last).
    static func decimate(_ count: Int, maxPoints: Int) -> [Int] {
        guard count > 0 else { return [] }
        guard count > maxPoints, maxPoints >= 2 else { return Array(0 ..< count) }
        let step = Double(count - 1) / Double(maxPoints - 1)
        var indices: [Int] = []
        indices.reserveCapacity(maxPoints)
        for i in 0 ..< maxPoints {
            let index = min(count - 1, Int((Double(i) * step).rounded()))
            if indices.last != index { indices.append(index) }
        }
        if indices.last != count - 1 { indices.append(count - 1) }
        return indices
    }

    /// Smallest map rect containing every valid coordinate, padded so the content clears the
    /// cards (extra room at the bottom where the route / preview card sits). Nil when empty.
    static func framingRect(_ coordinates: [CLLocationCoordinate2D], minimumSideMeters: Double = 600,
                            bottomPadding: Double = 0.55) -> MKMapRect? {
        var rect = MKMapRect.null
        for c in coordinates where CLLocationCoordinate2DIsValid(c) && !(c.latitude == 0 && c.longitude == 0) {
            let p = MKMapPoint(c)
            rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
        }
        guard !rect.isNull else { return nil }
        let center = MKMapPoint(x: rect.midX, y: rect.midY)
        let minimumSide = minimumSideMeters * MKMapPointsPerMeterAtLatitude(center.coordinate.latitude)
        let width = max(rect.width, minimumSide)
        let height = max(rect.height, minimumSide)
        let padX = width * 0.18
        let padTop = height * 0.18
        let padBottom = height * max(bottomPadding, 0.18)
        return MKMapRect(x: center.x - width / 2 - padX,
                         y: center.y - height / 2 - padTop,
                         width: width + 2 * padX,
                         height: height + padTop + padBottom)
    }

    /// Camera that frames a route preview: every candidate route plus the rider and the place.
    static func previewRect(_ preview: RoutePreview, rider: GeoPoint?) -> MKMapRect? {
        var coords: [CLLocationCoordinate2D] = [coordinate(preview.place)]
        if let rider { coords.append(coordinate(rider)) }
        for route in preview.routes {
            coords.append(contentsOf: coordinates(route.points, maxPoints: 300))
        }
        return framingRect(coords)
    }

    /// Straight-line distance in metres between two points (nil when either is missing).
    static func distance(from origin: GeoPoint?, to place: Place) -> Double? {
        guard let origin, !(place.lat == 0 && place.lon == 0) else { return nil }
        return GeoMath.haversineM(origin.lat, origin.lon, place.lat, place.lon)
    }

    /// "350 m" / "12.4 km" / "0.8 mi" in the rider's units.
    static func distanceText(_ meters: Double, units: MapUnits) -> String {
        let separator: Character = Locale.current.decimalSeparator?.first ?? "."
        return NavFormat.formatDistance(meters, units: units, decimalSeparator: separator)
    }

    /// Places worth drawing as pins: not at (0,0), no duplicates, not the destination / previewed place.
    static func pins(_ snapshot: NavSnapshot) -> [Place] {
        var seen = Set<Place>()
        var out: [Place] = []
        for place in snapshot.pins where !(place.lat == 0 && place.lon == 0) {
            if let destination = snapshot.destination, destination.isSameLocation(as: place) { continue }
            if let previewed = snapshot.preview?.place, previewed.isSameLocation(as: place) { continue }
            if seen.insert(place).inserted { out.append(place) }
        }
        return out
    }

    /// Indices of the preview routes that are not selected (drawn grey, under the selected one).
    static func alternativeIndices(_ preview: RoutePreview) -> [Int] {
        preview.routes.indices.filter { $0 != preview.selectedIndex && preview.routes[$0].points.count > 1 }
    }
}

/// Key of what the camera should frame for a preview (refit only when one of these changes).
struct NavigatePreviewFraming: Equatable {
    var place: Place
    var routeCount: Int
    var selectedIndex: Int
    var loading: Bool

    init?(_ preview: RoutePreview?) {
        guard let preview else { return nil }
        place = preview.place
        routeCount = preview.routes.count
        selectedIndex = preview.selectedIndex
        loading = preview.loading
    }
}

enum NavigateIcons {
    /// SF Symbol for a maneuver (the dash's `ic_man_*` set: MERGE_*/FORK_* and STRAIGHT/CONTINUE share).
    static func maneuver(_ dir: TurnDir) -> String {
        switch dir {
        case .left: return "arrow.turn.up.left"
        case .right: return "arrow.turn.up.right"
        case .sharpLeft: return "arrow.turn.down.left"
        case .sharpRight: return "arrow.turn.down.right"
        case .slightLeft: return "arrow.up.left"
        case .slightRight: return "arrow.up.right"
        case .uturn: return "arrow.uturn.down"
        case .roundabout: return "arrow.clockwise"
        case .mergeLeft, .mergeRight: return "arrow.merge"
        case .forkLeft, .forkRight: return "arrow.triangle.branch"
        case .straight, .continue: return "arrow.up"
        case .arrive: return "flag.checkered"
        }
    }

    /// SF Symbol for a place category (POI chip labels, home / parking / pins / GPX / laps).
    static func place(_ category: String) -> String {
        switch category.lowercased() {
        case "home": return "house.fill"
        case "parking": return "parkingsign"
        case "pin": return "mappin"
        case "gpx": return "point.topleft.down.to.point.bottomright.curvepath"
        case "wpt": return "flag.fill"
        case "lap": return "flag.checkered"
        case "mode": return "road.lanes"
        case "fuel": return "fuelpump.fill"
        case "cafe": return "cup.and.saucer.fill"
        case "food", "restaurant": return "fork.knife"
        case "hotel": return "bed.double.fill"
        case "atm": return "banknote.fill"
        case "hospital": return "cross.case.fill"
        case "viewpoint": return "binoculars.fill"
        case "city", "town", "village", "municipality", "hamlet": return "building.2.fill"
        default: return "mappin.circle.fill"
        }
    }

    /// SF Symbol of a POI chip.
    static func chip(_ chip: PlaceSearch.PoiChip) -> String {
        place(chip.label)
    }
}

enum NavigateColors {
    /// Off-route status colour of the dash (`#FF8A80`).
    static let warning = Color(hex: 0xFF8A80)
    /// Dashed rider → destination line (no road route yet).
    static let straightLine = Color(hex: 0xFFD54F)
    /// Unselected preview routes.
    static let alternative = Color(hex: 0x8A93A3)
}
