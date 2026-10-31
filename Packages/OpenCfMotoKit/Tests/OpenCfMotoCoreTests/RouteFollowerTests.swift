// SPDX-License-Identifier: AGPL-3.0-or-later
// RouteFollower (GpxNav port): upstream GpxNavTest vectors, spec-derived vectors, Kotlin golden
// progress sequences (parity mode) and the iOS fixes (monotonic steps, via arrivals, snapped
// distances).

import XCTest
@testable import OpenCfMotoCore

final class RouteFollowerTests: XCTestCase {
    private func track(_ coords: [(Double, Double)], ele: [Double?]? = nil, waypoints: [TrackPoint] = []) -> GpxTrack {
        GpxTrack(name: "t", points: coords.enumerated().map { i, c in TrackPoint(lat: c.0, lon: c.1, ele: ele?[i]) }, waypoints: waypoints)
    }

    private var straight: GpxTrack { track([(0, 0), (0.01, 0), (0.02, 0)]) }

    private var corner: GpxTrack {
        var pts: [(Double, Double)] = []
        for i in 0 ... 20 { pts.append((Double(i) * 0.001, 0)) }
        for i in 1 ... 20 { pts.append((0.02, Double(i) * 0.001)) }
        return track(pts)
    }

    // MARK: Upstream GpxNavTest

    func testTotalAndProgressAlongStraightTrack() {
        var nav = RouteFollower(track: straight, parityMode: true)
        XCTAssertTrue((2200.0 ... 2300.0).contains(nav.totalM))
        XCTAssertEqual(nav.totalM, 2223.8985, accuracy: 1e-3)
        let mid = nav.progress(lat: 0.01, lon: 0, speedMps: 10)!
        XCTAssertEqual(mid.nearestIndex, 1)
        XCTAssertTrue((1100.0 ... 1150.0).contains(mid.doneM))
        XCTAssertTrue((1100.0 ... 1150.0).contains(mid.remainM))
        XCTAssertEqual(mid.remainM, 1111.9493, accuracy: 1e-3)
        XCTAssertLessThan(mid.offTrackM, 5)
        XCTAssertEqual(mid.etaSec, 111)
    }

    func testEtaUsesAssumedCruiseWhenStopped() {
        var nav = RouteFollower(track: track([(0, 0), (0.01, 0)]), parityMode: true)
        let eta = nav.progress(lat: 0, lon: 0, speedMps: 0)!.etaSec
        XCTAssertEqual(eta, 80) // 1111.95 / 13.889
        XCTAssertGreaterThan(eta!, 60)
    }

    func testElevationAscentAndGrade() {
        var nav = RouteFollower(track: track([(0, 0), (0.001, 0), (0.002, 0)], ele: [100, 110, 130]), parityMode: true)
        XCTAssertTrue(nav.hasElevation)
        XCTAssertEqual(nav.totalAscentM, 30, accuracy: 1e-9)
        let p = nav.progress(lat: 0, lon: 0)!
        XCTAssertEqual(p.remainAscentM!, 30, accuracy: 1e-9)
        XCTAssertGreaterThan(p.gradePct!, 0)
        XCTAssertEqual(p.gradePct!, 13.4898, accuracy: 1e-3)
    }

    func testDetectsRightTurnAhead() {
        let nav = RouteFollower(track: corner, parityMode: true)
        let turn = nav.upcomingTurn(fromIndex: 0, lookAheadM: 5000, minTurnDeg: 35)!
        XCTAssertEqual(turn.dir, .right)
        XCTAssertEqual(turn.index, 20)
        XCTAssertEqual(turn.distanceFromRiderM, 2223.90, accuracy: 0.01)
        XCTAssertEqual(turn.speak, "In 2.2 km, turn right")
        XCTAssertEqual(turn.shortLabel, "Right → · 2.2 km")
        XCTAssertEqual(turn.instr, "turn right")
        XCTAssertNil(turn.roadName)
        XCTAssertNil(turn.laneLabel)
    }

    func testDirToFaceUsesCompassRelativeToTarget() {
        XCTAssertEqual(RouteFollower.dirToFace(headingDeg: 0, targetBearingDeg: 90), .right)
        XCTAssertEqual(RouteFollower.dirToFace(headingDeg: 0, targetBearingDeg: 270), .left)
        XCTAssertEqual(RouteFollower.dirToFace(headingDeg: 45, targetBearingDeg: 50), .straight)
        XCTAssertEqual(RouteFollower.dirToFace(headingDeg: 0, targetBearingDeg: 180), .uturn)
    }

