// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) NominatimSearch.kt, GpxDashUi.kt (POI chip results)
//
// Worldwide place search (docs/spec/navigation-dash.md §7): Photon (two location-biased queries:
// everything + settlements) with Nominatim as fallback, one ranking formula, top 12, LRU cache of
// 64 queries; POI chips run Overpass "around me" tag searches at 6 / 18 / 48 km.

import Foundation

/// Place search and "near me" POI chips. Thread-safe (`NSLock` around the cache).
public final class PlaceSearch: @unchecked Sendable {
    /// Category chip (label shown, OSM tag queried).
    public struct PoiChip: Sendable, Equatable, Hashable {
        public var label: String
        public var query: String
        public init(label: String, query: String) { self.label = label; self.query = query }
    }

    /// Android chip order.
    public static let poiChips: [PoiChip] = [
        PoiChip(label: "Fuel", query: "amenity=fuel"),
        PoiChip(label: "Cafe", query: "amenity=cafe"),
        PoiChip(label: "Food", query: "amenity=restaurant"),
        PoiChip(label: "Parking", query: "amenity=parking"),
        PoiChip(label: "Hotel", query: "tourism=hotel"),
        PoiChip(label: "ATM", query: "amenity=atm"),
        PoiChip(label: "Hospital", query: "amenity=hospital"),
        PoiChip(label: "Viewpoint", query: "tourism=viewpoint"),
    ]

    /// A candidate before ranking.
    public struct ScoredPlace: Sendable, Equatable {
        public var place: Place
        public var type: String
        public var importance: Double
        public var nameMatch: String
    }

    public let http: HTTPClient
    public let overpass: OverpassClient
    private let cacheCapacity: Int
    private let lock = NSLock()
    private var cache: [String: [Place]] = [:]
    private var cacheOrder: [String] = []

    public init(http: HTTPClient, cacheCapacity: Int = 64) {
        self.http = http
        overpass = OverpassClient(http: http)
        self.cacheCapacity = cacheCapacity
    }

    // MARK: Text search

