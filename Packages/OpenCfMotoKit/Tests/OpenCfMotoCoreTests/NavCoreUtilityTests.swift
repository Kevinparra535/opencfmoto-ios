// SPDX-License-Identifier: AGPL-3.0-or-later
// Low-level helpers of the navigation core: Java-compatible number formatting, org.json-style
// JSON access, geometry helpers, compass smoothing, and a concurrency stress test of the session.

import XCTest
@testable import OpenCfMotoCore

final class NavCoreUtilityTests: XCTestCase {
    func testFixedHalfUpOnShortestRepresentation() {
        XCTAssertEqual(NavNumberFormat.fixed(12.5, decimals: 0), "13")      // C printf: "12"
        XCTAssertEqual(NavNumberFormat.fixed(0.15, decimals: 1), "0.2")     // binary 0.1499… but shortest "0.15"
        XCTAssertEqual(NavNumberFormat.fixed(1.005, decimals: 2), "1.01")
        XCTAssertEqual(NavNumberFormat.fixed(0.125, decimals: 2), "0.13")
        XCTAssertEqual(NavNumberFormat.fixed(9.96, decimals: 1), "10.0")
        XCTAssertEqual(NavNumberFormat.fixed(999.5, decimals: 0), "1000")
        XCTAssertEqual(NavNumberFormat.fixed(0.05, decimals: 1), "0.1")
        XCTAssertEqual(NavNumberFormat.fixed(0.04, decimals: 1), "0.0")
        XCTAssertEqual(NavNumberFormat.fixed(1e-7, decimals: 3), "0.000")
        XCTAssertEqual(NavNumberFormat.fixed(5e-324, decimals: 2), "0.00")
        XCTAssertEqual(NavNumberFormat.fixed(1e20, decimals: 1), "100000000000000000000.0")
        XCTAssertEqual(NavNumberFormat.fixed(123456.0, decimals: 0), "123456")
        XCTAssertEqual(NavNumberFormat.fixed(-2.5, decimals: 0), "-3")       // HALF_UP is away from zero on magnitude
        XCTAssertEqual(NavNumberFormat.fixed(-0.04, decimals: 1), "-0.0")
        XCTAssertEqual(NavNumberFormat.fixed(44.4268, decimals: 6), "44.426800")
        XCTAssertEqual(NavNumberFormat.fixed(1.25, decimals: 1, decimalSeparator: ","), "1,3")
        XCTAssertEqual(NavNumberFormat.fixed(.nan, decimals: 1), "NaN")
        XCTAssertEqual(NavNumberFormat.fixed(-.infinity, decimals: 1), "-Infinity")
    }

    func testJavaDoubleToString() {
        XCTAssertEqual(NavNumberFormat.javaString(45), "45.0")
        XCTAssertEqual(NavNumberFormat.javaString(26.1025), "26.1025")
        XCTAssertEqual(NavNumberFormat.javaString(0.001), "0.001")
        XCTAssertEqual(NavNumberFormat.javaString(0.0001), "1.0E-4")
        XCTAssertEqual(NavNumberFormat.javaString(-0.00002), "-2.0E-5")
        XCTAssertEqual(NavNumberFormat.javaString(1.2345e-5), "1.2345E-5")
        XCTAssertEqual(NavNumberFormat.javaString(9_999_999.5), "9999999.5")
        XCTAssertEqual(NavNumberFormat.javaString(1e7), "1.0E7")
        XCTAssertEqual(NavNumberFormat.javaString(123_456_789), "1.23456789E8")
        XCTAssertEqual(NavNumberFormat.javaString(0), "0.0")
        XCTAssertEqual(NavNumberFormat.javaString(-0.0), "-0.0")
        XCTAssertEqual(NavNumberFormat.javaString(26.1025 - 1.6), "24.502499999999998")
    }

    func testKotlinRounding() {
        XCTAssertEqual(NavNumberFormat.roundHalfUp(2.5), 3)
        XCTAssertEqual(NavNumberFormat.roundHalfUp(-2.5), -2)          // ties toward +∞
        XCTAssertEqual(NavNumberFormat.roundHalfUp(0.49999999999999994), 0)
        XCTAssertEqual(NavNumberFormat.roundHalfUp(-0.5), 0)
        XCTAssertEqual(NavNumberFormat.roundHalfUp(.nan), 0)
        XCTAssertEqual(NavNumberFormat.truncateToInt(-2.9), -2)
        XCTAssertEqual(NavNumberFormat.truncateToInt(1e300), Int.max)
        XCTAssertEqual(NavNumberFormat.padded(5, width: 2), "05")
        XCTAssertEqual(NavNumberFormat.padded(-5, width: 3), "-005")
    }

