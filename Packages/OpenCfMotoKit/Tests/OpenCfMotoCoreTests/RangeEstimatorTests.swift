// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: the range estimate — the reference table (450MT: 17.5 L, 20.5 km/L, 12 %; every value 0.05 km
// away from its threshold), partials, levels, learned vs seed, the single-interval cap, and aging.
import Foundation
import XCTest
@testable import OpenCfMotoCore

final class RangeEstimatorTests: XCTestCase {
    private typealias T = FuelT

    private func estimate(_ log: [RefuelEntry], odo: Double, profile: FuelProfile? = FuelT.mt450(), stats: FuelStats = .empty,
                          odometer: FuelOdometerState? = nil, now: Int64 = FuelT.now) -> FuelEstimate {
        var o = odometer ?? T.odometer(odo)
        o.totalKm = odo
        return RangeEstimator.estimate(profile: profile, log: log, odometer: o, stats: stats, nowMs: now)
    }

    private func km(_ e: FuelEstimate) -> Double? {
        switch e.state {
        case let .ok(k), let .low(k): return k
        default: return nil
        }
    }

    private let fullAt1000 = [FuelT.full("f", odo: 1000)]

    func testTheReferenceTable() {
        let e0 = estimate(fullAt1000, odo: 1000)
        guard case let .ok(k0) = e0.state else { return XCTFail("\(e0.state)") }
        XCTAssertEqual(k0, 315.7, accuracy: 1e-6)
        XCTAssertEqual(e0.fullRangeToReserveKm ?? 0, 315.7, accuracy: 1e-6)
        XCTAssertEqual(e0.kmPerL, 20.5)
        XCTAssertEqual(e0.kmPerLSource, .seed)
        XCTAssertEqual(e0.kmSinceLastEntry, 0)
        XCTAssertEqual(e0.lastRefuelAtMs, T.now)
        XCTAssertEqual(e0.anchorAtMs, T.now)
        XCTAssertTrue(e0.isTrustworthy)
        guard case let .ok(a) = estimate(fullAt1000, odo: 1235.65).state else { return XCTFail() }
        XCTAssertEqual(a, 80.05, accuracy: 1e-6)
        guard case let .low(b) = estimate(fullAt1000, odo: 1235.75).state else { return XCTFail() }
        XCTAssertEqual(b, 79.95, accuracy: 1e-6)
        guard case let .low(c) = estimate(fullAt1000, odo: 1315.65).state else { return XCTFail() }
        XCTAssertEqual(c, 0.05, accuracy: 1e-6)
        XCTAssertEqual(estimate(fullAt1000, odo: 1315.75).state, .reserve)
        XCTAssertEqual(estimate(fullAt1000, odo: 1394.575).state, .reserve)
        XCTAssertEqual(estimate(fullAt1000, odo: 1394.575).kmToReserve, 0)
        guard case let .checkRefuel(since) = estimate(fullAt1000, odo: 1394.675).state else { return XCTFail() }
        XCTAssertEqual(since, 394.675, accuracy: 1e-6)
        XCTAssertEqual(estimate(fullAt1000, odo: 1394.675).kmToReserve, 0)
        XCTAssertFalse(estimate(fullAt1000, odo: 1394.675).isTrustworthy, "never alerts / «Llegas»")
    }

    /// Review UI-3: «Corregir nivel ▸ Reserva» (the reserve light) anchors at the profile's reserve: `reserve`
    /// at 0 km and after 10 km, never a trustworthy «~40 km».
    func testAReserveLevelAnchorsAtTheReserve() {
        let lv = fullAt1000 + [T.level("l", odo: 1100, .reserve)]
        XCTAssertEqual(estimate(lv, odo: 1100).state, .reserve)
        XCTAssertTrue(estimate(lv, odo: 1100).isTrustworthy)
        XCTAssertEqual(estimate(lv, odo: 1110).state, .reserve, "10 km on: still reserve, not checkRefuel")
        XCTAssertEqual(estimate(lv, odo: 1100, profile: T.mt450(reserve: 20)).state, .reserve, "follows the reserve %")
        // a partial that says the tank is at the reserve light anchors there too
        XCTAssertEqual(estimate(fullAt1000 + [T.partial("p", odo: 1200, litres: 1, level: .reserve)], odo: 1200).state, .reserve)
    }

    func testReservePercent() {
        XCTAssertEqual(km(estimate(fullAt1000, odo: 1000, profile: T.mt450(reserve: 20))) ?? 0, 287.0, accuracy: 1e-6)
        XCTAssertEqual(km(estimate(fullAt1000, odo: 1000, profile: T.mt450(reserve: 5))) ?? 0, 16.625 * 20.5, accuracy: 1e-6)
        XCTAssertEqual(km(estimate(fullAt1000, odo: 1000, profile: T.mt450(reserve: 30))) ?? 0, 12.25 * 20.5, accuracy: 1e-6)
    }

