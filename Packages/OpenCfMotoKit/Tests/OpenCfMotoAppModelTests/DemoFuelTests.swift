// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: the `-demoSeed` fuel data — each mode yields its intended state through FuelStats + RangeEstimator,
// for the 675SR-R catalog row and the hand-entered fallback; every litre figure fits the tank; no position.
import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class DemoFuelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)
    private var nowMs: Int64 { Int64(now.timeIntervalSince1970 * 1000) }

    private func estimate(_ profile: FuelProfile, _ mode: DemoFuel.Mode) -> (FuelEstimate, RefuelLog, FuelOdometerState) {
        let docs = DemoFuel.documents(profile: profile, mode: mode, nowMs: nowMs)
        let stats = FuelStats.compute(log: docs.log.entries, seedKmPerL: profile.seedKmPerL, tankL: profile.tankL)
        return (RangeEstimator.estimate(profile: profile, log: docs.log.entries, odometer: docs.odometer, stats: stats, nowMs: nowMs),
                docs.log, docs.odometer)
    }

    func testTheReferenceNumbersForThe675SRR() throws {
        let entry = try XCTUnwrap(FuelCatalog.entry(id: DemoFuel.catalogId))
        let p = DemoFuel.demoProfile(entry: entry, nowMs: nowMs)
        XCTAssertEqual(p.tankL, 15)
        XCTAssertEqual(p.seedKmPerL, 16.5)
        let (ok, log, odo) = estimate(p, .ok)
        XCTAssertEqual(log.entries.map(\.odometerKm), [4000, 4210, 4330])
        XCTAssertEqual(log.entries[1].litres, 12)
        XCTAssertEqual(odo.totalKm, 4389.55, accuracy: 1e-6)
        guard case let .ok(km) = ok.state else { return XCTFail("\(ok.state)") }
        XCTAssertEqual(km, 138.95, accuracy: 1e-6)
        XCTAssertEqual(FuelFormat.range(km, units: .metric).text, "~130 km")
        XCTAssertEqual(ok.kmSinceLastEntry ?? 0, 59.55, accuracy: 1e-6)
        XCTAssertEqual(FuelFormat.distance(ok.kmSinceLastEntry ?? 0, units: .metric), "60 km")
        XCTAssertEqual(ok.kmPerL, 17.5, "the measured km/L (one interval, under the cap)")
        XCTAssertEqual(ok.kmPerLSource, .learned(intervals: 1))
        XCTAssertNil(ok.aged)
        let (low, _, lowOdo) = estimate(p, .low)
        XCTAssertEqual(lowOdo.totalKm, 4468.5, accuracy: 1e-6)
        guard case let .low(lkm) = low.state else { return XCTFail("\(low.state)") }
        XCTAssertEqual(lkm, 60.0, accuracy: 1e-6)
        let (aged, agedLog, _) = estimate(p, .aged)
        XCTAssertEqual(aged.aged, .old(days: 38))
        XCTAssertEqual(agedLog.entries.last?.atMs, nowMs - 38 * RangeEstimator.msPerDay)
    }

    func testEveryModeForTheRowAndTheManualFallback() {
        for entry in [FuelCatalog.entry(id: DemoFuel.catalogId), nil] {
            let p = DemoFuel.demoProfile(entry: entry, nowMs: nowMs)
            XCTAssertTrue(p.isComplete)
            for mode in [DemoFuel.Mode.ok, .low, .aged] {
                let tag = "\(entry?.id ?? "manual") \(mode)"
                let (e, log, odo) = estimate(p, mode)
                for l in log.entries.compactMap(\.litres) { XCTAssertLessThanOrEqual(l, p.tankL, tag) }
                XCTAssertGreaterThan(e.kmSinceLastEntry ?? 0, 0, "\(tag): never «0 km» since the last refuel")
                XCTAssertNil(odo.last, "\(tag): no position seeded")
                switch mode {
                case .ok:
                    guard case let .ok(km) = e.state else { XCTFail("\(tag) \(e.state)"); continue }
                    XCTAssertGreaterThan(km, 80, tag)
                    XCTAssertNil(e.aged, tag)
                case .low:
                    guard case let .low(km) = e.state else { XCTFail("\(tag) \(e.state)"); continue }
                    XCTAssertEqual(km, 60, accuracy: 1e-6, tag)
                    XCTAssertTrue(e.isTrustworthy, tag)
                case .aged:
                    guard case .old = e.aged else { XCTFail("\(tag) \(String(describing: e.aged))"); continue }
                case .setup:
                    break
                }
            }
        }
    }

    @MainActor
    func testSeedWritesOnlyTheDemoBikesScopedKeys() async {
        for mode in DemoFuel.Mode.allCases {
            let env = FuelTestEnv(wall: Locked(now))
            let other = env.addOtherBike()
            let before = Set(env.kv.allKeys())
            DemoFuel.seed(store: env.kv, garage: env.core.garage, bikeId: env.bike.id, mode: mode, now: now)
            env.model.garage.reload()
            let added = Set(env.kv.allKeys()).subtracting(before).filter { $0.hasPrefix("fuel_") }
            XCTAssertTrue(added.allSatisfy { $0.hasSuffix("#\(env.bike.id)") }, "\(mode): \(added)")
            XCTAssertFalse(env.kv.allKeys().contains { $0.hasPrefix("fuel_") && $0.hasSuffix("#\(other.id)") })
            XCTAssertEqual(env.core.garage.bike(id: env.bike.id)?.profileHint, .legacy, "\(mode)")
            let again = FuelTestEnv(kv: env.kv, secrets: env.secrets, wall: env.wall)
            switch mode {
            case .setup:
                XCTAssertTrue(added.isEmpty, "no fuel data")
                XCTAssertNil(again.fuel.current?.profile)
                XCTAssertEqual(again.fuel.setupPrompt?.bikeId, env.bike.id, "Home shows «¿Cuál es tu moto?»")
            case .ok:
                XCTAssertEqual(again.fuel.current?.profile?.catalogId, DemoFuel.catalogId)
                guard case .ok? = again.fuel.current?.estimate.state else { XCTFail("ok"); continue }
                XCTAssertNil(again.fuel.current?.estimate.aged)
            case .low:
                guard case .low? = again.fuel.current?.estimate.state else { XCTFail("low"); continue }
            case .aged:
                guard case .old? = again.fuel.current?.estimate.aged else { XCTFail("aged"); continue }
            }
            XCTAssertNil(again.storedOdometer()?.last, "no position")
            // re-seeding replaces (the demo store persists between launches)
            DemoFuel.seed(store: env.kv, garage: env.core.garage, bikeId: env.bike.id, mode: .setup, now: now)
            XCTAssertFalse(env.kv.allKeys().contains { $0.hasPrefix("fuel_") && $0.hasSuffix("#\(env.bike.id)") })
        }
    }
}
