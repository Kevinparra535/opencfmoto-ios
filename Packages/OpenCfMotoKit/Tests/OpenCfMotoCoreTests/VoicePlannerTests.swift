// SPDX-License-Identifier: AGPL-3.0-or-later
// VoicePlanner (GpxVoice port): heads-up / execute distances, phrases, waypoint and join-route cues.

import XCTest
@testable import OpenCfMotoCore

final class VoicePlannerTests: XCTestCase {
    private func progress(turnAt d: Double, index: Int = 7, instr: String = "turn right onto Main St", dir: TurnDir = .right,
                          offTrack: Double = 0, waypoint: TrackPoint? = nil, waypointM: Double? = nil) -> RouteProgress {
        let cue = TurnCue(index: index, distanceAlongM: 1000, distanceFromRiderM: d, dir: dir, speak: "", shortLabel: "", instr: instr)
        return RouteProgress(nearestIndex: 1, doneM: 0, remainM: 2000, offTrackM: offTrack, snapLat: 0, snapLon: 0,
                             nextWaypoint: waypoint, nextWaypointM: waypointM, upcomingTurn: cue)
    }

    func testDistanceTableFromSpec() {
        // speed (km/h) → prepare / execute (§5.1 table).
        let rows: [(Double, Double, Double)] = [(0, 150, 25), (38.5, 150, 25), (50, 194.4, 25), (80, 311.1, 35.6), (100, 388.9, 44.4), (130, 505.6, 57.8)]
        for (kmh, prep, exec) in rows {
            XCTAssertEqual(VoicePlanner.prepareDistanceM(speedMps: kmh / 3.6), prep, accuracy: 0.1, "\(kmh)")
            XCTAssertEqual(VoicePlanner.executeDistanceM(speedMps: kmh / 3.6), exec, accuracy: 0.1, "\(kmh)")
        }
        XCTAssertEqual(VoicePlanner.prepareDistanceM(speedMps: 100), 700)
        XCTAssertEqual(VoicePlanner.executeDistanceM(speedMps: 100), 60)
    }

    func testHeadsUpThenExecuteOncePerManeuver() {
        var v = VoicePlanner()
        XCTAssertEqual(v.onProgress(progress(turnAt: 400), units: .metric, speedMps: 10), []) // beyond 150 m
        XCTAssertEqual(v.onProgress(progress(turnAt: 149), units: .metric, speedMps: 10), ["In 150 meters, turn right onto Main St"])
        XCTAssertEqual(v.onProgress(progress(turnAt: 120), units: .metric, speedMps: 10), [])
        XCTAssertEqual(v.onProgress(progress(turnAt: 24), units: .metric, speedMps: 10), ["Turn right onto Main St"])
        XCTAssertEqual(v.onProgress(progress(turnAt: 5), units: .metric, speedMps: 10), [])
        // Next maneuver: the execute phase alone (heads-up skipped once executed).
        XCTAssertEqual(v.onProgress(progress(turnAt: 20, index: 9), units: .metric, speedMps: 10), ["Turn right onto Main St"])
        XCTAssertEqual(v.onProgress(progress(turnAt: 100, index: 9), units: .metric, speedMps: 10), [])
    }

    func testFallbackPhraseImperialAndHighSpeed() {
        var v = VoicePlanner()
        let p = progress(turnAt: 480, instr: " ", dir: .roundabout)
        XCTAssertEqual(v.onProgress(p, units: .imperial, speedMps: 130 / 3.6), ["In 0.3 miles, enter the roundabout"])
        XCTAssertEqual(v.onProgress(progress(turnAt: 50, index: 8, instr: "", dir: .forkLeft), units: .metric, speedMps: 130 / 3.6),
                       ["Keep left at the fork"])
    }

    func testOffRouteSilencesTurnCuesAndJoinBands() {
        var v = VoicePlanner()
        XCTAssertEqual(v.onProgress(progress(turnAt: 100, offTrack: 41), units: .metric, speedMps: 5), [])
        XCTAssertEqual(v.onJoinRoute(dir: .left, offTrackM: 120, units: .metric, nowMs: 1_000), "Turn left toward the route, 120 m")
        XCTAssertNil(v.onJoinRoute(dir: .left, offTrackM: 110, units: .metric, nowMs: 10_000))
        XCTAssertEqual(v.onJoinRoute(dir: .sharpRight, offTrackM: 110, units: .metric, nowMs: 11_000), "Sharp right toward the route, 110 m")
        XCTAssertNil(v.onJoinRoute(dir: .sharpRight, offTrackM: 100, units: .metric, nowMs: 29_000))
        XCTAssertEqual(v.onJoinRoute(dir: .sharpRight, offTrackM: 90, units: .metric, nowMs: 29_001), "Sharp right toward the route, 90 m")
        // Back on route resets the band: the same direction is spoken again immediately.
        _ = v.onProgress(progress(turnAt: 900), units: .metric, speedMps: 5)
        XCTAssertEqual(v.onJoinRoute(dir: .sharpRight, offTrackM: 50, units: .metric, nowMs: 30_000), "Sharp right toward the route, 50 m")
    }

