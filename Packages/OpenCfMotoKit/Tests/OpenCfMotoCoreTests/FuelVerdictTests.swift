// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: the route verdict — references 0.05 km away from every threshold, stops, aged / unknown mapping,
// and no verdict for a straight-line fallback (including a beeline with a forced label).
import Foundation
import XCTest
@testable import OpenCfMotoCore

final class FuelVerdictTests: XCTestCase {
    private func ok(_ km: Double, aged: FuelAgedReason? = nil, full: Double = 315.7) -> FuelEstimate {
        FuelEstimate(state: km > RangeEstimator.lowThresholdKm ? .ok(kmToReserve: km) : .low(kmToReserve: km), aged: aged,
                     kmPerL: 20.5, kmPerLSource: .seed, fullRangeToReserveKm: full)
    }

    private func v(_ e: FuelEstimate, _ km: Double) -> FuelVerdict? {
        FuelVerdictRule.verdict(estimate: e, routeDistanceM: km * 1000)
    }

    private func margin(_ verdict: FuelVerdict?) -> Double? {
        switch verdict {
        case let .reaches(m), let .tight(m): return m
        default: return nil
        }
    }

    func testReferences() {
        let e = ok(315.7)
        guard case .reaches = v(e, 290.65) else { return XCTFail("\(String(describing: v(e, 290.65)))") }
        XCTAssertEqual(margin(v(e, 290.65)) ?? 0, 25.05, accuracy: 1e-6)
        guard case .tight = v(e, 290.75) else { return XCTFail() }
        XCTAssertEqual(margin(v(e, 290.75)) ?? 0, 24.95, accuracy: 1e-6)
        guard case .tight = v(e, 315.65) else { return XCTFail() }
        XCTAssertEqual(margin(v(e, 315.65)) ?? 0, 0.05, accuracy: 1e-6)
        XCTAssertEqual(v(e, 315.75), .needsRefuel(stops: 1))
        XCTAssertEqual(v(e, 631.35), .needsRefuel(stops: 1))
        XCTAssertEqual(v(e, 631.45), .needsRefuel(stops: 2))
        XCTAssertEqual(v(e, 632.4), .needsRefuel(stops: 2))
    }

    func testStops() {
        let e = ok(100, full: 300)
        XCTAssertEqual(v(e, 350), .needsRefuel(stops: 1))
        XCTAssertEqual(v(e, 650), .needsRefuel(stops: 2))
        XCTAssertEqual(v(e, 950), .needsRefuel(stops: 3))
        XCTAssertEqual(v(e, 1250), .needsRefuel(stops: 4))
        XCTAssertEqual(v(FuelEstimate(state: .ok(kmToReserve: 100)), 500), .needsRefuel(stops: 1), "no full range known")
    }

    func testAgedOnlyDowngradesReaches() {
        let aged = ok(315.7, aged: .gap)
        XCTAssertEqual(v(aged, 100), .unknown(.aged))
        guard case .tight = v(aged, 300) else { return XCTFail("tight stays tight") }
        XCTAssertEqual(v(aged, 700), .needsRefuel(stops: 2))
        XCTAssertEqual(v(ok(315.7, aged: .noGps), 10), .unknown(.aged))
        XCTAssertEqual(v(ok(315.7, aged: .old(days: 40)), 10), .unknown(.aged))
    }

    func testUnknownAndCheckRefuelMapping() {
        XCTAssertEqual(v(.unknown(.noProfile), 10), .unknown(.noProfile))
        XCTAssertEqual(v(.unknown(.noRefuel), 10), .unknown(.noRefuel))
        XCTAssertEqual(v(.unknown(.partialWithoutAmount), 10), .unknown(.partialWithoutAmount))
        XCTAssertEqual(v(FuelEstimate(state: .checkRefuel(kmSinceAnchor: 400), fullRangeToReserveKm: 315.7), 10), .unknown(.checkRefuel))
    }

    func testReserveHasNoRemainingRange() {
        let reserve = FuelEstimate(state: .reserve, kmPerL: 20.5, fullRangeToReserveKm: 315.7)
        XCTAssertEqual(v(reserve, 10), .needsRefuel(stops: 1))
        XCTAssertEqual(v(reserve, 400), .needsRefuel(stops: 2))
    }

    func testBadDistancesGiveNoVerdict() {
        let e = ok(315.7)
        XCTAssertNil(v(e, 0))
        XCTAssertNil(v(e, -1))
        XCTAssertNil(FuelVerdictRule.verdict(estimate: e, routeDistanceM: .nan))
        XCTAssertNil(FuelVerdictRule.verdict(estimate: e, routeDistanceM: .infinity))
        XCTAssertNil(FuelVerdictRule.verdict(estimate: e, routeDistanceM: 1000, isStraightLine: true))
    }

    func testRoutesUseIsDirectFallback() {
        let e = ok(315.7)
        let a = GeoPoint(lat: 4.6, lon: -74.08), b = GeoPoint(lat: 4.7, lon: -74.0)
        let beeline = RouteOrchestrator.beeline(from: a, to: b)
        XCTAssertNil(FuelVerdictRule.verdict(estimate: e, route: beeline.withLabel("Direct")))
        XCTAssertFalse(beeline.withLabel("Circuit").isStraightLine, "isStraightLine misses a forced label")
        XCTAssertNil(FuelVerdictRule.verdict(estimate: e, route: beeline.withLabel("Circuit")), "a beeline with a forced label")
        let online = Route(points: [TrackPoint(lat: a.lat, lon: a.lon), TrackPoint(lat: b.lat, lon: b.lon)], distanceM: 20_000,
                           durationSec: 1200, steps: [RouteStep(maneuverType: "depart", roadName: "Calle 26", maneuverLat: a.lat,
                                                                maneuverLon: a.lon)], label: "Fast")
        guard case .reaches = FuelVerdictRule.verdict(estimate: e, route: online) else { return XCTFail("an online route") }
        XCTAssertEqual(FuelVerdictRule.marginKm, 25)
    }
}
