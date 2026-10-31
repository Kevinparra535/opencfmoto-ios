// SPDX-License-Identifier: AGPL-3.0-or-later
// OSRM / Valhalla / ORS clients and the via planner against Kotlin golden output
// (golden_routers.json, produced by the upstream routers fed with the same fixtures).

import XCTest
@testable import OpenCfMotoCore

/// Compares a parsed route with a golden route object.
func navAssertRoute(_ r: Route, _ g: NavGJ, _ tag: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(r.label, g["label"].string, "\(tag) label", file: file, line: line)
    navAssertClose(r.distanceM, g["distanceM"].d, 1e-12, "\(tag) distance", file: file, line: line)
    navAssertClose(r.durationSec, g["durationSec"].d, 1e-12, "\(tag) duration", file: file, line: line)
    XCTAssertEqual(r.points.count, g["points"].int, "\(tag) points", file: file, line: line)
    navAssertClose(r.points.first?.lat, g["firstLat"].d, 1e-12, tag, file: file, line: line)
    navAssertClose(r.points.first?.lon, g["firstLon"].d, 1e-12, tag, file: file, line: line)
    navAssertClose(r.points.last?.lat, g["lastLat"].d, 1e-12, tag, file: file, line: line)
    navAssertClose(r.points.last?.lon, g["lastLon"].d, 1e-12, tag, file: file, line: line)
    let gs = g["steps"].array
    XCTAssertEqual(r.steps.count, gs.count, "\(tag) steps", file: file, line: line)
    for (i, (s, e)) in zip(r.steps, gs).enumerated() {
        let t = "\(tag) step \(i)"
        XCTAssertEqual(s.maneuverType, e["type"].string, t, file: file, line: line)
        XCTAssertEqual(s.modifier, e["modifier"].string, t, file: file, line: line)
        XCTAssertEqual(s.roadName, e["road"].string, t, file: file, line: line)
        navAssertClose(s.maneuverLat, e["lat"].d, 1e-12, t, file: file, line: line)
        navAssertClose(s.maneuverLon, e["lon"].d, 1e-12, t, file: file, line: line)
        navAssertClose(s.distanceM, e["distanceM"].d, 1e-12, t, file: file, line: line)
        XCTAssertEqual(s.exit, e["exit"].int, t, file: file, line: line)
        if e["lanes"].isNull {
            XCTAssertNil(s.lanes, t, file: file, line: line)
        } else {
            let lanes = e["lanes"].array.map { Lane(valid: $0["valid"].bool ?? false, indications: $0["indications"].array.compactMap(\.string)) }
            XCTAssertEqual(s.lanes, lanes, t, file: file, line: line)
        }
    }
}

/// JSON texts equal as parsed values (org.json on the JVM does not keep key order).
func navAssertSameJSON(_ a: String, _ b: String?, _ tag: String, file: StaticString = #filePath, line: UInt = #line) {
    guard let b,
          let x = try? JSONSerialization.jsonObject(with: Data(a.utf8), options: [.fragmentsAllowed]),
          let y = try? JSONSerialization.jsonObject(with: Data(b.utf8), options: [.fragmentsAllowed]) else {
        XCTFail("\(tag): unparsable JSON", file: file, line: line); return
    }
    XCTAssertEqual(NSArray(array: [x]), NSArray(array: [y]), "\(tag)\n\(a)\n\(b)", file: file, line: line)
}

final class RouterClientsTests: XCTestCase {
    private lazy var golden = NavGJ(NavFixtures.json("golden_routers.json"))
    private let s = GeoPoint(lat: 44.43, lon: 26.10)
    private let e = GeoPoint(lat: 44.44, lon: 26.115)

