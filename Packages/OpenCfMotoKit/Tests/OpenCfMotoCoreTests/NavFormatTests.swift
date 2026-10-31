// SPDX-License-Identifier: AGPL-3.0-or-later
// Formatting parity with the Kotlin implementation (golden_format.json generated from the upstream
// GpxNav / OverpassClient / LapTimer code) plus the vectors quoted in docs/spec/navigation-dash.md.

import XCTest
@testable import OpenCfMotoCore

final class NavFormatTests: XCTestCase {
    private lazy var golden = NavGJ(NavFixtures.json("golden_format.json"))

    // MARK: Spec / upstream test vectors

    func testUpstreamFormatKmAndEta() {
        XCTAssertEqual(NavFormat.formatKm(500), "500 m")
        XCTAssertEqual(NavFormat.formatKm(1500), "1.5 km")
        XCTAssertEqual(NavFormat.formatEta(300), "5m")
    }

    func testUpstreamImperialDistanceAndSpeed() {
        XCTAssertEqual(NavFormat.formatDistance(152.4, units: .imperial), "500 ft")
        XCTAssertEqual(NavFormat.formatDistance(1609.344, units: .imperial), "1.0 mi")
        XCTAssertEqual(NavFormat.formatSpeed(kmh: 100, units: .imperial), "62")
        XCTAssertEqual(NavFormat.speedUnitLabel(.imperial), "mph")
        XCTAssertEqual(NavFormat.speedUnitLabel(.metric), "km/h")
    }

    func testUpstreamZoomForSpeed() {
        XCTAssertEqual(NavFormat.zoomForSpeedKmh(10), 17.0, accuracy: 0.01)
        XCTAssertEqual(NavFormat.zoomForSpeedKmh(80), 13.8, accuracy: 0.01)
    }

    func testSpecDistanceEdgeCases() {
        // §4.11 derived vectors (Java HALF_UP; C printf would give "12 m").
        XCTAssertEqual(NavFormat.formatDistance(12.5, units: .metric), "13 m")
        XCTAssertEqual(NavFormat.formatDistance(999.4, units: .metric), "999 m")
        XCTAssertEqual(NavFormat.formatDistance(999.6, units: .metric), "1000 m")
        XCTAssertEqual(NavFormat.formatDistance(1000, units: .metric), "1.0 km")
        XCTAssertEqual(NavFormat.formatDistance(1049, units: .metric), "1.0 km")
        XCTAssertEqual(NavFormat.formatDistance(1050, units: .metric), "1.1 km")
        XCTAssertEqual(NavFormat.formatDistance(12345, units: .metric), "12.3 km")
        XCTAssertEqual(NavFormat.formatDistance(160.9, units: .imperial), "528 ft")
        XCTAssertEqual(NavFormat.formatDistance(161, units: .imperial), "0.1 mi")
        XCTAssertEqual(NavFormat.formatDistance(499.5, units: .imperial), "0.3 mi")
    }

    func testSpecEtaVectors() {
        let cases: [(Int?, String)] = [(nil, "—"), (0, "0m"), (59, "0m"), (60, "1m"), (3599, "59m"), (3600, "1h00m"),
                                       (3900, "1h05m"), (36000, "10h00m")]
        for (s, t) in cases { XCTAssertEqual(NavFormat.formatEta(s), t) }
    }

    func testSpokenDistanceSpecVectors() {
        XCTAssertEqual(NavFormat.roundedSpokenDistance(10, units: .metric), "50 meters")
        XCTAssertEqual(NavFormat.roundedSpokenDistance(51, units: .metric), "100 meters")
        XCTAssertEqual(NavFormat.roundedSpokenDistance(260, units: .metric), "300 meters")
        XCTAssertEqual(NavFormat.roundedSpokenDistance(650, units: .metric), "700 meters")
        XCTAssertEqual(NavFormat.roundedSpokenDistance(820, units: .metric), "800 meters")
        XCTAssertEqual(NavFormat.roundedSpokenDistance(850, units: .metric), "900 meters")
        XCTAssertEqual(NavFormat.roundedSpokenDistance(950, units: .metric), "1000 meters")
        // The spec's derived "1.2 kilometers" is wrong: Java HALF_UP on 1.25 gives 1.3 (golden).
        XCTAssertEqual(NavFormat.roundedSpokenDistance(1250, units: .metric), "1.3 kilometers")
        XCTAssertEqual(NavFormat.roundedSpokenDistance(50, units: .imperial), "200 feet")
        XCTAssertEqual(NavFormat.roundedSpokenDistance(152.4, units: .imperial), "800 feet")
        XCTAssertEqual(NavFormat.roundedSpokenDistance(260, units: .imperial), "1000 feet")
        XCTAssertEqual(NavFormat.roundedSpokenDistance(322, units: .imperial), "0.2 miles")
    }

