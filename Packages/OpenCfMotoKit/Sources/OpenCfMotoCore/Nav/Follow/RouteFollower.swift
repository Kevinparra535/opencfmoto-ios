// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) GpxNav.kt
//
// Route-following maths (docs/spec/navigation-dash.md §4.1–§4.6): windowed snapping with a forward
// cursor, progress / remaining / ETA, next maneuver (router steps or geometric inference for GPX
// tracks), waypoints, grade and ascent.
//
// `parityMode == true` reproduces Android exactly (used by the golden-vector tests). The default
// (`false`) enables the iOS fixes recommended by the spec (§4.2 note, §4.3 pitfalls, §15.2):
//  (a) step indices are assigned monotonically along the route (out-and-back / circuit return-leg
//      maneuvers no longer snap onto the outbound leg);
//  (b) intermediate `arrive` steps (one per via / leg) are skipped instead of hiding every cue until
//      the via is passed; `depart` steps are skipped as before;
//  (c) the distance to a maneuver is measured from the snapped position (`cumDist[idx] − doneM`)
//      instead of from the nearest vertex;
//  (d) on coincident legs (an out-and-back circuit returns along the same centre line) a vertex at
//      or after the cursor that ties within 3 m wins, so the cursor can leave the turnaround —
//      Android's "no backward hop" rule otherwise pins it there for the whole return leg.

import Foundation

/// Follows a track or road route and computes `RouteProgress` per GPS fix (Android `GpxNav`).
///
/// A value type: `progress(...)` is `mutating` because it advances the snapping cursor. Not meant to
/// be shared between threads without external synchronisation (`NavigationSession` owns one).
public struct RouteFollower: Sendable {
    /// Off-route distance above which guidance switches to "join the route" (`OFF_ROUTE_GUIDE_M`).
    public static let offRouteGuideM = 40.0
    /// Distance tolerance treating a vertex at/after the cursor as tied with an earlier one (fix (d)).
    static let coincidentTieM = 3.0

    public let track: GpxTrack
    /// Router guidance steps (empty for GPX tracks or a route without steps → geometric turns).
    public let steps: [RouteStep]
    /// Cumulative haversine distance to each vertex.
    public let cumDistM: [Double]
    public let totalM: Double
    /// Cumulative positive elevation gain at each vertex.
    public let cumAscentM: [Double]
    /// At least `max(n/2, 2)` vertices carry an elevation.
    public let hasElevation: Bool
    public let totalAscentM: Double
    /// Track index of each step's maneuver point (parallel to `steps`).
    public let stepIndex: [Int]
    /// Android behaviour without the iOS fixes (see file header).
    public let parityMode: Bool
    /// Language / decimal separator of the cue texts.
    public var strings: NavStrings
    /// Last snapped vertex — keeps the rider on the forward leg.
    public private(set) var cursor: Int = 0

    private let waypointTrackIndex: [Int]
    /// Index in `steps` of the last `arrive` step (the real destination), if any.
    private let finalArriveStep: Int?

    public init(track: GpxTrack, steps: [RouteStep]? = nil, parityMode: Bool = false, strings: NavStrings = .english) {
        self.track = track
        self.steps = steps ?? []
        self.parityMode = parityMode
        self.strings = strings
        let pts = track.points
        let n = pts.count
        var cum = [Double](repeating: 0, count: n)
        var cumAsc = [Double](repeating: 0, count: n)
        var acc = 0.0
        var asc = 0.0
        var elevCount = 0
        for i in 0 ..< n {
            if pts[i].ele != nil { elevCount += 1 }
            if i > 0 {
                acc += GeoMath.haversineM(pts[i - 1].lat, pts[i - 1].lon, pts[i].lat, pts[i].lon)
                if let e0 = pts[i - 1].ele, let e1 = pts[i].ele, e1 > e0 { asc += e1 - e0 }
            }
            cum[i] = acc
            cumAsc[i] = asc
        }
        cumDistM = cum
        cumAscentM = cumAsc
        totalM = acc
        hasElevation = elevCount >= max(n / 2, 2)
        totalAscentM = asc

        let stepList = self.steps
        if stepList.isEmpty || n == 0 {
            stepIndex = []
        } else if parityMode {
            // Android: global nearest vertex for every maneuver.
            stepIndex = stepList.map { s in Self.nearestIndex(pts, s.maneuverLat, s.maneuverLon, from: 0) }
        } else {
            stepIndex = Self.monotonicStepIndices(pts, stepList)
        }
        finalArriveStep = stepList.lastIndex(where: { $0.maneuverType == "arrive" })
        waypointTrackIndex = n == 0 ? [] : track.waypoints.map { Self.nearestIndex(pts, $0.lat, $0.lon, from: 0) }
    }