    func testPartials() {
        // +8 L at 1200, now 1200 → (17.5 − 200/20.5 + 8 − 2.1) × 20.5 = 279.7
        let p8 = estimate(fullAt1000 + [T.partial("p", odo: 1200, litres: 8)], odo: 1200)
        XCTAssertEqual(km(p8) ?? 0, 279.7, accuracy: 1e-6)
        XCTAssertEqual(p8.kmSinceLastEntry, 0)
        XCTAssertEqual(p8.kmSinceAnchor, 200)
        // +10 L at 1050 → capped at the tank → 315.7
        XCTAssertEqual(km(estimate(fullAt1000 + [T.partial("p", odo: 1050, litres: 10)], odo: 1050)) ?? 0, 315.7, accuracy: 1e-6)
        // a partial without litres → unknown until the next full
        let none = estimate(fullAt1000 + [T.partial("p", odo: 1050)], odo: 1100)
        XCTAssertEqual(none.state, .unknown(.partialWithoutAmount))
        XCTAssertNil(none.kmToReserve)
        XCTAssertFalse(none.isTrustworthy)
        XCTAssertEqual(estimate(fullAt1000 + [T.partial("p", odo: 1050), T.full("g", odo: 1100)], odo: 1100).kmToReserve ?? 0,
                       315.7, accuracy: 1e-6)
    }

    func testLevelAnchors() {
        // partial ½ at 1200 → (8.75 − 2.1) × 20.5 = 136.325; level ½ the same
        XCTAssertEqual(km(estimate(fullAt1000 + [T.partial("p", odo: 1200, level: .half)], odo: 1200)) ?? 0, 136.325, accuracy: 1e-6)
        XCTAssertEqual(km(estimate(fullAt1000 + [T.level("l", odo: 1200, .half)], odo: 1200)) ?? 0, 136.325, accuracy: 1e-6)
        XCTAssertEqual(km(estimate([T.level("l", odo: 0, .quarter)], odo: 0)) ?? 0, (4.375 - 2.1) * 20.5, accuracy: 1e-6)
        XCTAssertEqual(km(estimate([T.level("l", odo: 0, .threeQuarters)], odo: 0)) ?? 0, (13.125 - 2.1) * 20.5, accuracy: 1e-6)
        // a level anchor after a partial without litres clears the unknown
        let fixed = estimate(fullAt1000 + [T.partial("p", odo: 1050), T.level("l", odo: 1100, .half)], odo: 1100)
        XCTAssertEqual(km(fixed) ?? 0, 136.325, accuracy: 1e-6)
    }

    func testNoProfileAndNoRefuel() {
        XCTAssertEqual(estimate(fullAt1000, odo: 1000, profile: nil), .unknown(.noProfile))
        XCTAssertEqual(estimate([], odo: 1000), .unknown(.noRefuel))
        XCTAssertEqual(estimate([T.partial("p", odo: 1000, litres: 5)], odo: 1000), .unknown(.noRefuel), "no anchor")
        XCTAssertNil(FuelEstimate.unknown(.noRefuel).kmToReserve)
    }

    func testLearnedVersusSeed() {
        let one = FuelStats(intervals: [], learnedKmPerL: 22, learnedIntervalCount: 1, lastKmPerL: 22, costPerKm: nil)
        let e = estimate(fullAt1000, odo: 1000, stats: one)
        XCTAssertEqual(e.kmPerL, 22)
        XCTAssertEqual(e.kmPerLSource, .learned(intervals: 1))
        XCTAssertEqual(km(e) ?? 0, 15.4 * 22, accuracy: 1e-6)
        let off = estimate(fullAt1000, odo: 1000, profile: T.mt450(preferLearned: false), stats: one)
        XCTAssertEqual(off.kmPerL, 20.5)
        XCTAssertEqual(off.kmPerLSource, .seed)
        // a single interval is capped at seed × 1.15 = 23.575
        let high = FuelStats(intervals: [], learnedKmPerL: 30, learnedIntervalCount: 1, lastKmPerL: 30, costPerKm: nil)
        let capped = estimate(fullAt1000, odo: 1000, stats: high)
        XCTAssertEqual(capped.kmPerL ?? 0, 23.575, accuracy: 1e-9)
        XCTAssertEqual(capped.kmPerLSource, .learnedCapped)
        // two intervals: uncapped
        let two = FuelStats(intervals: [], learnedKmPerL: 30, learnedIntervalCount: 2, lastKmPerL: 30, costPerKm: nil)
        XCTAssertEqual(estimate(fullAt1000, odo: 1000, stats: two).kmPerL, 30)
        XCTAssertEqual(estimate(fullAt1000, odo: 1000, stats: two).kmPerLSource, .learned(intervals: 2))
        XCTAssertTrue(RangeEstimator.effectiveKmPerL(profile: T.mt450(), stats: .empty) == (20.5, .seed))
    }