    func testNavJSONOrgJsonSemantics() throws {
        let j = try NavJSON.parse(Data(#"{"b":true,"i":1,"z":0,"d":1.5,"s":"2.5","t":"TRUE","n":null,"a":[1,"x",null],"big":12345678901234}"#.utf8))
        XCTAssertTrue(j["b"].bool(false))
        XCTAssertFalse(j["i"].bool(false))             // a number is not a boolean in org.json
        XCTAssertEqual(j["i"].int(9), 1)
        XCTAssertEqual(j["b"].int(9), 9)               // a boolean is not a number
        XCTAssertEqual(j["s"].double(0), 2.5)          // numeric strings coerce
        XCTAssertEqual(j["s"].int(0), 2)
        XCTAssertTrue(j["t"].bool(false))
        XCTAssertEqual(j["d"].string(), "1.5")
        XCTAssertEqual(j["i"].string(), "1")
        XCTAssertEqual(j["b"].string(), "true")
        XCTAssertEqual(j["big"].string(), "12345678901234")
        XCTAssertTrue(j["n"].isNull)
        XCTAssertFalse(j.has("n"))
        XCTAssertEqual(j["missing"].string("fb"), "fb")
        XCTAssertEqual(j["a"].count, 3)
        XCTAssertTrue(j["a"][2].isNull)
        XCTAssertEqual(j["a"][1].string(), "x")
        XCTAssertTrue(j["a"][9].isNull)
        XCTAssertThrowsError(try NavJSON.parse(Data("{".utf8)))
    }

    func testGeometryHelpers() {
        let p = GeoMath.projectOntoSegment(lat: 0.004, lon: 0.0003, aLat: 0, aLon: 0, bLat: 0.01, bLon: 0)
        XCTAssertEqual(p.t, 0.4, accuracy: 1e-12)
        XCTAssertEqual(p.distanceM, 33.396, accuracy: 1e-3)
        XCTAssertEqual(p.segmentLengthM, 1113.2, accuracy: 1e-9)
        XCTAssertEqual(p.lat, 0.004, accuracy: 1e-15)
        let degenerate = GeoMath.projectOntoSegment(lat: 1, lon: 1, aLat: 0, aLon: 0, bLat: 0, bLon: 0)
        XCTAssertEqual(degenerate.t, 0)
        let pts = [TrackPoint(lat: 0, lon: 0), TrackPoint(lat: 0.01, lon: 0), TrackPoint(lat: 0.02, lon: 0)]
        let cum = GeoMath.cumulativeDistances(pts)
        XCTAssertEqual(cum[0], 0)
        XCTAssertEqual(cum[2], 2223.8985, accuracy: 1e-3)
        XCTAssertEqual(GeoMath.pathLength([]), 0)
        XCTAssertEqual(GeoMath.normalizeDelta(540), 180)
        XCTAssertEqual(GeoMath.normalizeDelta(-190), 170)
        XCTAssertEqual(GeoMath.normalizeDeltaF(181), -179)
        let d = GeoMath.destinationPoint(lat: 45, lon: 25, distanceKm: 10, bearingDeg: 90)
        XCTAssertEqual(GeoMath.haversineKm(45, 25, d.lat, d.lon), 10, accuracy: 1e-9)
        XCTAssertEqual(GeoMath.bearingDeg(0, 0, 0, -1), 270, accuracy: 1e-9)
    }

    func testHeadingSmoother() {
        var h = HeadingSmoother()
        XCTAssertNil(h.heading)
        XCTAssertEqual(h.add(350), 350, accuracy: 1e-4)
        // Crossing north smooths through 0, not through 180.
        let v = h.add(10)
        XCTAssertTrue(v > 350 || v < 10, "\(v)")
        for _ in 0 ..< 60 { h.add(10) }
        XCTAssertEqual(h.heading!, 10, accuracy: 0.01)
        h.reset()
        XCTAssertNil(h.heading)
    }

    func testSpanishStatusLine() {
        let es = NavStrings(language: .es, decimalSeparator: ",")
        let p = RouteProgress(nearestIndex: 1, doneM: 0, remainM: 1, offTrackM: 95, snapLat: 0, snapLon: 0,
                              nextWaypoint: TrackPoint(lat: 1, lon: 1, name: nil), nextWaypointM: 1500, gradePct: -3.4)
        XCTAssertEqual(es.hudStatus(avgKmh: 42.4, progress: p, totalM: 12345, units: .metric, showNextStop: true),
                       "Ruta · 12,3 km · FUERA 95 m · -3% · media 42 · → pto 1,5 km")
        XCTAssertEqual(es.freeRideStatus(speedKmh: 36, avgKmh: 0, units: .metric), "36 km/h · ruta libre · media 0")
        XCTAssertEqual(es.toDestinationStatus(speedKmh: 0, distanceM: 1600, name: "X", avgKmh: 0, units: .imperial),
                       "0 mph · 1,0 mi hasta X · media 0")
    }

    func testConcurrentSessionUseIsSafe() async {
        let env = NavSessionEnv(http: NavFakeHTTPClient(NavSessionFlowTests.osrmOnly))
        let s = env.session
        s.updateLocation(env.fix(44.43, 26.10, speed: 0))
        s.navigate(to: NavSessionFlowTests.dest)
        await withTaskGroup(of: Void.self) { group in
            for k in 0 ..< 8 {
                group.addTask {
                    for i in 0 ..< 50 {
                        let lat = 44.43 + Double(i) * 0.0001
                        switch k % 4 {
                        case 0: s.updateLocation(env.fix(lat, 26.10, speed: 10, course: 0))
                        case 1: s.updateHeading(Double(i * 7 % 360))
                        case 2: _ = s.snapshot
                        default: if i % 10 == 0 { s.previewPlace(NavSessionFlowTests.dest) } else { s.selectRoute(i % 3) }
                        }
                    }
                }
            }
        }
        await s.waitUntilIdle()
        let revs = env.rec.snapshots.map(\.revision)
        XCTAssertEqual(revs, revs.sorted())
        XCTAssertEqual(s.snapshot.mode, .navTo(NavSessionFlowTests.dest))
    }
}
