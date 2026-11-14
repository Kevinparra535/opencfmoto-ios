// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP (BRIEF safety pin: the rider never types while riding): every fuel sheet and every typed write is
// refused while moving; single taps stay; FuelModel never opens a sheet by itself.
import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class FuelMovingLockTests: XCTestCase {
    /// The ride's own last fix decides (as wired in AppModel).
    @MainActor
    private func moving(_ env: FuelTestEnv, kmh: Double = 30, ageSeconds: Double = 2) {
        env.fuel.lastFixProvider = { [weak ride = env.ride] in ride?.lastFix }
        let t = env.nowMs - Int64(ageSeconds * 1000)
        env.h.location.emit(FuelFix.at(t, north: 0, speed: kmh / 3.6))
    }

    @MainActor
    func testEverySheetAndTypedWriteIsRefusedWhileMoving() async {
        let env = FuelTestEnv()
        let id = env.bike.id
        env.setUp450MT()
        env.fuel.undoWindow = 30
        moving(env)
        XCTAssertFalse(env.fuel.canLogNow)
        for sheet in [FuelSheet.picker(bikeId: id, fromPrompt: true), .picker(bikeId: id, fromPrompt: false), .editProfile(bikeId: id),
                      .refuel(bikeId: id, late: false), .refuel(bikeId: id, late: true), .level(bikeId: id)] {
            XCTAssertFalse(env.fuel.present(sheet), "\(sheet)")
            XCTAssertNil(env.fuel.sheet)
        }
        XCTAssertEqual(env.fuel.saveProfile(env.fuel.draft(from: FuelCatalog.entry(id: "cfmoto-450sr")!), for: id), .refusedWhileMoving)
        XCTAssertEqual(env.fuel.state(for: id).profile?.catalogId, "cfmoto-450mt", "nothing saved")
        XCTAssertEqual(env.fuel.logRefuel(RefuelInput(kind: .full, litres: 10), for: id), .refusedWhileMoving)
        XCTAssertEqual(env.fuel.logLevel(.half, for: id), .refusedWhileMoving)
        XCTAssertEqual(env.fuel.state(for: id).log.count, 1)
        // stale (11 s): allowed again
        env.advance(11)
        XCTAssertTrue(env.fuel.canLogNow)
        XCTAssertTrue(env.fuel.present(.refuel(bikeId: id, late: false)))
        XCTAssertEqual(env.fuel.sheet, .refuel(bikeId: id, late: false))
        env.fuel.dismissSheet()
        XCTAssertNil(env.fuel.sheet)
        guard case .logged = env.fuel.logRefuel(RefuelInput(kind: .full, litres: 10), for: id) else { return XCTFail() }
        // slow (≤ 5 km/h) counts as stopped
        moving(env, kmh: 4)
        XCTAssertTrue(env.fuel.canLogNow)
        XCTAssertFalse(env.fuel.present(.refuel(bikeId: "b-nope", late: false)), "unknown bike")
    }

    @MainActor
    func testSingleTapsStayAvailableWhileMoving() async {
        let env = FuelTestEnv()
        let id = env.bike.id
        env.fuel.undoWindow = 30
        env.setUp450MT()
        guard case .logged = env.fuel.logRefuel(RefuelInput(kind: .partial, litres: 3), for: id) else { return XCTFail() }
        moving(env)
        XCTAssertFalse(env.fuel.canLogNow)
        env.fuel.setReservePct(20, for: id)
        XCTAssertEqual(env.fuel.state(for: id).profile?.reservePct, 20)
        env.fuel.setPreferLearned(false, for: id)
        XCTAssertEqual(env.fuel.state(for: id).profile?.preferLearned, false)
        env.fuel.undoLastRefuel()
        XCTAssertEqual(env.fuel.state(for: id).log.count, 1)
        env.fuel.deleteRefuel(id: env.fuel.state(for: id).log[0].id, for: id)
        XCTAssertEqual(env.fuel.state(for: id).log.count, 0)
        let other = env.addOtherBike()
        env.fuel.deferSetup(for: other.id)
        XCTAssertTrue(env.fuel.state(for: other.id).isSetupDeferred)
    }

    @MainActor
    func testFuelModelNeverOpensASheetByItself() async throws {
        // A real Connect: CLIENT_INFO arrives mid-session (profileHint) → the setup prompt appears, no sheet.
        let net = LinkMemoryNetwork(phoneHost: "192.168.0.2")
        let dash = LinkFakeDash(network: net, host: "192.168.0.1")
        dash.installProbeServer()
        let env = FuelTestEnv(wall: Locked(Date()), network: net, frameSource: TestFrameSource())
        XCTAssertNil(env.fuel.setupPrompt, "no CLIENT_INFO yet")
        env.model.connection.connect()
        _ = await eventually { dash.acceptedCount.current == 1 }
        let closers = try await fuelStreamFromFakeDash(dash)
        let streaming = await eventually { env.model.connection.phase == .streaming }
        XCTAssertTrue(streaming)
        let prompted = await eventually { env.fuel.setupPrompt != nil }
        XCTAssertTrue(prompted)
        XCTAssertEqual(env.fuel.setupPrompt?.bikeId, env.bike.id)
        // riding: the card shows, the sheet stays closed and refuses to open
        env.fuel.lastFixProvider = { [weak ride = env.ride] in ride?.lastFix }
        env.h.location.emit(FuelFix.at(env.nowMs, north: 0, speed: 15))
        XCTAssertNil(env.fuel.sheet)
        XCTAssertFalse(env.fuel.present(.picker(bikeId: env.bike.id, fromPrompt: true)))
        XCTAssertNil(env.fuel.sheet)
        for _ in 0 ..< 5 {
            await settle(0.02)
            XCTAssertNil(env.fuel.sheet, "never set by the model")
        }
        env.model.connection.stop()
        closers.forEach { $0() }
    }
}
