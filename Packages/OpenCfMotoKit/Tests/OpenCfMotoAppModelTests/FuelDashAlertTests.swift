// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: the dash alert end to end (FuelModel → RideModel): one toast + one voice line when the estimate
// crosses into low, one more at the reserve; re-armed by a refuel, restored by its undo; never while aged /
// unknown / checkRefuel; persisted across a relaunch; no dash-model field, no focus change.
import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class FuelDashAlertTests: XCTestCase {
    /// 450MT full, then a «½» level correction: 136.3 km to the reserve (57 km of riding → low).
    @MainActor
    private func halfTank(_ env: FuelTestEnv) {
        env.setUp450MT()
        _ = env.fuel.logLevel(.half, for: env.bike.id)
    }

    @MainActor
    private func lang(_ env: FuelTestEnv) -> DashLanguage { DashLanguage(rawValue: env.core.language.rawValue) ?? .en }

    @MainActor
    func testOneToastAndOneVoiceLinePerCrossing() async {
        let env = FuelTestEnv()
        halfTank(env)
        env.projectOwnUI()
        env.startCountable()
        let modelBefore = env.ride.lastModel
        let focusBefore = env.ride.ui.state.focusedId
        env.rideKm(50, everyMs: 5000)
        XCTAssertNil(env.ride.ui.state.toast, "still ok")
        XCTAssertEqual(env.h.speech.spoken, [])
        env.rideKm(8, fromNorth: 50_000, everyMs: 5000)
        guard case let .low(km)? = env.fuel.current?.estimate.state else { return XCTFail("\(String(describing: env.fuel.current?.estimate.state))") }
        let toast = env.ride.ui.state.toast ?? ""
        XCTAssertTrue(toast.hasPrefix(lang(env) == .es ? "Autonomía baja: ~" : "Low range: ~"), toast)
        XCTAssertTrue(toast.hasSuffix(lang(env) == .es ? "hasta la reserva" : "to reserve"), toast)
        XCTAssertEqual(env.h.speech.spoken.count, 1)
        XCTAssertTrue(env.h.speech.spoken[0].contains(lang(env) == .es ? "Autonomía baja." : "Low range."))
        XCTAssertLessThan(km, 80)
        XCTAssertEqual(env.kv.string(forKey: "fuel_alert_v1#\(env.bike.id)"), "low", "the latch is persisted")
        XCTAssertNil(env.ride.lastModel?.toastText, "no dash-model field")
        _ = modelBefore
        XCTAssertEqual(env.ride.ui.state.focusedId, focusBefore, "no focus change")
        // more riding in low: nothing new
        env.rideKm(30, fromNorth: 58_000, everyMs: 5000)
        XCTAssertEqual(env.h.speech.spoken.count, 1)
        // the reserve: one more (the low toast has expired by then)
        env.clock.jump(FuelAlertPolicy.toastSeconds + 1)
        env.rideKm(60, fromNorth: 88_000, everyMs: 5000)
        XCTAssertEqual(env.fuel.current?.estimate.state, .reserve)
        XCTAssertEqual(env.h.speech.spoken.count, 2)
        XCTAssertTrue(env.h.speech.spoken[1].contains(lang(env) == .es ? "Estás en reserva" : "You're on reserve"))
        let reserveToast = DashStrings.fuelToast(.reserve, range: FuelFormat.range(0, units: .metric), lang(env))
        XCTAssertEqual(env.ride.ui.state.toast, reserveToast)
        XCTAssertEqual(env.kv.string(forKey: "fuel_alert_v1#\(env.bike.id)"), "reserve")
        env.endSession()
    }

    @MainActor
    func testAnnounceFuelAddsNoDashModelFieldAndMovesNoFocus() async {
        let env = FuelTestEnv()
        env.projectOwnUI()
        env.ride.flushModel()
        let model = env.ride.lastModel
        let focus = env.ride.ui.state.focusedId
        let order = env.ride.ui.state.focusOrder
        env.ride.announceFuel(FuelDashAlert(level: .low, kmToReserve: 70))
        XCTAssertEqual(env.ride.lastModel, model)
        XCTAssertEqual(env.ride.ui.state.focusedId, focus)
        XCTAssertEqual(env.ride.ui.state.focusOrder, order)
        XCTAssertEqual(env.ride.ui.state.toast, DashStrings.fuelToast(.low, range: FuelFormat.range(70, units: .metric), lang(env)))
    }

    @MainActor
    func testVoiceOffGivesTheToastOnlyAndAMirrorSessionTheVoiceOnly() async {
        let env = FuelTestEnv()
        var prefs = env.model.settings.current.map
        prefs.voiceOn = false
        env.model.settings.setMapPreferences(prefs)
        halfTank(env)
        env.projectOwnUI()
        env.startCountable()
        env.rideKm(58, everyMs: 5000)
        XCTAssertNotNil(env.ride.ui.state.toast)
        XCTAssertEqual(env.h.speech.spoken, [], "voice off")
        env.endSession()

        let mirror = FuelTestEnv()
        halfTank(mirror)
        mirror.ride.sessionChanged(active: true, mirror: true) // a Mirror session: no own UI on the dash
        mirror.startCountable()
        mirror.rideKm(58, everyMs: 5000)
        XCTAssertNil(mirror.ride.ui.state.toast, "nothing drawn in a Mirror session")
        XCTAssertEqual(mirror.h.speech.spoken.count, 1)
        XCTAssertNil(mirror.ride.pendingFuelAlert)
    }

    @MainActor
    func testARefuelReArmsAndItsUndoRestoresTheLatch() async {
        let env = FuelTestEnv()
        env.fuel.undoWindow = 30
        halfTank(env)
        env.projectOwnUI()
        env.startCountable()
        env.rideKm(58, everyMs: 5000)
        XCTAssertEqual(env.h.speech.spoken.count, 1)
        // refuel (stopped): re-armed
        guard case .logged = env.fuel.logRefuel(RefuelInput(kind: .full, litres: 10), for: env.bike.id) else { return XCTFail() }
        XCTAssertNil(env.kv.string(forKey: "fuel_alert_v1#\(env.bike.id)"))
        // undo: the latch comes back, no repeat on the next fix
        env.fuel.undoLastRefuel()
        XCTAssertEqual(env.kv.string(forKey: "fuel_alert_v1#\(env.bike.id)"), "low")
        env.rideKm(1, fromNorth: 58_000, everyMs: 5000)
        XCTAssertEqual(env.h.speech.spoken.count, 1, "no repeat")
        // a real refuel this time: the next low crossing alerts again
        guard case .logged = env.fuel.logRefuel(RefuelInput(kind: .full, litres: 10), for: env.bike.id) else { return XCTFail() }
        env.rideKm(240, fromNorth: 59_000, everyMs: 5000)
        XCTAssertEqual(env.h.speech.spoken.count, 2)
    }

    @MainActor
    func testNoAlertWhileAgedUnknownOrCheckRefuel() async {
        // aged by a gap
        let gap = FuelTestEnv()
        halfTank(gap)
        gap.projectOwnUI()
        gap.startCountable()
        gap.rideKm(1, everyMs: 5000)
        gap.emit([FuelFix.at(gap.nowMs + 1_200_000, north: 60_000)]) // 20 min, 59 km: unseen → gap, into low
        XCTAssertEqual(gap.fuel.current?.estimate.aged, .gap)
        XCTAssertEqual(gap.h.speech.spoken, [])
        XCTAssertNil(gap.ride.pendingFuelAlert)
        // unknown: a partial without litres
        let unknown = FuelTestEnv()
        halfTank(unknown)
        _ = unknown.fuel.logRefuel(RefuelInput(kind: .partial), for: unknown.bike.id)
        unknown.projectOwnUI()
        unknown.startCountable()
        unknown.rideKm(80, everyMs: 5000)
        XCTAssertEqual(unknown.fuel.current?.estimate.state, .unknown(.partialWithoutAmount))
        XCTAssertEqual(unknown.h.speech.spoken, [])
        // checkRefuel straight away (a full long ago, far past the range): never alerts
        let check = FuelTestEnv()
        check.setUp450MT()
        check.projectOwnUI()
        check.startCountable()
        check.rideKm(400, everyMs: 5000)
        guard case .checkRefuel? = check.fuel.current?.estimate.state else { return XCTFail() }
        XCTAssertEqual(check.h.speech.spoken.count, 2, "low and reserve were crossed on the way")
        check.rideKm(50, fromNorth: 400_000, everyMs: 5000)
        XCTAssertEqual(check.h.speech.spoken.count, 2, "nothing more in checkRefuel")
    }

    @MainActor
    func testARelaunchMidLowDoesNotRepeat() async {
        let env = FuelTestEnv()
        halfTank(env)
        env.projectOwnUI()
        env.startCountable()
        env.rideKm(58, everyMs: 5000)
        XCTAssertEqual(env.h.speech.spoken.count, 1)
        env.endSession()
        let again = FuelTestEnv(kv: env.kv, secrets: env.secrets, wall: env.wall)
        again.projectOwnUI()
        again.startCountable()
        again.rideKm(5, fromNorth: 58_000, everyMs: 5000)
        guard case .low? = again.fuel.current?.estimate.state else { return XCTFail() }
        XCTAssertEqual(again.h.speech.spoken, [], "the persisted latch")
        XCTAssertNil(again.ride.ui.state.toast)
    }
}
