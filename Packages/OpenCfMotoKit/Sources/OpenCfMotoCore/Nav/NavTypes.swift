// SPDX-License-Identifier: AGPL-3.0-or-later
// CONTRACT FILE — navigation data model shared by the nav engine (Nav/), the dash UI (Dash/),
// trips and the app. Mirrors the Android models (docs/spec/navigation-dash.md §2).

import Foundation

public struct GeoPoint: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
    public var lat: Double
    public var lon: Double
    public init(lat: Double, lon: Double) { self.lat = lat; self.lon = lon }
    public var description: String { String(format: "%.5f,%.5f", lat, lon) }
}

/// One GPX / route vertex (Android `GpxPoint`).
public struct TrackPoint: Sendable, Equatable, Codable {
    public var lat: Double
    public var lon: Double
    public var ele: Double?
    public var name: String?
    public init(lat: Double, lon: Double, ele: Double? = nil, name: String? = nil) {
        self.lat = lat; self.lon = lon; self.ele = ele; self.name = name
    }
    public var point: GeoPoint { GeoPoint(lat: lat, lon: lon) }
}

/// Android `GpxTrack`.
public struct GpxTrack: Sendable, Equatable, Codable {
    public var name: String
    public var points: [TrackPoint]
    public var waypoints: [TrackPoint]
    public init(name: String, points: [TrackPoint], waypoints: [TrackPoint] = []) {
        self.name = name; self.points = points; self.waypoints = waypoints
    }
}

/// Android `MapPlace` (MapPlaces.kt:10-16). Categories: "" / home / parking / pin / gpx / mode / wpt / lap / poi…
public struct Place: Sendable, Equatable, Hashable, Codable {
    public var name: String
    public var lat: Double
    public var lon: Double
    public var category: String
    public var subtitle: String
    public init(name: String, lat: Double, lon: Double, category: String = "", subtitle: String = "") {
        self.name = name; self.lat = lat; self.lon = lon; self.category = category; self.subtitle = subtitle
    }
    public var point: GeoPoint { GeoPoint(lat: lat, lon: lon) }
    /// Android: same place if |dlat| and |dlon| < 1e-5.
    public func isSameLocation(as other: Place) -> Bool {
        abs(lat - other.lat) < 1e-5 && abs(lon - other.lon) < 1e-5
    }
}

public struct Lane: Sendable, Equatable, Codable {
    public var valid: Bool
    public var indications: [String]
    public init(valid: Bool, indications: [String]) { self.valid = valid; self.indications = indications }
}

/// Router-independent step (Android `RouteStep`, OsrmRouter.kt:17-40). `maneuverType`/`modifier`
/// use OSRM vocabulary (Valhalla/ORS are mapped into it).
public struct RouteStep: Sendable, Equatable, Codable {
    public var maneuverType: String
    public var modifier: String?
    public var roadName: String
    public var maneuverLat: Double
    public var maneuverLon: Double
    public var distanceM: Double
    public var exit: Int?
    public var lanes: [Lane]?
    public init(maneuverType: String, modifier: String? = nil, roadName: String = "", maneuverLat: Double,
                maneuverLon: Double, distanceM: Double = 0, exit: Int? = nil, lanes: [Lane]? = nil) {
        self.maneuverType = maneuverType; self.modifier = modifier; self.roadName = roadName
        self.maneuverLat = maneuverLat; self.maneuverLon = maneuverLon; self.distanceM = distanceM
        self.exit = exit; self.lanes = lanes
    }
}

public struct Route: Sendable, Equatable, Codable {
    public var points: [TrackPoint]
    public var distanceM: Double
    public var durationSec: Double
    public var steps: [RouteStep]
    /// Fast / Fun / Alt / Circuit / Direct / No highway / No toll / No hwy/toll …
    public var label: String
    public init(points: [TrackPoint], distanceM: Double, durationSec: Double, steps: [RouteStep] = [], label: String = "") {
        self.points = points; self.distanceM = distanceM; self.durationSec = durationSec; self.steps = steps; self.label = label
    }
    /// Straight-line fallback ("Direct").
    public var isStraightLine: Bool { label == "Direct" }
}

public struct RouteResult: Sendable, Equatable {
    public var routes: [Route]
    public var avoidHonored: Bool
    public var warning: String?
    public init(routes: [Route], avoidHonored: Bool = true, warning: String? = nil) {
        self.routes = routes; self.avoidHonored = avoidHonored; self.warning = warning
    }
}

public enum MapUnits: String, Sendable, Codable, CaseIterable { case metric = "METRIC", imperial = "IMPERIAL" }
public enum RouteMode: String, Sendable, Codable, CaseIterable { case fast = "FAST", fun = "FUN" }
public enum MapTheme: String, Sendable, Codable, CaseIterable { case auto = "AUTO", day = "DAY", night = "NIGHT" }

/// Background behind the map (MapPrefs.kt:13-18).
public enum MapChrome: String, Sendable, Codable, CaseIterable {
    case dark = "DARK", black = "BLACK", slate = "SLATE", forest = "FOREST"
    public var argb: UInt32 {
        switch self {
        case .dark: return 0xFF10_1418
        case .black: return 0xFF00_0000
        case .slate: return 0xFF1A_2332
        case .forest: return 0xFF0E_1A14
        }
    }
}

