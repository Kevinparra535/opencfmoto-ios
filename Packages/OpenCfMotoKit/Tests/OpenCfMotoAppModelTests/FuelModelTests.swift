// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: FuelModel — profiles per bike and the seedSource rule, `current`, refuels with undo / delete,
// level corrections, copies, the route verdict, units, the pump's unit, the Problem Report keys and log
// hygiene (no litres, prices, trip values or coordinates in any log line).
import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class FuelModelTests: XCTestCase {
    private let mt450 = FuelCatalog.entry(id: "cfmoto-450mt")!

    @MainActor
    func testProfilesArePerBikeAndSurviveARelaunch() async {
        let env = FuelTestEnv()
        let other = env.addOtherBike()
        env.setUp450MT(refuel: false)
        XCTAssertEqual(env.fuel.state(for: env.bike.id).profile?.catalogId, "cfmoto-450mt")
        XCTAssertEqual(env.fuel.state(for: env.bike.id).entry?.id, "cfmoto-450mt")
        XCTAssertNil(env.fuel.state(for: other.id).profile)
        XCTAssertEqual(env.fuel.current?.bikeId, env.bike.id)
        XCTAssertEqual(env.fuel.current?.profile?.tankL, 17.5)
        XCTAssertNotNil(env.kv.data(forKey: "fuel_profile_v1#\(env.bike.id)"))
        XCTAssertNil(env.kv.data(forKey: "fuel_profile_v1"), "never a global key")
        XCTAssertNil(env.kv.data(forKey: "fuel_profile_v1#\(other.id)"))
        let again = FuelTestEnv(kv: env.kv, secrets: env.secrets)
        XCTAssertEqual(again.fuel.state(for: env.bike.id).profile, env.fuel.state(for: env.bike.id).profile)
        XCTAssertEqual(env.fuel.saveProfile(env.fuel.draft(from: mt450), for: "b-unknown"), .noSuchBike)
    }

    @MainActor
    func testTheSeedSourceRule() async {
        let env = FuelTestEnv()
        let id = env.bike.id
        func save(_ p: FuelProfile) -> FuelSeedSource? {
            XCTAssertEqual(env.fuel.saveProfile(p, for: id), .saved)
            return env.fuel.state(for: id).profile?.seedSource
        }
        var d = env.fuel.draft(from: mt450)
        XCTAssertEqual(d.seedSource, .catalog)
        XCTAssertEqual(save(d), .catalog)
        d.seedKmPerL = 20.49 // a unit round trip
        XCTAssertEqual(save(d), .catalog, "within the 0.05 tolerance")
        d.seedKmPerL = 20.6
        XCTAssertEqual(save(d), .edited)
        d.seedKmPerL = 20.5
        d.tankL = 17.56
        XCTAssertEqual(save(d), .edited)
        d.tankL = 17.5
        d.reservePct = 20
        XCTAssertEqual(save(d), .catalog, "the reserve never changes the source")
        XCTAssertEqual(env.fuel.state(for: id).profile?.reservePct, 20)
        d.reservePct = 40
        XCTAssertEqual(save(d), .catalog)
        XCTAssertEqual(env.fuel.state(for: id).profile?.reservePct, 30, "clamped")
        var manual = env.fuel.draftManual()
        XCTAssertEqual(env.fuel.saveProfile(manual, for: id), .incomplete, "no tank yet")
        manual.tankL = 14
        XCTAssertEqual(save(manual), .manual)
        XCTAssertEqual(env.fuel.state(for: id).profile?.seedKmPerL, 15.5)
        // a copy: kept as copied unless a value is changed
        let other = env.addOtherBike()
        let copy = env.fuel.draftCopy(from: id)
        XCTAssertEqual(copy?.seedSource, .copied)
        XCTAssertEqual(env.fuel.saveProfile(copy!, for: other.id), .saved)
        XCTAssertEqual(env.fuel.state(for: other.id).profile?.seedSource, .copied)
        var changed = copy!
        changed.tankL = 16
        XCTAssertEqual(env.fuel.saveProfile(changed, for: other.id), .saved)
        XCTAssertEqual(env.fuel.state(for: other.id).profile?.seedSource, .manual, "a changed copy of a manual profile")
    }

    @MainActor
    func testCurrentFollowsTheSelectedBikeThenTheSessionBike() async {
        let env = FuelTestEnv()
        let other = env.addOtherBike()
        XCTAssertEqual(env.fuel.currentBikeId, env.bike.id)
        env.model.garage.select(other.id)
        XCTAssertEqual(env.fuel.currentBikeId, other.id)
        env.model.garage.select(env.bike.id)
        env.startCountable(env.bike.id)
        env.model.garage.select(other.id)
        XCTAssertEqual(env.fuel.currentBikeId, env.bike.id, "the session's bike while a session runs")
        env.endSession()
        XCTAssertEqual(env.fuel.currentBikeId, other.id, "back to the selected bike")
        XCTAssertEqual(env.fuel.current?.bikeId, other.id)
    }

    @MainActor
    func testLogRefuelUndoAndDelete() async {
        let env = FuelTestEnv()
        let id = env.bike.id
        env.setUp450MT()
        env.startCountable()
        env.rideKm(5)
        let counter = env.fuel.state(for: id).odometerKm
        XCTAssertEqual(counter, 5, accuracy: 0.1)
        guard case let .logged(entry) = env.fuel.logRefuel(RefuelInput(kind: .full, litres: 0.3), for: id) else {
            return XCTFail("refused")
        }
        XCTAssertEqual(entry.odometerKm, counter)
        XCTAssertEqual(env.fuel.undoOffer, FuelUndoOffer(bikeId: id, entryId: entry.id))
        XCTAssertEqual(env.fuel.current?.log.count, 2)
        XCTAssertEqual(env.storedOdometer()?.totalKm ?? -1, counter, accuracy: 1e-9, "the counter is persisted with the entry")
        let cleared = await eventually(timeout: 2) { env.fuel.undoOffer == nil }
        XCTAssertTrue(cleared, "the undo offer goes after undoWindow")
        // log + undo
        guard case let .logged(second) = env.fuel.logRefuel(RefuelInput(kind: .partial, litres: 4), for: id) else { return XCTFail() }
        XCTAssertEqual(env.fuel.undoOffer?.entryId, second.id)
        env.fuel.undoLastRefuel()
        XCTAssertNil(env.fuel.undoOffer)
        XCTAssertEqual(env.fuel.state(for: id).log.map(\.id), [env.fuel.state(for: id).log[0].id, entry.id])
        env.fuel.undoLastRefuel() // no offer: no-op
        XCTAssertEqual(env.fuel.state(for: id).log.count, 2)
        // delete by id
        env.fuel.deleteRefuel(id: entry.id, for: id)
        XCTAssertEqual(env.fuel.state(for: id).log.count, 1)
        let stored = try? JSONDecoder().decode(RefuelLog.self, from: env.kv.data(forKey: "fuel_log_v1#\(id)") ?? Data())
        XCTAssertEqual(stored?.entries.count, 1)
        // invalid input and unknown bikes
        XCTAssertEqual(env.fuel.logRefuel(RefuelInput(kind: .full, litres: 0), for: id), .invalid(.litres))
        XCTAssertEqual(env.fuel.logRefuel(RefuelInput(kind: .level), for: id), .invalid(.level))
        XCTAssertEqual(env.fuel.logRefuel(RefuelInput(kind: .full), for: "b-nope"), .noSuchBike)
        XCTAssertEqual(env.fuel.state(for: id).log.count, 1)
    }

    @MainActor
    func testANewRefuelReplacesTheUndoOffer() async {
        let env = FuelTestEnv()
        env.fuel.undoWindow = 30
        env.setUp450MT()
        let id = env.bike.id
        let first = env.fuel.state(for: id).log[0].id
        XCTAssertEqual(env.fuel.undoOffer?.entryId, first)
        guard case .logged = env.fuel.logLevel(.half, for: id) else { return XCTFail() }
        let levelId = env.fuel.state(for: id).log.last!.id
        XCTAssertEqual(env.fuel.undoOffer?.entryId, levelId, "the newest entry replaces the offer")
        env.fuel.undoLastRefuel()
        XCTAssertEqual(env.fuel.state(for: id).log.map(\.id), [first])
        XCTAssertNil(env.fuel.undoOffer)
    }

    @MainActor
    func testALevelCorrectionIsAnAnchorAndLeavesTheStatsAlone() async {
        let env = FuelTestEnv()
        let id = env.bike.id
        env.setUp450MT()
        let statsBefore = env.fuel.state(for: id).stats
        guard case let .logged(level) = env.fuel.logLevel(.half, for: id) else { return XCTFail() }
        XCTAssertEqual(level.kind, .level)
        XCTAssertEqual(level.levelAfter, .half)
        XCTAssertNil(level.litres)
        XCTAssertEqual(env.fuel.state(for: id).stats, statsBefore)
        XCTAssertEqual(env.fuel.current?.estimate.kmValue ?? 0, (8.75 - 2.1) * 20.5, accuracy: 1e-6)
        XCTAssertNotNil(env.fuel.undoOffer, "an undo bar is shown for a level correction too")
    }

    @MainActor
    func testCopySourcesAndDraftCopy() async {
        let env = FuelTestEnv()
        let other = env.addOtherBike()
        XCTAssertEqual(env.fuel.copySources(excluding: other.id), [])
        env.setUp450MT(refuel: false)
        let sources = env.fuel.copySources(excluding: other.id)
        XCTAssertEqual(sources.map(\.bikeId), [env.bike.id])
        XCTAssertEqual(sources.first?.profile.catalogId, "cfmoto-450mt")
        XCTAssertEqual(env.fuel.copySources(excluding: env.bike.id), [], "never the bike itself")
        let copy = env.fuel.draftCopy(from: env.bike.id)
        XCTAssertEqual(copy?.seedSource, .copied)
        XCTAssertEqual(copy?.catalogId, "cfmoto-450mt")
        XCTAssertEqual(copy?.name, "CFMOTO 450MT")
        XCTAssertNil(env.fuel.draftCopy(from: other.id))
        XCTAssertNil(env.fuel.draftCopy(from: "b-nope"))
        XCTAssertEqual(env.fuel.saveProfile(copy!, for: other.id), .saved)
        XCTAssertEqual(env.fuel.state(for: other.id).log, [], "a copy carries the profile only, never the log")
    }

    // MARK: Route verdict

    static let osrm333m = """
    {"code":"Ok","routes":[{"distance":333.6,"duration":40,
     "geometry":{"type":"LineString","coordinates":[[-74.08,4.6],[-74.08,4.603]]},"legs":[{"steps":[]}]}]}
    """

    @MainActor
    func testThePreviewVerdictFollowsTheNavigationPreview() async {
        let http = PreviewHTTPClient()
        http.respond(toPrefix: OsrmRouter.baseURL,
                     with: HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: Data(Self.osrm333m.utf8)))
        let env = FuelTestEnv { $0.http = http }
        let nav = env.model.navigation
        XCTAssertNil(env.fuel.previewVerdict, "no preview")
        env.core.navigation.updateLocation(FuelFix.at(env.nowMs, north: 0, speed: 0))
        let dest = Place(name: "Destino", lat: 4.603, lon: -74.08, category: "city")
        nav.preview(dest)
        await env.core.navigation.waitUntilIdle()
        let routed = await eventually { nav.snapshot.preview?.selectedRoute != nil }
        XCTAssertTrue(routed)
        XCTAssertNil(env.fuel.previewVerdict, "no profile: no verdict")
        env.setUp450MT()
        guard case let .reaches(margin)? = env.fuel.previewVerdict else {
            return XCTFail("\(String(describing: env.fuel.previewVerdict))")
        }
        XCTAssertEqual(margin, 315.7 - 0.3336, accuracy: 1e-6)
        // a beeline with a forced label never gets a verdict
        let beeline = RouteOrchestrator.beeline(from: GeoPoint(lat: 4.6, lon: -74.08), to: dest.point).withLabel("Circuit")
        XCTAssertNil(env.fuel.verdict(for: beeline))
        nav.cancelPreview()
        await env.core.navigation.waitUntilIdle()
        _ = await eventually { nav.snapshot.preview == nil }
        XCTAssertNil(env.fuel.previewVerdict)
    }

    @MainActor
    func testAStraightLineFallbackPreviewShowsNoVerdict() async {
        let env = FuelTestEnv() // routing answers 503: the preview falls back to the beeline
        env.setUp450MT()
        let nav = env.model.navigation
        env.core.navigation.updateLocation(FuelFix.at(env.nowMs, north: 0, speed: 0))
        nav.preview(Place(name: "Lejos", lat: 4.7, lon: -74.08, category: "city"))
        await env.core.navigation.waitUntilIdle()
        _ = await eventually(timeout: 3) { nav.snapshot.preview?.loading == false }
        if let route = nav.snapshot.preview?.selectedRoute {
            XCTAssertTrue(route.isDirectFallback, "\(route.label)")
        }
        XCTAssertNil(env.fuel.previewVerdict)
    }

    // MARK: Units

    @MainActor
    func testUnitsAndThePumpsVolumeUnit() async {
        let env = FuelTestEnv()
        XCTAssertEqual(env.fuel.units, .metric)
        env.fuel.regionCodeProvider = { "MX" }
        XCTAssertEqual(env.fuel.volumeUnit, .litre)
        env.fuel.regionCodeProvider = { "CO" }
        XCTAssertEqual(env.fuel.volumeUnit, .usGallon, "Colombia sells by the gallon")
        env.fuel.regionCodeProvider = { "MX" }
        var prefs = env.model.settings.current.map
        prefs.units = .imperial
        env.model.settings.setMapPreferences(prefs)
        XCTAssertEqual(env.fuel.units, .imperial)
        XCTAssertEqual(env.fuel.volumeUnit, .usGallon, "imperial default")
        env.fuel.volumeUnit = .litre
        XCTAssertEqual(env.fuel.volumeUnit, .litre)
        XCTAssertEqual(env.kv.string(forKey: "ios_fuel_volume_unit_v1"), "L")
        let again = FuelTestEnv(kv: env.kv, secrets: env.secrets)
        XCTAssertEqual(again.fuel.volumeUnit, .litre, "remembered")
    }

    // MARK: Problem Report

    @MainActor
    func testProblemDiagnosticsCarryTheModelIdAndTheFuelSetupOnly() async {
        let env = FuelTestEnv()
        var d = env.model.logs.diagnostics()
        XCTAssertEqual(d["modelId"], "37416", "from the stored QR, no connect needed")
        XCTAssertEqual(d["fuel"], "none")
        XCTAssertNil(d["huidPrefix"], "no session")
        env.setUp450MT()
        _ = env.fuel.logRefuel(RefuelInput(kind: .full, litres: 13.37, pricePerLitre: 4321.5, tripMeterKm: 271.9), for: env.bike.id)
        d = env.model.logs.diagnostics()
        XCTAssertEqual(d["fuel"], "catalog:cfmoto-450mt, log 2")
        let all = d.values.joined(separator: " ")
        for secret in ["13.37", "4321", "271.9", "17.5"] { XCTAssertFalse(all.contains(secret), secret) }
    }

    // MARK: Log hygiene

    @MainActor
    func testNoLitresPricesTripValuesOrCoordinatesInTheLog() async {
        let env = FuelTestEnv()
        let id = env.bike.id
        let lines = await FuelTestEnv.captureLog {
            env.setUp450MT()
            env.startCountable()
            // fixes at 4.6512… (distinctive), a gap, a blind spell
            let base = FuelFix.track(start: env.nowMs + 1000, startNorth: 5_661, metresPerFix: 20, everyMs: 1000, count: 30)
            env.emit(base)
            env.emit([FuelFix.at(base.last!.timeMs + 1_200_000, north: 35_000)])
            env.emit([FuelFix.at(base.last!.timeMs + 1_201_000, north: 35_020, accuracy: 1500)])
            env.advance(30)
            _ = env.fuel.logRefuel(RefuelInput(kind: .full, litres: 13.37, pricePerLitre: 4321.5, tripMeterKm: 271.9), for: id)
            _ = env.fuel.logRefuel(RefuelInput(kind: .partial, litres: 2.71, totalPrice: 98_765), for: id)
            env.fuel.undoLastRefuel()
            env.endSession()
            env.model.scenePhaseChanged(.background)
        }
        let joined = lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("fuel: refuel logged: full, litres=yes, price=yes, trip=yes, late=no"), joined)
        XCTAssertTrue(joined.contains("gap detected"), joined)
        for secret in ["13.37", "4321", "271.9", "2.71", "98765", "98 765", "4.65", "-74.0", "74.08"] {
            XCTAssertFalse(joined.contains(secret), "«\(secret)» in the log:\n\(joined)")
        }
    }
}
