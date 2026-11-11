// SPDX-License-Identifier: AGPL-3.0-or-later
// The OSMF tile usage policy in RideModel (navigation-dash.md §10.4): no route-corridor prefetch while
// the dash map uses the OpenStreetMap Foundation servers (the default template), the corridor for a tile
// server the rider configured, and the "© OpenStreetMap" credit in the dash model only for OSMF tiles.
import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class RideModelTilePolicyTests: XCTestCase {
    static let customServer = "https://tiles.example.com/{z}/{x}/{y}.png"

    /// A small GPX track starting at `lat` (distinct routes → distinct route keys).
    private func gpx(_ lat: Double) -> Data {
        let points = (0 ..< 6).map { i in
            String(format: "<trkpt lat=\"%.4f\" lon=\"%.4f\"/>", lat + Double(i) * 0.002, 25.0 + Double(i) * 0.003)
        }.joined(separator: "\n")
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="test"><trk><name>T\(lat)</name><trkseg>
        \(points)
        </trkseg></trk></gpx>
        """.utf8)
    }

    @MainActor
    func testNoCorridorPrefetchFromTheDefaultOSMServerOnlyFromACustomOne() async throws {
        let spy = RideSpyProjection()
        let h = AppTestHarness { $0.projection = spy }
        XCTAssertEqual(h.model.settings.current.tileURLTemplate, BikeSettings().tileURLTemplate)
        XCTAssertTrue(MapTileSource.isOpenStreetMapFoundation(template: h.model.settings.current.tileURLTemplate))
        /// RideModel has handled the newest navigation snapshot (the prefetch decision is taken in the same
        /// step): its dash shows guidance (the map list starts on Recenter, P0) or free ride (the search pill).
        func dashShows(navigating: Bool) async -> Bool {
            await eventually {
                h.ride.flushModel()
                let order = h.ride.dashUIState.focusOrder
                return navigating ? order.first == DashFocusEngine.recenterId : order.contains("pill")
            }
        }

        // 1. Default template (tile.openstreetmap.org): a route is applied, nothing is prefetched.
        h.model.navigation.loadGpx(data: gpx(45.10), fileName: "osm-a.gpx")
        let routeA = await dashShows(navigating: true)
        XCTAssertTrue(routeA, "route A reached RideModel")
        await settle()
        XCTAssertEqual(spy.corridors.current.count, 0, "no prefetch from the OSMF server")

        // 2. A tile server the rider set: the next route's corridor is prefetched.
        h.model.settings.setTileURLTemplate(Self.customServer)
        XCTAssertEqual(h.model.settings.current.tileURLTemplate, Self.customServer)
        h.model.navigation.loadGpx(data: gpx(45.20), fileName: "custom-b.gpx")
        let prefetched = await eventually { !spy.corridors.current.isEmpty }
        XCTAssertTrue(prefetched, "the custom server gets the corridor")
        XCTAssertEqual(spy.corridors.current.count, 1, "\(spy.corridors.current.count) corridor(s)")
        XCTAssertEqual(try XCTUnwrap(spy.corridors.current.first?.first?.lat), 45.20, accuracy: 1e-9, "route B's corridor")

        // 3. Back to the default (an empty field restores it): the next route asks for nothing.
        h.core.navigation.endNavigation()
        let free = await dashShows(navigating: false)
        XCTAssertTrue(free, "free ride reached RideModel")
        h.model.settings.setTileURLTemplate("")
        XCTAssertEqual(h.model.settings.current.tileURLTemplate, BikeSettings().tileURLTemplate)
        h.model.navigation.loadGpx(data: gpx(45.30), fileName: "osm-c.gpx")
        let routeC = await dashShows(navigating: true)
        XCTAssertTrue(routeC, "route C reached RideModel")
        await settle()
        XCTAssertEqual(spy.corridors.current.map { $0.first?.lat }, [45.20], "never route A or C")
    }

    /// The dash model carries the credit only while the tiles come from the OSMF servers.
    @MainActor
    func testTheDashModelCreditFollowsTheTileServer() async throws {
        let h = AppTestHarness()
        h.ride.flushModel()
        func credit() -> String? {
            let list = h.ride.displayList(now: h.core.services.clock.now())
            return list.commands.compactMap { cmd -> String? in
                if case let .text(s, _, _) = cmd, s == MapTileSource.openStreetMapCredit { return s }
                return nil
            }.first
        }
        // No GPS fix yet: put the rider somewhere so the map (and its credit) is drawn.
        h.location.emit(LocationFix(lat: 45.1, lon: 25.0, speedMps: 0, courseDeg: nil, accuracyM: 5, altitudeM: 400,
                                    timeMs: 1_790_000_000_000))
        let drawn = await eventually { h.ride.flushModel(); return credit() != nil }
        XCTAssertTrue(drawn, "© OpenStreetMap on the default tiles")
        h.model.settings.setTileURLTemplate(Self.customServer)
        h.ride.flushModel()
        XCTAssertNil(credit(), "no label for a custom tile server")
        h.model.settings.setTileURLTemplate("https://a.tile.openstreetmap.org/{z}/{x}/{y}.png")
        h.ride.flushModel()
        XCTAssertEqual(credit(), "© OpenStreetMap")
    }
}
