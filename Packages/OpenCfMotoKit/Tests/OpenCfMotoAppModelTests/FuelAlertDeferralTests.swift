// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP (dash safety rule 7 for the fuel path): the fuel alert never draws over a card, a sheet, the
// arrival card, a preview, the hold picture or another toast, and never starts its voice line over speech or a
// near turn cue; it waits in one slot, up to 60 s, then is dropped and its latch restored.
import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class FuelAlertDeferralTests: XCTestCase {
    private let alert = FuelDashAlert(level: .low, kmToReserve: 70)

    @MainActor
    private func lang(_ env: FuelTestEnv) -> DashLanguage { DashLanguage(rawValue: env.core.language.rawValue) ?? .en }

    @MainActor
    private func toastText(_ env: FuelTestEnv, _ a: FuelDashAlert = FuelDashAlert(level: .low, kmToReserve: 70)) -> String {
        DashStrings.fuelToast(a.level, range: FuelFormat.range(a.kmToReserve, units: .metric), lang(env))
    }

    @MainActor
    private func drawsAToast(_ env: FuelTestEnv) -> Bool {
        env.ride.ui.displayList(now: env.clock.now()).commands.contains {
            if case let .fill(_, color, _) = $0 { return color == DashPalette.toastFill }
            return false
        }
    }

    /// An own-UI session navigating a beeline (routing answers 503): the End confirm card is reachable.
    @MainActor
    private func navigating(_ env: FuelTestEnv) async {
        env.projectOwnUI()
        env.core.navigation.updateLocation(FuelFix.at(env.nowMs, north: 0, speed: 0))
        env.model.navigation.navigate(to: Place(name: "Destino", lat: 4.7, lon: -74.08, category: "city"))
        await env.core.navigation.waitUntilIdle()
        _ = await eventually(timeout: 4) { env.ride.lastModel?.navigating == true }
    }

    // MARK: Toast channel

    @MainActor
    private func fuelLines(_ env: FuelTestEnv) -> [String] {
        env.h.speech.spoken.filter { $0.contains("reserve") || $0.contains("reserva") }
    }

    @MainActor
    func testTheConfirmCardHoldsTheToastUntilItCloses() async {
        let env = FuelTestEnv()
        await navigating(env)
        XCTAssertEqual(env.ride.lastModel?.navigating, true)
        // the navigation's own toasts ("Route · …") expire first
        env.clock.jump(3)
        _ = env.ride.ui.displayList(now: env.clock.now())
        XCTAssertNil(env.ride.ui.state.toast)
        env.h.speech.isSpeaking = true // keep the slot open on the voice side too
        _ = env.ride.ui.perform(.endNavigation, now: env.clock.now())
        XCTAssertEqual(env.ride.ui.state.sheet, .confirm)
        env.ride.announceFuel(alert)
        for _ in 0 ..< 5 {
            await settle(0.03)
            XCTAssertNotEqual(env.ride.ui.state.toast, toastText(env))
            XCTAssertFalse(drawsAToast(env), "no toast fill while the confirm card is open")
        }
        XCTAssertNotNil(env.ride.pendingFuelAlert)
        // «Seguir» (BACK) closes the card: exactly one fuel toast
        _ = env.ride.ui.handle(.key(.back), now: env.clock.now())
        XCTAssertEqual(env.ride.ui.state.sheet, DashSheet.none)
        let shown = await eventually(timeout: 2) { env.ride.ui.state.toast == self.toastText(env) }
        XCTAssertTrue(shown)
        XCTAssertTrue(drawsAToast(env))
        XCTAssertEqual(env.ride.lastModel?.navigating, true, "the route kept running")
        XCTAssertEqual(fuelLines(env), [], "the voice is still busy")
        env.h.speech.isSpeaking = false
        let spoken = await eventually(timeout: 2) { self.fuelLines(env).count == 1 }
        XCTAssertTrue(spoken)
        XCTAssertNil(env.ride.pendingFuelAlert)
    }

    @MainActor
    func testTheMenuAndSearchSheetsHoldTheToast() async {
        for open in ["menu", "search"] {
            let env = FuelTestEnv()
            env.projectOwnUI()
            env.ride.flushModel()
            let now = env.clock.now()
            if open == "menu" { _ = env.ride.ui.handle(.key(.home), now: now) } else { _ = env.ride.ui.perform(.openSearch, now: now) }
            XCTAssertNotEqual(env.ride.ui.state.sheet, DashSheet.none, open)
            env.ride.announceFuel(alert)
            await settle(0.05)
            XCTAssertNil(env.ride.ui.state.toast, open)
            XCTAssertFalse(drawsAToast(env), open)
            XCTAssertEqual(fuelLines(env).count, 1, "\(open): the voice is independent")
            _ = env.ride.ui.handle(.key(.back), now: env.clock.now())
            if env.ride.ui.state.sheet != .none { _ = env.ride.ui.perform(.closeSheets, now: env.clock.now()) }
            let shown = await eventually(timeout: 2) { env.ride.ui.state.toast == self.toastText(env) }
            XCTAssertTrue(shown, open)
        }
    }

    @MainActor
    func testADashPreviewHoldsTheToast() async {
        let env = FuelTestEnv()
        env.projectOwnUI()
        env.core.navigation.updateLocation(FuelFix.at(env.nowMs, north: 0, speed: 0))
        env.model.navigation.preview(Place(name: "Destino", lat: 4.61, lon: -74.08, category: "city"))
        _ = await eventually { env.ride.lastModel?.inPreview == true }
        env.ride.announceFuel(alert)
        await settle(0.05)
        XCTAssertNil(env.ride.ui.state.toast)
        env.model.navigation.cancelPreview()
        let shown = await eventually(timeout: 3) { env.ride.ui.state.toast == self.toastText(env) }
        XCTAssertTrue(shown)
    }

    @MainActor
    func testANavigationToastIsNeverReplaced() async {
        let env = FuelTestEnv()
        env.projectOwnUI()
        env.ride.ui.showToast("Parking marked", now: env.clock.now())
        env.ride.announceFuel(alert)
        XCTAssertEqual(env.ride.ui.state.toast, "Parking marked", "not replaced")
        env.clock.jump(3) // the 2.5 s toast expires
        let shown = await eventually(timeout: 2) { env.ride.ui.state.toast == self.toastText(env) }
        XCTAssertTrue(shown)
    }

    func testTheBlockingRuleCoversEveryCardAndOverlay() {
        var m = DashModel()
        XCTAssertNil(RideModel.fuelToastBlocker(sheet: .none, model: m, toastShowing: false, holdShowing: false))
        XCTAssertNil(RideModel.fuelToastBlocker(sheet: .none, model: nil, toastShowing: false, holdShowing: false))
        XCTAssertEqual(RideModel.fuelToastBlocker(sheet: .confirm, model: m, toastShowing: false, holdShowing: false), "confirm card")
        XCTAssertEqual(RideModel.fuelToastBlocker(sheet: .menu, model: m, toastShowing: false, holdShowing: false), "menu")
        XCTAssertEqual(RideModel.fuelToastBlocker(sheet: .search, model: m, toastShowing: false, holdShowing: false), "search")
        XCTAssertEqual(RideModel.fuelToastBlocker(sheet: .music, model: m, toastShowing: false, holdShowing: false), "Music sheet")
        XCTAssertEqual(RideModel.fuelToastBlocker(sheet: .none, model: m, toastShowing: true, holdShowing: false), "another toast")
        XCTAssertEqual(RideModel.fuelToastBlocker(sheet: .none, model: m, toastShowing: false, holdShowing: true), "hold picture",
                       "the engine's hold picture (locked phone), which RideModel never puts in the model")
        m.nav.arrival = ArrivalCard(title: "Destino", meta: "")
        XCTAssertEqual(RideModel.fuelToastBlocker(sheet: .none, model: m, toastShowing: false, holdShowing: false), "arrival card")
        m.nav.preview = RoutePreview(place: Place(name: "x", lat: 1, lon: 1))
        XCTAssertEqual(RideModel.fuelToastBlocker(sheet: .none, model: m, toastShowing: false, holdShowing: false), "dash preview")
    }

    // MARK: Voice channel

    func testTheVoiceWaitsForSpeechAndANearTurn() {
        XCTAssertNil(RideModel.fuelVoiceBlocker(isSpeaking: false, model: nil))
        XCTAssertEqual(RideModel.fuelVoiceBlocker(isSpeaking: true, model: nil), "voice busy")
        var m = DashModel()
        let dest = Place(name: "Destino", lat: 4.7, lon: -74.08)
        m.nav = NavSnapshot(mode: .navTo(dest), destination: dest)
        func turn(at metres: Double) -> RouteProgress {
            RouteProgress(nearestIndex: 0, doneM: 0, remainM: 5000, offTrackM: 0, snapLat: 4.6, snapLon: -74.08,
                          upcomingTurn: TurnCue(index: 1, distanceAlongM: 900, distanceFromRiderM: metres, dir: .left,
                                                speak: "Turn left", shortLabel: "Left"))
        }
        m.nav.progress = turn(at: 300)
        XCTAssertEqual(RideModel.fuelVoiceBlocker(isSpeaking: false, model: m), "turn cue near")
        m.nav.progress = turn(at: 500)
        XCTAssertEqual(RideModel.fuelVoiceBlocker(isSpeaking: false, model: m), "turn cue near")
        m.nav.progress = turn(at: 501)
        XCTAssertNil(RideModel.fuelVoiceBlocker(isSpeaking: false, model: m))
        m.nav.progress = RouteProgress(nearestIndex: 0, doneM: 0, remainM: 100, offTrackM: 0, snapLat: 4.6, snapLon: -74.08)
        XCTAssertNil(RideModel.fuelVoiceBlocker(isSpeaking: false, model: m), "the turn passed")
        m.nav.progress = turn(at: 100)
        m.nav.mode = .freeRide
        XCTAssertNil(RideModel.fuelVoiceBlocker(isSpeaking: false, model: m), "not navigating")
    }

    @MainActor
    func testSpeechInProgressDelaysTheVoiceLine() async {
        let env = FuelTestEnv()
        env.projectOwnUI()
        env.h.speech.isSpeaking = true
        env.ride.announceFuel(alert)
        await settle(0.1)
        XCTAssertEqual(env.h.speech.spoken, [])
        XCTAssertEqual(env.ride.ui.state.toast, toastText(env), "the toast does not wait for the voice")
        env.h.speech.isSpeaking = false
        let spoken = await eventually(timeout: 2) { env.h.speech.spoken.count == 1 }
        XCTAssertTrue(spoken)
    }

    // MARK: Drop, cancel, session end

    /// 450MT at «½»: 58 km of riding crosses into low (FuelModel → RideModel, the real wiring).
    @MainActor
    private func crossIntoLow(_ env: FuelTestEnv) {
        env.setUp450MT()
        _ = env.fuel.logLevel(.half, for: env.bike.id)
        env.startCountable()
        env.rideKm(58, everyMs: 5000)
    }

    @MainActor
    func testUndeliveredFor60SecondsIsDroppedAndTheNextFixFiresAgain() async {
        let env = FuelTestEnv()
        env.projectOwnUI()
        env.ride.flushModel()
        _ = env.ride.ui.handle(.key(.home), now: env.clock.now()) // the menu blocks the toast
        env.h.speech.isSpeaking = true // and the voice is busy
        crossIntoLow(env)
        XCTAssertNotNil(env.ride.pendingFuelAlert)
        XCTAssertEqual(env.kv.string(forKey: "fuel_alert_v1#\(env.bike.id)"), "low")
        env.clock.jump(61)
        env.ride.retryPendingFuelAlert(now: env.clock.now())
        XCTAssertNil(env.ride.pendingFuelAlert, "dropped")
        XCTAssertNil(env.kv.string(forKey: "fuel_alert_v1#\(env.bike.id)"), "latch restored")
        // the next fix fires again (once the dash is clear)
        _ = env.ride.ui.perform(.closeSheets, now: env.clock.now())
        env.h.speech.isSpeaking = false
        env.rideKm(0.2, fromNorth: 58_000, everyMs: 5000)
        let shown = await eventually(timeout: 2) { env.ride.ui.state.toast?.isEmpty == false && env.h.speech.spoken.count == 1 }
        XCTAssertTrue(shown)
        XCTAssertEqual(env.kv.string(forKey: "fuel_alert_v1#\(env.bike.id)"), "low")
    }

    @MainActor
    func testAToastDeliveredWithTheVoiceBusyKeepsTheLatch() async {
        let env = FuelTestEnv()
        env.projectOwnUI()
        env.h.speech.isSpeaking = true
        crossIntoLow(env)
        XCTAssertNotNil(env.ride.ui.state.toast)
        env.clock.jump(61)
        env.ride.retryPendingFuelAlert(now: env.clock.now())
        XCTAssertNil(env.ride.pendingFuelAlert)
        XCTAssertEqual(env.h.speech.spoken, [])
        XCTAssertEqual(env.kv.string(forKey: "fuel_alert_v1#\(env.bike.id)"), "low", "the toast was seen: no repeat")
    }

    @MainActor
    func testARefuelWhilePendingCancelsIt() async {
        let env = FuelTestEnv()
        env.projectOwnUI()
        env.ride.flushModel()
        _ = env.ride.ui.handle(.key(.home), now: env.clock.now())
        env.h.speech.isSpeaking = true
        crossIntoLow(env)
        XCTAssertNotNil(env.ride.pendingFuelAlert)
        guard case .logged = env.fuel.logRefuel(RefuelInput(kind: .full, litres: 9), for: env.bike.id) else { return XCTFail() }
        XCTAssertNil(env.ride.pendingFuelAlert, "cancelled")
        _ = env.ride.ui.perform(.closeSheets, now: env.clock.now())
        env.h.speech.isSpeaking = false
        await settle(0.1)
        XCTAssertNil(env.ride.ui.state.toast)
        XCTAssertEqual(env.h.speech.spoken, [])
    }

    @MainActor
    func testTheSessionEndingWhilePendingDropsItAndRestoresTheLatch() async {
        let env = FuelTestEnv()
        env.projectOwnUI()
        env.ride.flushModel()
        _ = env.ride.ui.handle(.key(.home), now: env.clock.now())
        env.h.speech.isSpeaking = true
        crossIntoLow(env)
        XCTAssertNotNil(env.ride.pendingFuelAlert)
        env.ride.sessionChanged(active: false, mirror: false)
        XCTAssertNil(env.ride.pendingFuelAlert)
        XCTAssertNil(env.kv.string(forKey: "fuel_alert_v1#\(env.bike.id)"), "latch restored for the next session")
    }
}
