// SPDX-License-Identifier: AGPL-3.0-or-later
// RouteOrchestrator (OfflineRouter port) decision tree vs. the Kotlin implementation driven with
// the same scripted HTTP answers (golden_orchestrator.json), plus unit tests of the selection
// helpers (dedupe, same corridor, preview picking, via junk filter, beeline).

import XCTest
@testable import OpenCfMotoCore

final class RouteOrchestratorTests: XCTestCase {
    /// Same routing table as the Kotlin generator's `handlerFor`.
    static func handler(valhalla: String?, osrmDirect: String?, osrmVia: String?, ors: String?) -> @Sendable (HTTPRequest) throws -> HTTPResponse {
        { r in
            let u = r.url.absoluteString
            if u.contains("valhalla") {
                guard let f = valhalla else { throw NavFakeNetworkError("valhalla down") }
                return .navOK(fixture: f)
            }
            if u.contains("openrouteservice") {
                guard let f = ors else { throw NavFakeNetworkError("ors down") }
                return .navOK(fixture: f)
            }
            if u.contains("project-osrm") {
                let path = u.components(separatedBy: "/driving/")[1].components(separatedBy: "?")[0]
                let coords = path.split(separator: ";").count
                if coords <= 2 {
                    guard let f = osrmDirect else { throw NavFakeNetworkError("osrm down") }
                    return .navOK(fixture: f)
                }
                guard let f = osrmVia else { throw NavFakeNetworkError("osrm via down") }
                return .navOK(fixture: f)
            }
            throw NavFakeNetworkError("unexpected \(u)")
        }
    }

    struct Scenario {
        var name: String
        var kind: String
        var options: RouteOptions
        var key: String
        var handler: @Sendable (HTTPRequest) throws -> HTTPResponse
    }

    static let scenarios: [Scenario] = [
        Scenario(name: "previewFast", kind: "alts", options: RouteOptions(), key: "", handler: handler(valhalla: "valhalla_route.json", osrmDirect: "osrm_route_alts.json", osrmVia: nil, ors: nil)),
        Scenario(name: "previewFun", kind: "alts", options: RouteOptions(mode: .fun), key: "", handler: handler(valhalla: "valhalla_route.json", osrmDirect: "osrm_route_alts.json", osrmVia: nil, ors: nil)),
        Scenario(name: "previewViaFill", kind: "alts", options: RouteOptions(), key: "", handler: handler(valhalla: nil, osrmDirect: "osrm_reroute.json", osrmVia: "osrm_route_alts.json", ors: nil)),
        Scenario(name: "previewOsrmOnly", kind: "alts", options: RouteOptions(), key: "", handler: handler(valhalla: nil, osrmDirect: "osrm_route_alts.json", osrmVia: nil, ors: nil)),
        Scenario(name: "single", kind: "single", options: RouteOptions(), key: "", handler: handler(valhalla: "valhalla_route.json", osrmDirect: "osrm_route_alts.json", osrmVia: nil, ors: nil)),
        Scenario(name: "singleFun", kind: "single", options: RouteOptions(mode: .fun), key: "", handler: handler(valhalla: nil, osrmDirect: "osrm_route_alts.json", osrmVia: nil, ors: nil)),
        Scenario(name: "avoidHwyValhalla", kind: "alts", options: RouteOptions(avoidHighways: true), key: "", handler: handler(valhalla: "valhalla_route.json", osrmDirect: "osrm_route_alts.json", osrmVia: nil, ors: nil)),
        Scenario(name: "avoidHwySingle", kind: "single", options: RouteOptions(avoidHighways: true), key: "", handler: handler(valhalla: "valhalla_route.json", osrmDirect: nil, osrmVia: nil, ors: nil)),
        Scenario(name: "avoidOrs", kind: "alts", options: RouteOptions(avoidTolls: true, avoidHighways: true), key: "key1", handler: handler(valhalla: nil, osrmDirect: nil, osrmVia: nil, ors: "ors_route.json")),
        Scenario(name: "avoidOrsLong", kind: "alts", options: RouteOptions(avoidTolls: true), key: "key1", handler: handler(valhalla: nil, osrmDirect: nil, osrmVia: nil, ors: "ors_error.json")),
        Scenario(name: "avoidFallback", kind: "alts", options: RouteOptions(avoidTolls: true), key: "", handler: handler(valhalla: nil, osrmDirect: "osrm_route_alts.json", osrmVia: nil, ors: nil)),
        Scenario(name: "noKeyOrsFallback", kind: "alts", options: RouteOptions(), key: "key2", handler: handler(valhalla: nil, osrmDirect: nil, osrmVia: nil, ors: "ors_route.json")),
        Scenario(name: "allDownPreview", kind: "alts", options: RouteOptions(), key: "", handler: handler(valhalla: nil, osrmDirect: nil, osrmVia: nil, ors: nil)),
        Scenario(name: "allDownSingle", kind: "single", options: RouteOptions(mode: .fun), key: "", handler: handler(valhalla: nil, osrmDirect: nil, osrmVia: nil, ors: nil)),
        Scenario(name: "longTrip", kind: "alts", options: RouteOptions(), key: "", handler: handler(valhalla: "valhalla_route.json", osrmDirect: "osrm_route_alts.json", osrmVia: "osrm_reroute.json", ors: nil)),
        Scenario(name: "circuitOsrm", kind: "circuit", options: RouteOptions(), key: "", handler: handler(valhalla: nil, osrmDirect: nil, osrmVia: "osrm_route_alts.json", ors: nil)),
        Scenario(name: "circuitValhalla", kind: "circuit", options: RouteOptions(avoidHighways: true), key: "", handler: handler(valhalla: "valhalla_circuit.json", osrmDirect: nil, osrmVia: nil, ors: nil)),
        Scenario(name: "circuitAvoidOsrmOnly", kind: "circuit", options: RouteOptions(avoidTolls: true), key: "", handler: handler(valhalla: nil, osrmDirect: nil, osrmVia: "osrm_route_alts.json", ors: nil)),
        Scenario(name: "circuitAllDown", kind: "circuit", options: RouteOptions(), key: "", handler: handler(valhalla: nil, osrmDirect: nil, osrmVia: nil, ors: nil)),
        Scenario(name: "circuitAllDownAvoid", kind: "circuit", options: RouteOptions(avoidHighways: true), key: "", handler: handler(valhalla: nil, osrmDirect: nil, osrmVia: nil, ors: nil)),
    ]