    func testOrientsTrackOppositeWhenHeadingIsReverse() {
        let (oriented, flipped) = straight.orientedForRider(lat: 0.02, lon: 0, headingDeg: 180)
        XCTAssertTrue(flipped)
        XCTAssertEqual(oriented.points.first!.lat, 0.02, accuracy: 1e-9)
        XCTAssertEqual(oriented.points.last!.lat, 0.0, accuracy: 1e-9)
    }

    func testProgressDoesNotHopBackwardOnNearbyReturnLeg() {
        var nav = RouteFollower(track: track([(0, 0), (0.01, 0), (0.02, 0), (0.01, 0.0002), (0, 0.0002)]), parityMode: true)
        XCTAssertEqual(nav.progress(lat: 0.01, lon: 0, speedMps: 8)!.nearestIndex, 1)
        XCTAssertLessThanOrEqual(nav.progress(lat: 0.01, lon: 0.00005, speedMps: 8)!.nearestIndex, 2)
    }

    // MARK: Spec-derived vectors (§4.11)

    func testSnapVector() {
        var nav = RouteFollower(track: straight, parityMode: true)
        let p = nav.progress(lat: 0.004, lon: 0.0003, speedMps: 0)!
        XCTAssertEqual(p.nearestIndex, 0)
        XCTAssertEqual(p.offTrackM, 33.396, accuracy: 1e-3)
        XCTAssertEqual(p.snapLat, 0.004, accuracy: 1e-12)
        XCTAssertEqual(p.snapLon, 0.0, accuracy: 1e-12)
        XCTAssertEqual(p.doneM, 445.28, accuracy: 0.01)
        XCTAssertEqual(p.remainM, 1778.6185, accuracy: 1e-3)
        XCTAssertEqual(p.etaSec, 128)
        var nav2 = RouteFollower(track: straight, parityMode: true)
        XCTAssertEqual(nav2.progress(lat: 0.004, lon: 0.0003, speedMps: 20)!.etaSec, 89)
    }

    func testEmptyAndSinglePointTracks() {
        var empty = RouteFollower(track: GpxTrack(name: "e", points: []))
        XCTAssertNil(empty.progress(lat: 1, lon: 1))
        XCTAssertEqual(empty.pointsDone(3), [])
        XCTAssertEqual(empty.pointsRemain(0), [])
        var one = RouteFollower(track: track([(1, 1)]))
        let p = one.progress(lat: 1.001, lon: 1)!
        XCTAssertEqual(p.offTrackM, 0)
        XCTAssertEqual(p.snapLat, 1)
        XCTAssertEqual(p.remainM, 0)
        XCTAssertEqual(p.etaSec, 0)
        XCTAssertEqual(p.trackBearingDeg, 0)
    }

    func testPointsDoneAndRemain() {
        let nav = RouteFollower(track: straight)
        XCTAssertEqual(nav.pointsDone(-5).count, 1)
        XCTAssertEqual(nav.pointsDone(1).count, 2)
        XCTAssertEqual(nav.pointsDone(10).count, 3)
        XCTAssertEqual(nav.pointsRemain(1).count, 2)
        XCTAssertEqual(nav.pointsRemain(99).count, 1)
        XCTAssertEqual(nav.pointsRemain(-1).count, 3)
    }

    func testHasElevationThreshold() {
        // n = 5 → needs max(5/2, 2) = 2 elevations.
        let pts: [(Double, Double)] = [(0, 0), (0.001, 0), (0.002, 0), (0.003, 0), (0.004, 0)]
        XCTAssertFalse(RouteFollower(track: track(pts, ele: [1, nil, nil, nil, nil])).hasElevation)
        XCTAssertTrue(RouteFollower(track: track(pts, ele: [1, nil, 3, nil, nil])).hasElevation)
        // Ascent only between consecutive points that both have elevation.
        XCTAssertEqual(RouteFollower(track: track(pts, ele: [1, nil, 3, 10, 5])).totalAscentM, 7)
    }

