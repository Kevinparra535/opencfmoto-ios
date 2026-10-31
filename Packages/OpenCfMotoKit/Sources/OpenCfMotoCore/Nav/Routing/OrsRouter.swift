// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) OrsRouter.kt
//
// OpenRouteService directions, driving-car GeoJSON (docs/spec/navigation-dash.md §6.4). Needs an
// API key; honours avoid highways / tolls; alternative routes for trips under ~100 km.
// The unused `roundTrip` endpoint is not ported (spec R10).

import Foundation

/// Client for `api.openrouteservice.org/v2/directions/driving-car/geojson`.
public struct OrsRouter: Sendable {
    public static let directionsURL = URL(string: "https://api.openrouteservice.org/v2/directions/driving-car/geojson")!

    public let http: HTTPClient

    public init(http: HTTPClient) { self.http = http }

    // MARK: Request

    /// Body in Android key order: coordinates, instructions, geometry, elevation, preference,
    /// [alternative_routes {target_count 3, weight_factor 2, share_factor 0.8}],
    /// [options.avoid_features ["highways","tollways"]].
    /// `preference` = "recommended" when avoiding, "shortest" in FUN mode, else "recommended".
    public static func requestBody(from: GeoPoint, to: GeoPoint, options: RouteOptions, vias: [GeoPoint] = [],
                                   alternatives: Bool) -> OrderedJSONObject {
        func pair(_ p: GeoPoint) -> JSONValue { .array([.double(p.lon), .double(p.lat)]) }
        var coords: [JSONValue] = [pair(from)]
        for v in vias { coords.append(pair(v)) }
        coords.append(pair(to))
        var body = OrderedJSONObject()
        body.put("coordinates", .array(coords))
        body.put("instructions", true)
        body.put("geometry", true)
        body.put("elevation", false)
        let preference: String
        if options.wantsAvoids { preference = "recommended" } else if options.mode == .fun { preference = "shortest" } else { preference = "recommended" }
        body.put("preference", preference)
        if alternatives && options.maxAlternatives > 0 {
            var alt = OrderedJSONObject()
            alt.put("target_count", 3)
            alt.put("weight_factor", 2.0)
            alt.put("share_factor", 0.8)
            body.put("alternative_routes", alt)
        }
        var avoid: [JSONValue] = []
        if options.avoidHighways { avoid.append(.string("highways")) }
        if options.avoidTolls { avoid.append(.string("tollways")) }
        if !avoid.isEmpty {
            var opt = OrderedJSONObject()
            opt.put("avoid_features", .array(avoid))
            body.put("options", opt)
        }
        return body
    }

    // MARK: Routing

    /// Routes from ORS. On failure with `alternatives`, retries once without `alternative_routes`.
    public func routes(apiKey: String, from: GeoPoint, to: GeoPoint, options: RouteOptions = RouteOptions(),
                       vias: [GeoPoint] = [], alternatives: Bool = true, label: String = "") async throws -> [Route] {
        var body = Self.requestBody(from: from, to: to, options: options, vias: vias, alternatives: alternatives)
        if options.wantsAvoids {
            Log.i("NAV", "[route] ORS avoid_features=\(options.avoidHighways ? "highways " : "")\(options.avoidTolls ? "tollways" : "")")
        }
        do {
            return try await postAndParse(apiKey: apiKey, body: body, label: label)
        } catch {
            try Task.checkCancellation()
            guard alternatives else { throw error }
            Log.i("NAV", "[route] ORS alts failed (\(NavServiceError.message(for: error, fallback: "error"))) — retry single")
            body["alternative_routes"] = nil
            return try await postAndParse(apiKey: apiKey, body: body, label: label)
        }
    }

    /// Single route (no alternatives).
    public func route(apiKey: String, from: GeoPoint, to: GeoPoint, options: RouteOptions = RouteOptions(),
                      vias: [GeoPoint] = []) async throws -> Route {
        guard let r = try await routes(apiKey: apiKey, from: from, to: to, options: options, vias: vias,
                                       alternatives: false).first else { throw NavServiceError.service("No route") }
        return r
    }

