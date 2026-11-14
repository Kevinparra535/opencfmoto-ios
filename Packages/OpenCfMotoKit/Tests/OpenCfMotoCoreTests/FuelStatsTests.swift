// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: learned km/L from full-to-full fills (completeness, trip meter check, unseen stamps,
// plausibility, seed band with corroboration, last-5 mean, cost per km).
import Foundation
import XCTest
@testable import OpenCfMotoCore

final class FuelStatsTests: XCTestCase {
    private typealias T = FuelT

    private func stats(_ log: [RefuelEntry], seed: Double = 20.5, tank: Double = 17.5) -> FuelStats {
        FuelStats.compute(log: log, seedKmPerL: seed, tankL: tank)
    }

    func testFullToFullWithLitres() throws {
        let s = stats([T.full("a", odo: 1000), T.full("b", odo: 1300, litres: 15)])
        XCTAssertEqual(s.intervals.count, 1)
        let iv = try XCTUnwrap(s.intervals.first)
        XCTAssertEqual(iv.fromEntryId, "a")
        XCTAssertEqual(iv.toEntryId, "b")
        XCTAssertEqual(iv.km, 300)
        XCTAssertEqual(iv.litres, 15)
        XCTAssertEqual(iv.kmPerL, 20)
        XCTAssertEqual(iv.distanceSource, .app)
        XCTAssertNil(iv.cost)
        XCTAssertEqual(s.learnedKmPerL, 20)
        XCTAssertEqual(s.learnedIntervalCount, 1)
        XCTAssertEqual(s.lastKmPerL, 20)
        XCTAssertEqual(FuelStats.compute(log: [], seedKmPerL: 20.5, tankL: 17.5), .empty)
        XCTAssertEqual(stats([T.full("a", odo: 0)]), .empty)
        XCTAssertEqual(stats([T.full("a", odo: 0), T.full("b", odo: 300)]).intervals, [], "the closing full needs litres")
    }

    func testPartialsWithLitresSumIntoTheInterval() {
        let s = stats([T.full("a", odo: 1000), T.partial("p1", odo: 1100, litres: 4), T.partial("p2", odo: 1200, litres: 5),
                       T.full("b", odo: 1400, litres: 11)])
        XCTAssertEqual(s.intervals.first?.litres, 20)
        XCTAssertEqual(s.intervals.first?.kmPerL, 20)
    }

    func testAPartialWithoutLitresOrWithOnlyALevelBreaksTheInterval() {
        XCTAssertEqual(stats([T.full("a", odo: 1000), T.partial("p", odo: 1100), T.full("b", odo: 1400, litres: 20)]).intervals, [])
        XCTAssertEqual(stats([T.full("a", odo: 1000), T.partial("p", odo: 1100, level: .half), T.full("b", odo: 1400, litres: 20)]).intervals, [])
    }

    func testALevelEntryIsIgnoredButItsUnseenStampCounts() {
        let kept = stats([T.full("a", odo: 1000), T.level("l", odo: 1150, .half), T.full("b", odo: 1300, litres: 15)])
        XCTAssertEqual(kept.intervals.first?.litres, 15)
        XCTAssertEqual(kept.intervals.first?.km, 300)
        let unseen = stats([T.full("a", odo: 1000), T.level("l", odo: 1150, .half, unseen: true), T.full("b", odo: 1300, litres: 15)])
        XCTAssertEqual(unseen.intervals, [], "an app-distance interval with unseen km is not learned")
    }

    func testTheTripMeter() {
        // on every fill and inside the check → overrides the app km
        let trip = stats([T.full("a", odo: 1000), T.partial("p", odo: 1100, litres: 5, trip: 110),
                          T.full("b", odo: 1300, litres: 10, trip: 205)])
        XCTAssertEqual(trip.intervals.first?.km, 315)
        XCTAssertEqual(trip.intervals.first?.distanceSource, .tripMeter)
        // 600 km against 300 app km: a meter not reset → ignored
        let notReset = stats([T.full("a", odo: 1000), T.full("b", odo: 1300, litres: 15, trip: 600)])
        XCTAssertEqual(notReset.intervals.first?.km, 300)
        XCTAssertEqual(notReset.intervals.first?.distanceSource, .app)
        // 0.85 × app → ignored
        XCTAssertEqual(stats([T.full("a", odo: 1000), T.full("b", odo: 1300, litres: 15, trip: 255)]).intervals.first?.km, 300)
        // above T × seed × 1.3 = 466.375 km → ignored even when it fits the app window (app 400, window ≤ 600)
        let big = stats([T.full("a", odo: 1000), T.full("b", odo: 1400, litres: 20, trip: 470)])
        XCTAssertEqual(big.intervals.first?.km, 400)
        // the +50 km slack of a short interval: app 60, trip 105 ≤ max(90, 110)
        let slack = stats([T.full("a", odo: 1000), T.full("b", odo: 1060, litres: 5, trip: 105)])
        XCTAssertEqual(slack.intervals.first?.km, 105)
        // missing on one fill → app distance
        let partialTrip = stats([T.full("a", odo: 1000), T.partial("p", odo: 1100, litres: 5),
                                 T.full("b", odo: 1300, litres: 10, trip: 205)])
        XCTAssertEqual(partialTrip.intervals.first?.distanceSource, .app)
    }

    func testUnseenStampsExcludeAppDistanceButNotAValidTripMeter() {
        XCTAssertEqual(stats([T.full("a", odo: 1000), T.full("b", odo: 1300, litres: 15, unseen: true)]).intervals, [])
        let kept = stats([T.full("a", odo: 1000), T.full("b", odo: 1300, litres: 15, trip: 310, unseen: true)])
        XCTAssertEqual(kept.intervals.first?.km, 310)
        XCTAssertEqual(kept.intervals.first?.distanceSource, .tripMeter)
        // the stamp on the OPENING full belongs to the interval before it
        XCTAssertEqual(stats([T.full("a", odo: 1000, unseen: true), T.full("b", odo: 1300, litres: 15)]).intervals.count, 1)
    }

