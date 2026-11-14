// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: the low-range alert fires once per crossing and is re-armed by a refuel; untrustworthy estimates
// never fire and never re-arm.
import Foundation
import XCTest
@testable import OpenCfMotoCore

final class FuelAlertPolicyTests: XCTestCase {
    private let ok = FuelEstimate(state: .ok(kmToReserve: 200))
    private let low = FuelEstimate(state: .low(kmToReserve: 60))
    private let reserve = FuelEstimate(state: .reserve)

    /// The FuelModel order per odometer change: re-arm, then fire.
    private func step(_ alerted: inout FuelAlertLevel?, _ e: FuelEstimate) -> FuelAlertLevel? {
        alerted = FuelAlertPolicy.rearmed(alerted, estimate: e)
        let fire = FuelAlertPolicy.alertToFire(estimate: e, alerted: alerted)
        if let fire { alerted = fire }
        return fire
    }

    func testOncePerCrossingAndReArm() {
        var latch: FuelAlertLevel?
        XCTAssertNil(step(&latch, ok))
        XCTAssertEqual(step(&latch, low), .low)
        XCTAssertNil(step(&latch, low), "low again")
        XCTAssertNil(step(&latch, FuelEstimate(state: .low(kmToReserve: 30))))
        XCTAssertEqual(step(&latch, reserve), .reserve)
        XCTAssertNil(step(&latch, reserve))
        XCTAssertEqual(latch, .reserve)
        // a refuel back to ok re-arms
        XCTAssertNil(step(&latch, ok))
        XCTAssertNil(latch)
        XCTAssertEqual(step(&latch, low), .low)
    }

    func testOkStraightToReserveFiresReserveOnly() {
        var latch: FuelAlertLevel?
        XCTAssertEqual(step(&latch, reserve), .reserve)
        XCTAssertNil(step(&latch, low), "a reserve latch covers low")
    }

    func testAPartialBackIntoLowAfterReserveLatchesLow() {
        var latch: FuelAlertLevel? = .reserve
        XCTAssertNil(step(&latch, low))
        XCTAssertEqual(latch, .low)
        XCTAssertEqual(step(&latch, reserve), .reserve, "reserve fires again later")
    }

    func testUntrustworthyEstimatesNeverFireNorReArm() {
        let untrustworthy = [
            FuelEstimate(state: .low(kmToReserve: 60), aged: .old(days: 40)),
            FuelEstimate(state: .low(kmToReserve: 60), aged: .gap),
            FuelEstimate(state: .reserve, aged: .noGps),
            FuelEstimate(state: .ok(kmToReserve: 200), aged: .gap),
            FuelEstimate.unknown(.noRefuel),
            FuelEstimate.unknown(.partialWithoutAmount),
            FuelEstimate(state: .checkRefuel(kmSinceAnchor: 500)),
        ]
        for e in untrustworthy {
            XCTAssertNil(FuelAlertPolicy.level(of: e), "\(e)")
            XCTAssertNil(FuelAlertPolicy.alertToFire(estimate: e, alerted: nil), "\(e)")
            XCTAssertEqual(FuelAlertPolicy.rearmed(.low, estimate: e), .low, "\(e)")
            XCTAssertEqual(FuelAlertPolicy.rearmed(.reserve, estimate: e), .reserve, "\(e)")
            XCTAssertNil(FuelAlertPolicy.rearmed(nil, estimate: e))
        }
    }

    func testLevelsAndOrder() {
        XCTAssertNil(FuelAlertPolicy.level(of: ok))
        XCTAssertEqual(FuelAlertPolicy.level(of: low), .low)
        XCTAssertEqual(FuelAlertPolicy.level(of: reserve), .reserve)
        XCTAssertLessThan(FuelAlertLevel.low, .reserve)
        XCTAssertEqual([FuelAlertLevel.reserve, .low].sorted(), [.low, .reserve])
        XCTAssertEqual(FuelAlertPolicy.rearmed(.reserve, estimate: low), .low)
        XCTAssertEqual(FuelAlertPolicy.rearmed(.low, estimate: reserve), .low)
        XCTAssertNil(FuelAlertPolicy.rearmed(.reserve, estimate: ok))
        XCTAssertEqual(FuelAlertPolicy.toastSeconds, 6)
    }
}