    func testGoldenDecisionTree() async throws {
        let golden = NavGJ(NavFixtures.json("golden_orchestrator.json"))
        for sc in Self.scenarios {
            let g = golden[sc.name]
            XCTAssertFalse(g.isNull, sc.name)
            let from = GeoPoint(lat: g["from"][0].d, lon: g["from"][1].d)
            let to = GeoPoint(lat: g["to"][0].d, lon: g["to"][1].d)
            let client = NavFakeHTTPClient(sc.handler)
            let orch = RouteOrchestrator(http: client, orsApiKey: sc.key)
            var result: RouteResult
            switch sc.kind {
            case "alts": result = await orch.alternatives(from: from, to: to, options: sc.options)
            case "single": result = RouteResult(routes: [await orch.route(from: from, to: to, options: sc.options)])
            default: result = try await orch.circuit(from: from, to: to, options: sc.options)
            }
            let groutes = g["routes"].array
            XCTAssertEqual(result.routes.count, groutes.count, "\(sc.name) count")
            for (i, (r, gr)) in zip(result.routes, groutes).enumerated() { navAssertRoute(r, gr, "\(sc.name)[\(i)]") }
            if sc.kind == "alts" {
                XCTAssertEqual(result.avoidHonored, g["avoidHonored"].bool, sc.name)
                XCTAssertEqual(result.warning, g["warning"].string, sc.name)
            }
            let reqs = client.requests
            let greqs = g["requests"].array
            XCTAssertEqual(reqs.count, greqs.count, "\(sc.name) request count")
            for (k, (r, gr)) in zip(reqs, greqs).enumerated() {
                XCTAssertEqual(r.method, gr["method"].string, "\(sc.name) req \(k)")
                XCTAssertEqual(r.navURLText, gr["url"].string, "\(sc.name) req \(k)")
                if let body = gr["body"].string { navAssertSameJSON(r.navBodyText, body, "\(sc.name) req \(k)") }
            }
        }
    }

    func testCircuitWarningsAreReported() async throws {
        // Android drops the RouteResult of a circuit (only routes reach the UI); iOS keeps it.
        let client = NavFakeHTTPClient(Self.handler(valhalla: nil, osrmDirect: nil, osrmVia: "osrm_route_alts.json", ors: nil))
        let orch = RouteOrchestrator(http: client)
        let r = try await orch.circuit(from: GeoPoint(lat: 44.43, lon: 26.10), to: GeoPoint(lat: 44.44, lon: 26.115),
                                       options: RouteOptions(avoidTolls: true))
        XCTAssertFalse(r.avoidHonored)
        XCTAssertEqual(r.warning, RouteOrchestrator.warningCircuitAvoid)
        XCTAssertEqual(r.routes.first?.label, "Circuit")
    }