    func testAgedByTimeFromTheNewestEntry() {
        let old = [T.full("f", odo: 1000, at: T.now - 31 * T.dayMs)]
        XCTAssertEqual(estimate(old, odo: 1000).aged, .old(days: 31))
        XCTAssertFalse(estimate(old, odo: 1000).isTrustworthy)
        // a partial with litres 5 days ago after a full 40 days ago → not aged
        let topped = [T.full("f", odo: 1000, at: T.now - 40 * T.dayMs), T.partial("p", odo: 1100, litres: 5, at: T.now - 5 * T.dayMs)]
        XCTAssertNil(estimate(topped, odo: 1100).aged)
        // 30 days ± 1 ms
        let edge = [T.full("f", odo: 1000, at: T.now - 30 * T.dayMs)]
        XCTAssertNil(estimate(edge, odo: 1000).aged)
        XCTAssertEqual(estimate(edge, odo: 1000, now: T.now + 1).aged, .old(days: 30))
    }

    func testAgedByAGapAfterTheAnchorOnly() {
        var odo = T.odometer(1000)
        odo.gapsMs = [T.now + 10]
        XCTAssertEqual(estimate(fullAt1000, odo: 1000, odometer: odo, now: T.now + 20).aged, .gap)
        odo.gapsMs = [T.now - 10]
        XCTAssertNil(estimate(fullAt1000, odo: 1000, odometer: odo).aged, "a gap before the anchor")
        // a new anchor clears it
        odo.gapsMs = [T.now + 10]
        let again = fullAt1000 + [T.full("g", odo: 1100, at: T.now + 20)]
        XCTAssertNil(estimate(again, odo: 1100, odometer: odo, now: T.now + 30).aged)
    }

    func testAgedByNoGps() {
        var odo = T.odometer(1000)
        odo.openBlindSinceMs = T.now
        XCTAssertNil(estimate(fullAt1000, odo: 1000, odometer: odo, now: T.now + 119_000).aged, "1 min 59 s")
        XCTAssertEqual(estimate(fullAt1000, odo: 1000, odometer: odo, now: T.now + 120_000).aged, .noGps)
        // a closed mark after the anchor
        var closed = T.odometer(1000)
        closed.noGpsMs = [T.now + 5]
        XCTAssertEqual(estimate(fullAt1000, odo: 1000, odometer: closed, now: T.now + 10).aged, .noGps)
        // a new anchor clears a closed mark, not an open spell
        let again = fullAt1000 + [T.full("g", odo: 1000, at: T.now + 20)]
        XCTAssertNil(estimate(again, odo: 1000, odometer: closed, now: T.now + 30).aged)
        var open = closed
        open.openBlindSinceMs = T.now + 25
        XCTAssertEqual(estimate(again, odo: 1000, odometer: open, now: T.now + 25 + 120_000).aged, .noGps)
        // aged is not set on unknown states
        XCTAssertNil(estimate([], odo: 1000, odometer: open, now: T.now + 999_999).aged)
    }

    func testAnOdometerBelowTheAnchorCountsZero() {
        let e = estimate(fullAt1000, odo: 900)
        XCTAssertEqual(e.kmSinceAnchor, 0)
        XCTAssertEqual(e.kmSinceLastEntry, 0)
        XCTAssertEqual(km(e) ?? 0, 315.7, accuracy: 1e-6)
    }

    func testTrustworthiness() {
        XCTAssertTrue(estimate(fullAt1000, odo: 1000).isTrustworthy)
        XCTAssertTrue(estimate(fullAt1000, odo: 1300).isTrustworthy)
        XCTAssertTrue(estimate(fullAt1000, odo: 1350).isTrustworthy, "reserve")
        XCTAssertFalse(estimate(fullAt1000, odo: 1400).isTrustworthy, "checkRefuel")
        XCTAssertFalse(estimate([], odo: 0).isTrustworthy)
        var gap = T.odometer(1000)
        gap.gapsMs = [T.now + 1]
        XCTAssertFalse(estimate(fullAt1000, odo: 1300, odometer: gap, now: T.now + 2).isTrustworthy)
        XCTAssertEqual(estimate(fullAt1000, odo: 1300, odometer: gap, now: T.now + 2).aged, .gap)
    }
}
