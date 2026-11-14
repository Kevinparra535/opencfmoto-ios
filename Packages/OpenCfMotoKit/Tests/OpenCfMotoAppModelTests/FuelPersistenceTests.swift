// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: removal deletes a bike's fuel data and nothing resurrects it; a re-scan keeps it; the settings export
// carries none; a lost / unreadable counter is raised to the log and ages the estimate instead of a full tank.
import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class FuelPersistenceTests: XCTestCase {
    @MainActor
    func testRemovingABikeDeletesItsFuelDataAndNothingResurrectsIt() async {
        let env = FuelTestEnv()
        env.fuel.undoWindow = 30
        let id = env.bike.id
        let other = env.addOtherBike()
        env.setUp450MT(other.id)
        env.setUp450MT() // the undo offer is for the bike that goes
        env.startCountable()
        env.rideKm(2)
        env.fuel.deferSetup(for: id)
        XCTAssertEqual(env.fuel.undoOffer?.bikeId, id)
        XCTAssertTrue(env.kv.allKeys().contains { $0.hasPrefix("fuel_") && $0.hasSuffix("#\(id)") })
        env.model.garage.remove(id)
        XCTAssertFalse(env.kv.allKeys().contains { $0.hasSuffix("#\(id)") }, "\(env.kv.allKeys().sorted())")
        XCTAssertNil(env.fuel.undoOffer, "the undo offer of the removed bike goes")
        // the session still runs for the removed id: its fixes and a pending undo / persist write nothing
        env.rideKm(1, fromNorth: 2000)
        env.fuel.undoLastRefuel()
        env.endSession()
        env.model.scenePhaseChanged(.background)
        XCTAssertFalse(env.kv.allKeys().contains { $0.hasSuffix("#\(id)") }, "no resurrection")
        XCTAssertEqual(env.fuel.logRefuel(RefuelInput(kind: .full), for: id), .noSuchBike)
        XCTAssertEqual(env.fuel.saveProfile(env.fuel.draft(from: FuelCatalog.entry(id: "cfmoto-450mt")!), for: id), .noSuchBike)
        XCTAssertFalse(env.fuel.present(.refuel(bikeId: id, late: false)))
        // the other bike is intact
        XCTAssertEqual(env.fuel.state(for: other.id).profile?.catalogId, "cfmoto-450mt")
        XCTAssertNotNil(env.kv.data(forKey: "fuel_profile_v1#\(other.id)"))
        XCTAssertEqual(env.fuel.currentBikeId, other.id)
    }

    @MainActor
    func testRemovingTheBikeOfAnOpenSheetClosesIt() async {
        let env = FuelTestEnv()
        let id = env.bike.id
        XCTAssertTrue(env.fuel.present(.picker(bikeId: id, fromPrompt: false)))
        env.model.garage.remove(id)
        XCTAssertNil(env.fuel.sheet)
        XCTAssertNil(env.fuel.current)
    }

    @MainActor
    func testAReScanOfTheSameQRKeepsTheProfile() async {
        let env = FuelTestEnv()
        env.setUp450MT()
        guard case let .paired(bike) = env.model.garage.pair(rawQR: AppTestHarness.sampleRaw) else { return XCTFail() }
        XCTAssertEqual(bike.id, env.bike.id)
        XCTAssertEqual(env.fuel.state(for: bike.id).profile?.catalogId, "cfmoto-450mt")
    }

    @MainActor
    func testTheSettingsExportHasNoFuelData() async throws {
        let env = FuelTestEnv()
        env.setUp450MT()
        _ = env.fuel.logRefuel(RefuelInput(kind: .full, litres: 13.37, pricePerLitre: 4321.5), for: env.bike.id)
        env.fuel.volumeUnit = .usGallon
        let file = try env.model.settings.exportSettings()
        let text = try String(contentsOf: file.url, encoding: .utf8).lowercased()
        for word in ["fuel", "tank", "litre", "refuel", "13.37", "4321", "cfmoto-450mt"] {
            XCTAssertFalse(text.contains(word), "«\(word)» in the settings export")
        }
    }

    @MainActor
    func testALostCounterIsRaisedToTheLogAndAgesTheEstimate() async {
        let env = FuelTestEnv()
        let id = env.bike.id
        env.setUp450MT()
        env.startCountable()
        env.rideKm(20, everyMs: 5000)
        env.endSession()
        guard case .logged = env.fuel.logRefuel(RefuelInput(kind: .full, litres: 1), for: id) else { return XCTFail() }
        let newest = env.fuel.state(for: id).log.last!.odometerKm
        XCTAssertEqual(newest, 20, accuracy: 0.1)
        // the odometer document is lost (or unreadable / older); the log is intact
        env.kv.removeValue(forKey: "fuel_odo_v1#\(id)")
        env.advance(60)
        let again = FuelTestEnv(kv: env.kv, secrets: env.secrets, wall: env.wall)
        let s = again.fuel.state(for: id)
        XCTAssertEqual(s.odometerKm, newest, accuracy: 1e-9, "never restarts below the log")
        XCTAssertEqual(s.estimate.aged, .gap, "aged, not a silently full tank")
        XCTAssertEqual(s.stats, env.fuel.state(for: id).stats, "learning reads the entry stamps, not the lost document")
        // an unreadable document is left in place until a rider action writes it
        env.kv.set(Data(#"{"totalKm":1,"v":2}"#.utf8), forKey: "fuel_odo_v1#\(id)")
        let fresh = FuelTestEnv(kv: env.kv, secrets: env.secrets, wall: env.wall)
        fresh.startCountable()
        fresh.rideKm(1, fromNorth: 100_000)
        fresh.endSession()
        XCTAssertEqual(String(decoding: env.kv.data(forKey: "fuel_odo_v1#\(id)") ?? Data(), as: UTF8.self), #"{"totalKm":1,"v":2}"#)
        guard case .logged = fresh.fuel.logRefuel(RefuelInput(kind: .full), for: id) else { return XCTFail() }
        XCTAssertNotNil(fresh.storedOdometer(), "a rider action writes it")
    }
}