    /// Follower for a road route (`GpxNav(OsrmRouter.toTrack(name, route), route.steps)`).
    public init(route: Route, name: String = "", parityMode: Bool = false, strings: NavStrings = .english) {
        self.init(track: GpxTrack(name: name, points: route.points, waypoints: []), steps: route.steps,
                  parityMode: parityMode, strings: strings)
    }

    /// The followed geometry as a `Route` (GPX tracks get label "GPX" and no steps/duration).
    public func asRoute(label: String = "GPX", durationSec: Double = 0) -> Route {
        Route(points: track.points, distanceM: totalM, durationSec: durationSec, steps: steps, label: label)
    }

    // MARK: - Step index assignment

    static func nearestIndex(_ pts: [TrackPoint], _ lat: Double, _ lon: Double, from: Int) -> Int {
        var bi = from
        var bd = Double.greatestFiniteMagnitude
        var i = from
        while i < pts.count {
            let d = GeoMath.haversineM(lat, lon, pts[i].lat, pts[i].lon)
            if d < bd { bd = d; bi = i }
            i += 1
        }
        return bi
    }

    /// iOS fix (a): every maneuver is searched from the previous maneuver's index forward. Within
    /// that range the first local minimum closer than 5 m wins (router maneuver points are route
    /// vertices, so an out-and-back's return leg can't steal an outbound maneuver); otherwise the
    /// forward global minimum.
    static func monotonicStepIndices(_ pts: [TrackPoint], _ steps: [RouteStep]) -> [Int] {
        let snapTolM = 5.0
        var out: [Int] = []
        out.reserveCapacity(steps.count)
        var from = 0
        for s in steps {
            var bestI = from
            var bestD = Double.greatestFiniteMagnitude
            var nearI: Int?
            var nearD = Double.greatestFiniteMagnitude
            var i = from
            while i < pts.count {
                let d = GeoMath.haversineM(s.maneuverLat, s.maneuverLon, pts[i].lat, pts[i].lon)
                if d < bestD { bestD = d; bestI = i }
                if d < snapTolM {
                    if nearI == nil || d < nearD { nearI = i; nearD = d }
                } else if nearI != nil {
                    break // left the first close-approach region
                }
                i += 1
            }
            let idx = nearI ?? bestI
            out.append(idx)
            from = idx
        }
        return out
    }

    // MARK: - Progress

    /// Per-fix progress (Android `GpxNav.progress`). Returns nil for an empty track.
    /// - Parameters:
    ///   - speedMps: GPS speed (unknown → 0); drives the ETA (50 km/h floor below 1.5 m/s).
    ///   - gpsAltitudeM: GPS altitude; falls back to the track elevation at the snapped vertex.
    public mutating func progress(lat: Double, lon: Double, speedMps: Double = 0, gpsAltitudeM: Double? = nil,
                                  units: MapUnits = .metric) -> RouteProgress? {
        let pts = track.points
        guard !pts.isEmpty else { return nil }
        let n = pts.count
        let searchFrom = max(cursor - 8, 0)
        var bestI = min(max(cursor, 0), n - 1)
        var bestD = Double.greatestFiniteMagnitude
        for i in searchFrom ..< n {
            let d = GeoMath.haversineM(lat, lon, pts[i].lat, pts[i].lon)
            if d < bestD { bestD = d; bestI = i }
        }
        if !parityMode && bestD <= 80.0 && bestI < cursor {
            // iOS fix (d): coincident legs (out-and-back circuits share the road centre line). A tie
            // (within 3 m) at or after the cursor wins over the earlier leg, otherwise the cursor
            // stays pinned at the turnaround forever (Android).
            var i = max(cursor, searchFrom)
            while i < n {
                let d = GeoMath.haversineM(lat, lon, pts[i].lat, pts[i].lon)
                if d <= bestD + Self.coincidentTieM { bestD = d; bestI = i; break }
                i += 1
            }
        }
        if bestD > 80.0 {
            for i in 0 ..< n {
                let d = GeoMath.haversineM(lat, lon, pts[i].lat, pts[i].lon)
                if d < bestD { bestD = d; bestI = i }
            }
        } else if bestI < cursor {
            let backM = cumDistM[cursor] - cumDistM[bestI]
            if backM > 40.0 { bestI = cursor }
        }
        cursor = bestI
        let snap = snapToRoute(lat: lat, lon: lon, index: bestI)
        let done = min(max(cumDistM[bestI] + snap.along, 0), totalM)
        let remain = max(totalM - done, 0)
        let bearing = Double(bearingAtF(bestI))
        let nextWpt = nextWaypointAhead(fromIndex: bestI, lat: lat, lon: lon)
        // iOS fix (c): scan from the segment the rider is on (the snap may lie on the segment
        // ending at bestI); otherwise a geometric turn at vertex bestI vanishes ~half a segment
        // before the corner and the "execute" cue never fires on sparse tracks.
        let scanFrom = (!parityMode && snap.along < 0) ? max(bestI - 1, 0) : bestI
        let turn = upcomingTurn(fromIndex: scanFrom, units: units, riderAlongM: parityMode ? nil : done)
        let alt = gpsAltitudeM ?? pts[bestI].ele
        let remainAsc: Double? = hasElevation ? max(totalAscentM - cumAscentM[bestI], 0) : nil
        let grade = gradeAhead(fromIndex: bestI, windowM: 150)
        let eta = NavFormat.etaSeconds(remainM: remain, speedMps: speedMps)
        return RouteProgress(nearestIndex: bestI, doneM: done, remainM: remain, offTrackM: snap.dist,
                             snapLat: snap.lat, snapLon: snap.lon, nextWaypoint: nextWpt?.0, nextWaypointM: nextWpt?.1,
                             trackBearingDeg: bearing, upcomingTurn: turn, altitudeM: alt, remainAscentM: remainAsc,
                             gradePct: grade, etaSec: eta)
    }