    func testWaypointAnnouncedOncePerWaypoint() {
        var v = VoicePlanner()
        let w = TrackPoint(lat: 45.0155, lon: 25.0002, name: "Peak")
        let far = RouteProgress(nearestIndex: 0, doneM: 0, remainM: 1, offTrackM: 0, snapLat: 0, snapLon: 0, nextWaypoint: w, nextWaypointM: 121)
        XCTAssertEqual(v.onProgress(far, units: .metric, speedMps: 5), [])
        var near = far
        near.nextWaypointM = 120
        XCTAssertEqual(v.onProgress(near, units: .metric, speedMps: 5), ["Approaching Peak"])
        XCTAssertEqual(v.onProgress(near, units: .metric, speedMps: 5), [])
        near.nextWaypoint = TrackPoint(lat: 45.1, lon: 25, name: nil)
        XCTAssertEqual(v.onProgress(near, units: .metric, speedMps: 5), ["Approaching waypoint"])
        // Turn + waypoint in the same update → both, in order.
        var both = progress(turnAt: 20, waypoint: TrackPoint(lat: 1, lon: 1, name: "Fuel"), waypointM: 50)
        both.offTrackM = 0
        XCTAssertEqual(v.onProgress(both, units: .metric, speedMps: 5), ["Turn right onto Main St", "Approaching Fuel"])
    }

    func testSpanishPhrases() {
        var v = VoicePlanner(strings: NavStrings(language: .es))
        XCTAssertEqual(v.onProgress(progress(turnAt: 290, instr: "", dir: .left), units: .metric, speedMps: 25),
                       ["En 300 metros, gira a la izquierda"])
        XCTAssertEqual(v.onJoinRoute(dir: .right, offTrackM: 1500, units: .metric, nowMs: 0), "Gira a la derecha hacia la ruta, 1.5 km")
        var es = VoicePlanner(strings: NavStrings(language: .es, decimalSeparator: ","))
        XCTAssertEqual(es.onJoinRoute(dir: .uturn, offTrackM: 1500, units: .metric, nowMs: 0), "Da la vuelta hacia la ruta, 1,5 km")
        // The heads-up is capped at 700 m, so decimals only appear in imperial (≥ 0.2 mi).
        XCTAssertEqual(es.onProgress(progress(turnAt: 480, instr: "", dir: .right), units: .imperial, speedMps: 36), ["En 0,3 millas, gira a la derecha"])
        XCTAssertEqual(es.onProgress(progress(turnAt: 650, index: 8, instr: "", dir: .left), units: .metric, speedMps: 60), ["En 700 metros, gira a la izquierda"])
    }

    func testDirPhraseTableEnglish() {
        let s = NavStrings.english
        let exp: [TurnDir: String] = [.left: "turn left", .right: "turn right", .sharpLeft: "make a sharp left", .sharpRight: "make a sharp right",
            .slightLeft: "keep left", .slightRight: "keep right", .uturn: "make a U-turn", .roundabout: "enter the roundabout",
            .mergeLeft: "merge left", .mergeRight: "merge right", .forkLeft: "keep left at the fork", .forkRight: "keep right at the fork",
            .arrive: "you have arrived", .straight: "continue straight", .continue: "continue straight"]
        for d in TurnDir.allCases { XCTAssertEqual(s.dirPhrase(d), exp[d], d.rawValue) }
        let words: [TurnDir: String] = [.left: "Turn left", .right: "Turn right", .sharpLeft: "Sharp left", .sharpRight: "Sharp right",
            .slightLeft: "Slight left", .slightRight: "Slight right", .uturn: "U-turn", .roundabout: "Roundabout", .mergeLeft: "Merge",
            .mergeRight: "Merge", .forkLeft: "Keep left", .forkRight: "Keep right", .straight: "Continue", .continue: "Continue", .arrive: "Arrive"]
        for d in TurnDir.allCases { XCTAssertEqual(s.maneuverWord(d), words[d], d.rawValue) }
    }

