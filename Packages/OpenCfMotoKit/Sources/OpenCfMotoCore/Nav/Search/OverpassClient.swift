// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) OverpassClient.kt
//
// Overpass API helpers (docs/spec/navigation-dash.md §7.4, §7.5, §8): "near me" POIs by OSM tag,
// the speed-limit (`maxspeed`) lookup and roadside corridor POIs. Queries are POSTed as
// `data=<URLEncoder(query)>` to overpass-api.de; the query texts are byte-identical to Android's
// (after `trimIndent`).

import Foundation

public struct OverpassClient: Sendable {
    public static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!

    public let http: HTTPClient

    public init(http: HTTPClient) { self.http = http }

    // MARK: Queries

    /// Nearby-by-tag query, e.g. for `amenity=fuel` at (44.4268, 26.1025) within 6 000 m:
    /// `[out:json][timeout:25];\n(\n  node["amenity"="fuel"](around:6000,44.4268,26.1025);\n  way[…];\n);\nout center 60;`
    /// The centre is rounded to 3 decimals (~110 m, against a ≥ 6 km radius) so a POI chip does not send
    /// the exact fix (iOS deviation, review SEC-7); the results are still sorted from the exact one.
    public static func nearbyQuery(key: String, value: String, radiusM: Int, lat: Double, lon: Double, maxResults: Int) -> String {
        let la = NavNumberFormat.javaString(PlaceSearch.roundedCoordinate(lat, decimals: 3))
        let lo = NavNumberFormat.javaString(PlaceSearch.roundedCoordinate(lon, decimals: 3))
        return """
        [out:json][timeout:25];
        (
          node["\(key)"="\(value)"](around:\(radiusM),\(la),\(lo));
          way["\(key)"="\(value)"](around:\(radiusM),\(la),\(lo));
        );
        out center \(maxResults * 2);
        """
    }

    /// Speed-limit query (radius 25 m): `[out:json][timeout:12];\nway(around:25,lat,lon)["maxspeed"];\nout tags center 1;`
    public static func maxspeedQuery(lat: Double, lon: Double, radiusM: Int = 25) -> String {
        """
        [out:json][timeout:12];
        way(around:\(radiusM),\(NavNumberFormat.javaString(lat)),\(NavNumberFormat.javaString(lon)))["maxspeed"];
        out tags center 1;
        """
    }

    /// Roadside POIs inside the track's bounding box (≤ 60 sampled points, padded 0.003°).
    public static func corridorQuery(points: [TrackPoint], maxResults: Int = 40) -> String? {
        guard !points.isEmpty else { return nil }
        let sample = subsample(points, max: 60)
        var minLat = sample[0].lat, maxLat = sample[0].lat, minLon = sample[0].lon, maxLon = sample[0].lon
        for p in sample {
            minLat = min(minLat, p.lat); maxLat = max(maxLat, p.lat)
            minLon = min(minLon, p.lon); maxLon = max(maxLon, p.lon)
        }
        let pad = 0.003
        let s = NavNumberFormat.javaString(minLat - pad), n = NavNumberFormat.javaString(maxLat + pad)
        let w = NavNumberFormat.javaString(minLon - pad), e = NavNumberFormat.javaString(maxLon + pad)
        return """
        [out:json][timeout:25];
        (
          node["amenity"~"fuel|parking|cafe|restaurant|hospital|atm"](\(s),\(w),\(n),\(e));
          node["tourism"~"hotel|viewpoint"](\(s),\(w),\(n),\(e));
        );
        out body \(maxResults);
        """
    }

    static func subsample(_ points: [TrackPoint], max: Int) -> [TrackPoint] {
        if points.count <= max { return points }
        let step = points.count / max
        return points.enumerated().filter { $0.offset % step == 0 || $0.offset == points.count - 1 }.map(\.element)
    }

    /// `data=` + Java-URLEncoder-encoded query.
    public static func formBody(_ query: String) -> String { "data=" + FormURLEncoding.encode(query) }

    func post(_ query: String) async throws -> NavJSON {
        let req = NavHTTP.postFormRequest(Self.endpoint, formBody: Self.formBody(query))
        let data = try await NavHTTP.fetch(http, req, maxBytes: NavHTTPPolicy.postForm.maxBytes)
        return try NavJSON.parse(data)
    }

    // MARK: Nearby by tag