    private struct Snap { var lat: Double; var lon: Double; var dist: Double; var along: Double }

    /// Projects onto the two segments touching vertex `index` (`GpxNav.snapToRoute`).
    private func snapToRoute(lat: Double, lon: Double, index i: Int) -> Snap {
        let pts = track.points
        if pts.count < 2 { return Snap(lat: pts[i].lat, lon: pts[i].lon, dist: 0, along: 0) }
        var best = Snap(lat: pts[i].lat, lon: pts[i].lon, dist: Double.greatestFiniteMagnitude, along: 0)
        for (ai, bi) in [(i - 1, i), (i, i + 1)] {
            if ai < 0 || bi > pts.count - 1 { continue }
            let a = pts[ai], b = pts[bi]
            let p = GeoMath.projectOntoSegment(lat: lat, lon: lon, aLat: a.lat, aLon: a.lon, bLat: b.lat, bLon: b.lon)
            if p.distanceM < best.dist {
                let along = ai == i ? p.t * p.segmentLengthM : -(1.0 - p.t) * p.segmentLengthM
                best = Snap(lat: p.lat, lon: p.lon, dist: p.distanceM, along: along)
            }
        }
        return best
    }

    /// `points[0 ... index]` (at least one point) — the grey "done" polyline.
    public func pointsDone(_ index: Int) -> [TrackPoint] {
        let pts = track.points
        guard !pts.isEmpty else { return [] }
        return Array(pts[0 ..< min(max(index + 1, 1), pts.count)])
    }

    /// `points[index ...]` — the blue "remaining" polyline.
    public func pointsRemain(_ index: Int) -> [TrackPoint] {
        let pts = track.points
        guard !pts.isEmpty else { return [] }
        return Array(pts[min(max(index, 0), pts.count - 1) ..< pts.count])
    }

    // MARK: - Maneuvers

    /// Next maneuver ahead of vertex `fromIndex` (`GpxNav.upcomingTurn`).
    /// Road routes use the router steps (never fake geometric turns when steps exist); GPX tracks
    /// infer turns ≥ `minTurnDeg` from the geometry within `lookAheadM`.
    /// - Parameter riderAlongM: rider's along-route distance (snapped). When given, cue distances
    ///   are measured from it (iOS fix (c)); nil = from the vertex (Android).
    public func upcomingTurn(fromIndex: Int, lookAheadM: Double = 900, minTurnDeg: Double = 38,
                             units: MapUnits = .metric, riderAlongM: Double? = nil) -> TurnCue? {
        if !steps.isEmpty {
            return stepCue(fromIndex: fromIndex, units: units, riderAlongM: riderAlongM)
        }
        let pts = track.points
        let last = pts.count - 1
        if fromIndex >= last { return nil }
        let startDist = fromIndex >= 0 && fromIndex < cumDistM.count ? cumDistM[fromIndex] : 0
        let origin = riderAlongM ?? startDist
        let endDist = startDist + lookAheadM
        let minTurn = Float(minTurnDeg)
        var i = fromIndex
        var prevBrng = bearingAtF(fromIndex)
        var lastSampleDist = startDist
        while i < last && cumDistM[i] <= endDist {
            i += 1
            let d = cumDistM[i]
            if d - lastSampleDist < 40.0 && i < last { continue }
            lastSampleDist = d
            let brng = bearingAtF(min(i, last - 1))
            let delta = GeoMath.normalizeDeltaF(brng - prevBrng)
            if abs(delta) >= minTurn {
                let dir: TurnDir
                if delta > 100 { dir = .sharpRight } else if delta < -100 { dir = .sharpLeft } else if delta > 0 { dir = .right } else { dir = .left }
                let distFromRider = max(d - origin, 0)
                let distLabel = strings.distance(distFromRider, units)
                let word = strings.geometricTurnWord(dir)
                return TurnCue(index: i, distanceAlongM: d, distanceFromRiderM: distFromRider, dir: dir,
                               speak: strings.inDistance(distLabel, word),
                               shortLabel: "\(strings.geometricShortLabel(dir)) · \(distLabel)", instr: word)
            }
            prevBrng = brng
        }
        return nil
    }