    private func compare(_ outcome: Result<[Route], Error>, _ client: NavFakeHTTPClient, _ g: NavGJ, _ tag: String,
                         file: StaticString = #filePath, line: UInt = #line) {
        switch outcome {
        case let .success(routes):
            XCTAssertTrue(g["error"].isNull, "\(tag) expected error \(g["error"].string ?? "")", file: file, line: line)
            XCTAssertEqual(routes.count, g["routes"].array.count, tag, file: file, line: line)
            for (i, (r, gr)) in zip(routes, g["routes"].array).enumerated() { navAssertRoute(r, gr, "\(tag)[\(i)]", file: file, line: line) }
        case let .failure(err):
            XCTAssertEqual(NavServiceError.message(for: err, fallback: ""), g["error"].string, tag, file: file, line: line)
        }
        let reqs = client.requests
        let greqs = g["requests"].array
        XCTAssertEqual(reqs.count, greqs.count, "\(tag) request count", file: file, line: line)
        for (r, gr) in zip(reqs, greqs) {
            XCTAssertEqual(r.method, gr["method"].string, tag, file: file, line: line)
            XCTAssertEqual(r.navURLText, gr["url"].string, tag, file: file, line: line)
            if let body = gr["body"].string { navAssertSameJSON(r.navBodyText, body, tag, file: file, line: line) }
            if let auth = gr["headers"]["Authorization"].string { XCTAssertEqual(r.headers["Authorization"], auth, tag, file: file, line: line) }
        }
    }

    private func run(_ client: NavFakeHTTPClient, _ body: @escaping @Sendable () async throws -> [Route]) async -> Result<[Route], Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    // MARK: OSRM

    func testOsrmGolden() async {
        let c = NavFakeHTTPClient { _ in .navOK(fixture: "osrm_route_alts.json") }
        let osrm = OsrmRouter(http: c)
        let (s, e) = (self.s, self.e)
        compare(await run(c) { try await osrm.routes(from: s, to: e, alternatives: 2) }, c, golden["osrm"], "osrm")
    }

    func testOsrmViasClampAndJavaDoubleToString() async {
        let c = NavFakeHTTPClient { _ in .navOK(fixture: "osrm_route_alts.json") }
        let osrm = OsrmRouter(http: c)
        let (s, e) = (self.s, self.e)
        let vias = [GeoPoint(lat: 44.435, lon: 26.105), GeoPoint(lat: 0.0001, lon: -0.00002)]
        compare(await run(c) { try await osrm.routes(from: s, to: e, alternatives: 7, vias: vias, label: "Alt") }, c, golden["osrmVias"], "osrmVias")
        // Kotlin Double.toString: 1.0E-4, -2.0E-5.
        XCTAssertTrue(c.requests[0].navURLText.contains(";-2.0E-5,1.0E-4;"))
    }

    func testOsrmFallbackChain() async {
        let counter = Locked(0)
        let c = NavFakeHTTPClient { _ in
            let n = counter.withLock { $0 += 1; return $0 }
            if n <= 2 { throw NavFakeNetworkError("boom \(n)") }
            return .navOK(fixture: "osrm_reroute.json")
        }
        let osrm = OsrmRouter(http: c)
        let from = GeoPoint(lat: 44.435, lon: 26.1013), e = self.e
        compare(await run(c) { try await osrm.routes(from: from, to: e, alternatives: 2) }, c, golden["osrmFallback"], "osrmFallback")
    }