    /// Real "what's near me" search for an OSM tag (`amenity=fuel`), nearest first. Radii tried in
    /// order `radiusM`, ×3, ×8 (6 / 18 / 48 km by default) until something is found.
    public func nearbyByTag(_ tag: String, lat: Double, lon: Double, radiusM: Int = 6_000, maxResults: Int = 30) async throws -> [Place] {
        let key = tag.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map {
            String($0).trimmingCharacters(in: .whitespaces)
        } ?? ""
        let value: String = {
            guard let eq = tag.firstIndex(of: "=") else { return "" }
            return String(tag[tag.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        }()
        if key.isEmpty || value.isEmpty { return [] }
        for r in [radiusM, radiusM * 3, radiusM * 8] {
            let root = try await post(Self.nearbyQuery(key: key, value: value, radiusM: r, lat: lat, lon: lon, maxResults: maxResults))
            let found = Self.parseNearby(root, value: value, lat: lat, lon: lon, maxResults: maxResults)
            if !found.isEmpty { return found }
        }
        return []
    }

    /// Parses Overpass `elements[]` for the nearby search: position = lat/lon or center; name =
    /// tags.name → brand/operator → value with "_"→" " capitalised; subtitle = brand (if ≠ name) ·
    /// "<addr:street> <addr:housenumber>"; sorted by planar distance; distinct by "%.5f,%.5f".
    static func parseNearby(_ root: NavJSON, value: String, lat: Double, lon: Double, maxResults: Int) -> [Place] {
        var scored: [(Place, Double)] = []
        for o in root["elements"].elements {
            let plat: Double, plon: Double
            if o.has("lat") && o.has("lon"), let a = o["lat"].doubleOrNil, let b = o["lon"].doubleOrNil {
                plat = a; plon = b
            } else if o.has("center"), let a = o["center"]["lat"].doubleOrNil, let b = o["center"]["lon"].doubleOrNil {
                plat = a; plon = b
            } else {
                continue
            }
            guard GeoMath.isValidCoordinate(lat: plat, lon: plon) else { continue } // review SEC-1
            let tags = o["tags"]
            func tag(_ k: String) -> String? {
                let v = tags[k].string("")
                return v.isNavBlank ? nil : v
            }
            let brand = tag("brand") ?? tag("operator")
            let name = tag("name") ?? brand ?? value.replacingOccurrences(of: "_", with: " ").navCapitalizedFirst
            let street = [tag("addr:street"), tag("addr:housenumber")].compactMap { $0 }.joined(separator: " ")
            var subParts: [String] = []
            if let brand, brand != name { subParts.append(brand) }
            if !street.isNavBlank { subParts.append(street) }
            scored.append((Place(name: name, lat: plat, lon: plon, category: value, subtitle: subParts.joined(separator: " · ")),
                           GeoMath.approxMetres(lat, lon, plat, plon)))
        }
        let sorted = scored.enumerated().sorted { a, b in
            a.element.1 != b.element.1 ? a.element.1 < b.element.1 : a.offset < b.offset
        }.map { $0.element.0 }
        return Array(distinctByPosition(sorted).prefix(maxResults))
    }

    static func distinctByPosition(_ places: [Place]) -> [Place] {
        var seen = Set<String>()
        return places.filter { seen.insert(NavNumberFormat.fixed($0.lat, decimals: 5) + "," + NavNumberFormat.fixed($0.lon, decimals: 5)).inserted }
    }

    // MARK: Speed limit

    /// Uncached maxspeed lookup: first element's `tags.maxspeed` (trimmed); none → (nil, "—").
    /// `label` is the raw OSM value (e.g. "50", "50 mph", "RO:urban").
    public func maxspeed(lat: Double, lon: Double, radiusM: Int = 25) async throws -> SpeedLimit {
        let root = try await post(Self.maxspeedQuery(lat: lat, lon: lon, radiusM: radiusM))
        return Self.parseMaxspeed(root)
    }

    static func parseMaxspeed(_ root: NavJSON) -> SpeedLimit {
        let els = root["elements"]
        guard els.count > 0 else { return SpeedLimit(kmh: nil, label: "—") }
        let raw = els[0]["tags"]["maxspeed"].string("").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return SpeedLimit(kmh: nil, label: "—") }
        return SpeedLimit(kmh: SpeedLimitParsing.parseMaxspeedKmh(raw), label: raw)
    }

    // MARK: Corridor POIs

    /// Roadside POIs for a loaded track (hub "download roadside POI"): subtitle "OSM <kind>".
    public func corridorPois(points: [TrackPoint], maxResults: Int = 40) async throws -> [Place] {
        guard let q = Self.corridorQuery(points: points, maxResults: maxResults) else { return [] }
        let root = try await post(q)
        var out: [Place] = []
        for o in root["elements"].elements {
            guard o.has("lat"), o.has("lon"), let lat = o["lat"].doubleOrNil, let lon = o["lon"].doubleOrNil,
                  GeoMath.isValidCoordinate(lat: lat, lon: lon) else { continue }
            let tags = o["tags"]
            guard tags.object != nil else { continue }
            let amenity = tags["amenity"].string("")
            let kind = amenity.isNavBlank ? tags["tourism"].string("") : amenity
            let n = tags["name"].string("")
            out.append(Place(name: n.isNavBlank ? kind.navCapitalizedFirst : n, lat: lat, lon: lon, category: kind,
                             subtitle: "OSM \(kind)"))
        }
        return Array(Self.distinctByPosition(out).prefix(maxResults))
    }
}