public struct RouteOptions: Sendable, Equatable, Codable {
    public var mode: RouteMode
    public var avoidTolls: Bool
    public var avoidHighways: Bool
    public var maxAlternatives: Int
    public var circuitKm: Int
    public init(mode: RouteMode = .fast, avoidTolls: Bool = false, avoidHighways: Bool = false,
                maxAlternatives: Int = 4, circuitKm: Int = 60) {
        self.mode = mode; self.avoidTolls = avoidTolls; self.avoidHighways = avoidHighways
        self.maxAlternatives = maxAlternatives; self.circuitKm = circuitKm
    }
    public var wantsAvoids: Bool { avoidTolls || avoidHighways }
}

/// Android `TurnDir` (GpxNav.kt:66-70).
public enum TurnDir: String, Sendable, Codable, CaseIterable {
    case left = "LEFT", right = "RIGHT", sharpLeft = "SHARP_LEFT", sharpRight = "SHARP_RIGHT"
    case slightLeft = "SLIGHT_LEFT", slightRight = "SLIGHT_RIGHT", uturn = "UTURN", roundabout = "ROUNDABOUT"
    case mergeLeft = "MERGE_LEFT", mergeRight = "MERGE_RIGHT", forkLeft = "FORK_LEFT", forkRight = "FORK_RIGHT"
    case straight = "STRAIGHT", arrive = "ARRIVE", `continue` = "CONTINUE"
}

/// Android `TurnCue` (GpxNav.kt:72-85).
public struct TurnCue: Sendable, Equatable {
    public var index: Int
    public var distanceAlongM: Double
    public var distanceFromRiderM: Double
    public var dir: TurnDir
    public var speak: String
    public var shortLabel: String
    public var instr: String
    public var roadName: String?
    public var laneLabel: String?
    public init(index: Int, distanceAlongM: Double, distanceFromRiderM: Double, dir: TurnDir, speak: String,
                shortLabel: String, instr: String = "", roadName: String? = nil, laneLabel: String? = nil) {
        self.index = index; self.distanceAlongM = distanceAlongM; self.distanceFromRiderM = distanceFromRiderM
        self.dir = dir; self.speak = speak; self.shortLabel = shortLabel; self.instr = instr
        self.roadName = roadName; self.laneLabel = laneLabel
    }
}

/// Android `Progress` (GpxNav.kt:87-107).
public struct RouteProgress: Sendable, Equatable {
    public var nearestIndex: Int
    public var doneM: Double
    public var remainM: Double
    public var offTrackM: Double
    public var snapLat: Double
    public var snapLon: Double
    public var nextWaypoint: TrackPoint?
    public var nextWaypointM: Double?
    public var trackBearingDeg: Double
    public var upcomingTurn: TurnCue?
    public var altitudeM: Double?
    public var remainAscentM: Double?
    public var gradePct: Double?
    public var etaSec: Int?
    public init(nearestIndex: Int, doneM: Double, remainM: Double, offTrackM: Double, snapLat: Double, snapLon: Double,
                nextWaypoint: TrackPoint? = nil, nextWaypointM: Double? = nil, trackBearingDeg: Double = 0,
                upcomingTurn: TurnCue? = nil, altitudeM: Double? = nil, remainAscentM: Double? = nil,
                gradePct: Double? = nil, etaSec: Int? = nil) {
        self.nearestIndex = nearestIndex; self.doneM = doneM; self.remainM = remainM; self.offTrackM = offTrackM
        self.snapLat = snapLat; self.snapLon = snapLon; self.nextWaypoint = nextWaypoint; self.nextWaypointM = nextWaypointM
        self.trackBearingDeg = trackBearingDeg; self.upcomingTurn = upcomingTurn; self.altitudeM = altitudeM
        self.remainAscentM = remainAscentM; self.gradePct = gradePct; self.etaSec = etaSec
    }
    public var snap: GeoPoint { GeoPoint(lat: snapLat, lon: snapLon) }
}

/// Android `SpeedLimit` (OverpassClient.kt:20). `kmh == nil` with a label means "none/variable…".
public struct SpeedLimit: Sendable, Equatable, Codable {
    public var kmh: Int?
    public var label: String
    public init(kmh: Int?, label: String) { self.kmh = kmh; self.label = label }
}

/// A GPS fix as consumed by the nav engine, trips and the dash. Produced from CLLocation on iOS.
public struct LocationFix: Sendable, Equatable, Codable {
    public var lat: Double
    public var lon: Double
    /// m/s; nil when unknown (CLLocation.speed < 0).
    public var speedMps: Double?
    /// degrees 0..360 clockwise from north; nil when unknown (course < 0).
    public var courseDeg: Double?
    /// horizontal accuracy in metres; nil when unknown.
    public var accuracyM: Double?
    public var altitudeM: Double?
    /// Wall-clock time of the fix (ms since 1970).
    public var timeMs: Int64
    public init(lat: Double, lon: Double, speedMps: Double? = nil, courseDeg: Double? = nil, accuracyM: Double? = nil,
                altitudeM: Double? = nil, timeMs: Int64) {
        self.lat = lat; self.lon = lon; self.speedMps = speedMps; self.courseDeg = courseDeg
        self.accuracyM = accuracyM; self.altitudeM = altitudeM; self.timeMs = timeMs
    }
    public var point: GeoPoint { GeoPoint(lat: lat, lon: lon) }
    /// Android "moving": hasSpeed && speed > 1.2 m/s.
    public var isMoving: Bool { (speedMps ?? 0) > 1.2 }
}