    /// Next router maneuver ahead of `fromIndex` with road name and lanes (`GpxNav.stepCue`).
    private func stepCue(fromIndex: Int, units: MapUnits, riderAlongM: Double?) -> TurnCue? {
        guard !steps.isEmpty, !stepIndex.isEmpty else { return nil }
        let startDist = fromIndex >= 0 && fromIndex < cumDistM.count ? cumDistM[fromIndex] : 0
        let origin = riderAlongM ?? startDist
        for s in steps.indices {
            let step = steps[s]
            let type = step.maneuverType
            if type == "depart" { continue }
            let idx = stepIndex[s]
            // Small tolerance so a maneuver just behind the snapped point still shows.
            if idx < fromIndex - 1 { continue }
            let along = idx >= 0 && idx < cumDistM.count ? cumDistM[idx] : startDist
            let dist = along - origin
            if dist < -15.0 { continue }
            if type == "arrive" {
                // iOS fix (b): an intermediate arrival (via / leg end) is not the destination.
                if !parityMode, let finalArriveStep, s != finalArriveStep { continue }
                // Arrival is handled by the destination logic; skip as a turn banner.
                if dist <= 25.0 { continue } else { return nil }
            }
            let dir = Self.dirFor(type: type, modifier: step.modifier)
            let distFromRider = max(dist, 0)
            let distLabel = strings.distance(distFromRider, units)
            let road: String? = step.roadName.isNavBlank ? nil : step.roadName
            let instr = strings.instruction(type: type, modifier: step.modifier, road: road, exit: step.exit)
            var short = Self.arrowFor(dir)
            if let road { short += " " + road }
            short += " · " + distLabel
            return TurnCue(index: idx, distanceAlongM: along, distanceFromRiderM: distFromRider, dir: dir,
                           speak: strings.inDistance(distLabel, instr), shortLabel: short, instr: instr,
                           roadName: road, laneLabel: Self.laneLabel(step.lanes))
        }
        return nil
    }

    // MARK: - Waypoints, grade

    private func gradeAhead(fromIndex: Int, windowM: Double) -> Double? {
        guard hasElevation else { return nil }
        let pts = track.points
        let start = cumDistM[fromIndex]
        guard let e0 = pts[fromIndex].ele else { return nil }
        var i = fromIndex
        while i < pts.count - 1 && cumDistM[i] - start < windowM { i += 1 }
        guard let e1 = pts[i].ele else { return nil }
        let dist = max(cumDistM[i] - start, 1.0)
        return ((e1 - e0) / dist) * 100.0
    }

    /// Nearest waypoint not behind the rider (straight-line distance), else the nearest overall.
    private func nextWaypointAhead(fromIndex: Int, lat: Double, lon: Double) -> (TrackPoint, Double)? {
        let wps = track.waypoints
        guard !wps.isEmpty else { return nil }
        let aheadFrom = cumDistM[fromIndex]
        var best: (TrackPoint, Double)?
        for (k, w) in wps.enumerated() {
            if cumDistM[waypointTrackIndex[k]] + 30 < aheadFrom { continue }
            let dRide = GeoMath.haversineM(lat, lon, w.lat, w.lon)
            if best == nil || dRide < best!.1 { best = (w, dRide) }
        }
        if let best { return best }
        var fallback: (TrackPoint, Double)?
        for w in wps {
            let d = GeoMath.haversineM(lat, lon, w.lat, w.lon)
            if fallback == nil || d < fallback!.1 { fallback = (w, d) }
        }
        return fallback
    }

    /// Bearing of segment `k → k+1` with `k = clamp(index, 0, n−2)`; 0 for < 2 points.
    public func bearingAt(_ index: Int) -> Double { Double(bearingAtF(index)) }