    func testOrsKeyIsTrimmedAndMutable() {
        let orch = RouteOrchestrator(http: NavFakeHTTPClient { _ in throw NavFakeNetworkError() }, orsApiKey: "  k1 \n")
        XCTAssertEqual(orch.orsApiKey, "k1")
        orch.orsApiKey = " k2 "
        XCTAssertEqual(orch.orsApiKey, "k2")
    }

    func testCancellationStopsFurtherRequests() async {
        let client = NavFakeHTTPClient(Self.handler(valhalla: nil, osrmDirect: nil, osrmVia: nil, ors: nil))
        let orch = RouteOrchestrator(http: client)
        let task = Task {
            // Cancelled before its first request whatever the scheduling (a `task.cancel()` from here
            // raced the task's start and failed under load in the full suite).
            withUnsafeCurrentTask { $0?.cancel() }
            return await orch.alternatives(from: GeoPoint(lat: 44.43, lon: 26.10), to: GeoPoint(lat: 44.44, lon: 26.115), options: RouteOptions())
        }
        let r = await task.value
        XCTAssertEqual(r.routes.first?.label, "Direct")
        XCTAssertLessThanOrEqual(client.requests.count, 1)
    }

    // MARK: Helpers

    private func route(_ d: Double, _ t: Double, label: String = "", steps: Int = 0) -> Route {
        Route(points: [TrackPoint(lat: 0, lon: 0), TrackPoint(lat: 0, lon: 0.01)], distanceM: d, durationSec: t,
              steps: Array(repeating: RouteStep(maneuverType: "turn", modifier: "left", maneuverLat: 0, maneuverLon: 0), count: steps),
              label: label)
    }

    func testDedupeTolerances() {
        // Short trips: < 200 m and < 40 s; otherwise < 800 m and < 120 s. First occurrence wins.
        let rs = [route(10_000, 600, label: "a"), route(10_150, 630, label: "b"), route(10_150, 641, label: "c"), route(10_700, 700, label: "d")]
        XCTAssertEqual(RouteOrchestrator.dedupe(rs, approxKm: 10).map(\.label), ["a", "c", "d"])
        XCTAssertEqual(RouteOrchestrator.dedupe(rs, approxKm: 60).map(\.label), ["a"])
        XCTAssertEqual(RouteOrchestrator.dedupe(rs).map(\.label), ["a"]) // default approxKm 100
    }

    func testSameCorridor() {
        XCTAssertTrue(RouteOrchestrator.sameCorridor(route(10_000, 600), route(10_499, 689), approxKm: 10))
        XCTAssertFalse(RouteOrchestrator.sameCorridor(route(10_000, 600), route(10_500, 600), approxKm: 10))
        XCTAssertFalse(RouteOrchestrator.sameCorridor(route(10_000, 600), route(10_000, 690), approxKm: 10))
        XCTAssertTrue(RouteOrchestrator.sameCorridor(route(10_000, 600), route(11_499, 779), approxKm: 50))
        XCTAssertFalse(RouteOrchestrator.sameCorridor(route(10_000, 600), route(11_500, 600), approxKm: 50))
    }

    func testPickPreviewRoutesOrderAndLabels() {
        let fast = route(10_000, 600)
        let twisty = route(14_000, 900, steps: 30)
        let alt = route(12_000, 700)
        let picked = RouteOrchestrator.pickPreviewRoutes([twisty, alt, fast], approxKm: 20, mode: .fast, forceLabel: nil)
        XCTAssertEqual(picked.map(\.label), ["Fast", "Fun", "Alt"])
        XCTAssertEqual(picked.map(\.durationSec), [600, 900, 700])
        let funFirst = RouteOrchestrator.pickPreviewRoutes([twisty, alt, fast], approxKm: 20, mode: .fun, forceLabel: "Circuit")
        XCTAssertEqual(funFirst.map(\.label), ["Circuit", "Fast", "Alt"])
        XCTAssertEqual(funFirst.map(\.durationSec), [900, 600, 700])
        XCTAssertEqual(RouteOrchestrator.pickPreviewRoutes([], approxKm: 20, mode: .fast, forceLabel: nil), [])
        // Long trips add extra Alts up to 5.
        let many = [route(100_000, 3600), route(110_000, 3900, steps: 50), route(120_000, 4200), route(130_000, 4500), route(140_000, 4800), route(150_000, 5100)]
        let long = RouteOrchestrator.pickPreviewRoutes(many, approxKm: 150, mode: .fast, forceLabel: nil)
        XCTAssertEqual(long.count, 5)
        XCTAssertEqual(long.map(\.label), ["Fast", "Fun", "Alt", "Alt", "Alt"])
    }

