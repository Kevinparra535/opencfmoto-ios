// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: «¿Cuál es tu moto?» — the per-bike prompt after the first CLIENT_INFO, «Luego», and the
// candidates FuelModel resolves from the stored QR, the learned canvas, the hint and the live CLIENT_INFO.
import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class FuelSetupPromptTests: XCTestCase {
    @MainActor
    private func identify(_ env: FuelTestEnv, _ bikeId: String, as profile: BikeProfileID = .legacy) {
        env.core.garage.setProfileHint(bikeId, profile)
        env.model.garage.reload()
    }

    @MainActor
    func testThePromptAppearsAfterCLIENT_INFOAndLuegoHidesItForThatBike() async {
        let env = FuelTestEnv()
        let id = env.bike.id
        XCTAssertNil(env.fuel.setupPrompt, "no CLIENT_INFO yet")
        identify(env, id)
        XCTAssertEqual(env.fuel.setupPrompt, FuelSetupPrompt(bikeId: id, bikeName: env.bike.name))
        XCTAssertNil(env.fuel.sheet, "a Home card, never a sheet")
        env.fuel.deferSetup(for: id)
        XCTAssertNil(env.fuel.setupPrompt)
        XCTAssertEqual(env.kv.bool(forKey: "fuel_setup_later_v1#\(id)"), true)
        // survives a relaunch
        let again = FuelTestEnv(kv: env.kv, secrets: env.secrets)
        XCTAssertNil(again.fuel.setupPrompt)
        XCTAssertTrue(again.fuel.state(for: id).isSetupDeferred)
        // another bike still prompts
        let other = again.addOtherBike()
        identify(again, other.id)
        again.model.garage.select(other.id)
        XCTAssertEqual(again.fuel.setupPrompt?.bikeId, other.id)
        // a saved profile ends it
        XCTAssertEqual(again.fuel.saveProfile(again.fuel.draft(from: FuelCatalog.entry(id: "cfmoto-450mt")!), for: other.id), .saved)
        XCTAssertNil(again.fuel.setupPrompt)
    }

    @MainActor
    func testCandidatesForTheDemoLegacyQR() async {
        let env = FuelTestEnv()
        identify(env, env.bike.id)
        let list = env.fuel.candidates(for: env.bike.id)
        XCTAssertEqual(list.families, [.legacy])
        XCTAssertEqual(list.ids.first, "cfmoto-450mt")
        XCTAssertNil(list.preselectedId)
        XCTAssertEqual(env.fuel.catalogEntries(list.ids).map(\.id), list.ids)
        XCTAssertEqual(env.fuel.search("675ss", brand: list.brand).map(\.id), ["cfmoto-675sr-r"])
    }

    @MainActor
    func testCandidatesFor37426WithAndWithoutALearnedCanvas() async {
        let env = FuelTestEnv()
        let nk = env.core.garage.save(BikeQR.parse(LDTest.qr4288)!)
        env.model.garage.reload()
        identify(env, nk.id, as: .cfdl26Landscape)
        XCTAssertEqual(env.fuel.candidates(for: nk.id).ids, BikeCandidates.ambiguous37426)
        XCTAssertNil(env.fuel.candidates(for: nk.id).preselectedId)
        env.core.dashMemory.observe(ssid: nk.ssid, width: 720, height: 712)
        let adv = env.fuel.candidates(for: nk.id)
        XCTAssertEqual(adv.ids, ["cfmoto-800nk-advanced"])
        XCTAssertEqual(adv.preselectedId, "cfmoto-800nk-advanced")
    }

    @MainActor
    func testUnknownDashesGetNoCandidates() async {
        let env = FuelTestEnv()
        let unknown = env.addOtherBike(ssid: "TRK502X-01", modelId: "12345")
        identify(env, unknown.id, as: .nkAdvanced)
        XCTAssertEqual(env.fuel.candidates(for: unknown.id).ids, [], "an uncorroborated hint")
        // a per-bike profile override makes the hint the override: not evidence either
        env.core.settings.setProfileOverride(.nkAdvanced, forBike: unknown.id)
        XCTAssertEqual(env.fuel.candidates(for: unknown.id).ids, [])
    }

    @MainActor
    func testTheLiveCLIENT_INFOIsReadOnlyForTheSessionBike() async {
        let env = FuelTestEnv()
        let unknown = env.addOtherBike(ssid: "DASH-77", modelId: "12345")
        let liveCFDL26 = DashInfo(huid: "6WX0AT231300200", profile: .cfdl26Portrait,
                                  rawJSON: #"{"HUID":"6WX0AT231300200","package_name":"com.cfmoto.cfdashmotoplay","version_name":"CFDL26.2.3.5.0.6","sdkVersion":"1.1.4","enableSockServerAuth":true,"supportScreenTouch":true,"supportFunction":128}"#)
        env.fuel.liveDashInfoProvider = { liveCFDL26 }
        XCTAssertEqual(env.fuel.candidates(for: unknown.id).ids, [], "not the session bike: no live data")
        env.fuel.sessionBikeProvider = { unknown.id }
        XCTAssertEqual(env.fuel.candidates(for: unknown.id).families, [.cfdl26Portrait], "a corroborated live winner")
        XCTAssertEqual(env.fuel.candidates(for: unknown.id).source, .clientInfo)
    }

    @MainActor
    func testARealConnectShowsThePromptAndTheLegacyListWithLiveData() async throws {
        let net = LinkMemoryNetwork(phoneHost: "192.168.0.2")
        let dash = LinkFakeDash(network: net, host: "192.168.0.1")
        dash.installProbeServer()
        let env = FuelTestEnv(wall: Locked(Date()), network: net, frameSource: TestFrameSource())
        env.model.connection.connect()
        _ = await eventually { dash.acceptedCount.current == 1 }
        let closers = try await fuelStreamFromFakeDash(dash)
        _ = await eventually { env.model.connection.phase == .streaming }
        XCTAssertTrue(env.model.connection.isFuelCountable)
        XCTAssertEqual(env.model.connection.sessionBikeId, env.bike.id)
        let prompted = await eventually { env.fuel.setupPrompt != nil }
        XCTAssertTrue(prompted)
        let list = env.fuel.candidates(for: env.bike.id)
        XCTAssertEqual(list.families, [.legacy])
        XCTAssertEqual(list.source, .clientInfo, "the live CFDL16 CLIENT_INFO (800×386 decides nothing)")
        XCTAssertEqual(list.ids.first, "cfmoto-450mt")
        // the Problem Report gains the 4-character dash family prefix while linked
        let d = env.model.logs.diagnostics()
        XCTAssertEqual(d["huidPrefix"], "6GUV")
        XCTAssertEqual(d["modelId"], "37416")
        env.model.connection.stop()
        closers.forEach { $0() }
        let stopped = await eventually { !env.model.connection.isSessionActive }
        XCTAssertTrue(stopped)
        XCTAssertFalse(env.model.connection.isFuelCountable)
        XCTAssertNil(env.model.logs.diagnostics()["huidPrefix"], "absent without a session")
    }
}