    func testSpanishSpokenDistanceAndDecimalComma() {
        XCTAssertEqual(NavFormat.roundedSpokenDistance(260, units: .metric, language: .es), "300 metros")
        XCTAssertEqual(NavFormat.roundedSpokenDistance(1250, units: .metric, language: .es), "1,3 kilómetros")
        XCTAssertEqual(NavFormat.roundedSpokenDistance(50, units: .imperial, language: .es), "200 pies")
        XCTAssertEqual(NavFormat.roundedSpokenDistance(322, units: .imperial, language: .es), "0,2 millas")
        XCTAssertEqual(NavFormat.formatDistance(1500, units: .metric, decimalSeparator: ","), "1,5 km")
        XCTAssertEqual(NavFormat.formatDistance(500, units: .metric, decimalSeparator: ","), "500 m")
    }

    func testArrivalClock() {
        let tz = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_700_000_000) // 22:13:20 UTC
        XCTAssertEqual(NavFormat.formatArrival(nil, now: now, timeZone: tz), "—")
        XCTAssertEqual(NavFormat.formatArrival(0, now: now, timeZone: tz), "22:13")
        XCTAssertEqual(NavFormat.formatArrival(3600, now: now, timeZone: tz), "23:13")
        XCTAssertEqual(NavFormat.formatArrival(7200, now: now, timeZone: tz), "00:13")
        // Capped at 48 h.
        XCTAssertEqual(NavFormat.formatArrival(10 * 86400 + 600, now: now, timeZone: tz), "22:13")
        let bucharest = TimeZone(identifier: "Europe/Bucharest")!
        XCTAssertEqual(NavFormat.formatArrival(0, now: now, timeZone: bucharest), "00:13")
    }

    func testFollowZoomBikeOffset() {
        XCTAssertEqual(NavFormat.followZoom(speedKmh: 5), 18.6, accuracy: 1e-9)
        XCTAssertEqual(NavFormat.followZoom(speedKmh: 10), 18.1, accuracy: 1e-9)
        XCTAssertEqual(NavFormat.followZoom(speedKmh: 30), 17.3, accuracy: 1e-9)
        XCTAssertEqual(NavFormat.followZoom(speedKmh: 40), 16.5, accuracy: 1e-9)
        XCTAssertEqual(NavFormat.followZoom(speedKmh: 70), 15.7, accuracy: 1e-9)
        XCTAssertEqual(NavFormat.followZoom(speedKmh: 100), 14.9, accuracy: 1e-9)
        XCTAssertEqual(NavFormat.followZoom(speedKmh: 130), 14.1, accuracy: 1e-9)
        XCTAssertEqual(NavFormat.followZoom(speedKmh: 130, projected: false), 13.0, accuracy: 1e-9)
    }

    func testSpeedKmhUsesFloatMaths() {
        XCTAssertEqual(NavFormat.speedKmh(fromMps: 10), Double(Float(10) * Float(3.6)))
        XCTAssertEqual(NavFormat.speedKmh(fromMps: nil), 0)
    }

    // MARK: Golden (Kotlin) vectors

    func testGoldenDistances() {
        let rows = golden["distance"].array
        XCTAssertGreaterThan(rows.count, 30)
        for r in rows {
            XCTAssertEqual(NavFormat.formatDistance(r["m"].d, units: .metric), r["metric"].string, "metric \(r["m"].d)")
            XCTAssertEqual(NavFormat.formatDistance(r["m"].d, units: .imperial), r["imperial"].string, "imperial \(r["m"].d)")
        }
    }

    func testGoldenEta() {
        for r in golden["eta"].array { XCTAssertEqual(NavFormat.formatEta(r["s"].int), r["t"].string) }
    }

    func testGoldenSpeed() {
        for r in golden["speed"].array {
            let kmh = r["kmh"].d
            XCTAssertEqual(NavFormat.formatSpeed(kmh: kmh, units: .metric), r["metric"].string, "\(kmh)")
            XCTAssertEqual(NavFormat.formatSpeed(kmh: kmh, units: .imperial), r["imperial"].string, "\(kmh)")
        }
    }

    func testGoldenAltitudeAndAscent() {
        for r in golden["altitude"].array {
            let m = r["m"].d
            XCTAssertEqual(NavFormat.formatAltitude(m, units: .metric), r["metric"].string, "\(m)")
            XCTAssertEqual(NavFormat.formatAltitude(m, units: .imperial), r["imperial"].string, "\(m)")
            XCTAssertEqual(NavFormat.formatAscent(m, units: .metric), r["ascentMetric"].string)
            XCTAssertEqual(NavFormat.formatAscent(m, units: .imperial), r["ascentImperial"].string)
        }
    }

    func testGoldenSpokenDistances() {
        for r in golden["spoken"].array {
            let m = r["m"].d
            XCTAssertEqual(NavFormat.roundedSpokenDistance(m, units: .metric), r["metric"].string, "\(m)")
            XCTAssertEqual(NavFormat.roundedSpokenDistance(m, units: .imperial), r["imperial"].string, "\(m)")
        }
    }

    func testGoldenZoom() {
        for r in golden["zoom"].array { XCTAssertEqual(NavFormat.zoomForSpeedKmh(r["kmh"].d), r["z"].d, "\(r["kmh"].d)") }
    }

    func testGoldenEtaSeconds() {
        for r in golden["etaSeconds"].array {
            XCTAssertEqual(NavFormat.etaSeconds(remainM: r["remain"].d, speedMps: r["speed"].d), r["eta"].int,
                           "remain \(r["remain"].d) speed \(r["speed"].d)")
        }
    }

    func testGoldenDirToFace() {
        let rows = golden["dirToFace"].array
        XCTAssertEqual(rows.count, 18)
        for r in rows {
            XCTAssertEqual(RouteFollower.dirToFace(headingDeg: r["h"].d, targetBearingDeg: r["t"].d).rawValue, r["dir"].string,
                           "\(r["h"].d) → \(r["t"].d)")
        }
    }

    func testGoldenGeometry() {
        for r in golden["geo"].array {
            let a = r["a"].array.map(\.d)
            navAssertClose(GeoMath.haversineM(a[0], a[1], a[2], a[3]), r["haversineM"].d, 1e-12)
            XCTAssertEqual(Double(GeoMath.bearingDegF(a[0], a[1], a[2], a[3])), r["bearingF"].d, accuracy: 1e-4)
            navAssertClose(GeoMath.bearingDeg(a[0], a[1], a[2], a[3]), r["bearingD"].d, 1e-12)
            navAssertClose(GeoMath.haversineKm(a[0], a[1], a[2], a[3]), r["haversineKm"].d, 1e-12)
            navAssertClose(GeoMath.approxMetres(a[0], a[1], a[2], a[3]), r["approxMetres"].d, 1e-12)
            navAssertClose(LapTimer.meters(a[0], a[1], a[2], a[3]), r["lapMeters"].d, 1e-12)
        }
    }

    func testGoldenInstructionTable() {
        let rows = golden["instruction"].array
        XCTAssertGreaterThan(rows.count, 300)
        for r in rows {
            let type = r["type"].string!
            let mod = r["modifier"].string
            let road = r["road"].string
            let exit = r["exit"].int
            XCTAssertEqual(RouteFollower.dirFor(type: type, modifier: mod).rawValue, r["dir"].string, "\(type)/\(String(describing: mod))")
            let expected = r["text"].string!
            XCTAssertEqual(RouteFollower.instruction(type: type, modifier: mod, road: road, exit: exit), expected,
                           "\(type)/\(String(describing: mod))/\(String(describing: road))/\(String(describing: exit))")
        }
    }

    func testSpecInstructionExamples() {
        XCTAssertEqual(RouteFollower.instruction(type: "turn", modifier: "right", road: "Main St", exit: nil), "turn right onto Main St")
        XCTAssertEqual(RouteFollower.instruction(type: "roundabout", modifier: nil, road: "DN1", exit: 2), "at the roundabout take exit 2 onto DN1")
        XCTAssertEqual(RouteFollower.instruction(type: "fork", modifier: "slight left", road: nil, exit: nil), "keep left")
        XCTAssertEqual(RouteFollower.instruction(type: "turn", modifier: "slight left", road: nil, exit: nil), "turn slight left")
    }

    func testGoldenArrowsAndJoinWords() {
        for d in TurnDir.allCases {
            XCTAssertEqual(RouteFollower.arrowFor(d), golden["arrows"][d.rawValue].string, d.rawValue)
            XCTAssertEqual(RouteFollower.joinRouteWord(d), golden["join"][d.rawValue]["word"].string, d.rawValue)
            XCTAssertEqual(RouteFollower.joinRouteSpeak(d), golden["join"][d.rawValue]["speak"].string, d.rawValue)
        }
    }

    func testGoldenLaneLabels() {
        for r in golden["lanes"].array {
            let lanes: [Lane]? = r["lanes"].isNull ? nil : r["lanes"].array.map {
                Lane(valid: $0["valid"].bool ?? false, indications: $0["indications"].array.compactMap(\.string))
            }
            XCTAssertEqual(RouteFollower.laneLabel(lanes), r["label"].string)
        }
        // Spec example.
        XCTAssertEqual(RouteFollower.laneLabel([Lane(valid: false, indications: ["left"]), Lane(valid: true, indications: ["straight"]),
                                                Lane(valid: true, indications: ["straight", "right"])]), "↑ ↑")
    }

    func testGoldenMaxspeedAndLimits() {
        for r in golden["maxspeed"].array {
            XCTAssertEqual(SpeedLimitParsing.parseMaxspeedKmh(r["raw"].string!), r["kmh"].int, "raw '\(r["raw"].string!)'")
        }
        for r in golden["limit"].array {
            let k = r["kmh"].int
            let l = SpeedLimit(kmh: k, label: k.map(String.init) ?? "—")
            XCTAssertEqual(NavFormat.formatLimit(l, units: .metric), r["metric"].string)
            XCTAssertEqual(NavFormat.formatLimit(l, units: .imperial), r["imperial"].string)
        }
    }

    func testUpstreamOverpassVectors() {
        XCTAssertEqual(SpeedLimitParsing.parseMaxspeedKmh("50"), 50)
        XCTAssertEqual(SpeedLimitParsing.parseMaxspeedKmh("50 km/h"), 50)
        XCTAssertEqual(SpeedLimitParsing.parseMaxspeedKmh("50 mph"), 80)
        XCTAssertNil(SpeedLimitParsing.parseMaxspeedKmh("none"))
        XCTAssertEqual(NavFormat.formatLimit(SpeedLimit(kmh: 100, label: "100"), units: .metric), "100")
        XCTAssertEqual(NavFormat.formatLimit(SpeedLimit(kmh: 100, label: "100"), units: .imperial), "62")
    }

    func testNativeMphKeptInImperial() {
        let raw = SpeedLimit(kmh: SpeedLimitParsing.parseMaxspeedKmh("50 mph"), label: "50 mph")
        // Android pitfall: toInt(toInt(50·1.60934)·0.621371) = 49.
        XCTAssertEqual(NavFormat.formatLimit(raw, units: .imperial, keepNativeUnit: false), "49")
        XCTAssertEqual(NavFormat.formatLimit(raw, units: .imperial, keepNativeUnit: true), "50")
        XCTAssertEqual(NavFormat.formatLimit(raw, units: .metric, keepNativeUnit: true), "80")
    }

    func testGoldenHudStatusLine() {
        let rows = golden["hud"].array
        XCTAssertEqual(rows.count, 20)
        for r in rows {
            let p = r["progress"]
            var wp: TrackPoint?
            if r["hasWp"].bool == true { wp = TrackPoint(lat: 1, lon: 1, name: r["wpName"].string) }
            let prog = RouteProgress(nearestIndex: 1, doneM: 100, remainM: 900, offTrackM: p["offTrackM"].d, snapLat: 0, snapLon: 0,
                                     nextWaypoint: wp, nextWaypointM: p["nextWaypointM"].double, gradePct: p["gradePct"].double, etaSec: 60)
            let units: MapUnits = r["units"].string == "IMPERIAL" ? .imperial : .metric
            XCTAssertEqual(NavStrings.english.hudStatus(avgKmh: r["avg"].d, progress: prog, totalM: r["total"].d, units: units,
                                                        showNextStop: r["showNextStop"].bool ?? true), r["text"].string)
        }
        XCTAssertEqual(NavStrings.english.hudStatus(avgKmh: 0, progress: nil, totalM: 100, units: .metric, showNextStop: true), "")
    }

    func testGoldenLapFormat() {
        for r in golden["lapFormat"].array { XCTAssertEqual(LapTimer.formatMs(Int64(r["ms"].int!)), r["t"].string) }
    }
}