    /// Searches `query` near `near` (Photon first when a position is known, Nominatim otherwise or
    /// when Photon fails / finds nothing). Results ranked, distinct, at most 12. Non-empty results
    /// are cached by `"<lower q>|%.2f,%.2f"` (or `"|-"`). Nominatim errors are thrown.
    public func search(_ query: String, near: GeoPoint?) async throws -> [Place] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return [] }
        let key = Self.cacheKey(query: q, near: near)
        if let hit = cacheGet(key) { return hit }
        var result: [Place] = []
        if let near {
            var photon: [Place] = []
            do {
                photon = try await searchPhotonBiased(q, near: near)
            } catch {
                try Task.checkCancellation()
                Log.i("NAV", "[search] Photon failed: \(NavServiceError.message(for: error, fallback: "error"))")
            }
            if !photon.isEmpty {
                result = photon
            } else {
                result = Self.rank(try await fetchNominatim(q, near: near), query: q, near: near)
            }
        } else {
            result = Self.rank(try await fetchNominatim(q, near: nil), query: q, near: nil)
        }
        if !result.isEmpty { cachePut(key, result) }
        return result
    }

    public static func cacheKey(query: String, near: GeoPoint?) -> String {
        let n = near.map { NavNumberFormat.fixed($0.lat, decimals: 2) + "," + NavNumberFormat.fixed($0.lon, decimals: 2) } ?? "-"
        return query.lowercased() + "|" + n
    }

    private func searchPhotonBiased(_ q: String, near: GeoPoint) async throws -> [Place] {
        let general = try await fetchPhoton(q, near: near, limit: 12, settlementsOnly: false)
        let settlements = try await fetchPhoton(q, near: near, limit: 10, settlementsOnly: true)
        return Self.rank(general + settlements, query: q, near: near)
    }

    /// `https://photon.komoot.io/api/?q={enc}&lat={lat}&lon={lon}&limit={n}&location_bias_scale=
    /// {0.2|0.12}&lang=default[&osm_tag=place:city&osm_tag=place:town&osm_tag=place:municipality]`.
    public static func photonURL(query: String, near: GeoPoint, limit: Int, settlementsOnly: Bool) -> URL {
        let bias = settlementsOnly ? 0.12 : 0.2
        var s = "https://photon.komoot.io/api/?q=\(FormURLEncoding.encode(query))&lat=\(NavNumberFormat.javaString(near.lat))"
            + "&lon=\(NavNumberFormat.javaString(near.lon))&limit=\(limit)&location_bias_scale=\(NavNumberFormat.javaString(bias))&lang=default"
        if settlementsOnly { s += "&osm_tag=place:city&osm_tag=place:town&osm_tag=place:municipality" }
        return URL(string: s)!
    }

    /// `https://nominatim.openstreetmap.org/search?q={enc}&format=jsonv2&addressdetails=1&limit=20`
    /// `[&viewbox={lon-1.6},{lat+1.6},{lon+1.6},{lat-1.6}&bounded=0]`.
    public static func nominatimURL(query: String, near: GeoPoint?) -> URL {
        var s = "https://nominatim.openstreetmap.org/search?q=\(FormURLEncoding.encode(query))&format=jsonv2&addressdetails=1&limit=20"
        if let near {
            let d = 1.6
            s += "&viewbox=\(NavNumberFormat.javaString(near.lon - d)),\(NavNumberFormat.javaString(near.lat + d)),"
                + "\(NavNumberFormat.javaString(near.lon + d)),\(NavNumberFormat.javaString(near.lat - d))&bounded=0"
        }
        return URL(string: s)!
    }

    private func fetchPhoton(_ q: String, near: GeoPoint, limit: Int, settlementsOnly: Bool) async throws -> [ScoredPlace] {
        let url = Self.photonURL(query: q, near: near, limit: limit, settlementsOnly: settlementsOnly)
        let data = try await NavHTTP.fetch(http, NavHTTP.getRequest(url), maxBytes: NavHTTPPolicy.getText.maxBytes)
        return try Self.parsePhoton(data)
    }

    private func fetchNominatim(_ q: String, near: GeoPoint?) async throws -> [ScoredPlace] {
        let url = Self.nominatimURL(query: q, near: near)
        let data = try await NavHTTP.fetch(http, NavHTTP.getRequest(url), maxBytes: NavHTTPPolicy.getText.maxBytes)
        return try Self.parseNominatim(data)
    }

    // MARK: Parsing

    /// Photon GeoJSON: `features[].geometry.coordinates[lon,lat]`, name (blank → street → "Place"),
    /// type = osm_value (blank → type), importance = extent proxy + properties.importance.
    public static func parsePhoton(_ data: Data) throws -> [ScoredPlace] {
        let root = try NavJSON.parse(data)
        var out: [ScoredPlace] = []
        for f in root["features"].elements {
            guard let lon = f["geometry"]["coordinates"][0].doubleOrNil,
                  let lat = f["geometry"]["coordinates"][1].doubleOrNil else {
                throw NavServiceError.invalidJSON("Photon feature without coordinates")
            }
            let p = f["properties"]
            guard p.object != nil else { throw NavServiceError.invalidJSON("Photon feature without properties") }
            var name = p["name"].string("")
            if name.isNavBlank { name = p["street"].string(""); if name.isNavBlank { name = "Place" } }
            var type = p["osm_value"].string("")
            if type.isNavBlank { type = p["type"].string("") }
            out.append(ScoredPlace(place: Place(name: name, lat: lat, lon: lon, category: type, subtitle: photonSubtitle(p)),
                                   type: type, importance: extentImportance(p) + p["importance"].double(0), nameMatch: name))
        }
        return out
    }

    /// Nominatim jsonv2 array: lat/lon arrive as strings; name blank → display_name before the
    /// first ',' → "Place"; type blank → addresstype; subtitle = display_name.
    public static func parseNominatim(_ data: Data) throws -> [ScoredPlace] {
        let root = try NavJSON.parse(data)
        guard root.array != nil else { throw NavServiceError.invalidJSON("Nominatim response is not an array") }
        var out: [ScoredPlace] = []
        for o in root.elements {
            guard o.object != nil, let lat = o["lat"].doubleOrNil, let lon = o["lon"].doubleOrNil else {
                throw NavServiceError.invalidJSON("Nominatim result without lat/lon")
            }
            let display = o["display_name"].string("")
            var name = o["name"].string("")
            if name.isNavBlank {
                name = display.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                if name.isNavBlank { name = "Place" }
            }
            var type = o["type"].string("")
            if type.isNavBlank { type = o["addresstype"].string("") }
            out.append(ScoredPlace(place: Place(name: name, lat: lat, lon: lon, category: type, subtitle: display),
                                   type: type, importance: o["importance"].double(0), nameMatch: name))
        }
        return out
    }

    /// `min(0.9, |e2−e0|·|e1−e3|·80)` from `properties.extent[4]` (0 if absent).
    static func extentImportance(_ p: NavJSON) -> Double {
        let ext = p["extent"]
        guard ext.array != nil, ext.count >= 4 else { return 0 }
        let w = abs(ext[2].double(0) - ext[0].double(0))
        let h = abs(ext[1].double(0) - ext[3].double(0))
        return min(0.9, w * h * 80.0)
    }

    /// `"<osm_value> · <distinct non-blank of city, county, state, country joined by ", ">"`,
    /// falling back to `country`.
    static func photonSubtitle(_ p: NavJSON) -> String {
        var parts: [String] = []
        for k in ["city", "county", "state", "country"] {
            let v = p[k].string("")
            if !v.isNavBlank && !parts.contains(v) { parts.append(v) }
        }
        let type = p["osm_value"].string("")
        var s = ""
        if !type.isNavBlank { s += type }
        if !parts.isEmpty {
            if !s.isEmpty { s += " · " }
            s += parts.joined(separator: ", ")
        }
        return s.isNavBlank ? p["country"].string("") : s
    }

    // MARK: Ranking

    /// `score = typeWeight·12 + importance·90 + nameBonus − distPenalty`, sorted descending,
    /// distinct by "<lower name>|%.3f|%.3f", first 12. Without a position the distance is 500 km.
    public static func rank(_ items: [ScoredPlace], query: String, near: GeoPoint?) -> [Place] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scored: [(Place, Double)] = items.map { s in
            let distKm = near.map { GeoMath.haversineKm($0.lat, $0.lon, s.place.lat, s.place.lon) } ?? 500.0
            let name = s.nameMatch.lowercased()
            let nameBonus: Double = name == q ? 40 : (name.hasPrefix(q) ? 28 : (name.contains(q) ? 10 : 0))
            return (s.place, typeWeight(s.type) * 12.0 + s.importance * 90.0 + nameBonus - distancePenalty(distKm))
        }
        let sorted = scored.enumerated().sorted { a, b in
            a.element.1 != b.element.1 ? a.element.1 > b.element.1 : a.offset < b.offset
        }.map { $0.element.0 }
        var seen = Set<String>()
        var out: [Place] = []
        for p in sorted {
            let key = p.name.lowercased() + "|" + NavNumberFormat.fixed(p.lat, decimals: 3) + "|" + NavNumberFormat.fixed(p.lon, decimals: 3)
            if seen.insert(key).inserted { out.append(p) }
            if out.count == 12 { break }
        }
        return out
    }

    /// Soft distance penalty: < 50 km ·0.12; < 150 6+(d−50)·0.35; < 500 41+(d−150)·0.55;
    /// < 2000 233+(d−500)·0.35; else 758+d·0.15.
    public static func distancePenalty(_ d: Double) -> Double {
        if d < 50 { return d * 0.12 }
        if d < 150 { return 6.0 + (d - 50) * 0.35 }
        if d < 500 { return 41.0 + (d - 150) * 0.55 }
        if d < 2000 { return 233.0 + (d - 500) * 0.35 }
        return 758.0 + d * 0.15
    }

    /// Place-type weight (city/municipality 100 … else 20).
    public static func typeWeight(_ type: String) -> Double {
        switch type.lowercased() {
        case "city", "municipality": return 100
        case "town": return 88
        case "administrative", "county", "state", "region": return 70
        case "suburb", "borough", "quarter", "neighbourhood", "neighborhood": return 45
        case "village": return 28
        case "hamlet", "isolated_dwelling", "farm", "allotments": return 8
        case "locality": return 22
        case "highway", "road", "residential": return 35
        case "station", "bus_stop", "tram_stop", "subway_entrance": return 12
        default: return 20
        }
    }

    // MARK: POI chips

    /// Overpass tag search for a chip, results rewritten for display like the dash
    /// (`withDistance`): category = chip label, subtitle = "<distance> · <old subtitle>", nearest first.
    public func nearby(_ chip: PoiChip, near: GeoPoint, units: MapUnits = .metric,
                       decimalSeparator: Character = ".") async throws -> [Place] {
        let list = try await overpass.nearbyByTag(chip.query, lat: near.lat, lon: near.lon)
        return Self.withDistance(list, from: near, label: chip.label, units: units, decimalSeparator: decimalSeparator)
    }

    /// `GpxDashUi.withDistance`: tags each POI with its planar distance and sorts nearest first.
    public static func withDistance(_ list: [Place], from: GeoPoint, label: String, units: MapUnits,
                                    decimalSeparator: Character = ".") -> [Place] {
        let tagged: [(Place, Double)] = list.map { p in
            let d = GeoMath.approxMetres(from.lat, from.lon, p.lat, p.lon)
            let dist = NavFormat.formatDistance(d, units: units, decimalSeparator: decimalSeparator)
            let sub = [dist, p.subtitle].filter { !$0.isNavBlank }.joined(separator: " · ")
            var q = p
            q.category = label
            q.subtitle = sub
            return (q, d)
        }
        return tagged.enumerated().sorted { a, b in
            a.element.1 != b.element.1 ? a.element.1 < b.element.1 : a.offset < b.offset
        }.map { $0.element.0 }
    }

    // MARK: Cache

    private func cacheGet(_ key: String) -> [Place]? {
        lock.lock(); defer { lock.unlock() }
        guard let v = cache[key] else { return nil }
        if let i = cacheOrder.firstIndex(of: key) { cacheOrder.remove(at: i) }
        cacheOrder.append(key)
        return v
    }

    private func cachePut(_ key: String, _ value: [Place]) {
        lock.lock(); defer { lock.unlock() }
        if cache[key] != nil, let i = cacheOrder.firstIndex(of: key) { cacheOrder.remove(at: i) }
        cache[key] = value
        cacheOrder.append(key)
        while cacheOrder.count > cacheCapacity {
            let eldest = cacheOrder.removeFirst()
            cache[eldest] = nil
        }
    }

    /// Number of cached queries (diagnostics / tests).
    public var cachedQueryCount: Int {
        lock.lock(); defer { lock.unlock() }
        return cache.count
    }
}