    func testViaJunkFilter() {
        func steps(_ names: [String], uturnAt: Int? = nil) -> [RouteStep] {
            names.enumerated().map { i, n in
                RouteStep(maneuverType: "turn", modifier: i == uturnAt ? "uturn" : "left", roadName: n, maneuverLat: 0, maneuverLon: 0, distanceM: 100)
            }
        }
        let pts = (0 ..< 20).map { TrackPoint(lat: 0, lon: Double($0) * 0.001) }
        XCTAssertTrue(RouteOrchestrator.isViaJunk(Route(points: pts, distanceM: 2000, durationSec: 200, steps: steps(["a", "b", "c"], uturnAt: 1))))
        XCTAssertFalse(RouteOrchestrator.isViaJunk(Route(points: pts, distanceM: 2000, durationSec: 200, steps: steps(["a", "b", "c"], uturnAt: 0))))
        // Local street ping-pong 40–500 m apart.
        XCTAssertTrue(RouteOrchestrator.isViaJunk(Route(points: pts, distanceM: 2000, durationSec: 200,
                                                         steps: steps(["DN1", "Strada Lunga", "Aleea X", "strada lunga", "DN1"]))))
        XCTAssertFalse(RouteOrchestrator.isViaJunk(Route(points: pts, distanceM: 2000, durationSec: 200,
                                                          steps: steps(["DN1", "DN7", "Calea Victoriei", "DN7", "x"]))))
        XCTAssertFalse(RouteOrchestrator.isLocalStreetName("dn1 strada"))
        XCTAssertFalse(RouteOrchestrator.isLocalStreetName("a1 strada"))
        XCTAssertTrue(RouteOrchestrator.isLocalStreetName("strada unirii"))
        XCTAssertTrue(RouteOrchestrator.isLocalStreetName("intrarea x"))
        XCTAssertFalse(RouteOrchestrator.isLocalStreetName("str"))
        XCTAssertFalse(RouteOrchestrator.isLocalStreetName("bulevardul unirii"))
        // Tight cul-de-sac: out 200 m and straight back.
        var spur: [TrackPoint] = (0 ..< 11).map { TrackPoint(lat: 0, lon: Double($0) * 0.0002) }
        spur += (1 ..< 11).map { TrackPoint(lat: 0.00005, lon: 0.002 - Double($0) * 0.0002) }
        XCTAssertTrue(RouteOrchestrator.hasTightCulDeSacSpur(spur))
        XCTAssertFalse(RouteOrchestrator.hasTightCulDeSacSpur(pts))
        XCTAssertFalse(RouteOrchestrator.hasTightCulDeSacSpur(Array(spur.prefix(9))))
    }

    func testBeeline() {
        let from = GeoPoint(lat: 44.43, lon: 26.10), to = GeoPoint(lat: 44.44, lon: 26.115)
        let b = RouteOrchestrator.beeline(from: from, to: to)
        XCTAssertEqual(b.points.count, 3) // n = clamp(1629/2000 → 0, 2, 200) = 2 segments
        XCTAssertEqual(b.distanceM, GeoMath.haversineM(from, to), accuracy: 1e-9)
        XCTAssertEqual(b.durationSec, b.distanceM / 13.9, accuracy: 1e-9)
        XCTAssertEqual(b.steps.map(\.maneuverType), ["depart", "arrive"])
        XCTAssertEqual(b.steps[0].roadName, "Head toward destination (offline)")
        XCTAssertTrue(b.withLabel("x").isDirectFallback) // "offline" in a step name
        XCTAssertTrue(b.withLabel("Direct").isStraightLine)
        let far = RouteOrchestrator.beeline(from: GeoPoint(lat: 0, lon: 0), to: GeoPoint(lat: 0, lon: 10))
        XCTAssertEqual(far.points.count, 201) // capped at 200 segments
        XCTAssertEqual(far.points[100].lon, 5, accuracy: 1e-12)
    }

    func testFinalizeSingleUsesModeLabel() {
        let rs = [route(10_000, 700), route(10_100, 600)]
        XCTAssertEqual(RouteOrchestrator.finalize(rs, mode: .fun, forceLabel: nil, wantAlts: false, approxKm: 100).map(\.label), ["Fun"])
        XCTAssertEqual(RouteOrchestrator.finalize(rs, mode: .fast, forceLabel: "Circuit", wantAlts: false, approxKm: 100).map(\.label), ["Circuit"])
        XCTAssertEqual(RouteOrchestrator.finalize([], mode: .fast, forceLabel: nil, wantAlts: false, approxKm: 100), [])
        XCTAssertEqual(RouteOrchestrator.finalizeAvoid(rs, forceLabel: nil, wantAlts: false, approxKm: 10, mode: .fun).map(\.durationSec), [700])
    }
}