    func testEveryPhraseHasEnglishAndSpanishText() {
        let all: [NavPhrase] = [.routeUpdated, .routeReady, .arrived, .navigationFinished, .typeSearchOnPhone, .navigatingTo("X"), .saved,
            .homeSet, .markerAdded, .parkingMarked, .parkingUpdated, .parkingCleared, .backOnTrack, .centered, .buildingCircuit,
            .lapTimerArmed, .pinDropped, .destinationReached, .arrivingAt("X"), .lap(3), .followingTrackReversed, .rerouting,
            .approaching("X"), .approaching(nil), .routing, .noRoadRoute, .routeSummary("1 km"), .gpsFreeRide, .gpsNavigateTo("X"),
            .gpsTrack("2 km"), .gpsOnly, .savedToFavorites("X"), .savePinHint, .alreadyFreeRide, .alreadyNearby, .noGpsForParking,
            .parkedSpotCleared, .noHomeSet, .noGpsToSetHome, .homeSetHere, .snapBackOnTrack, .recentered, .noGps, .needGpsForCircuit,
            .pickDestinationForCircuit, .pickPlaceAwayForCircuit, .buildingCircuitTo("X"), .thereAndBackReturning, .thereAndBackReturns,
            .noCircuitFound, .lapTimerOff, .needGpsForLap, .lapArmedHint, .lapFinished(2, "1:00.00"), .freeRide, .gettingRoute,
            .waitingForGps, .straightLine, .avoidNotApplied, .centeredOnGps, .noGpsYet, .headingUp, .northUp, .savedPlaceNotSet(2),
            .searching, .noResults, .placesFound(4), .recentAndFavorites, .searchIdleHintPhone, .searchIdleHintBike, .suggestions,
            .needGpsForPoi, .findingNearby("Fuel"), .noneFoundNearby("fuel"), .foundNearby(3, "fuel")]
        let en = NavStrings(language: .en), es = NavStrings(language: .es)
        for p in all {
            XCTAssertFalse(en.phrase(p).isEmpty)
            XCTAssertFalse(es.phrase(p).isEmpty)
        }
        // Verbatim Android English (§5.3, §11.8).
        XCTAssertEqual(en.phrase(.navigatingTo("Câmpina")), "Navigating to Câmpina")
        XCTAssertEqual(en.phrase(.followingTrackReversed), "Following the track the other way")
        XCTAssertEqual(en.phrase(.noHomeSet), "No Home set — long-press map or use Set Home")
        XCTAssertEqual(en.phrase(.buildingCircuitTo("X")), "Building there & back to X…")
        XCTAssertEqual(es.phrase(.navigatingTo("Câmpina")), "Navegando a Câmpina")
        XCTAssertEqual(es.phrase(.destinationReached), "Has llegado a tu destino")
        XCTAssertEqual(en.arrivalTitle("Câmpina"), "Arrived · Câmpina")
        XCTAssertEqual(en.arrivalTitle(" "), "You've arrived")
        XCTAssertEqual(en.arrivalMeta, "Mark parking, find a spot, or continue free ride")
        XCTAssertEqual(es.routeLabel("Fast"), "Rápida")
        XCTAssertEqual(en.routeLabel("Fast"), "Fast")
        XCTAssertEqual(es.routingWarning(RouteOrchestrator.warningAvoidFallback),
                       "No se pudieron evitar autopistas/peajes en línea: ruta normal (puede usar autopista)")
        XCTAssertEqual(es.poiChipLabel("Fuel"), "Gasolina")
    }

    func testSpanishInstructions() {
        let es = NavStrings(language: .es)
        XCTAssertEqual(es.instruction(type: "turn", modifier: "right", road: "Calle 80", exit: nil), "gira a la derecha hacia Calle 80")
        XCTAssertEqual(es.instruction(type: "roundabout", modifier: nil, road: "DN1", exit: 2), "en la rotonda, toma la salida 2 hacia DN1")
        XCTAssertEqual(es.instruction(type: "fork", modifier: "slight left", road: nil, exit: nil), "mantente a la izquierda")
        XCTAssertEqual(es.instruction(type: "turn", modifier: "uturn", road: nil, exit: nil), "da la vuelta")
        XCTAssertEqual(es.instruction(type: "new name", modifier: "straight", road: "Av. Boyacá", exit: nil), "continúa por Av. Boyacá")
        XCTAssertEqual(es.instruction(type: "continue", modifier: nil, road: nil, exit: nil), "sigue recto")
        XCTAssertEqual(es.instruction(type: "off ramp", modifier: "right", road: nil, exit: nil), "toma la salida a la derecha")
        XCTAssertEqual(es.instruction(type: "arrive", modifier: nil, road: nil, exit: nil), "has llegado")
        XCTAssertEqual(es.instruction(type: "end of road", modifier: "left", road: "Calle 1", exit: nil), "gira a la izquierda hacia Calle 1")
        XCTAssertEqual(es.instruction(type: "turn", modifier: "sharp left", road: nil, exit: nil), "gira bruscamente a la izquierda")
        XCTAssertEqual(NavLanguage.from(languages: ["es-CO", "en"]), .es)
        XCTAssertEqual(NavLanguage.from(languages: ["en-GB", "es"]), .en)
        XCTAssertEqual(NavLanguage.from(languages: []), .en)
    }
}
