// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) OsrmRouter.kt
//
// Public OSRM demo server, driving profile (docs/spec/navigation-dash.md §6.2). No avoid flags.

import Foundation

/// Client for `router.project-osrm.org`.
public struct OsrmRouter: Sendable {
    public static let baseURL = "https://router.project-osrm.org/route/v1/driving/"

    public let http: HTTPClient

    public init(http: HTTPClient) { self.http = http }

    // MARK: Request

    /// `{fromLon},{fromLat}[;{viaLon},{viaLat}…];{toLon},{toLat}` with Kotlin `Double.toString()`.
    public static func coordinatePath(from: GeoPoint, to: GeoPoint, vias: [GeoPoint]) -> String {
        var s = NavNumberFormat.javaString(from.lon) + "," + NavNumberFormat.javaString(from.lat)
        for v in vias { s += ";" + NavNumberFormat.javaString(v.lon) + "," + NavNumberFormat.javaString(v.lat) }
        s += ";" + NavNumberFormat.javaString(to.lon) + "," + NavNumberFormat.javaString(to.lat)
        return s
    }

    /// Full: `?overview=full&geometries=geojson&steps=true&alternatives={false|N}`;
    /// simplified fallback: `?overview=simplified&geometries=geojson&steps=false&alternatives=false`.
    /// `alternatives` is clamped to 0…4 (0 → "false").
    public static func routeURL(from: GeoPoint, to: GeoPoint, vias: [GeoPoint] = [], alternatives: Int,
                                simplified: Bool = false) -> URL {
        let query = simplified ? "?overview=simplified&geometries=geojson&steps=false"
            : "?overview=full&geometries=geojson&steps=true"
        let alt = min(max(alternatives, 0), 4)
        let altParam = alt <= 0 ? "&alternatives=false" : "&alternatives=\(alt)"
        let text = baseURL + coordinatePath(from: from, to: to, vias: vias) + query + altParam
        // Coordinates are plain ASCII digits / '.', '-', 'E'; the URL is always valid.
        return URL(string: text)!
    }

    // MARK: Routing

    /// One or several routes through optional `vias` (`OsrmRouter.routes`). `alternatives` is the
    /// count of extra options (clamped 0…4). Fallback chain: with alternatives → full + alts →
    /// full single → simplified single; without → full single → simplified single.
    public func routes(from: GeoPoint, to: GeoPoint, alternatives: Int = 3, vias: [GeoPoint] = [],
                       label: String = "") async throws -> [Route] {
        let altCount = min(max(alternatives, 0), 4)
        func fetch(_ alts: Int, simplified: Bool) async throws -> [Route] {
            let url = Self.routeURL(from: from, to: to, vias: vias, alternatives: alts, simplified: simplified)
            let policy: NavHTTPPolicy = simplified ? .osrmSimplified : .osrmFull
            let body = try await NavHTTP.fetch(http, NavHTTP.getRequest(url, policy: policy), maxBytes: policy.maxBytes)
            return try Self.parse(body, label: label)
        }
        do {
            return try await fetch(altCount, simplified: false)
        } catch {
            try Task.checkCancellation()
            if altCount > 0 {
                Log.i("NAV", "[route] OSRM alts failed (\(NavServiceError.message(for: error, fallback: "error"))) — retry single")
                do {
                    return try await fetch(0, simplified: false)
                } catch {
                    try Task.checkCancellation()
                    Log.i("NAV", "[route] OSRM single failed (\(NavServiceError.message(for: error, fallback: "error"))) — simplified fallback")
                    return try await fetch(0, simplified: true)
                }
            }
            Log.i("NAV", "[route] OSRM full failed (\(NavServiceError.message(for: error, fallback: "error"))) — simplified fallback")
            return try await fetch(0, simplified: true)
        }
    }

    /// Single best route.
    public func route(from: GeoPoint, to: GeoPoint) async throws -> Route {
        guard let r = try await routes(from: from, to: to, alternatives: 0).first else { throw NavServiceError.service("No route") }
        return r
    }

    // MARK: Parsing

    /// Parses an OSRM `route` response: `code` must be "Ok" (else `message` / `code` / "No route"),
    /// `routes[]` non-empty, routes that fail to parse are skipped ("Route too short" if none).
    public static func parse(_ data: Data, label: String = "") throws -> [Route] {
        let root = try NavJSON.parse(data)
        if root["code"].string() != "Ok" {
            let fallback = root["code"].isNull ? "No route" : root["code"].string("No route")
            throw NavServiceError.service(root["message"].isNull ? fallback : root["message"].string(fallback))
        }
        let routes = root["routes"]
        guard routes.array != nil else { throw NavServiceError.service("No route") }
        if routes.count == 0 { throw NavServiceError.service("No route") }
        var out: [Route] = []
        for r in routes.elements {
            if let route = parseRoute(r, label: label) { out.append(route) }
        }
        if out.isEmpty { throw NavServiceError.service("Route too short") }
        return out
    }

    static func parseRoute(_ r0: NavJSON, label: String) -> Route? {
        let coords = r0["geometry"]["coordinates"]
        guard coords.array != nil else { return nil }
        var pts: [TrackPoint] = []
        pts.reserveCapacity(coords.count)
        for c in coords.elements {
            // A garbage coordinate rejects the geometry like a missing one (review SEC-1).
            guard let lon = c[0].doubleOrNil, let lat = c[1].doubleOrNil,
                  GeoMath.isValidCoordinate(lat: lat, lon: lon) else { return nil }
            pts.append(TrackPoint(lat: lat, lon: lon))
        }
        if pts.count < 2 { return nil }
        return Route(points: pts, distanceM: r0["distance"].double(0), durationSec: r0["duration"].double(0),
                     steps: parseSteps(r0), label: label)
    }

    static func parseSteps(_ route: NavJSON) -> [RouteStep] {
        var out: [RouteStep] = []
        for leg in route["legs"].elements {
            let steps = leg["steps"]
            guard steps.array != nil else { continue }
            for step in steps.elements {
                let man = step["maneuver"]
                guard man.object != nil else { continue }
                let loc = man["location"]
                guard loc.array != nil else { continue }
                let lat = loc[1].double(.nan)
                let lon = loc[0].double(.nan)
                let exit: Int?
                if man.has("exit") { exit = man["exit"].int(0) } else if step.has("exit") { exit = step["exit"].int(0) } else { exit = nil }
                let modifier = man["modifier"].string()
                out.append(RouteStep(maneuverType: man["type"].string("continue"),
                                     modifier: modifier.isNavBlank ? nil : modifier,
                                     roadName: step["name"].string(""),
                                     maneuverLat: lat, maneuverLon: lon,
                                     distanceM: step["distance"].double(0),
                                     exit: exit,
                                     lanes: parseLanes(step)))
            }
        }
        return out
    }

    /// Lanes from the first intersection that has `lanes[]` (`{valid (default false), indications[]}`).
    static func parseLanes(_ step: NavJSON) -> [Lane]? {
        let inters = step["intersections"]
        guard inters.array != nil else { return nil }
        for inter in inters.elements {
            let lanesArr = inter["lanes"]
            guard lanesArr.array != nil else { continue }
            var lanes: [Lane] = []
            for l in lanesArr.elements {
                let inds = l["indications"].elements.map { $0.string() }
                lanes.append(Lane(valid: l["valid"].bool(false), indications: inds))
            }
            if !lanes.isEmpty { return lanes }
        }
        return nil
    }
}
