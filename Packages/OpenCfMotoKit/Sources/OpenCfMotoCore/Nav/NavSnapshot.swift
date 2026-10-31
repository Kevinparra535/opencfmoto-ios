// SPDX-License-Identifier: AGPL-3.0-or-later
// CONTRACT FILE — what the navigation engine (Nav/NavigationSession.swift) publishes for the dash
// UI (Dash/) and the phone UI. The engine owns ALL navigation state (mode, destination, preview
// candidates, active route, progress, arrival, reroute) and pre-formats the HUD strings exactly
// as Android does (docs/spec/navigation-dash.md §4, §11.7). The dash UI only lays them out.

import Foundation

public enum NavMode: Sendable, Equatable {
    case freeRide
    /// Following a GPX track (name shown in the HUD).
    case gpx(name: String)
    /// Navigating to a place.
    case navTo(Place)

    public var isNavigating: Bool {
        if case .freeRide = self { return false }
        return true
    }
}

/// The maneuver row of the nav card (icon + big distance + road/instruction + lanes).
public struct HudCue: Sendable, Equatable {
    /// Icon to draw (ic_man_* mapping: MERGE_*/FORK_* share one icon, STRAIGHT/CONTINUE share one).
    public var dir: TurnDir
    /// e.g. "350 m", "1.2 km", "GPS".
    public var distanceText: String
    /// Road name or maneuver word, e.g. "Calle 80", "Turn left", "To Bogotá".
    public var text: String
    /// Lane arrows ("↑ ↑ →") or nil.
    public var lanes: String?
    public init(dir: TurnDir, distanceText: String, text: String, lanes: String? = nil) {
        self.dir = dir; self.distanceText = distanceText; self.text = text; self.lanes = lanes
    }
}

/// The metrics card (TIME / ARRIVE / LEFT / ALT) + status line.
public struct HudMetrics: Sendable, Equatable {
    public var time: String      // formatEta, "—" when unknown
    public var arrive: String    // "HH:mm", "—"
    public var left: String      // formatDistance(remain), "—"
    public var alt: String       // formatAltitude, "—"
    /// Altitude unit label for the ALT column: "m" / "ft".
    public var altUnit: String
    /// Status line, e.g. "Route · 12.3 km · OFF 95 m".
    public var status: String
    /// Off route > 80 m → status shown in warning colour #FF8A80.
    public var statusWarning: Bool
    public init(time: String = "—", arrive: String = "—", left: String = "—", alt: String = "—", altUnit: String = "m",
                status: String = "", statusWarning: Bool = false) {
        self.time = time; self.arrive = arrive; self.left = left; self.alt = alt; self.altUnit = altUnit
        self.status = status; self.statusWarning = statusWarning
    }
}

/// Route preview (search result / dropped pin / Go Home) with candidate routes ("chips").
public struct RoutePreview: Sendable, Equatable {
    public var place: Place
    public var routes: [Route]
    public var selectedIndex: Int
    /// Meta line under the name, e.g. "10.2 km · 14:14 · city · Prahova".
    public var meta: String
    /// Chip labels in order, e.g. "★ Fast · 14:14 · 10.2 km".
    public var chipLabels: [String]
    /// Routing request in flight.
    public var loading: Bool
    public var isCircuit: Bool
    /// Dropped-pin setup (Home / Marker actions, "Done" instead of "Cancel").
    public var pinMode: Bool
    public init(place: Place, routes: [Route] = [], selectedIndex: Int = 0, meta: String = "", chipLabels: [String] = [],
                loading: Bool = false, isCircuit: Bool = false, pinMode: Bool = false) {
        self.place = place; self.routes = routes; self.selectedIndex = selectedIndex; self.meta = meta
        self.chipLabels = chipLabels; self.loading = loading; self.isCircuit = isCircuit; self.pinMode = pinMode
    }
    public var selectedRoute: Route? { routes.indices.contains(selectedIndex) ? routes[selectedIndex] : nil }
}

/// Arrive card (after "Destination reached" when auto-finish offers parking).
public struct ArrivalCard: Sendable, Equatable {
    public var title: String
    public var meta: String
    public init(title: String, meta: String) { self.title = title; self.meta = meta }
}

/// Everything the dash/phone UI needs from navigation, published after every fix / command.
public struct NavSnapshot: Sendable, Equatable {
    public var mode: NavMode
    public var destination: Place?
    /// Active route (NAV_TO road route or the GPX track as a Route); nil in free ride.
    public var route: Route?
    public var progress: RouteProgress?
    /// Nav card content (nil = hidden). While navigating it is never nil (seeded "GPS" / "To …").
    public var cue: HudCue?
    public var metrics: HudMetrics
    public var preview: RoutePreview?
    public var arrival: ArrivalCard?
    /// NAV_TO without a road route yet: dashed rider→destination line.
    public var showStraightLineToDestination: Bool
    /// Puck position (snapped when within 40 m of the route) and bearing for the map.
    public var puck: GeoPoint?
    public var puckBearingDeg: Double
    public var speedLimit: SpeedLimit?
    /// Saved places / overlays to draw as pins (destination pin drawn separately).
    public var pins: [Place]
    /// Monotonic counter, bumped on every change.
    public var revision: UInt64

    public init(mode: NavMode = .freeRide, destination: Place? = nil, route: Route? = nil, progress: RouteProgress? = nil,
                cue: HudCue? = nil, metrics: HudMetrics = HudMetrics(), preview: RoutePreview? = nil, arrival: ArrivalCard? = nil,
                showStraightLineToDestination: Bool = false, puck: GeoPoint? = nil, puckBearingDeg: Double = 0,
                speedLimit: SpeedLimit? = nil, pins: [Place] = [], revision: UInt64 = 0) {
        self.mode = mode; self.destination = destination; self.route = route; self.progress = progress
        self.cue = cue; self.metrics = metrics; self.preview = preview; self.arrival = arrival
        self.showStraightLineToDestination = showStraightLineToDestination; self.puck = puck
        self.puckBearingDeg = puckBearingDeg; self.speedLimit = speedLimit; self.pins = pins; self.revision = revision
    }
}

/// Side effects requested by the navigation engine (performed by the app layer).
public enum NavEffect: Sendable, Equatable {
    /// Speak a phrase (QUEUE_FLUSH semantics: stop current speech first).
    case speak(String)
    /// Short on-screen status / toast text.
    case toast(String)
    /// Places store changed (favorite/home/parked/marker/history) — persist & refresh lists.
    case placesChanged
}