    func bearingAtF(_ index: Int) -> Float {
        let pts = track.points
        if pts.count < 2 { return 0 }
        let i = min(max(index, 0), max(pts.count - 2, 0))
        let a = pts[i], b = pts[min(i + 1, pts.count - 1)]
        return GeoMath.bearingDegF(a.lat, a.lon, b.lat, b.lon)
    }

    // MARK: - Static vocabulary (Android companion)

    /// OSRM type + modifier → `TurnDir` (`GpxNav.dirFor`).
    public static func dirFor(type: String, modifier: String?) -> TurnDir {
        let m = modifier?.lowercased()
        switch type.lowercased() {
        case "roundabout", "rotary", "roundabout turn", "exit roundabout", "exit rotary": return .roundabout
        case "merge": return (m?.contains("left") ?? false) ? .mergeLeft : .mergeRight
        case "fork": return (m?.contains("left") ?? false) ? .forkLeft : .forkRight
        case "arrive": return .arrive
        default:
            switch m {
            case "uturn"?: return .uturn
            case "sharp left"?: return .sharpLeft
            case "sharp right"?: return .sharpRight
            case "slight left"?: return .slightLeft
            case "slight right"?: return .slightRight
            case "left"?: return .left
            case "right"?: return .right
            case "straight"?: return .straight
            default: return .continue
            }
        }
    }

    /// English instruction (`GpxNav.instruction`); see `NavStrings.instruction` for Spanish.
    public static func instruction(type: String, modifier: String?, road: String?, exit: Int?) -> String {
        NavStrings.english.instruction(type: type, modifier: modifier, road: road, exit: exit)
    }

    /// Compact arrow per direction (`GpxNav.arrowFor`).
    public static func arrowFor(_ dir: TurnDir) -> String {
        switch dir {
        case .left: return "←"
        case .right: return "→"
        case .sharpLeft: return "↰"
        case .sharpRight: return "↱"
        case .slightLeft: return "↖"
        case .slightRight: return "↗"
        case .uturn: return "⤺"
        case .roundabout: return "↻"
        case .mergeLeft: return "⇜"
        case .mergeRight: return "⇝"
        case .forkLeft, .forkRight: return "⋔"
        case .straight, .continue: return "↑"
        case .arrive: return "◉"
        }
    }

    /// Lane arrows of the valid lanes joined by a space; nil without usable lane data.
    public static func laneLabel(_ lanes: [Lane]?) -> String? {
        guard let lanes, !lanes.isEmpty else { return nil }
        let valid = lanes.filter { $0.valid }
        guard !valid.isEmpty else { return nil }
        let arrows = valid.map { laneArrow($0.indications) }.joined(separator: " ")
        return arrows.isNavBlank ? nil : arrows
    }

    private static func laneArrow(_ indications: [String]) -> String {
        guard let first = indications.first?.lowercased() else { return "↑" }
        if first.contains("sharp left") { return "↰" }
        if first.contains("sharp right") { return "↱" }
        if first.contains("slight left") { return "↖" }
        if first.contains("slight right") { return "↗" }
        if first.contains("uturn") { return "⤺" }
        if first.contains("left") { return "←" }
        if first.contains("right") { return "→" }
        return "↑"
    }

    /// Which way to turn (relative to `headingDeg`) to face `targetBearingDeg` (`GpxNav.dirToFace`,
    /// evaluated in `Float`): |d|>150 U-turn, >100 sharp, >35 turn, >15 slight, else straight.
    public static func dirToFace(headingDeg: Double, targetBearingDeg: Double) -> TurnDir {
        let d = GeoMath.normalizeDeltaF(Float(targetBearingDeg) - Float(headingDeg))
        if d > 150 || d < -150 { return .uturn }
        if d > 100 { return .sharpRight }
        if d < -100 { return .sharpLeft }
        if d > 35 { return .right }
        if d < -35 { return .left }
        if d > 15 { return .slightRight }
        if d < -15 { return .slightLeft }
        return .straight
    }

    /// English HUD word fallback (`GpxDashUi.maneuverWord`).
    public static func maneuverWord(_ dir: TurnDir) -> String { NavStrings.english.maneuverWord(dir) }
    /// English join-route HUD word (`GpxNav.joinRouteWord`).
    public static func joinRouteWord(_ dir: TurnDir) -> String { NavStrings.english.joinRouteWord(dir) }
    /// English join-route voice phrase (`GpxNav.joinRouteSpeak`).
    public static func joinRouteSpeak(_ dir: TurnDir) -> String { NavStrings.english.joinRouteSpeak(dir) }
}
