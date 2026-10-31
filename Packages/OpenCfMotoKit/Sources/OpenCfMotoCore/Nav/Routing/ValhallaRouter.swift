// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) ValhallaRouter.kt
//
// Valhalla turn-by-turn via the public FOSSGIS OSM.de instance — no API key
// (docs/spec/navigation-dash.md §6.3). "Avoid highways" = `motorcycle` costing with
// `exclude_highways: true` (DN/trunk roads allowed, motorways banned). Never `use_highways=0`
// on `auto`: it over-penalises national roads and invents 8–10 h detours.

import Foundation

/// Client for `valhalla1.openstreetmap.de/route`.
public struct ValhallaRouter: Sendable {
    public static let routeURL = URL(string: "https://valhalla1.openstreetmap.de/route")!

    public let http: HTTPClient

    public init(http: HTTPClient) { self.http = http }

    // MARK: Request

    /// Request body with Android's insertion-ordered keys, e.g.
    /// `{"locations":[{"lat":44.4268,"lon":26.1025},…],"costing":"auto","costing_options":{"auto":
    /// {"shortest":false}},"directions_options":{"units":"kilometers"},"alternates":2}`.
    /// `alternates` is present only when `clamp(alternatives, 0, 3) > 0`.
    public static func requestBody(from: GeoPoint, to: GeoPoint, options: RouteOptions, vias: [GeoPoint] = [],
                                   alternatives: Int = 0) -> OrderedJSONObject {
        func loc(_ p: GeoPoint) -> JSONValue {
            var o = OrderedJSONObject()
            o.put("lat", p.lat)
            o.put("lon", p.lon)
            return .object(o)
        }
        var locations: [JSONValue] = [loc(from)]
        for v in vias { locations.append(loc(v)) }
        locations.append(loc(to))
        let profile = options.avoidHighways ? "motorcycle" : "auto"
        var costing = OrderedJSONObject()
        costing.put("shortest", false)
        if options.avoidHighways { costing.put("exclude_highways", true) }
        if options.avoidTolls {
            costing.put("use_tolls", 0)
            costing.put("toll_booth_penalty", 600)
        }
        var costingOptions = OrderedJSONObject()
        costingOptions.put(profile, costing)
        var directions = OrderedJSONObject()
        directions.put("units", "kilometers")
        var body = OrderedJSONObject()
        body.put("locations", .array(locations))
        body.put("costing", profile)
        body.put("costing_options", costingOptions)
        body.put("directions_options", directions)
        let alt = min(max(alternatives, 0), 3)
        if alt > 0 { body.put("alternates", alt) }
        return body
    }

    /// Label used when the caller gives none: "No hwy/toll" / "No highway" / "No toll" / "Fast".
    public static func avoidLabel(_ options: RouteOptions) -> String {
        if options.avoidHighways && options.avoidTolls { return "No hwy/toll" }
        if options.avoidHighways { return "No highway" }
        if options.avoidTolls { return "No toll" }
        return "Fast"
    }

    // MARK: Routing

    /// Routes sorted by duration. Trips crossing ≥ 1 km of motorway (avoid highways) or toll
    /// (avoid tolls) are dropped unless none survive. Throws "No Valhalla route" when empty.
    public func routes(from: GeoPoint, to: GeoPoint, options: RouteOptions = RouteOptions(), vias: [GeoPoint] = [],
                       alternatives: Int = 0, label: String = "") async throws -> [Route] {
        let body = Self.requestBody(from: from, to: to, options: options, vias: vias, alternatives: alternatives)
        Log.i("NAV", "[route] Valhalla profile=\(options.avoidHighways ? "motorcycle" : "auto") avoidHwy=\(options.avoidHighways) avoidToll=\(options.avoidTolls) alts=\(alternatives) vias=\(vias.count)")
        let request = NavHTTP.postJSONRequest(Self.routeURL, json: body.jsonString, policy: .valhalla)
        let data = try await NavHTTP.fetch(http, request, maxBytes: NavHTTPPolicy.valhalla.maxBytes)
        return try Self.parse(data, options: options, label: label)
    }

    // MARK: Parsing

    struct ParsedTrip {
        var route: Route
        var motorwayKm: Double
        var tollKm: Double
    }

    /// Parses `trip` (label = `label` or the avoid label) and `alternates[].trip` (label "Alt").
    public static func parse(_ data: Data, options: RouteOptions, label: String = "") throws -> [Route] {
        let root = try NavJSON.parse(data)
        var parsed: [ParsedTrip] = []
        let trip = root["trip"]
        if trip.object != nil, let p = parseTrip(trip, label: label.isNavBlank ? avoidLabel(options) : label) {
            parsed.append(p)
        }
        for alt in root["alternates"].elements {
            let t = alt["trip"]
            guard t.object != nil else { continue }
            if let p = parseTrip(t, label: "Alt") { parsed.append(p) }
        }
        var filtered = parsed.filter { p in
            let hwyOk = !options.avoidHighways || p.motorwayKm < 1.0
            let tollOk = !options.avoidTolls || p.tollKm < 1.0
            return hwyOk && tollOk
        }
        if filtered.isEmpty { filtered = parsed } // best effort if every alternate clipped a ramp
        let out = navStableSorted(filtered, by: { $0.route.durationSec }).map(\.route)
        if out.isEmpty { throw NavServiceError.service("No Valhalla route") }
        return out
    }