    func testOsrmErrors() async {
        for (fixtureText, key) in [(NavFixtures.string("osrm_noroute.json"), "osrmNoRoute"),
                                   (#"{"code":"Ok","routes":[{"geometry":{"coordinates":[[26.1,44.43]]},"distance":1}]}"#, "osrmTooShort"),
                                   (#"{"code":"InvalidQuery"}"#, "osrmCodeOnly")] {
            let c = NavFakeHTTPClient { _ in .navOK(Data(fixtureText.utf8)) }
            let osrm = OsrmRouter(http: c)
            let (s, e) = (self.s, self.e)
            compare(await run(c) { try await osrm.routes(from: s, to: e, alternatives: 0) }, c, golden[key], key)
        }
    }

    func testOsrmHttpErrorMessages() async {
        let c = NavFakeHTTPClient { _ in HTTPResponse(status: 429) }
        do {
            _ = try await OsrmRouter(http: c).route(from: s, to: e)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(NavServiceError.message(for: error, fallback: ""), "Map service is busy (rate limited) — try again shortly")
        }
        XCTAssertEqual(NavServiceError.forStatus(503).description, "Map service temporarily unavailable (HTTP 503)")
        XCTAssertEqual(NavServiceError.forStatus(404).description, "Request failed (HTTP 404)")
        XCTAssertEqual(NavServiceError.forStatus(404), .http(code: 404, message: "Request failed (HTTP 404)", busy: false))
        if case let .http(_, _, busy) = NavServiceError.forStatus(500) { XCTAssertTrue(busy) } else { XCTFail() }
    }

    func testOsrmUrlFormat() {
        let url = OsrmRouter.routeURL(from: GeoPoint(lat: 44.4268, lon: 26.1025), to: GeoPoint(lat: 45.7489, lon: 21.2087), alternatives: 2)
        XCTAssertEqual(url.absoluteString,
                       "https://router.project-osrm.org/route/v1/driving/26.1025,44.4268;21.2087,45.7489?overview=full&geometries=geojson&steps=true&alternatives=2")
        XCTAssertEqual(OsrmRouter.routeURL(from: s, to: e, alternatives: 0, simplified: true).absoluteString,
                       "https://router.project-osrm.org/route/v1/driving/26.1,44.43;26.115,44.44?overview=simplified&geometries=geojson&steps=false&alternatives=false")
        XCTAssertEqual(OsrmRouter.coordinatePath(from: GeoPoint(lat: 45, lon: 7), to: GeoPoint(lat: 1e7, lon: -0.0), vias: []),
                       "7.0,45.0;-0.0,1.0E7")
    }

    // MARK: Valhalla

    func testValhallaGoldenAllOptionSets() async {
        let sets: [(String, RouteOptions)] = [("none", RouteOptions()), ("hwy", RouteOptions(avoidHighways: true)),
                                              ("toll", RouteOptions(avoidTolls: true)),
                                              ("both", RouteOptions(avoidTolls: true, avoidHighways: true)), ("fun", RouteOptions(mode: .fun))]
        for (name, opts) in sets {
            let c = NavFakeHTTPClient { _ in .navOK(fixture: "valhalla_route.json") }
            let v = ValhallaRouter(http: c)
            let (s, e) = (self.s, self.e)
            compare(await run(c) { try await v.routes(from: s, to: e, options: opts, alternatives: 2) }, c, golden["valhalla"][name], "valhalla.\(name)")
        }
    }

    func testValhallaViasCircuitAndEmpty() async {
        let c1 = NavFakeHTTPClient { _ in .navOK(fixture: "valhalla_route.json") }
        let v1 = ValhallaRouter(http: c1)
        let (s, e) = (self.s, self.e)
        compare(await run(c1) { try await v1.routes(from: s, to: s, options: RouteOptions(avoidHighways: true), vias: [e],
                                                     alternatives: 9, label: "Circuit") }, c1, golden["valhallaVias"], "valhallaVias")
        let c2 = NavFakeHTTPClient { _ in .navOK(fixture: "valhalla_circuit.json") }
        let v2 = ValhallaRouter(http: c2)
        compare(await run(c2) { try await v2.routes(from: s, to: s, options: RouteOptions(), vias: [e], label: "Circuit") },
                c2, golden["valhallaCircuit"], "valhallaCircuit")
        let c3 = NavFakeHTTPClient { _ in .navOK(Data(#"{"trip":{"legs":[]}}"#.utf8)) }
        let v3 = ValhallaRouter(http: c3)
        compare(await run(c3) { try await v3.routes(from: s, to: e) }, c3, golden["valhallaEmpty"], "valhallaEmpty")
    }

    func testValhallaBodiesMatchSpecByteForByte() {
        let a = GeoPoint(lat: 44.4268, lon: 26.1025), b = GeoPoint(lat: 45.7489, lon: 21.2087)
        XCTAssertEqual(ValhallaRouter.requestBody(from: a, to: b, options: RouteOptions(), alternatives: 2).jsonString,
                       #"{"locations":[{"lat":44.4268,"lon":26.1025},{"lat":45.7489,"lon":21.2087}],"costing":"auto","costing_options":{"auto":{"shortest":false}},"directions_options":{"units":"kilometers"},"alternates":2}"#)
        XCTAssertEqual(ValhallaRouter.requestBody(from: a, to: b, options: RouteOptions(avoidTolls: true, avoidHighways: true), alternatives: 3).jsonString,
                       #"{"locations":[{"lat":44.4268,"lon":26.1025},{"lat":45.7489,"lon":21.2087}],"costing":"motorcycle","costing_options":{"motorcycle":{"shortest":false,"exclude_highways":true,"use_tolls":0,"toll_booth_penalty":600}},"directions_options":{"units":"kilometers"},"alternates":3}"#)
        XCTAssertEqual(ValhallaRouter.requestBody(from: a, to: b, options: RouteOptions(avoidTolls: true), alternatives: 0).jsonString,
                       #"{"locations":[{"lat":44.4268,"lon":26.1025},{"lat":45.7489,"lon":21.2087}],"costing":"auto","costing_options":{"auto":{"shortest":false,"use_tolls":0,"toll_booth_penalty":600}},"directions_options":{"units":"kilometers"}}"#)
    }

    func testValhallaManeuverMapping() {
        let table: [Int: (String, String?)] = [1: ("depart", nil), 2: ("depart", nil), 3: ("depart", nil), 4: ("arrive", nil),
            5: ("arrive", nil), 6: ("arrive", nil), 7: ("continue", "straight"), 8: ("continue", "straight"), 9: ("turn", "slight right"),
            10: ("turn", "right"), 11: ("turn", "sharp right"), 12: ("turn", "uturn"), 13: ("turn", "uturn"), 14: ("turn", "sharp left"),
            15: ("turn", "left"), 16: ("turn", "slight left"), 17: ("on ramp", "straight"), 18: ("on ramp", "right"), 19: ("on ramp", "left"),
            20: ("off ramp", "right"), 21: ("off ramp", "left"), 22: ("continue", "straight"), 23: ("fork", "right"), 24: ("fork", "left"),
            25: ("merge", nil), 26: ("roundabout", nil), 27: ("exit roundabout", nil), 28: ("ferry", nil), 29: ("ferry", nil),
            0: ("continue", "straight"), 99: ("continue", "straight")]
        for (t, exp) in table {
            let m = ValhallaRouter.mapManeuver(t)
            XCTAssertEqual(m.0, exp.0, "\(t)")
            XCTAssertEqual(m.1, exp.1, "\(t)")
        }
    }

    func testMotorwayNamePatterns() {
        XCTAssertTrue(ValhallaRouter.looksLikeMotorway("A1"))
        XCTAssertTrue(ValhallaRouter.looksLikeMotorway("Autostrada Soarelui"))
        XCTAssertTrue(ValhallaRouter.looksLikeMotorway("A 2"))
        XCTAssertTrue(ValhallaRouter.looksLikeMotorway("E81/A1"))
        XCTAssertTrue(ValhallaRouter.looksLikeMotorway("Bundesautobahn"))
        XCTAssertFalse(ValhallaRouter.looksLikeMotorway("DN2A"))
        XCTAssertFalse(ValhallaRouter.looksLikeMotorway("DJ12A"))
        XCTAssertFalse(ValhallaRouter.looksLikeMotorway("Strada A12b"))
        XCTAssertFalse(ValhallaRouter.looksLikeMotorway("Calea Victoriei"))
        XCTAssertFalse(ValhallaRouter.looksLikeMotorway("   "))
    }

    // MARK: ORS

    func testOrsGolden() async {
        let c = NavFakeHTTPClient { _ in .navOK(fixture: "ors_route.json") }
        let ors = OrsRouter(http: c)
        let (s, e) = (self.s, self.e)
        compare(await run(c) { try await ors.routes(apiKey: "  abc ", from: s, to: e, options: RouteOptions(avoidTolls: true, avoidHighways: true),
                                                    alternatives: true) }, c, golden["ors"], "ors")
        let c2 = NavFakeHTTPClient { _ in .navOK(fixture: "ors_route.json") }
        let ors2 = OrsRouter(http: c2)
        compare(await run(c2) { try await ors2.routes(apiKey: "abc", from: s, to: e, options: RouteOptions(mode: .fun),
                                                      vias: [GeoPoint(lat: 44.435, lon: 26.11)], alternatives: false, label: "X") },
                c2, golden["orsFun"], "orsFun")
    }

    func testOrsBearerAndAlternativeRetries() async {
        let (s, e) = (self.s, self.e)
        let c1 = NavFakeHTTPClient { r in
            if r.headers["Authorization"] == "abc" { throw NavFakeNetworkError("401") }
            return .navOK(fixture: "ors_route.json")
        }
        let o1 = OrsRouter(http: c1)
        compare(await run(c1) { try await o1.routes(apiKey: "abc", from: s, to: e, options: RouteOptions(), alternatives: true) },
                c1, golden["orsBearer"], "orsBearer")
        let c2 = NavFakeHTTPClient { r in
            if r.navBodyText.contains("alternative_routes") { throw NavFakeNetworkError("alts") }
            return .navOK(fixture: "ors_route.json")
        }
        let o2 = OrsRouter(http: c2)
        compare(await run(c2) { try await o2.routes(apiKey: "abc", from: s, to: e, options: RouteOptions(avoidTolls: true), alternatives: true) },
                c2, golden["orsAltRetry"], "orsAltRetry")
        let c3 = NavFakeHTTPClient { _ in throw NavFakeNetworkError("down") }
        let o3 = OrsRouter(http: c3)
        compare(await run(c3) { try await o3.routes(apiKey: "Bearer xyz", from: s, to: e, options: RouteOptions(maxAlternatives: 0), alternatives: true) },
                c3, golden["orsBearerKeyFails"], "orsBearerKeyFails")
        let c4 = NavFakeHTTPClient { _ in .navOK(fixture: "ors_error.json") }
        let o4 = OrsRouter(http: c4)
        compare(await run(c4) { try await o4.routes(apiKey: "abc", from: s, to: e, options: RouteOptions(), alternatives: false) },
                c4, golden["orsError"], "orsError")
    }

    func testOrsBodyMatchesSpecExample() {
        let body = OrsRouter.requestBody(from: GeoPoint(lat: 44.4268, lon: 26.1025), to: GeoPoint(lat: 45.7489, lon: 21.2087),
                                         options: RouteOptions(avoidTolls: true, avoidHighways: true), alternatives: true)
        XCTAssertEqual(body.jsonString,
                       #"{"coordinates":[[26.1025,44.4268],[21.2087,45.7489]],"instructions":true,"geometry":true,"elevation":false,"preference":"recommended","alternative_routes":{"target_count":3,"weight_factor":2,"share_factor":0.8},"options":{"avoid_features":["highways","tollways"]}}"#)
        let fun = OrsRouter.requestBody(from: s, to: e, options: RouteOptions(mode: .fun), alternatives: false)
        XCTAssertEqual(fun["preference"], .string("shortest"))
        XCTAssertNil(fun["alternative_routes"])
        XCTAssertNil(fun["options"])
        XCTAssertNil(OrsRouter.requestBody(from: s, to: e, options: RouteOptions(maxAlternatives: 0), alternatives: true)["alternative_routes"])
    }

    func testOrsTypeMapping() {
        let exp: [(String, String?)] = [("turn", "left"), ("turn", "right"), ("turn", "sharp left"), ("turn", "sharp right"),
            ("turn", "slight left"), ("turn", "slight right"), ("continue", "straight"), ("roundabout", nil), ("exit roundabout", nil),
            ("turn", "uturn"), ("arrive", nil), ("depart", nil), ("turn", "slight left"), ("turn", "slight right")]
        for (t, e) in exp.enumerated() {
            XCTAssertEqual(OrsRouter.mapType(t).0, e.0)
            XCTAssertEqual(OrsRouter.mapType(t).1, e.1)
        }
        XCTAssertEqual(OrsRouter.mapType(42).0, "continue")
    }

    // MARK: Polyline

    func testPolyline6GoldenAndSpecVectors() {
        for row in golden["polyline6"].array {
            let pts = PolylineCodec.decode(row["shape"].string!, precision: 6)
            let exp = row["points"].array
            XCTAssertEqual(pts.count, exp.count)
            for (p, q) in zip(pts, exp) {
                XCTAssertEqual(p.lat, q[0].d, accuracy: 1e-12)
                XCTAssertEqual(p.lon, q[1].d, accuracy: 1e-12)
            }
        }
        // Spec: Google sample at precision 6 and 5; Valhalla round trip within 1e-5.
        let google = [GeoPoint(lat: 38.5, lon: -120.2), GeoPoint(lat: 40.7, lon: -120.95), GeoPoint(lat: 43.252, lon: -126.453)]
        XCTAssertEqual(PolylineCodec.encode(google, precision: 6), "_izlhA~rlgdF_{geC~ywl@_kwzCn`{nI")
        XCTAssertEqual(PolylineCodec.encode(google, precision: 5), "_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        XCTAssertEqual(PolylineCodec.encode([GeoPoint(lat: 44.4268, lon: 26.1025), GeoPoint(lat: 45.7489, lon: 21.2087)], precision: 6),
                       "_brvsAgmdxp@gfuoAneuiH")
        let five = PolylineCodec.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@", precision: 5)
        XCTAssertEqual(five.count, 3)
        XCTAssertEqual(five[2].lon, -126.453, accuracy: 1e-9)
        XCTAssertTrue(PolylineCodec.decode("", precision: 6).isEmpty)
        // Precision 5 on Valhalla data is 10× off.
        XCTAssertEqual(PolylineCodec.decode("_brvsAgmdxp@gfuoAneuiH", precision: 5)[0].lat, 444.268, accuracy: 1e-6)
        // Truncated input stops at the last complete pair.
        XCTAssertEqual(PolylineCodec.decode("_brvsAgmdxp@gfuoA", precision: 6).count, 1)
    }

    // MARK: Fun planner

    func testFunViaSetsGolden() {
        let g = golden["fun"]
        for row in g["viaSets"].array {
            let c = row["c"].array.map(\.d)
            let from = GeoPoint(lat: c[0], lon: c[1]), to = GeoPoint(lat: c[2], lon: c[3])
            for (key, sets) in [("fun", FunRoutePlanner.funViaSets(from: from, to: to)), ("alt", FunRoutePlanner.altViaSets(from: from, to: to)),
                                ("short", FunRoutePlanner.shortViaSets(from: from, to: to))] {
                let exp = row[key].array
                XCTAssertEqual(sets.count, exp.count)
                for (set, es) in zip(sets, exp) {
                    XCTAssertEqual(set.count, es.array.count)
                    for (p, q) in zip(set, es.array) {
                        navAssertClose(p.lat, q[0].d, 1e-12, key)
                        navAssertClose(p.lon, q[1].d, 1e-12, key)
                    }
                }
            }
        }
        let circuit = FunRoutePlanner.circuitWaypoints(lat: 45, lon: 25, targetKm: 60)
        for (p, q) in zip(circuit, g["circuit"].array) {
            navAssertClose(p.lat, q[0].d, 1e-12)
            navAssertClose(p.lon, q[1].d, 1e-12)
        }
    }

    func testUpstreamFunRoutePlannerVectors() {
        let vias = FunRoutePlanner.circuitWaypoints(lat: 45, lon: 25, targetKm: 60)
        XCTAssertEqual(vias.count, 4)
        XCTAssertEqual(vias.last!.lat, 45, accuracy: 1e-9)
        XCTAssertEqual(vias.last!.lon, 25, accuracy: 1e-9)
        for v in vias.dropLast() { XCTAssertGreaterThan(GeoMath.haversineKm(45, 25, v.lat, v.lon), 3) }
        let sets = FunRoutePlanner.funViaSets(from: GeoPoint(lat: 45, lon: 25), to: GeoPoint(lat: 46, lon: 26))
        XCTAssertGreaterThanOrEqual(sets.count, 2)
        XCTAssertTrue(sets.allSatisfy { !$0.isEmpty })
        // Spec-derived: offset 18 km, midL (45.35776, 25.63947), midR (45.64193, 25.35958).
        XCTAssertEqual(sets[0][0].lat, 45.35776, accuracy: 1e-5)
        XCTAssertEqual(sets[0][0].lon, 25.63947, accuracy: 1e-5)
        XCTAssertEqual(sets[1][0].lat, 45.64193, accuracy: 1e-5)
        XCTAssertEqual(sets[1][0].lon, 25.35958, accuracy: 1e-5)
        let short = Route(points: [TrackPoint(lat: 0, lon: 0), TrackPoint(lat: 0.1, lon: 0.1)], distanceM: 10_000, durationSec: 600)
        let twisty = Route(points: [TrackPoint(lat: 0, lon: 0), TrackPoint(lat: 0.2, lon: 0.2)], distanceM: 25_000, durationSec: 1_200,
                           steps: Array(repeating: RouteStep(maneuverType: "turn", modifier: "left", roadName: "Road", maneuverLat: 0,
                                                             maneuverLon: 0, distanceM: 100), count: 20))
        XCTAssertEqual(FunRoutePlanner.twistScore(short), 8.5, accuracy: 1e-9)
        XCTAssertEqual(FunRoutePlanner.twistScore(twisty), 14.25, accuracy: 1e-9)
        let gt = golden["fun"]["twist"].array
        XCTAssertEqual(FunRoutePlanner.twistScore(short), gt[0].d)
        XCTAssertEqual(FunRoutePlanner.twistScore(twisty), gt[1].d)
        XCTAssertEqual(FunRoutePlanner.twistScore(Route(points: short.points, distanceM: 500, durationSec: 20)), gt[2].d)
    }
}