    func testWaypointAheadAndFallback() {
        let wps = [TrackPoint(lat: 0.0005, lon: 0, name: "Behind"), TrackPoint(lat: 0.015, lon: 0.0001, name: "Ahead")]
        var nav = RouteFollower(track: track([(0, 0), (0.01, 0), (0.02, 0)], waypoints: wps), parityMode: true)
        let p = nav.progress(lat: 0.01, lon: 0)!
        XCTAssertEqual(p.nextWaypoint?.name, "Ahead")
        XCTAssertEqual(p.nextWaypointM!, GeoMath.haversineM(0.01, 0, 0.015, 0.0001), accuracy: 1e-9)
        // Past every waypoint → nearest overall.
        var nav2 = RouteFollower(track: track([(0, 0), (0.01, 0), (0.02, 0)], waypoints: [wps[0]]), parityMode: true)
        XCTAssertEqual(nav2.progress(lat: 0.02, lon: 0)!.nextWaypoint?.name, "Behind")
    }

    // MARK: Golden sequences (Kotlin GpxNav, parity mode)

    func testGoldenProgressSequences() throws {
        let golden = NavGJ(NavFixtures.json("golden_follow.json"))
        let runs = golden["runs"].array
        XCTAssertGreaterThanOrEqual(runs.count, 8)
        // Rebuild the inputs exactly like the Kotlin generator.
        let sample = GpxParser.parse(NavFixtures.data("sample_track.gpx"), fallbackName: "sample")
        let osrmRoutes = try OsrmRouter.parse(NavFixtures.data("osrm_route_alts.json"))
        let ob = track([(0, 0), (0.01, 0), (0.02, 0), (0.01, 0.0002), (0, 0.0002)])
        let hill = track([(0, 0), (0.001, 0), (0.002, 0)], ele: [100, 110, 130])
        var checked = 0
        for run in runs {
            let name = run["name"].string!
            var nav: RouteFollower
            switch name {
            case "straight": nav = RouteFollower(track: straight, parityMode: true)
            case "corner", "corner_imperial": nav = RouteFollower(track: corner, parityMode: true)
            case "outAndBack": nav = RouteFollower(track: ob, parityMode: true)
            case "hill": nav = RouteFollower(track: hill, parityMode: true)
            case "sample": nav = RouteFollower(track: sample, parityMode: true)
            case "osrm0": nav = RouteFollower(route: osrmRoutes[0], name: "route", parityMode: true)
            case "osrm1": nav = RouteFollower(route: osrmRoutes[1], name: "route", parityMode: true)
            default: XCTFail("unknown run \(name)"); continue
            }
            let units: MapUnits = run["units"].string == "IMPERIAL" ? .imperial : .metric
            navAssertClose(nav.totalM, run["totalM"].d, 1e-12, name)
            XCTAssertEqual(nav.hasElevation, run["hasElevation"].bool, name)
            navAssertClose(nav.totalAscentM, run["totalAscentM"].d, 1e-12, name)
            for (i, c) in run["cumDistM"].array.enumerated() { navAssertClose(nav.cumDistM[i], c.d, 1e-12, "\(name) cum[\(i)]") }
            for (k, step) in run["sequence"].array.enumerated() {
                let tag = "\(name)#\(k)"
                let got = nav.progress(lat: step["lat"].d, lon: step["lon"].d, speedMps: step["speed"].d,
                                       gpsAltitudeM: step["alt"].double, units: units)
                let exp = step["progress"]
                guard let p = got else { XCTAssertTrue(exp.isNull, tag); continue }
                XCTAssertEqual(p.nearestIndex, exp["nearestIndex"].int, tag)
                navAssertClose(p.doneM, exp["doneM"].d, 1e-9, tag)
                navAssertClose(p.remainM, exp["remainM"].d, 1e-9, tag)
                navAssertClose(p.offTrackM, exp["offTrackM"].d, 1e-7, tag)
                navAssertClose(p.snapLat, exp["snapLat"].d, 1e-12, tag)
                navAssertClose(p.snapLon, exp["snapLon"].d, 1e-12, tag)
                XCTAssertEqual(p.trackBearingDeg, exp["trackBearingDeg"].d, accuracy: 1e-4, tag)
                // The regex-based Kotlin parser keeps "&amp;" and drops CDATA names; XMLParser decodes both.
                var expWpt = exp["nextWaypoint"].string
                if name == "sample" { expWpt = ["": "Peak", "Fuel &amp; Food": "Fuel & Food"][expWpt ?? "-"] ?? expWpt }
                XCTAssertEqual(p.nextWaypoint?.name ?? (p.nextWaypoint != nil ? "" : nil), expWpt, tag)
                navAssertClose(p.nextWaypointM, exp["nextWaypointM"].double, 1e-9, tag)
                navAssertClose(p.altitudeM, exp["altitudeM"].double, 1e-12, tag)
                navAssertClose(p.remainAscentM, exp["remainAscentM"].double, 1e-9, tag)
                navAssertClose(p.gradePct, exp["gradePct"].double, 1e-9, tag)
                XCTAssertEqual(p.etaSec, exp["etaSec"].int, tag)
                let et = exp["upcomingTurn"]
                if et.isNull {
                    XCTAssertNil(p.upcomingTurn, tag)
                } else if let t = p.upcomingTurn {
                    XCTAssertEqual(t.index, et["index"].int, tag)
                    XCTAssertEqual(t.dir.rawValue, et["dir"].string, tag)
                    navAssertClose(t.distanceAlongM, et["distanceAlongM"].d, 1e-9, tag)
                    navAssertClose(t.distanceFromRiderM, et["distanceFromRiderM"].d, 1e-9, tag)
                    XCTAssertEqual(t.speak, et["speak"].string, tag)
                    XCTAssertEqual(t.shortLabel, et["shortLabel"].string, tag)
                    XCTAssertEqual(t.instr, et["instr"].string, tag)
                    XCTAssertEqual(t.roadName, et["roadName"].string, tag)
                    XCTAssertEqual(t.laneLabel, et["laneLabel"].string, tag)
                } else {
                    XCTFail("missing turn \(tag)")
                }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 200)
    }

    func testGoldenCornerTurnAndOrientation() {
        let golden = NavGJ(NavFixtures.json("golden_follow.json"))
        let t = RouteFollower(track: corner, parityMode: true).upcomingTurn(fromIndex: 0, lookAheadM: 5000, minTurnDeg: 35)!
        XCTAssertEqual(t.speak, golden["cornerTurn"]["speak"].string)
        XCTAssertEqual(t.index, golden["cornerTurn"]["index"].int)
        let three = straight
        let four = track([(0, 0), (0.01, 0), (0.02, 0), (0.03, 0)])
        for r in golden["orient"].array {
            let tr = r["track"].string == "three" ? three : four
            let (o, flipped) = tr.orientedForRider(lat: r["lat"].d, lon: r["lon"].d, headingDeg: r["heading"].double)
            XCTAssertEqual(flipped, r["flipped"].bool, "\(r["track"].string!) \(r["lat"].d) \(String(describing: r["heading"].double))")
            XCTAssertEqual(o.points.first!.lat, r["firstLat"].d)
        }
    }

    func testGoldenRideStats() {
        let golden = NavGJ(NavFixtures.json("golden_follow.json"))
        var rs = RideStats()
        for r in golden["rideStats"].array {
            rs.onLocation(lat: r["lat"].d, lon: r["lon"].d, speedMps: r["speed"].d, nowMs: Int64(r["ms"].int!))
            XCTAssertEqual(rs.avgKmh(), r["avg"].d, accuracy: 1e-4, "at \(r["ms"].int!)")
        }
    }

    // MARK: Road route steps

    private func lRoute() throws -> Route { try OsrmRouter.parse(NavFixtures.data("osrm_route_alts.json"))[0] }

    func testStepCueOnRoadRoute() throws {
        var nav = RouteFollower(route: try lRoute(), parityMode: true)
        let p = nav.progress(lat: 44.4345, lon: 26.10001, speedMps: 10)!
        let t = try XCTUnwrap(p.upcomingTurn)
        XCTAssertEqual(t.dir, .right)
        XCTAssertEqual(t.roadName, "Strada Exemplu")
        XCTAssertEqual(t.instr, "turn right onto Strada Exemplu")
        XCTAssertEqual(t.laneLabel, "↑ ↑")
        XCTAssertTrue(t.speak.hasPrefix("In "))
        XCTAssertTrue(t.shortLabel.hasPrefix("→ Strada Exemplu · "))
        // Never fake geometric turns on a road route: after the last maneuver → nil.
        let end = nav.progress(lat: 44.44, lon: 26.112, speedMps: 10)!
        XCTAssertNil(end.upcomingTurn)
    }

    func testFixedModeMeasuresFromSnappedPosition() throws {
        let route = try lRoute()
        var parity = RouteFollower(route: route, parityMode: true)
        var fixed = RouteFollower(route: route, parityMode: false)
        // 30 m past vertex 5 (lat 44.435) heading north; the turn is at vertex 10 (44.44).
        let lat = 44.435 + 30.0 / 111_195.0
        let a = parity.progress(lat: lat, lon: 26.1, speedMps: 10)!
        let b = fixed.progress(lat: lat, lon: 26.1, speedMps: 10)!
        XCTAssertEqual(a.nearestIndex, b.nearestIndex)
        let fromVertex = route.points.count > 10 ? a.upcomingTurn!.distanceFromRiderM : 0
        XCTAssertEqual(b.upcomingTurn!.distanceFromRiderM, fromVertex - 30, accuracy: 0.5)
        XCTAssertEqual(b.upcomingTurn!.distanceFromRiderM, b.upcomingTurn!.distanceAlongM - b.doneM, accuracy: 1e-9)
    }

    /// Circuit start → dest → start through the same streets (two legs, an arrive/depart pair at the
    /// via). Android shows no cue before the via and snaps return-leg maneuvers onto the outbound leg.
    private func outAndBackRoute() -> Route {
        var pts: [TrackPoint] = []
        for i in 0 ... 10 { pts.append(TrackPoint(lat: 44.43 + Double(i) * 0.001, lon: 26.10)) }
        for i in 1 ... 10 { pts.append(TrackPoint(lat: 44.44, lon: 26.10 + Double(i) * 0.0015)) }
        let back = Array(pts.reversed().dropFirst())
        let all = pts + back
        let steps = [
            RouteStep(maneuverType: "depart", maneuverLat: 44.43, maneuverLon: 26.10, distanceM: 1112),
            RouteStep(maneuverType: "turn", modifier: "right", roadName: "Strada Exemplu", maneuverLat: 44.44, maneuverLon: 26.10, distanceM: 1191),
            RouteStep(maneuverType: "arrive", maneuverLat: 44.44, maneuverLon: 26.115),
            RouteStep(maneuverType: "depart", modifier: "uturn", maneuverLat: 44.44, maneuverLon: 26.115, distanceM: 1191),
            RouteStep(maneuverType: "turn", modifier: "left", roadName: "Bulevardul Test", maneuverLat: 44.44, maneuverLon: 26.10, distanceM: 1112),
            RouteStep(maneuverType: "arrive", maneuverLat: 44.43, maneuverLon: 26.10),
        ]
        return Route(points: all, distanceM: GeoMath.pathLength(all), durationSec: 500, steps: steps, label: "Circuit")
    }

    /// Rider path: outbound to the turnaround, then back along the same street to `returnTo`.
    private func ridePath(returnTo: Double = 26.105) -> [(Double, Double)] {
        var path: [(Double, Double)] = []
        var lat = 44.43
        while lat < 44.44 { path.append((lat, 26.10)); lat += 0.0004 }
        var lon = 26.10
        while lon < 26.115 { path.append((44.44, lon)); lon += 0.0005 }
        lon = 26.115
        while lon > returnTo - 1e-9 { path.append((44.44, lon)); lon -= 0.0005 }
        return path
    }

    func testParityModePinsCursorAtTurnaroundAndLosesReturnLegCues() {
        let route = outAndBackRoute()
        var parity = RouteFollower(route: route, parityMode: true)
        // Global snapping maps the return-leg "turn left" onto the outbound corner (index 10).
        XCTAssertEqual(parity.stepIndex[4], 10)
        var last: RouteProgress?
        for (lat, lon) in ridePath() { last = parity.progress(lat: lat, lon: lon, speedMps: 10) }
        // Android: the coincident outbound vertices win every tie and the 40 m backward-hop rule
        // keeps the cursor at the turnaround (index 20) — 6 vertices (~700 m) into the return leg
        // the remaining distance is still frozen and no cue shows. (It only recovers once the
        // outbound twins drop out of the cursor−8 search window.)
        XCTAssertEqual(last?.nearestIndex, 20)
        XCTAssertNil(last?.upcomingTurn)
        var recovered = parity
        let p = recovered.progress(lat: 44.44, lon: 26.1015, speedMps: 10)!
        XCTAssertEqual(p.nearestIndex, 29)
    }

    func testFixedModeFollowsReturnLeg() {
        var fixed = RouteFollower(route: outAndBackRoute(), parityMode: false)
        var last: RouteProgress?
        var sawReturnTurn = false
        for (lat, lon) in ridePath() {
            last = fixed.progress(lat: lat, lon: lon, speedMps: 10)
            if last?.upcomingTurn?.instr == "turn left onto Bulevardul Test" && (last?.nearestIndex ?? 0) > 20 { sawReturnTurn = true }
        }
        // lon 26.105 is nearest the return-leg twin of vertex 13 (26.1045) → index 27.
        XCTAssertEqual(last!.nearestIndex, 27)
        XCTAssertTrue(sawReturnTurn)
        XCTAssertEqual(last!.upcomingTurn?.instr, "turn left onto Bulevardul Test")
        // 0.005° of longitude back to the corner + the 1 112 m north leg.
        XCTAssertEqual(last!.remainM, 1112 + 0.005 * 111_195 * cos(44.44 * .pi / 180), accuracy: 2)
    }

    func testFixedModeKeepsReturnLegCuesAndSkipsViaArrival() {
        let route = outAndBackRoute()
        var fixed = RouteFollower(route: route, parityMode: false)
        XCTAssertEqual(fixed.stepIndex, [0, 10, 20, 20, 30, 40])
        // Before the via: the intermediate arrive is skipped… there is no further maneuver until the
        // return turn, which lies after the via → the cue is the return-leg turn.
        let before = fixed.progress(lat: 44.44, lon: 26.111, speedMps: 10)!
        XCTAssertEqual(before.upcomingTurn?.dir, .left)
        XCTAssertEqual(before.upcomingTurn?.index, 30)
        // At the via and on the return leg: "turn left onto Bulevardul Test".
        _ = fixed.progress(lat: 44.44, lon: 26.115, speedMps: 10)
        let after = fixed.progress(lat: 44.44, lon: 26.1135, speedMps: 10)!
        XCTAssertGreaterThan(after.nearestIndex, 20)
        XCTAssertEqual(after.upcomingTurn?.instr, "turn left onto Bulevardul Test")
        // Android (parity) hides every cue while approaching the via.
        var parity = RouteFollower(route: route, parityMode: true)
        _ = parity.progress(lat: 44.435, lon: 26.10, speedMps: 10)
        XCTAssertNil(parity.progress(lat: 44.44, lon: 26.111, speedMps: 10)!.upcomingTurn)
    }

    func testFinalArriveWithinTwentyFiveMetresIsNotACue() {
        var fixed = RouteFollower(route: outAndBackRoute(), parityMode: false)
        var last: RouteProgress?
        for (lat, lon) in ridePath(returnTo: 26.10) { last = fixed.progress(lat: lat, lon: lon, speedMps: 10) }
        var lat = 44.4395
        while lat > 44.4302 { _ = fixed.progress(lat: lat, lon: 26.10, speedMps: 10); lat -= 0.0005 }
        let p = fixed.progress(lat: 44.4302, lon: 26.10, speedMps: 10)!
        XCTAssertGreaterThan(p.nearestIndex, last!.nearestIndex)
        XCTAssertNil(p.upcomingTurn)
        XCTAssertLessThan(p.remainM, 25)
    }

    func testSpanishCueTexts() throws {
        var nav = RouteFollower(route: try lRoute(), parityMode: false, strings: NavStrings(language: .es, decimalSeparator: ","))
        let t = try XCTUnwrap(nav.progress(lat: 44.4345, lon: 26.10001, speedMps: 10)!.upcomingTurn)
        XCTAssertEqual(t.instr, "gira a la derecha hacia Strada Exemplu")
        XCTAssertTrue(t.speak.hasPrefix("En "), t.speak)
        var gpx = RouteFollower(track: corner, strings: NavStrings(language: .es, decimalSeparator: ","))
        let g = try XCTUnwrap(gpx.progress(lat: 0.0195, lon: 0, speedMps: 10)!.upcomingTurn)
        XCTAssertEqual(g.instr, "gira a la derecha")
        XCTAssertEqual(g.speak, "En 56 m, gira a la derecha")
        XCTAssertEqual(g.shortLabel, "Der. → · 56 m")
    }

    func testAsRouteAndBearingAt() {
        let nav = RouteFollower(track: corner)
        let r = nav.asRoute()
        XCTAssertEqual(r.label, "GPX")
        XCTAssertEqual(r.points.count, 41)
        XCTAssertEqual(r.distanceM, nav.totalM)
        XCTAssertEqual(nav.bearingAt(0), 0, accuracy: 1e-6)
        XCTAssertEqual(nav.bearingAt(25), 90, accuracy: 0.01)
        XCTAssertEqual(nav.bearingAt(999), nav.bearingAt(39))
    }
}
