// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: the km counter feed — RideModel's fixes count for the session's bike while countable, with trip
// logging off, without touching TripsModel's recorder closures; persisted every 15 s of fix time and on the
// stream's end; a relaunch keeps the total and never counts a re-delivered fix twice; two bikes never mix.
import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class FuelOdometerFeedTests: XCTestCase {
    @MainActor
    func testFixesOfACountableSessionCountForItsBikeWithTripLoggingOff() async {
        let env = FuelTestEnv()
        _ = env.core.settings.update(forBike: env.bike.id) { $0.logTrips = false }
        env.setUp450MT()
        // no session: nothing
        env.rideKm(1)
        XCTAssertEqual(env.fuel.state(for: env.bike.id).odometerKm, 0)
        env.startCountable()
        let track = env.rideKm(5, fromNorth: 2000)
        XCTAssertEqual(env.fuel.state(for: env.bike.id).odometerKm, FuelFix.km(track), accuracy: 1e-6)
        XCTAssertFalse(env.core.tripRecorder.isRecording, "no trip recording involved")
        XCTAssertEqual(env.fuel.current?.estimate.kmSinceAnchor ?? 0, FuelFix.km(track), accuracy: 1e-6)
    }

    @MainActor
    func testTheSessionBikeKeepsTheKmWhenTheSelectionChanges() async {
        let env = FuelTestEnv()
        let a = env.bike.id
        let b = env.addOtherBike().id
        env.setUp450MT(a)
        env.setUp450MT(b)
        env.startCountable(a)
        env.model.garage.select(b)
        env.rideKm(2)
        XCTAssertEqual(env.fuel.state(for: a).odometerKm, 2, accuracy: 0.05)
        XCTAssertEqual(env.fuel.state(for: b).odometerKm, 0, "the selection does not move km")
        // a new session for B: A's stream ends and is persisted, B counts
        env.endSession()
        XCTAssertEqual(env.storedOdometer(a)?.totalKm ?? 0, env.fuel.state(for: a).odometerKm, accuracy: 1e-9)
        env.startCountable(b)
        env.rideKm(3, fromNorth: 10_000)
        XCTAssertEqual(env.fuel.state(for: a).odometerKm, 2, accuracy: 0.05)
        XCTAssertEqual(env.fuel.state(for: b).odometerKm, 3, accuracy: 0.05)
        // a session bike switch without an end (the provider changes): A's stream ends first
        env.sessionBike = a
        env.rideKm(1, fromNorth: 30_000)
        XCTAssertEqual(env.fuel.state(for: b).odometerKm, 3, accuracy: 0.05, "two bikes never mix")
        XCTAssertGreaterThan(env.fuel.state(for: a).odometerKm, 2)
    }

    @MainActor
    func testPersistCadenceAndStreamEnds() async {
        let env = FuelTestEnv()
        let id = env.bike.id
        env.setUp450MT()
        env.startCountable()
        let start = env.storedOdometer()?.totalKm ?? -1
        XCTAssertEqual(start, 0)
        // 10 s of riding: not yet persisted (15 s of fix time)
        let t0 = env.nowMs + 1000
        let first = FuelFix.track(start: t0, metresPerFix: 20, everyMs: 1000, count: 11)
        env.emit(first)
        let after10 = env.storedOdometer()?.totalKm ?? -1
        XCTAssertLessThan(after10, env.fuel.state(for: id).odometerKm, "not every fix is written")
        // past 15 s: written
        env.emit(FuelFix.track(start: t0 + 11_000, startNorth: 220, metresPerFix: 20, everyMs: 1000, count: 10))
        XCTAssertGreaterThan(env.storedOdometer()?.totalKm ?? 0, after10)
        // session end → written exactly
        env.emit(FuelFix.track(start: t0 + 21_000, startNorth: 420, metresPerFix: 20, everyMs: 1000, count: 3))
        env.endSession()
        XCTAssertEqual(env.storedOdometer()?.totalKm ?? -1, env.fuel.state(for: id).odometerKm, accuracy: 1e-9)
        // countableChanged(false) → written; scene background → written
        env.startCountable()
        env.emit(FuelFix.track(start: env.nowMs + 1000, startNorth: 500, metresPerFix: 20, everyMs: 1000, count: 3))
        env.setCountable(false)
        XCTAssertEqual(env.storedOdometer()?.totalKm ?? -1, env.fuel.state(for: id).odometerKm, accuracy: 1e-9)
        env.setCountable(true)
        env.emit(FuelFix.track(start: env.nowMs + 1000, startNorth: 560, metresPerFix: 20, everyMs: 1000, count: 3))
        XCTAssertNotEqual(env.storedOdometer()?.totalKm ?? -1, env.fuel.state(for: id).odometerKm, accuracy: 1e-9)
        env.model.scenePhaseChanged(.background)
        XCTAssertEqual(env.storedOdometer()?.totalKm ?? -1, env.fuel.state(for: id).odometerKm, accuracy: 1e-9)
    }

    @MainActor
    func testARelaunchKeepsTheTotalAndNeverCountsAReDeliveredFixTwice() async {
        let env = FuelTestEnv()
        env.setUp450MT()
        env.startCountable()
        let track = env.rideKm(4)
        env.endSession()
        let total = env.fuel.state(for: env.bike.id).odometerKm
        let again = FuelTestEnv(kv: env.kv, secrets: env.secrets, wall: env.wall)
        XCTAssertEqual(again.fuel.state(for: env.bike.id).odometerKm, total, accuracy: 1e-9)
        again.startCountable()
        again.emit(Array(track.suffix(20))) // iOS re-delivers cached fixes
        XCTAssertEqual(again.fuel.state(for: env.bike.id).odometerKm, total, accuracy: 1e-9, "no double count")
        again.rideKm(1, fromNorth: track.last.map { ($0.lat - FuelFix.baseLat) * FuelFix.mPerDegLat } ?? 0)
        XCTAssertEqual(again.fuel.state(for: env.bike.id).odometerKm, total + 1, accuracy: 0.1)
    }

    @MainActor
    func testTripsModelStillGetsItsStatsAndTripsWhileTheCounterCounts() async {
        let env = FuelTestEnv()
        env.setUp450MT()
        env.startCountable()
        env.model.trips.startRecording()
        XCTAssertTrue(env.model.trips.isManualRecording)
        let track = env.rideKm(0.6)
        let live = await eventually { env.model.trips.live.distanceMeters > 500 }
        XCTAssertTrue(live, "TripsModel's live stats (its recorder closures intact)")
        XCTAssertEqual(env.fuel.state(for: env.bike.id).odometerKm, FuelFix.km(track), accuracy: 1e-6)
        env.model.trips.stopRecording()
        let saved = await eventually { !env.model.trips.sections.isEmpty }
        XCTAssertTrue(saved, "the trip is saved")
    }
}