    /// `Authorization: <key>` first; on ANY failure (HTTP error, network, bad JSON) retry once with
    /// `Authorization: Bearer <key>` unless the key already starts with "Bearer ".
    func postAndParse(apiKey: String, body: OrderedJSONObject, label: String) async throws -> [Route] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let json = body.jsonString
        func post(_ auth: String) async throws -> NavJSON {
            let req = NavHTTP.postJSONRequest(Self.directionsURL, json: json, policy: .ors, extraHeaders: ["Authorization": auth])
            let data = try await NavHTTP.fetch(http, req, maxBytes: NavHTTPPolicy.ors.maxBytes)
            return try NavJSON.parse(data)
        }
        let root: NavJSON
        do {
            root = try await post(key)
        } catch {
            try Task.checkCancellation()
            if key.lowercased().hasPrefix("bearer ") { throw error }
            Log.i("NAV", "[route] ORS auth retry with Bearer (\(NavServiceError.message(for: error, fallback: "error")))")
            root = try await post("Bearer " + key)
        }
        return try Self.parse(root: root, label: label)
    }

    // MARK: Parsing

    /// Parses an ORS GeoJSON directions response.
    public static func parse(_ data: Data, label: String = "") throws -> [Route] {
        try parse(root: try NavJSON.parse(data), label: label)
    }

    static func parse(root: NavJSON, label: String) throws -> [Route] {
        let features = root["features"]
        if features.array == nil || features.count == 0 {
            let err = root["error"]
            var message = "No route"
            if err.object != nil {
                let m = err["message"].string("")
                if !m.isNavBlank { message = m }
            }
            throw NavServiceError.service(message)
        }
        var out: [Route] = []
        for f in features.elements {
            if let r = parseFeature(f, label: label) { out.append(r) }
        }
        if out.isEmpty { throw NavServiceError.service("Route too short") }
        return out
    }

    static func parseFeature(_ f0: NavJSON, label: String) -> Route? {
        let coords = f0["geometry"]["coordinates"]
        guard coords.array != nil else { return nil }
        var pts: [TrackPoint] = []
        pts.reserveCapacity(coords.count)
        for c in coords.elements {
            guard let lon = c[0].doubleOrNil, let lat = c[1].doubleOrNil else { return nil }
            pts.append(TrackPoint(lat: lat, lon: lon))
        }
        if pts.count < 2 { return nil }
        let props = f0["properties"]
        let summary = props["summary"]
        return Route(points: pts,
                     distanceM: summary.object != nil ? summary["distance"].double(0) : 0,
                     durationSec: summary.object != nil ? summary["duration"].double(0) : 0,
                     steps: parseSteps(props, pts), label: label)
    }

    static func parseSteps(_ props: NavJSON, _ pts: [TrackPoint]) -> [RouteStep] {
        var out: [RouteStep] = []
        for seg in props["segments"].elements {
            let steps = seg["steps"]
            guard steps.array != nil else { continue }
            for step in steps.elements {
                let wp = step["way_points"]
                let idx = min(max(wp.array != nil ? wp[0].int(0) : 0, 0), pts.count - 1)
                let at = pts[idx]
                let (type, modifier) = mapType(step.has("type") ? step["type"].int(6) : 6)
                let name = step["name"].string("")
                out.append(RouteStep(maneuverType: type, modifier: modifier, roadName: name == "-" ? "" : name,
                                     maneuverLat: at.lat, maneuverLon: at.lon,
                                     distanceM: step["distance"].double(0),
                                     exit: step.has("exit_number") ? step["exit_number"].int(0) : nil, lanes: nil))
            }
        }
        return out
    }

    /// ORS instruction type → OSRM-style (type, modifier).
    public static func mapType(_ t: Int) -> (String, String?) {
        switch t {
        case 0: return ("turn", "left")
        case 1: return ("turn", "right")
        case 2: return ("turn", "sharp left")
        case 3: return ("turn", "sharp right")
        case 4: return ("turn", "slight left")
        case 5: return ("turn", "slight right")
        case 6: return ("continue", "straight")
        case 7: return ("roundabout", nil)
        case 8: return ("exit roundabout", nil)
        case 9: return ("turn", "uturn")
        case 10: return ("arrive", nil)
        case 11: return ("depart", nil)
        case 12: return ("turn", "slight left") // keep left
        case 13: return ("turn", "slight right") // keep right
        default: return ("continue", "straight")
        }
    }
}
