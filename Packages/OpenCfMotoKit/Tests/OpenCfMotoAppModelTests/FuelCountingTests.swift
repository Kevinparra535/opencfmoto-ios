// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: when km count. Parked (bus / car / walk with the phone) → nothing; un-park at the same place → no
// gap; far away → rule G. Approximate / denied location → aged `noGps`, no alert. A bike without
// «Combustible» set up counts and stores nothing. Plus the real ConnectionModel park path.
import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class FuelCountingTests: XCTestCase {
    @MainActor
    func testNothingCountsWhileParkedAndUnParkingAtTheSamePlaceIsNoGap() async {
        let env = FuelTestEnv()
        let id = env.bike.id
        env.setUp450MT()
        env.startCountable()
        let ride = env.rideKm(5)
        let counted = env.fuel.state(for: id).odometerKm
        XCTAssertEqual(counted, 5, accuracy: 0.05)
        // parked: the grace expired, GPS stays on, the rider takes a bus with the phone
        env.setCountable(false)
        env.rideKm(20, fromNorth: 5000)
        XCTAssertEqual(env.fuel.state(for: id).odometerKm, counted, "parked: nothing counts")
        // un-park at the anchor 30 min later (the rider walked back)
        env.advance(1800)
        env.setCountable(true)
        let back = FuelFix.track(start: env.nowMs + 1000, startNorth: 5000, metresPerFix: 0, everyMs: 1000, count: 3, speed: 0)
        env.emit(back)
        XCTAssertEqual(env.fuel.state(for: id).odometerKm, counted, accuracy: 1e-9)
        XCTAssertNil(env.fuel.current?.estimate.aged, "no gap, not aged")
        XCTAssertTrue(env.fuel.current?.estimate.isTrustworthy ?? false)
        _ = ride
    }

    @MainActor
    func testUnParkingFarAwayIsAGap() async {
        let env = FuelTestEnv()
        env.setUp450MT()
        env.startCountable()
        env.rideKm(2)
        env.setCountable(false)
        env.advance(600)
        env.setCountable(true)
        // 10 min later, 8 km away: up to ~19.8 − 8 = 11.8 km unseen → a gap (aged)
        env.emit([FuelFix.at(env.nowMs + 1000, north: 10_000, speed: 0)])
        XCTAssertEqual(env.fuel.current?.estimate.aged, .gap)
        XCTAssertGreaterThan(env.fuel.state(for: env.bike.id).odometerKm, 9.9, "the chord is added")
        XCTAssertEqual(env.storedOdometer()?.gapsMs.count, 1, "persisted at once")
        // the next refuel is stamped and clears it
        guard case let .logged(e) = env.fuel.logRefuel(RefuelInput(kind: .full, litres: 12), for: env.bike.id) else { return XCTFail() }
        XCTAssertEqual(e.unseenSincePrev, true)
        XCTAssertNil(env.fuel.current?.estimate.aged)
        XCTAssertEqual(env.fuel.current?.stats.intervals, [], "the unseen interval is not learned")
    }

    @MainActor
    func testTheRealParkPathFlipsCountingAndTheGraceStillCounts() async throws {
        let net = LinkMemoryNetwork(phoneHost: "192.168.0.2")
        let dash = LinkFakeDash(network: net, host: "192.168.0.1")
        dash.installProbeServer()
        let env = FuelTestEnv(wall: Locked(Date()), network: net, frameSource: TestFrameSource())
        var changes: [Bool] = []
        let wired = env.model.connection.onFuelCountableChange
        env.model.connection.onFuelCountableChange = { on in
            changes.append(on)
            wired?(on)
        }
        env.setUp450MT()
        env.model.connection.tuning.wifiParkGrace = 0.6
        env.model.connection.connect()
        _ = await eventually { dash.acceptedCount.current == 1 }
        let first = try await fuelStreamFromFakeDash(dash)
        _ = await eventually { env.model.connection.phase == .streaming }
        XCTAssertTrue(env.model.connection.isFuelCountable)
        XCTAssertEqual(changes.first, true)
        env.rideKm(1)
        let streamed = env.fuel.state(for: env.bike.id).odometerKm
        XCTAssertEqual(streamed, 1, accuracy: 0.05)
        // the bike Wi-Fi goes: the grace (.reconnecting) still counts
        env.h.wifi.setNetwork(.unavailable)
        first.forEach { $0() }
        _ = await eventually { env.model.connection.phase == .reconnecting }
        if env.model.connection.phase == .reconnecting {
            XCTAssertTrue(env.model.connection.isFuelCountable, "the 180 s grace counts")
            env.rideKm(0.2, fromNorth: 1000)
            XCTAssertGreaterThan(env.fuel.state(for: env.bike.id).odometerKm, streamed)
        }
        // the grace runs out: parked, not countable
        let parked = await eventually { env.model.connection.phase == .waitingForBike }
        XCTAssertTrue(parked)
        XCTAssertTrue(env.model.connection.isSessionActive)
        XCTAssertFalse(env.model.connection.isFuelCountable)
        XCTAssertEqual(changes.last, false)
        let atPark = env.fuel.state(for: env.bike.id).odometerKm
        env.rideKm(3, fromNorth: 2000)
        XCTAssertEqual(env.fuel.state(for: env.bike.id).odometerKm, atPark, "parked: nothing counts")
        XCTAssertEqual(env.storedOdometer()?.totalKm ?? -1, atPark, accuracy: 1e-9, "persisted at the park")
        env.model.connection.stop()
        _ = await eventually { !env.model.connection.isSessionActive }
        XCTAssertFalse(env.model.connection.isFuelCountable)
    }

    @MainActor
    func testApproximateLocationFreezesTheCounterAndAgesTheEstimate() async {
        let env = FuelTestEnv()
        let id = env.bike.id
        var alerts: [FuelDashAlert] = []
        env.fuel.onDashAlert = { alerts.append($0) }
        env.setUp450MT()
        // ride close to the low threshold first
        env.startCountable()
        env.rideKm(230, everyMs: 5000)
        XCTAssertEqual(env.fuel.current?.estimate.kmValue.map { $0 > 80 }, true)
        env.h.location.isPrecise = false
        // 3 min of approximate fixes (accuracy 1500 m) across the low threshold
        let blurred = FuelFix.track(start: env.nowMs + 1000, startNorth: 230_000, metresPerFix: 20, everyMs: 1000, count: 180,
                                    accuracy: 1500)
        let before = env.fuel.state(for: id).odometerKm
        env.emit(blurred)
        XCTAssertEqual(env.fuel.state(for: id).odometerKm, before, "frozen")
        XCTAssertEqual(env.fuel.current?.estimate.aged, .noGps)
        XCTAssertEqual(alerts, [], "never an alert while aged")
        // the session ends: the spell is recorded and stays after a relaunch
        env.endSession()
        XCTAssertEqual(env.storedOdometer()?.noGpsMs.count, 1)
        let again = FuelTestEnv(kv: env.kv, secrets: env.secrets, wall: env.wall)
        XCTAssertEqual(again.fuel.current?.estimate.aged, .noGps)
    }

    @MainActor
    func testAGoodFixAfterAShortSpellIsNotAged() async {
        let env = FuelTestEnv()
        env.setUp450MT()
        env.startCountable() // opens a "not measured yet" spell
        env.advance(60)
        env.emit([FuelFix.at(env.nowMs + 1000, north: 0)])
        XCTAssertNil(env.fuel.current?.estimate.aged)
        env.endSession()
        XCTAssertEqual(env.storedOdometer()?.noGpsMs, [])
    }

    @MainActor
    func testDeniedLocationAgesTheEstimateThroughTheBlindTimer() async {
        let env = FuelTestEnv()
        env.setUp450MT()
        env.h.location.permission = .denied
        env.startCountable()
        XCTAssertNil(env.fuel.current?.estimate.aged, "not yet")
        env.advance(180) // no fix for 3 min
        let aged = await eventually(timeout: 2) { env.fuel.current?.estimate.aged == .noGps }
        XCTAssertTrue(aged, "the blindAfter task rebuilt the estimate")
    }

    @MainActor
    func testABikeWithoutFuelSetUpCountsAndStoresNothing() async {
        let env = FuelTestEnv()
        let id = env.bike.id
        env.fuel.deferSetup(for: id)
        env.startCountable()
        env.rideKm(10)
        env.endSession()
        XCTAssertNil(env.kv.data(forKey: "fuel_odo_v1#\(id)"), "no counter, no rounded position")
        XCTAssertFalse(env.kv.allKeys().contains { $0.hasPrefix("fuel_odo_v1") })
        XCTAssertEqual(env.fuel.state(for: id).odometerKm, 0)
        // once set up, the next ride counts from `.started`
        env.setUp450MT()
        env.startCountable()
        let track = env.rideKm(2, fromNorth: 50_000)
        XCTAssertEqual(env.fuel.state(for: id).odometerKm, FuelFix.km(track), accuracy: 1e-6)
        XCTAssertNotNil(env.storedOdometer())
    }
}
