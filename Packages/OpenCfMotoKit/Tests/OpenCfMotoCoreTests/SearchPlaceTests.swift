// SPDX-License-Identifier: AGPL-3.0-or-later
// PlaceSearch (Photon + Nominatim) and POI chips vs. Kotlin golden output (golden_search.json).

import XCTest
@testable import OpenCfMotoCore

final class SearchPlaceTests: XCTestCase {
    private lazy var golden = NavGJ(NavFixtures.json("golden_search.json"))
    private let near = GeoPoint(lat: 44.4268, lon: 26.1025)

    static let photonHandler: @Sendable (HTTPRequest) throws -> HTTPResponse = { r in
        let u = r.url.absoluteString
        if u.contains("osm_tag=place") { return .navOK(fixture: "photon_settlements.json") }
        if u.contains("photon.komoot.io") { return .navOK(fixture: "photon_general.json") }
        if u.contains("nominatim") { return .navOK(fixture: "nominatim_search.json") }
        throw NavFakeNetworkError("unexpected")
    }

    private func comparePlaces(_ got: [Place], _ g: NavGJ, _ tag: String, file: StaticString = #filePath, line: UInt = #line) {
        let exp = g["places"].array
        XCTAssertEqual(got.count, exp.count, "\(tag) count", file: file, line: line)
        for (p, e) in zip(got, exp) {
            XCTAssertEqual(p.name, e["name"].string, tag, file: file, line: line)
            XCTAssertEqual(p.lat, e["lat"].d, accuracy: 1e-12, tag, file: file, line: line)
            XCTAssertEqual(p.lon, e["lon"].d, accuracy: 1e-12, tag, file: file, line: line)
            XCTAssertEqual(p.category, e["category"].string, tag, file: file, line: line)
            XCTAssertEqual(p.subtitle, e["subtitle"].string, tag, file: file, line: line)
        }
    }

    private func compareURLs(_ c: NavFakeHTTPClient, _ g: NavGJ, _ tag: String, file: StaticString = #filePath, line: UInt = #line) {
        let exp = g["requests"].array.map { $0["url"].string ?? "" }
        XCTAssertEqual(c.requests.map(\.navURLText), exp, tag, file: file, line: line)
        for (r, e) in zip(c.requests, g["requests"].array) where !e["body"].isNull {
            XCTAssertEqual(r.navBodyText, e["body"].string, tag, file: file, line: line)
        }
    }

    func testPhotonBiasedSearchAndCache() async throws {
        let c = NavFakeHTTPClient(Self.photonHandler)
        let search = PlaceSearch(http: c)
        let got = try await search.search(" Câmpina ", near: near)
        comparePlaces(got, golden["photon"], "photon")
        compareURLs(c, golden["photon"], "photon")
        // Cached by lower-cased query + %.2f position: no new request.
        let again = try await search.search("câmpina", near: GeoPoint(lat: 44.4301, lon: 26.0999))
        comparePlaces(again, golden["photonCached"], "photonCached")
        XCTAssertEqual(c.requests.count, 2)
        XCTAssertEqual(search.cachedQueryCount, 1)
    }

    func testNominatimWithoutPositionEncodesLikeJava() async throws {
        let c = NavFakeHTTPClient(Self.photonHandler)
        let got = try await PlaceSearch(http: c).search("Campina ~ & co", near: nil)
        comparePlaces(got, golden["nominatimNoPos"], "nominatimNoPos")
        compareURLs(c, golden["nominatimNoPos"], "nominatimNoPos")
    }

    func testPhotonDownFallsBackToNominatimWithViewbox() async throws {
        let c = NavFakeHTTPClient { r in
            if r.url.absoluteString.contains("photon") { throw NavFakeNetworkError("photon down") }
            return .navOK(fixture: "nominatim_search.json")
        }
        let got = try await PlaceSearch(http: c).search("Campina", near: near)
        comparePlaces(got, golden["photonDown"], "photonDown")
        compareURLs(c, golden["photonDown"], "photonDown")
    }

