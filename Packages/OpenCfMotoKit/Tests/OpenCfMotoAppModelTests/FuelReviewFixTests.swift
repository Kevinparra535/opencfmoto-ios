// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: regressions for the adversarial review of the fuel branch — «¿Cargaste hace rato?» km beyond what
// the app counted (MATH-1), a blind spell open across a refuel (MATH-2), a refuel logged before the first fix
// (math ODO-1), stationary indoor sessions (wiring ODO-1), a partial larger than the tank (UI-1), the moving
// lock re-rendering (LOCK-1), and the dash alert's delivery: decided when delivered (ALERT-1), the hold
// picture (ALERT-2), session switch / removal / turning unsure while pending (ALERT-3), quiet repeats (ALERT-4).
import Foundation
import Observation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class FuelReviewFixTests: XCTestCase {
    @MainActor
    private func voice(_ env: FuelTestEnv, _ on: Bool) {
        var prefs = env.model.settings.current.map
        prefs.voiceOn = on
        env.model.settings.setMapPreferences(prefs)
    }

    @MainActor
    private func latch(_ env: FuelTestEnv) -> String? { env.kv.string(forKey: "fuel_alert_v1#\(env.bike.id)") }

    @MainActor
    private func lang(_ env: FuelTestEnv) -> DashLanguage { DashLanguage(rawValue: env.core.language.rawValue) ?? .en }

    @MainActor
    private func isFuelToast(_ env: FuelTestEnv, _ text: String?) -> Bool {
        guard let text else { return false }
        return text.hasPrefix(lang(env) == .es ? "Autonomía baja" : "Low range") || text.hasPrefix(lang(env) == .es ? "En reserva" : "On reserve")
    }

    @MainActor
    private func fuelLines(_ env: FuelTestEnv) -> [String] {
        env.h.speech.spoken.filter { $0.contains("reserve") || $0.contains("reserva") }
    }

    /// 450MT full, then «¼»: low(46.6) right away ((4.375 − 2.1) × 20.5), latch nil (an edit never alerts by itself).
    @MainActor
    private func quarterTank(_ env: FuelTestEnv) {
        env.setUp450MT()
        _ = env.fuel.logLevel(.quarter, for: env.bike.id)
        XCTAssertEqual(env.fuel.current?.estimate.kmValue ?? 0, 46.6375, accuracy: 1e-6)
        XCTAssertNil(latch(env))
    }

    // MARK: MATH-1 — «¿Cargaste hace rato?» beyond what the app counted

    @MainActor
    func testLateKmOnTheFirstRefuelAreKept() async {
        let env = FuelTestEnv()
        let id = env.bike.id
        env.setUp450MT(refuel: false) // nothing counted yet
        guard case let .logged(e) = env.fuel.logRefuel(RefuelInput(kind: .full, lateKm: 40), for: id) else {
            return XCTFail("refused")
        }
        XCTAssertEqual(e.odometerKm, 0)
        XCTAssertNil(e.unseenSincePrev, "no interval before the first entry")
        let est = env.fuel.state(for: id).estimate
        XCTAssertEqual(est.kmValue ?? 0, 275.7, accuracy: 1e-6, "315.7 − the 40 km the rider rode since")
        XCTAssertTrue(est.isTrustworthy, "the rider's own number: not aged")
        XCTAssertEqual(est.kmSinceLastEntry ?? 0, 40, accuracy: 1e-9)
        XCTAssertEqual(env.storedOdometer()?.totalKm ?? 0, 40, accuracy: 1e-9, "the raised counter is persisted")
        XCTAssertEqual(env.storedOdometer()?.gapsMs, [])
        XCTAssertEqual(FuelVerdictRule.verdict(estimate: est, routeDistanceM: 290_000), .needsRefuel(stops: 1),
                       "290 km no longer «Llegas»")
    }

    @MainActor
    func testLateKmBeyondWhatTheAppCountedSinceThePreviousFull() async {
        let env = FuelTestEnv()
        let id = env.bike.id
        env.setUp450MT() // full at 0
        env.startCountable()
        env.rideKm(30)
        env.endSession()
        guard case let .logged(e) = env.fuel.logRefuel(RefuelInput(kind: .full, litres: 15, lateKm: 50), for: id) else {
            return XCTFail("refused")
        }
        XCTAssertEqual(e.odometerKm, 0, "at the previous entry: the app saw none of the km before the refuel")
        XCTAssertEqual(e.unseenSincePrev, true, "the interval before it missed km: never learned")
        var s = env.fuel.state(for: id)
        XCTAssertEqual(s.estimate.kmValue ?? 0, 265.7, accuracy: 1e-6)
        XCTAssertNil(s.estimate.aged)
        XCTAssertEqual(s.odometerKm, 50, accuracy: 1e-9)
        // the next full-to-full interval is learned from the true km since the refuel
        env.startCountable()
        env.rideKm(250, fromNorth: 30_000, everyMs: 5000)
        env.endSession()
        guard case .logged = env.fuel.logRefuel(RefuelInput(kind: .full, litres: 15), for: id) else { return XCTFail() }
        s = env.fuel.state(for: id)
        XCTAssertEqual(s.stats.learnedIntervalCount, 1)
        XCTAssertEqual(s.stats.learnedKmPerL ?? 0, 20.0, accuracy: 0.05, "300 km / 15 L")
    }

    @MainActor
    func testLateKmWithinWhatTheAppCountedRaiseNothing() async {
        let env = FuelTestEnv()
        let id = env.bike.id
        env.setUp450MT()
        env.startCountable()
        let track = env.rideKm(100, everyMs: 5000)
        env.endSession()
        guard case let .logged(e) = env.fuel.logRefuel(RefuelInput(kind: .full, litres: 5, lateKm: 50), for: id) else {
            return XCTFail()
        }
        XCTAssertEqual(e.odometerKm, FuelFix.km(track) - 50, accuracy: 1e-6)
        XCTAssertNil(e.unseenSincePrev)
        XCTAssertEqual(env.fuel.state(for: id).odometerKm, FuelFix.km(track), accuracy: 1e-6, "not raised")
        XCTAssertEqual(env.fuel.state(for: id).estimate.kmValue ?? 0, 265.7, accuracy: 1e-6)
    }

    // MARK: MATH-2 — a blind spell open across a refuel

    @MainActor
    private func blindRefuel(_ env: FuelTestEnv) {
        env.setUp450MT()
        env.startCountable()
        env.rideKm(1)
        env.h.location.isPrecise = false // approximate location: every fix ~1500 m off
        let t = env.nowMs
        env.emit((1 ... 60).map { FuelFix.at(t + Int64($0) * 60_000, north: 1000 + Double($0) * 500, accuracy: 1500) })
        XCTAssertEqual(env.fuel.current?.estimate.aged, .noGps)
        guard case .logged = env.fuel.logRefuel(RefuelInput(kind: .full, litres: 12), for: env.bike.id) else {
            return XCTFail("refused")
        }
        XCTAssertNil(env.fuel.current?.estimate.aged, "a fresh tank: the spell was split at the refuel")
    }

    @MainActor
    func testABlindSpellAcrossARefuelAgesTheNewTankByItsOwnBlindTime() async {
        let env = FuelTestEnv()
        blindRefuel(env)
        // 150 min more without a usable fix, then the session ends
        let t = env.nowMs
        env.emit((1 ... 150).map { FuelFix.at(t + Int64($0) * 60_000, north: 31_000 + Double($0) * 1000, accuracy: 1500) })
        XCTAssertEqual(env.fuel.current?.estimate.aged, .noGps, "live")
        env.endSession()
        XCTAssertEqual(env.fuel.current?.estimate.aged, .noGps, "after the stream too (was trustworthy before MATH-2)")
        XCTAssertEqual(env.storedOdometer()?.noGpsMs.count, 2, "the hour before the refuel + the 150 min after it")
        let route = FuelVerdictRule.verdict(estimate: env.fuel.current!.estimate, routeDistanceM: 280_000)
        XCTAssertEqual(route, .unknown(.aged), "never «Llegas» on a tank the app could not measure")
        guard case let .logged(next) = env.fuel.logRefuel(RefuelInput(kind: .full, litres: 12), for: env.bike.id) else {
            return XCTFail()
        }
        XCTAssertEqual(next.unseenSincePrev, true, "the next refuel is stamped")
    }

    @MainActor
    func testABlindSpellEndingRightAfterTheRefuelLeavesTheNewTankTrustworthy() async {
        let env = FuelTestEnv()
        blindRefuel(env)
        env.advance(60)
        env.endSession()
        XCTAssertNil(env.fuel.current?.estimate.aged)
        XCTAssertEqual(env.storedOdometer()?.noGpsMs.count, 1, "only the hour before the refuel")
        XCTAssertNil(env.storedOdometer()?.openBlindSinceMs)
    }

    // MARK: math ODO-1 — a refuel logged before the stream's first fix

    @MainActor
    private func homeThenPump(_ env: FuelTestEnv, logToFixSeconds: TimeInterval) -> RefuelEntry? {
        env.setUp450MT() // F0 at 0
        env.startCountable()
        env.rideKm(5) // the anchor: home, 5 km north
        env.endSession()
        env.advance(90 * 60) // rode 60 km to the pump without the app
        guard case let .logged(f1) = env.fuel.logRefuel(RefuelInput(kind: .full, litres: 14), for: env.bike.id) else {
            XCTFail("refused")
            return nil
        }
        env.advance(logToFixSeconds)
        env.startCountable() // Connect after logging
        env.emit([FuelFix.at(env.nowMs + 1000, north: 65_000)])
        return f1
    }

    @MainActor
    func testARefuelLoggedBeforeConnectingTakesTheUnseenRideBeforeIt() async {
        let env = FuelTestEnv()
        guard let f1 = homeThenPump(env, logToFixSeconds: 120) else { return }
        let s = env.fuel.state(for: env.bike.id)
        XCTAssertEqual(s.log.last?.id, f1.id)
        XCTAssertEqual(s.estimate.kmValue ?? 0, 315.7, accuracy: 1e-6, "a full tank at the pump")
        XCTAssertNil(s.estimate.aged, "the ride to the pump was before the refuel")
        XCTAssertEqual(s.log.last?.unseenSincePrev, true, "the tank before it is not learned")
        XCTAssertEqual(s.log.last?.odometerKm ?? 0, s.odometerKm, accuracy: 1e-9)
        XCTAssertEqual(env.storedOdometer()?.gapsMs, [])
        let stored = env.kv.data(forKey: "fuel_log_v1#\(env.bike.id)").flatMap { try? JSONDecoder().decode(RefuelLog.self, from: $0) }
        XCTAssertEqual(stored?.entries.last?.unseenSincePrev, true, "persisted")
    }

    @MainActor
    func testTheSameResumeLongAfterTheLogStaysInTheNewTank() async {
        let env = FuelTestEnv()
        guard homeThenPump(env, logToFixSeconds: 30 * 60) != nil else { return }
        let s = env.fuel.state(for: env.bike.id)
        XCTAssertEqual(s.estimate.aged, .gap, "the rider may have ridden after logging: aged, the safe side")
        XCTAssertLessThan(s.estimate.kmValue ?? 999, 315.7 - 50)
        XCTAssertNil(s.log.last?.unseenSincePrev)
    }

    // MARK: wiring ODO-1 — a session that could not measure but missed nothing

    @MainActor
    func testAStationaryIndoorSessionDoesNotAgeTheTank() async {
        let env = FuelTestEnv()
        env.setUp450MT()
        _ = env.fuel.logLevel(.half, for: env.bike.id)
        env.projectOwnUI()
        env.startCountable()
        env.rideKm(1)
        env.endSession()
        env.advance(3600)
        env.startCountable() // indoors: 3 min of 80 m fixes at the same spot, then Stop
        let t0 = env.nowMs
        env.emit((0 ..< 36).map { FuelFix.at(t0 + Int64($0) * 5000, north: 1000, speed: 0, accuracy: 80) })
        XCTAssertEqual(env.fuel.current?.estimate.aged, .noGps, "live: the app cannot measure right now")
        env.endSession()
        XCTAssertNil(env.fuel.current?.estimate.aged, "nothing was missed: the tank stays trustworthy")
        XCTAssertEqual(env.storedOdometer()?.noGpsMs, [])
        // the next ride alerts as usual
        env.advance(86_400)
        env.startCountable()
        env.rideKm(60, fromNorth: 1000, everyMs: 5000)
        guard case .low? = env.fuel.current?.estimate.state else { return XCTFail("\(String(describing: env.fuel.current?.estimate.state))") }
        XCTAssertEqual(latch(env), "low")
        XCTAssertEqual(fuelLines(env).count, 1)
        env.endSession()
    }

    @MainActor
    func testArrivingIntoAnUndergroundGarageDoesNotAgeTheTank() async {
        let env = FuelTestEnv()
        env.setUp450MT()
        env.startCountable()
        env.rideKm(10)
        let t0 = env.nowMs
        var fixes = [FuelFix.at(t0 + 1000, north: 10_030, speed: 3, accuracy: 65)]
        fixes += (1 ... 40).map { FuelFix.at(t0 + 1000 + Int64($0) * 5000, north: 10_040, speed: nil, accuracy: 65) }
        env.emit(fixes) // through the 180 s Wi-Fi grace
        env.setCountable(false) // parked
        XCTAssertNil(env.fuel.current?.estimate.aged)
        XCTAssertEqual(env.storedOdometer()?.noGpsMs, [])
        env.endSession()
    }

    @MainActor
    func testSpellsWithSignsOfMissedKmStillAge() async {
        // approximate location, standing still
        let approx = FuelTestEnv()
        approx.setUp450MT()
        approx.startCountable()
        approx.rideKm(1)
        approx.h.location.isPrecise = false
        let t = approx.nowMs
        approx.emit((1 ... 36).map { FuelFix.at(t + Int64($0) * 5000, north: 1000, speed: 0, accuracy: 1500) })
        approx.endSession()
        XCTAssertEqual(approx.fuel.current?.estimate.aged, .noGps, "approximate location")
        // inaccurate fixes drifting 2 km from the last good one
        let drift = FuelTestEnv()
        drift.setUp450MT()
        drift.startCountable()
        drift.rideKm(1)
        let t2 = drift.nowMs
        drift.emit((1 ... 36).map { FuelFix.at(t2 + Int64($0) * 5000, north: 1000 + Double($0) * 60, speed: 12, accuracy: 80) })
        drift.endSession()
        XCTAssertEqual(drift.fuel.current?.estimate.aged, .noGps, "the fixes strayed")
        // no fix at all for 3 min (a dead GPS)
        let dead = FuelTestEnv()
        dead.setUp450MT()
        dead.startCountable()
        dead.rideKm(1)
        dead.endSession()
        dead.advance(3600)
        dead.startCountable()
        dead.advance(180)
        dead.endSession()
        XCTAssertEqual(dead.fuel.current?.estimate.aged, .noGps, "no fix at all")
        // a spell left open in storage (relaunch: no evidence in memory) is recorded as before
        let opened = FuelTestEnv()
        opened.setUp450MT()
        opened.startCountable()
        opened.rideKm(1)
        let t3 = opened.nowMs
        opened.emit((1 ... 30).map { FuelFix.at(t3 + Int64($0) * 5000, north: 1000, speed: 0, accuracy: 80) })
        opened.fuel.scenePhaseChanged(.background)
        XCTAssertNotNil(opened.storedOdometer()?.openBlindSinceMs)
        let again = FuelTestEnv(kv: opened.kv, secrets: opened.secrets, wall: opened.wall)
        again.startCountable()
        again.endSession()
        XCTAssertEqual(again.fuel.current?.estimate.aged, .noGps, "unknown evidence after a relaunch: recorded")
    }

    // MARK: UI-1 — a partial larger than the tank

    @MainActor
    func testAPartialLargerThanTheTankIsRefused() async {
        let env = FuelTestEnv()
        let id = env.bike.id
        env.setUp450MT() // 17.5 L
        env.startCountable()
        env.rideKm(300, everyMs: 5000)
        env.endSession()
        let count = env.fuel.state(for: id).log.count
        XCTAssertEqual(env.fuel.logRefuel(RefuelInput(kind: .partial, litres: 18.93), for: id), .invalid(.litres), "5 gal typed as L")
        XCTAssertEqual(env.fuel.logRefuel(RefuelInput(kind: .partial, litres: 50), for: id), .invalid(.litres), "a missed comma")
        XCTAssertEqual(env.fuel.state(for: id).log.count, count, "nothing logged")
        XCTAssertEqual(FuelModel.maxFillOverTank, 1.05)
        guard case .logged = env.fuel.logRefuel(RefuelInput(kind: .partial, litres: 17.5 * 1.05), for: id) else {
            return XCTFail("up to 5 % over the rated tank is still accepted (a brimmed filler neck)")
        }
        guard case .logged = env.fuel.logRefuel(RefuelInput(kind: .full, litres: 30), for: id) else {
            return XCTFail("a full fill's range is the tank either way")
        }
    }

    // MARK: UI-3 — «Corregir nivel ▸ Reserva»

    @MainActor
    func testAReserveLevelCorrectionReadsReserve() async {
        let env = FuelTestEnv()
        env.setUp450MT()
        guard case .logged = env.fuel.logLevel(.reserve, for: env.bike.id) else { return XCTFail() }
        XCTAssertEqual(env.fuel.current?.estimate.state, .reserve)
        XCTAssertEqual(FuelVerdictRule.verdict(estimate: env.fuel.current!.estimate, routeDistanceM: 15_000), .needsRefuel(stops: 1))
    }

    // MARK: LOCK-1 — the moving lock lifts observably

    @MainActor
    func testTheMovingLockLiftsObservablyWhenTheGPSStopsOnAFastFix() async {
        let env = FuelTestEnv()
        env.fuel.lockRecheckAfter = 0.05
        env.fuel.lastFixProvider = { [weak ride = env.ride] in ride?.lastFix }
        env.h.location.emit(LocationFix(lat: 4.6, lon: -74.08, speedMps: 8.3, accuracyM: 5, timeMs: env.nowMs))
        XCTAssertFalse(env.fuel.canLogNow, "moving")
        let changed = Locked(false)
        withObservationTracking { _ = env.fuel.canLogNow } onChange: { changed.set(true) }
        env.advance(11) // no newer fix: the GPS stopped
        let fired = await eventually(timeout: 2) { changed.current }
        XCTAssertTrue(fired, "SwiftUI re-renders the card")
        XCTAssertTrue(env.fuel.canLogNow)
    }

    // MARK: ALERT-1 — the toast channel is decided when delivered

    @MainActor
    func testAnAlertFiredBeforeTheDashIsLiveIsShownOnceItIs() async {
        let env = FuelTestEnv()
        voice(env, false)
        quarterTank(env)
        env.ride.sessionChanged(active: true, mirror: false)
        env.ride.linkPhaseChanged(.joiningWifi)
        env.startCountable()
        let lines = await FuelTestEnv.captureLog {
            env.rideKm(0.2)
            XCTAssertNotNil(env.ride.pendingFuelAlert, "waits for the dash")
            XCTAssertNil(env.ride.ui.state.toast)
            XCTAssertEqual(self.latch(env), "low")
            env.ride.linkPhaseChanged(.linking)
            env.ride.retryPendingFuelAlert(now: env.clock.now())
            XCTAssertNil(env.ride.ui.state.toast, "linking: frames do not reach the dash")
            env.ride.linkPhaseChanged(.streaming)
            env.ride.projectionChanged(active: true)
            _ = await eventually(timeout: 2) { self.isFuelToast(env, env.ride.ui.state.toast) }
            env.rideKm(3, fromNorth: 200)
        }
        XCTAssertEqual(lines.filter { $0.contains("fuel alert shown on the dash") }.count, 1, "exactly one toast")
        XCTAssertTrue(lines.contains { $0.contains("fuel alert waiting: dash not live") })
        XCTAssertNil(env.ride.pendingFuelAlert)
        env.endSession()
    }

    @MainActor
    func testWithVoiceOnItIsSpokenAtOnceAndTheToastFollows() async {
        let env = FuelTestEnv()
        voice(env, true)
        quarterTank(env)
        env.ride.sessionChanged(active: true, mirror: false)
        env.ride.linkPhaseChanged(.linking)
        env.startCountable()
        env.rideKm(0.2)
        XCTAssertEqual(fuelLines(env).count, 1, "spoken while linking")
        XCTAssertNotNil(env.ride.pendingFuelAlert, "the toast still waits")
        env.ride.linkPhaseChanged(.streaming)
        env.ride.projectionChanged(active: true)
        let shown = await eventually(timeout: 2) { self.isFuelToast(env, env.ride.ui.state.toast) }
        XCTAssertTrue(shown)
        XCTAssertEqual(fuelLines(env).count, 1, "spoken once")
        env.endSession()
    }

    @MainActor
    func testAReconnectingLinkHoldsTheToast() async {
        let env = FuelTestEnv()
        voice(env, false)
        env.projectOwnUI()
        env.ride.linkPhaseChanged(.reconnecting) // a Wi-Fi blip: still projecting, frames not reaching the dash
        env.ride.announceFuel(FuelDashAlert(level: .low, kmToReserve: 70))
        XCTAssertNil(env.ride.ui.state.toast)
        XCTAssertNotNil(env.ride.pendingFuelAlert)
        env.ride.linkPhaseChanged(.streaming)
        let shown = await eventually(timeout: 2) { self.isFuelToast(env, env.ride.ui.state.toast) }
        XCTAssertTrue(shown)
    }

    @MainActor
    func testNoDashFor61SecondsWithVoiceOffDropsAndRetriesOnceStreaming() async {
        let env = FuelTestEnv()
        voice(env, false)
        quarterTank(env)
        env.ride.sessionChanged(active: true, mirror: false)
        env.ride.linkPhaseChanged(.linking)
        env.startCountable()
        env.rideKm(0.2)
        XCTAssertNotNil(env.ride.pendingFuelAlert)
        env.clock.jump(61)
        env.ride.retryPendingFuelAlert(now: env.clock.now())
        XCTAssertNil(env.ride.pendingFuelAlert, "dropped")
        XCTAssertNil(latch(env), "latch restored")
        env.ride.linkPhaseChanged(.streaming)
        env.ride.projectionChanged(active: true)
        env.rideKm(0.2, fromNorth: 200)
        let shown = await eventually(timeout: 2) { self.isFuelToast(env, env.ride.ui.state.toast) }
        XCTAssertTrue(shown, "the first fix after streaming fires again: one toast")
        XCTAssertEqual(latch(env), "low")
        env.endSession()
    }

    @MainActor
    func testAnAlertDroppedAtSessionEndIsShownInTheNextSession() async {
        let env = FuelTestEnv()
        voice(env, false)
        env.setUp450MT()
        _ = env.fuel.logLevel(.half, for: env.bike.id)
        env.projectOwnUI()
        env.ride.flushModel()
        _ = env.ride.ui.handle(.key(.home), now: env.clock.now()) // the menu holds the toast
        env.startCountable()
        env.rideKm(58, everyMs: 5000)
        XCTAssertNotNil(env.ride.pendingFuelAlert)
        env.ride.projectionChanged(active: false)
        env.ride.sessionChanged(active: false, mirror: false)
        env.endSession()
        XCTAssertNil(latch(env), "restored for the next session")
        _ = env.ride.ui.perform(.closeSheets, now: env.clock.now())
        env.advance(3600)
        env.ride.sessionChanged(active: true, mirror: false)
        env.ride.linkPhaseChanged(.joiningWifi)
        env.startCountable()
        env.rideKm(0.2, fromNorth: 58_000)
        XCTAssertNotNil(env.ride.pendingFuelAlert, "fired by the first fixes, before the dash is live")
        env.ride.linkPhaseChanged(.streaming)
        env.ride.projectionChanged(active: true)
        let shown = await eventually(timeout: 2) { self.isFuelToast(env, env.ride.ui.state.toast) }
        XCTAssertTrue(shown)
        env.endSession()
    }

    // MARK: ALERT-2 — the hold picture (locked phone)

    @MainActor
    func testTheHoldPictureHoldsTheToastAndTheVoiceStillSpeaks() async {
        for voiceOn in [false, true] {
            let env = FuelTestEnv()
            voice(env, voiceOn)
            env.setUp450MT()
            _ = env.fuel.logLevel(.half, for: env.bike.id)
            env.projectOwnUI()
            env.startCountable()
            env.rideKm(50, everyMs: 5000)
            env.h.projection.enterBackground() // locked: the dash shows the hold picture
            XCTAssertTrue(env.ride.dashShowsHoldPicture)
            env.rideKm(8, fromNorth: 50_000, everyMs: 5000)
            guard case .low? = env.fuel.current?.estimate.state else { return XCTFail() }
            XCTAssertNil(env.ride.ui.state.toast, "voice \(voiceOn): never into a controller the dash does not show")
            XCTAssertNotNil(env.ride.pendingFuelAlert)
            XCTAssertEqual(fuelLines(env).count, voiceOn ? 1 : 0, "spoken while held")
            env.h.projection.enterForeground()
            let shown = await eventually(timeout: 2) { self.isFuelToast(env, env.ride.ui.state.toast) }
            XCTAssertTrue(shown, "unlocked within 60 s: exactly one toast")
            env.endSession()
        }
    }

    // MARK: ALERT-3 — the pending slot follows its session, bike and trust

    /// Crosses into low with the toast blocked (a long navigation toast) and the voice busy.
    @MainActor
    private func pendingLow(_ env: FuelTestEnv) {
        env.setUp450MT()
        _ = env.fuel.logLevel(.half, for: env.bike.id)
        env.projectOwnUI()
        env.startCountable()
        env.rideKm(50, everyMs: 5000)
        env.ride.ui.showToast("Route · 12 km", now: env.clock.now(), duration: 30)
        env.rideKm(8, fromNorth: 50_000, everyMs: 5000)
        XCTAssertNotNil(env.ride.pendingFuelAlert)
        XCTAssertEqual(latch(env), "low")
    }

    @MainActor
    func testAHardSessionSwitchDropsThePendingAlertAndRestoresTheLatch() async {
        let env = FuelTestEnv()
        env.h.speech.isSpeaking = true
        pendingLow(env)
        env.ride.projectionChanged(active: false)
        env.ride.sessionChanged(active: true, mirror: true) // Mirror tapped while Connect runs
        XCTAssertNil(env.ride.pendingFuelAlert)
        XCTAssertNil(latch(env), "the old bike's latch is restored")
    }

    @MainActor
    func testRemovingTheBikeCancelsItsPendingAlert() async {
        let env = FuelTestEnv()
        env.h.speech.isSpeaking = true
        pendingLow(env)
        env.endSession()
        env.model.garage.remove(env.bike.id)
        XCTAssertNil(env.ride.pendingFuelAlert)
    }

    @MainActor
    func testAPendingAlertThatTurnsUnsureIsNotShownAndFiresOnceTrustworthyAgain() async {
        let env = FuelTestEnv()
        voice(env, false)
        pendingLow(env)
        // 3 min of inaccurate fixes: the estimate turns aged noGps while the alert waits
        let t0 = env.nowMs
        env.emit((1 ... 40).map { FuelFix.at(t0 + Int64($0) * 5000, north: 58_000, speed: 10, accuracy: 80) })
        XCTAssertEqual(env.fuel.current?.estimate.aged, .noGps)
        XCTAssertNil(env.ride.pendingFuelAlert, "never shown on an unsure number")
        XCTAssertNil(latch(env), "nothing was delivered: restored")
        env.clock.jump(31) // the navigation toast expires
        env.ride.retryPendingFuelAlert(now: env.clock.now())
        XCTAssertFalse(isFuelToast(env, env.ride.ui.state.toast))
        // a good fix: trustworthy again → fires once
        let lines = await FuelTestEnv.captureLog {
            env.emit([FuelFix.at(env.nowMs + 1000, north: 58_100, speed: 10)])
            _ = await eventually(timeout: 2) { self.isFuelToast(env, env.ride.ui.state.toast) }
            env.rideKm(2, fromNorth: 58_100, everyMs: 5000)
        }
        XCTAssertTrue(isFuelToast(env, env.ride.ui.state.toast))
        XCTAssertEqual(lines.filter { $0.contains("fuel alert shown on the dash") }.count, 1)
        XCTAssertEqual(latch(env), "low")
        env.endSession()
    }

    @MainActor
    func testAnAlertDeliveredAndThenAgedDoesNotFireAgain() async {
        let env = FuelTestEnv()
        voice(env, true)
        env.setUp450MT()
        _ = env.fuel.logLevel(.half, for: env.bike.id)
        env.projectOwnUI()
        env.startCountable()
        env.rideKm(58, everyMs: 5000)
        XCTAssertEqual(fuelLines(env).count, 1)
        let t0 = env.nowMs
        env.emit((1 ... 40).map { FuelFix.at(t0 + Int64($0) * 5000, north: 58_000, speed: 10, accuracy: 80) })
        XCTAssertEqual(env.fuel.current?.estimate.aged, .noGps)
        env.emit([FuelFix.at(env.nowMs + 1000, north: 58_100, speed: 10)])
        env.rideKm(2, fromNorth: 58_100, everyMs: 5000)
        XCTAssertNil(env.fuel.current?.estimate.aged)
        XCTAssertEqual(fuelLines(env).count, 1, "once per crossing")
        XCTAssertEqual(latch(env), "low")
        env.endSession()
    }

    // MARK: ALERT-4 — a blocker that lasts is not logged every minute

    @MainActor
    func testAPersistentBlockerLogsOnceAndShowsOneToastWhenItCloses() async {
        let env = FuelTestEnv()
        voice(env, false)
        env.setUp450MT()
        _ = env.fuel.logLevel(.half, for: env.bike.id)
        env.projectOwnUI()
        env.startCountable()
        env.rideKm(50, everyMs: 5000)
        env.ride.flushModel()
        _ = env.ride.ui.perform(.openSearch, now: env.clock.now())
        XCTAssertEqual(env.ride.ui.state.sheet, .search)
        var north = 50_000.0
        let lines = await FuelTestEnv.captureLog {
            env.rideKm(8, fromNorth: north, everyMs: 5000)
            north += 8000
            for _ in 0 ..< 5 { // 5 min with the search sheet open
                env.clock.jump(61)
                env.ride.retryPendingFuelAlert(now: env.clock.now())
                env.rideKm(0.5, fromNorth: north, everyMs: 5000)
                north += 500
            }
            XCTAssertEqual(env.ride.ui.state.sheet, .search)
            _ = env.ride.ui.perform(.closeSheets, now: env.clock.now())
            _ = await eventually(timeout: 2) { self.isFuelToast(env, env.ride.ui.state.toast) }
        }
        XCTAssertLessThanOrEqual(lines.filter { $0.hasPrefix("fuel: alert: ") }.count, 1, lines.joined(separator: "\n"))
        XCTAssertLessThanOrEqual(lines.filter { $0.contains("RIDE: fuel alert waiting") }.count, 1)
        XCTAssertLessThanOrEqual(lines.filter { $0.contains("RIDE: fuel alert dropped") }.count, 1)
        XCTAssertLessThanOrEqual(lines.filter { $0.hasPrefix("fuel: alert dropped") }.count, 1)
        XCTAssertEqual(lines.filter { $0.contains("fuel alert shown on the dash") }.count, 1, "one toast once it closes")
        XCTAssertTrue(isFuelToast(env, env.ride.ui.state.toast))
        env.endSession()
    }
}