    func testImplausibleIntervalsAreExcluded() {
        XCTAssertEqual(stats([T.full("a", odo: 1000), T.full("b", odo: 1029, litres: 1.4)]).intervals, [], "< 30 km")
        XCTAssertEqual(stats([T.full("a", odo: 1000), T.full("b", odo: 1040, litres: 0.9)]).intervals, [], "< 1 L")
        XCTAssertEqual(stats([T.full("a", odo: 1000), T.full("b", odo: 1070, litres: 10)], seed: 8).intervals, [], "7 km/L")
        XCTAssertEqual(stats([T.full("a", odo: 1000), T.full("b", odo: 1610, litres: 10)], seed: 50).intervals, [], "61 km/L")
    }

    func testTheSeedBandAndCorroboration() {
        // 40 km/L on a 20.5 seed (a «Lleno» that was not full) → excluded
        XCTAssertEqual(stats([T.full("a", odo: 1000), T.full("b", odo: 1400, litres: 10)]).intervals, [])
        // 30 km/L on a 22 seed (inside 0.6–1.4 × 22 = 13.2…30.8) → kept
        let in22 = stats([T.full("a", odo: 1000), T.full("b", odo: 1300, litres: 10), T.full("c", odo: 1600, litres: 10)], seed: 22)
        XCTAssertEqual(in22.intervals.count, 2)
        XCTAssertEqual(in22.learnedKmPerL, 30)
        // 32 km/L on a 22 seed: one alone is an outlier, two that agree are both kept
        XCTAssertEqual(stats([T.full("a", odo: 1000), T.full("b", odo: 1320, litres: 10)], seed: 22).intervals, [])
        let two = stats([T.full("a", odo: 1000), T.full("b", odo: 1320, litres: 10), T.full("c", odo: 1650, litres: 10)], seed: 22)
        XCTAssertEqual(two.intervals.count, 2, "corroborated")
        XCTAssertEqual(two.learnedKmPerL ?? 0, 32.5, accuracy: 1e-9)
        // a hand-entered bike left at 15.5 that really does 25 km/L (1.61 × seed)
        let manual = stats([T.full("a", odo: 0), T.full("b", odo: 250, litres: 10), T.full("c", odo: 510, litres: 10)], seed: 15.5)
        XCTAssertEqual(manual.intervals.count, 2)
        // disagreeing outliers stay out
        let apart = stats([T.full("a", odo: 0), T.full("b", odo: 320, litres: 10), T.full("c", odo: 720, litres: 10)], seed: 22)
        XCTAssertEqual(apart.intervals, [])
    }

    func testLastFiveDistanceWeightedMean() {
        var log = [T.full("f0", odo: 0)]
        var odo = 0.0
        // seven intervals: 300 km / 15 L (20) then six of 200 km / 10 L … 20 km/L except the oldest two
        let legs: [(km: Double, l: Double)] = [(300, 20), (300, 20), (300, 15), (200, 10), (400, 19), (100, 5), (300, 14)]
        for (i, leg) in legs.enumerated() {
            odo += leg.km
            log.append(T.full("f\(i + 1)", odo: odo, litres: leg.l, at: T.now + Int64(i)))
        }
        let s = stats(log)
        XCTAssertEqual(s.intervals.count, 7)
        XCTAssertEqual(s.intervals.first?.toEntryId, "f7", "newest first")
        XCTAssertEqual(s.learnedIntervalCount, 5)
        let newest5 = legs.suffix(5)
        let expected = newest5.reduce(0) { $0 + $1.km } / newest5.reduce(0) { $0 + $1.l }
        XCTAssertEqual(s.learnedKmPerL ?? 0, expected, accuracy: 1e-12)
        XCTAssertEqual(s.lastKmPerL ?? 0, 300.0 / 14, accuracy: 1e-12)
    }

    func testCostPerKm() {
        // per litre on both fills of the second interval, total on the first
        let s = stats([T.full("a", odo: 0), T.full("b", odo: 300, litres: 15, total: 60),
                       T.partial("p", odo: 400, litres: 5, per: 4), T.full("c", odo: 600, litres: 10, per: 4)])
        XCTAssertEqual(s.intervals.count, 2)
        XCTAssertEqual(s.intervals[0].cost, 60, "newest: 20 + 40")
        XCTAssertEqual(s.intervals[1].cost, 60)
        XCTAssertEqual(s.costPerKm ?? 0, 120.0 / 600, accuracy: 1e-12)
        // one fill without a price → that interval has no cost
        let mixed = stats([T.full("a", odo: 0), T.full("b", odo: 300, litres: 15, per: 4),
                           T.partial("p", odo: 400, litres: 5), T.full("c", odo: 600, litres: 10, per: 4)])
        XCTAssertNil(mixed.intervals[0].cost)
        XCTAssertEqual(mixed.intervals[1].cost, 60)
        XCTAssertEqual(mixed.costPerKm ?? 0, 60.0 / 300, accuracy: 1e-12)
        XCTAssertNil(stats([T.full("a", odo: 0), T.full("b", odo: 300, litres: 15)]).costPerKm)
        // the opening full's price is not part of the interval
        let opening = stats([T.full("a", odo: 0, litres: 12, per: 9), T.full("b", odo: 300, litres: 15, per: 4)])
        XCTAssertEqual(opening.intervals.first?.cost, 60)
    }
}