    static func parseTrip(_ trip: NavJSON, label: String) -> ParsedTrip? {
        let legs = trip["legs"]
        guard legs.array != nil, legs.count > 0 else { return nil }
        var allPts: [TrackPoint] = []
        var allSteps: [RouteStep] = []
        var distKm = 0.0
        var timeSec = 0.0
        var motorwayKm = 0.0
        var tollKm = 0.0
        for leg in legs.elements {
            let pts = PolylineCodec.decodeTrackPoints(leg["shape"].string(""), precision: 6)
            if pts.count < 2 { continue }
            if allPts.isEmpty { allPts.append(contentsOf: pts) } else { allPts.append(contentsOf: pts.dropFirst()) }
            let summary = leg["summary"]
            distKm += summary.object != nil ? summary["length"].double(0) : 0
            timeSec += summary.object != nil ? summary["time"].double(0) : 0
            let maneuvers = leg["maneuvers"]
            guard maneuvers.array != nil else { continue }
            for m in maneuvers.elements {
                let begin = m["begin_shape_index"].int(0)
                let at = pts[min(max(begin, 0), pts.count - 1)]
                var road = ""
                for (ni, n) in m["street_names"].elements.enumerated() {
                    if ni > 0 { road += "/" }
                    road += n.string("")
                }
                let lenKm = m["length"].double(0)
                if m["highway"].bool(false) || looksLikeMotorway(road) { motorwayKm += lenKm }
                if m["toll"].bool(false) { tollKm += lenKm }
                let (type, modifier) = mapManeuver(m["type"].int(0))
                let roadName = road.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                allSteps.append(RouteStep(maneuverType: type, modifier: modifier, roadName: roadName,
                                          maneuverLat: at.lat, maneuverLon: at.lon, distanceM: lenKm * 1000.0,
                                          exit: nil, lanes: nil))
            }
        }
        if allPts.count < 2 { return nil }
        let summary = trip["summary"]
        if distKm <= 0 { distKm = summary.object != nil ? summary["length"].double(0) : 0 }
        if timeSec <= 0 { timeSec = summary.object != nil ? summary["time"].double(0) : 0 }
        return ParsedTrip(route: Route(points: allPts, distanceM: distKm * 1000.0, durationSec: timeSec,
                                       steps: allSteps, label: label),
                          motorwayKm: motorwayKm, tollKm: tollKm)
    }

    private static let motorwayRef = try! NSRegularExpression(pattern: #"(?<![a-z])a\s?\d{1,3}(?!\d*[a-z])"#,
                                                              options: [.caseInsensitive])

    /// Romanian / EU motorway names: autostrada / autobahn / autoroute, or a bare "A2" / "A 12" ref
    /// (not "DN2A" / "DJ12A").
    public static func looksLikeMotorway(_ road: String) -> Bool {
        if road.isNavBlank { return false }
        let r = road.lowercased()
        if r.contains("autostrada") || r.contains("autobahn") || r.contains("autoroute") { return true }
        let range = NSRange(road.startIndex ..< road.endIndex, in: road)
        return motorwayRef.firstMatch(in: road, options: [], range: range) != nil
    }

    /// Valhalla maneuver type → OSRM-style (type, modifier) used by `RouteFollower`.
    public static func mapManeuver(_ t: Int) -> (String, String?) {
        switch t {
        case 1, 2, 3: return ("depart", nil)          // Start / StartRight / StartLeft
        case 4, 5, 6: return ("arrive", nil)          // Destination*
        case 7, 8: return ("continue", "straight")    // Becomes / Continue
        case 9: return ("turn", "slight right")
        case 10: return ("turn", "right")
        case 11: return ("turn", "sharp right")
        case 12: return ("turn", "uturn")             // UturnRight
        case 13: return ("turn", "uturn")             // UturnLeft
        case 14: return ("turn", "sharp left")
        case 15: return ("turn", "left")
        case 16: return ("turn", "slight left")
        case 17: return ("on ramp", "straight")       // RampStraight
        case 18: return ("on ramp", "right")
        case 19: return ("on ramp", "left")
        case 20: return ("off ramp", "right")         // ExitRight
        case 21: return ("off ramp", "left")
        case 22: return ("continue", "straight")      // StayStraight
        case 23: return ("fork", "right")             // StayRight
        case 24: return ("fork", "left")
        case 25: return ("merge", nil)
        case 26: return ("roundabout", nil)           // RoundaboutEnter
        case 27: return ("exit roundabout", nil)
        case 28, 29: return ("ferry", nil)
        default: return ("continue", "straight")
        }
    }
}

/// Stable sort (Kotlin `sortedBy` is stable; Swift's `sorted` is not guaranteed to be).
func navStableSorted<T>(_ items: [T], by key: (T) -> Double) -> [T] {
    items.enumerated().sorted { a, b in
        let ka = key(a.element), kb = key(b.element)
        if ka != kb { return ka < kb }
        return a.offset < b.offset
    }.map(\.element)
}