    func testAllDownPropagatesNominatimError() async {
        let c = NavFakeHTTPClient { r in
            if r.url.absoluteString.contains("photon") { return .navOK(Data(#"{"features":[]}"#.utf8)) }
            return HTTPResponse(status: 503)
        }
        do {
            _ = try await PlaceSearch(http: c).search("Nowhere", near: near)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(NavServiceError.message(for: error, fallback: ""), "Map service temporarily unavailable (HTTP 503)")
        }
        compareURLs(c, golden["allDown"], "allDown")
    }

    func testEmptyQueryAndCacheEviction() async throws {
        let c = NavFakeHTTPClient(Self.photonHandler)
        let search = PlaceSearch(http: c, cacheCapacity: 2)
        let none = try await search.search("   ", near: near)
        XCTAssertEqual(none, [])
        XCTAssertEqual(c.requests.count, 0)
        _ = try await search.search("a1", near: nil)
        _ = try await search.search("a2", near: nil)
        _ = try await search.search("a1", near: nil) // hit, refreshes a1
        _ = try await search.search("a3", near: nil) // evicts a2
        XCTAssertEqual(c.requests.count, 3)
        _ = try await search.search("a1", near: nil)
        XCTAssertEqual(c.requests.count, 3)
        _ = try await search.search("a2", near: nil)
        XCTAssertEqual(c.requests.count, 4)
    }

    func testURLBuilders() {
        XCTAssertEqual(PlaceSearch.photonURL(query: "Câmpina", near: near, limit: 12, settlementsOnly: false).absoluteString,
                       "https://photon.komoot.io/api/?q=C%C3%A2mpina&lat=44.4268&lon=26.1025&limit=12&location_bias_scale=0.2&lang=default")
        XCTAssertEqual(PlaceSearch.cacheKey(query: "Câmpina", near: near), "câmpina|44.43,26.10")
        XCTAssertEqual(PlaceSearch.cacheKey(query: "X", near: nil), "x|-")
    }

    func testRankingFormula() {
        XCTAssertEqual(PlaceSearch.distancePenalty(10), 1.2, accuracy: 1e-12)
        XCTAssertEqual(PlaceSearch.distancePenalty(100), 23.5, accuracy: 1e-12)
        XCTAssertEqual(PlaceSearch.distancePenalty(200), 68.5, accuracy: 1e-12)
        XCTAssertEqual(PlaceSearch.distancePenalty(1000), 408, accuracy: 1e-12)
        XCTAssertEqual(PlaceSearch.distancePenalty(3000), 1208, accuracy: 1e-12)
        XCTAssertEqual(PlaceSearch.typeWeight("City"), 100)
        XCTAssertEqual(PlaceSearch.typeWeight("hamlet"), 8)
        XCTAssertEqual(PlaceSearch.typeWeight("bus_stop"), 12)
        XCTAssertEqual(PlaceSearch.typeWeight("cafe"), 20)
        // Exact name beats prefix beats contains; top 12, distinct by name + %.3f position.
        func sp(_ n: String, _ lat: Double) -> PlaceSearch.ScoredPlace {
            PlaceSearch.ScoredPlace(place: Place(name: n, lat: lat, lon: 26), type: "village", importance: 0, nameMatch: n)
        }
        let ranked = PlaceSearch.rank([sp("Big Foo", 44), sp("Foo", 44), sp("Foobar", 44), sp("foo", 44.0001)], query: "foo",
                                      near: GeoPoint(lat: 44, lon: 26))
        XCTAssertEqual(ranked.map(\.name), ["Foo", "Foobar", "Big Foo"])
        let many = (0 ..< 20).map { sp("P\($0)", 44 + Double($0) * 0.01) }
        XCTAssertEqual(PlaceSearch.rank(many, query: "x", near: nil).count, 12)
    }

    func testPoiChipsAndDistanceRewrite() async throws {
        XCTAssertEqual(PlaceSearch.poiChips.map(\.label), ["Fuel", "Cafe", "Food", "Parking", "Hotel", "ATM", "Hospital", "Viewpoint"])
        XCTAssertEqual(PlaceSearch.poiChips[2].query, "amenity=restaurant")
        let c = NavFakeHTTPClient { _ in .navOK(fixture: "overpass_fuel.json") }
        let got = try await PlaceSearch(http: c).nearby(PlaceSearch.poiChips[0], near: near)
        XCTAssertEqual(got.map(\.name), ["OMV", "Lukoil", "Petrom Unirii", "Fuel"])
        XCTAssertTrue(got.allSatisfy { $0.category == "Fuel" })
        XCTAssertEqual(got[0].subtitle, NavFormat.formatDistance(GeoMath.approxMetres(near.lat, near.lon, 44.428, 26.103), units: .metric))
        XCTAssertTrue(got[2].subtitle.hasSuffix(" · Petrom · Bulevardul Unirii 12"))
    }
}

final class OverpassClientTests: XCTestCase {
    private lazy var golden = NavGJ(NavFixtures.json("golden_search.json"))

    func testNearbyByTagGolden() async throws {
        let c = NavFakeHTTPClient { _ in .navOK(fixture: "overpass_fuel.json") }
        let got = try await OverpassClient(http: c).nearbyByTag("amenity=fuel", lat: 44.4268, lon: 26.1025)
        let exp = golden["fuel"]["places"].array
        XCTAssertEqual(got.map(\.name), exp.map { $0["name"].string! })
        XCTAssertEqual(got.map(\.subtitle), exp.map { $0["subtitle"].string! })
        XCTAssertEqual(got.map(\.category), exp.map { $0["category"].string! })
        XCTAssertEqual(c.requests.map(\.navBodyText), golden["fuel"]["requests"].array.map { $0["body"].string! })
        // Spec example body for fuel at (44.4268, 26.1025).
        XCTAssertEqual(c.requests[0].navBodyText,
                       "data=%5Bout%3Ajson%5D%5Btimeout%3A25%5D%3B%0A%28%0A++node%5B%22amenity%22%3D%22fuel%22%5D%28around%3A6000%2C44.4268%2C26.1025%29%3B%0A++way%5B%22amenity%22%3D%22fuel%22%5D%28around%3A6000%2C44.4268%2C26.1025%29%3B%0A%29%3B%0Aout+center+60%3B")
        XCTAssertEqual(c.requests[0].headers["Content-Type"], "application/x-www-form-urlencoded; charset=UTF-8")
        XCTAssertEqual(c.requests[0].method, "POST")
        XCTAssertEqual(c.requests[0].navURLText, "https://overpass-api.de/api/interpreter")
    }

    func testNearbyWidensRadius() async throws {
        let n = Locked(0)
        let c = NavFakeHTTPClient { _ in
            let k = n.withLock { $0 += 1; return $0 }
            return .navOK(fixture: k < 3 ? "overpass_empty.json" : "overpass_fuel.json")
        }
        let got = try await OverpassClient(http: c).nearbyByTag(" amenity = fuel ", lat: 44.4268, lon: 26.1025, maxResults: 2)
        XCTAssertEqual(got.map(\.name), golden["fuelWiden"]["places"].array.map { $0["name"].string! })
        XCTAssertEqual(c.requests.map(\.navBodyText), golden["fuelWiden"]["requests"].array.map { $0["body"].string! })
        let bad = try await OverpassClient(http: c).nearbyByTag("amenity", lat: 0, lon: 0)
        XCTAssertEqual(bad, [])
    }

    func testMaxspeedQueryAndParse() async throws {
        let c = NavFakeHTTPClient { _ in .navOK(fixture: "overpass_maxspeed.json") }
        let lim = try await OverpassClient(http: c).maxspeed(lat: 44.4268, lon: 26.1025)
        XCTAssertEqual(lim, SpeedLimit(kmh: golden["maxspeed"]["kmh"].int, label: golden["maxspeed"]["label"].string!))
        XCTAssertEqual(c.requests[0].navBodyText, golden["maxspeed"]["requests"][0]["body"].string)
        // Spec example body.
        XCTAssertEqual(c.requests[0].navBodyText,
                       "data=%5Bout%3Ajson%5D%5Btimeout%3A12%5D%3B%0Away%28around%3A25%2C44.4268%2C26.1025%29%5B%22maxspeed%22%5D%3B%0Aout+tags+center+1%3B")
        let none = OverpassClient.parseMaxspeed(NavJSON(["elements": [Any]()]))
        XCTAssertEqual(none, SpeedLimit(kmh: nil, label: "—"))
        let implicit = OverpassClient.parseMaxspeed(NavJSON(["elements": [["tags": ["maxspeed": "RO:urban"]]]] as [String: Any]))
        XCTAssertEqual(implicit, SpeedLimit(kmh: nil, label: "RO:urban"))
    }

    func testCorridorPoisGolden() async throws {
        let c = NavFakeHTTPClient { _ in .navOK(fixture: "overpass_fuel.json") }
        let track = GpxParser.parse(NavFixtures.data("sample_track.gpx"))
        let got = try await OverpassClient(http: c).corridorPois(points: track.points)
        let exp = golden["corridor"]["places"].array
        XCTAssertEqual(got.map(\.name), exp.map { $0["name"].string! })
        XCTAssertEqual(got.map(\.subtitle), exp.map { $0["subtitle"].string! })
        XCTAssertEqual(c.requests[0].navBodyText, golden["corridor"]["requests"][0]["body"].string)
        XCTAssertNil(OverpassClient.corridorQuery(points: []))
    }

    func testFormURLEncodingMatchesJavaURLEncoder() {
        XCTAssertEqual(FormURLEncoding.encode("Câmpina"), "C%C3%A2mpina")
        XCTAssertEqual(FormURLEncoding.encode("a b~c*d.e-f_g"), "a+b%7Ec*d.e-f_g")
        XCTAssertEqual(FormURLEncoding.encode("[out:json];\n"), "%5Bout%3Ajson%5D%3B%0A")
        XCTAssertEqual(FormURLEncoding.encode("é/ü?&="), "%C3%A9%2F%C3%BC%3F%26%3D")
        XCTAssertEqual(FormURLEncoding.decode("a+b%7Ec%C3%A2%zz"), "a b~câ%zz")
    }
}

final class SearchSpeedLimitServiceTests: XCTestCase {
    func testRefreshGateCacheAndFailures() async {
        let clock = NavManualClock(0)
        let fail = Locked(false)
        let c = NavFakeHTTPClient { _ in
            if fail.current { throw NavFakeNetworkError("down") }
            return .navOK(fixture: "overpass_maxspeed.json")
        }
        let svc = SpeedLimitService(http: c, clock: clock)
        XCTAssertTrue(svc.shouldRefresh())
        clock.advance(12)
        XCTAssertFalse(svc.shouldRefresh()) // needs > 12 s
        clock.advance(0.5)
        XCTAssertTrue(svc.shouldRefresh())
        let a = await svc.lookup(lat: 44.4268, lon: 26.1025)
        XCTAssertEqual(a, SpeedLimit(kmh: 50, label: "50"))
        // Same "%.3f,%.3f" cell → cached (no request).
        let b = await svc.lookup(lat: 44.42710, lon: 26.10251)
        XCTAssertEqual(b, a)
        XCTAssertEqual(c.requests.count, 1)
        XCTAssertEqual(SpeedLimitService.cacheKey(lat: 44.4268, lon: 26.1025), "44.427,26.103")
        // TTL 10 min.
        clock.advance(601)
        _ = await svc.lookup(lat: 44.4268, lon: 26.1025)
        XCTAssertEqual(c.requests.count, 2)
        // Errors → (nil, "—"), not cached.
        fail.set(true)
        let e = await svc.lookup(lat: 1, lon: 1)
        XCTAssertEqual(e, SpeedLimit(kmh: nil, label: "—"))
        fail.set(false)
        _ = await svc.lookup(lat: 1, lon: 1)
        XCTAssertEqual(c.requests.count, 4)
    }

    func testDisplayLimit() {
        XCTAssertEqual(SpeedLimitService.displayLimit(SpeedLimit(kmh: 50, label: "50"), units: .metric), SpeedLimit(kmh: 50, label: "50"))
        XCTAssertEqual(SpeedLimitService.displayLimit(SpeedLimit(kmh: 100, label: "100"), units: .imperial), SpeedLimit(kmh: 100, label: "62"))
        XCTAssertEqual(SpeedLimitService.displayLimit(SpeedLimit(kmh: 80, label: "50 mph"), units: .imperial), SpeedLimit(kmh: 80, label: "50"))
        XCTAssertEqual(SpeedLimitService.displayLimit(SpeedLimit(kmh: nil, label: "none"), units: .metric), SpeedLimit(kmh: nil, label: "—"))
        XCTAssertFalse(SpeedLimitService.isVisible(SpeedLimit(kmh: nil, label: "—")))
        XCTAssertFalse(SpeedLimitService.isVisible(nil))
        XCTAssertTrue(SpeedLimitService.isVisible(SpeedLimit(kmh: 50, label: "50")))
    }
}
