// SPDX-License-Identifier: AGPL-3.0-or-later
// An opened GPX shows a preview instead of silently replacing the navigation (UI/UX P0, UX-17):
// a file opened from another app (AppModel.handleOpenURL) or picked in the Map hub becomes
// `NavigationModel.pendingGpx` and changes nothing; «Seguir este track» follows it, «Cancelar» drops
// it; unreadable files report an error and keep an earlier preview; big files are parsed off the main
// actor and a newer file wins; the card's summary and "replaces …" lines.
import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class GpxPreviewTests: XCTestCase {
    static let loop = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="test"><trk><name>Loop</name><trkseg>
    <trkpt lat="4.6584" lon="-74.0930"></trkpt><trkpt lat="4.6600" lon="-74.0900"></trkpt>
    <trkpt lat="4.6650" lon="-74.0850"></trkpt>
    </trkseg></trk>
    <wpt lat="4.6600" lon="-74.0900"><name>Café</name></wpt>
    <wpt lat="4.6650" lon="-74.0850"><name>Mirador</name></wpt>
    </gpx>
    """

    private func tempFile(_ name: String, _ text: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gpx-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    @MainActor
    func testAnOpenedGpxIsAPreviewThatReplacesNothingUntilFollowed() async throws {
        let h = AppTestHarness()
        let nav = h.model.navigation
        let strings = LogicData.Strings(h.language)
        h.location.emit(LocationFix(lat: 4.6584, lon: -74.0930, speedMps: 0, timeMs: 1_790_000_000_000))
        let home = Place(name: "Casa", lat: 4.70, lon: -74.04)
        h.core.navigation.navigate(to: home)
        _ = await eventually { nav.snapshot.mode == .navTo(home) }

        let url = try tempFile("Loop.gpx", Self.loop)
        XCTAssertNil(h.model.handleOpenURL(url), "no banner: the preview is the answer")
        XCTAssertNil(h.model.banner)
        let preview = try XCTUnwrap(nav.pendingGpx)
        XCTAssertEqual(preview.name, "Loop")
        XCTAssertEqual(preview.fileName, "Loop.gpx")
        XCTAssertEqual(preview.track.points.count, 3)
        XCTAssertEqual(preview.outline.count, 3)
        XCTAssertGreaterThan(preview.lengthMeters, 900)
        XCTAssertEqual(nav.pendingGpxReplaces, strings.gpxReplacesRoute("Casa"))
        // Nothing changed: still navigating home, the dash too.
        await settle(0.1)
        XCTAssertEqual(nav.snapshot.mode, .navTo(home))
        XCTAssertEqual(h.core.navigation.snapshot.mode, .navTo(home))
        XCTAssertFalse(nav.history.contains { $0.category == "gpx" })

        // «Seguir este track»: now, at the rider's word.
        nav.followPendingGpx()
        XCTAssertNil(nav.pendingGpx)
        XCTAssertEqual(h.core.navigation.snapshot.mode, .gpx(name: "Loop"))
        await LDTest.expect { nav.snapshot.mode == .gpx(name: "Loop") }
        await LDTest.expect { nav.history.contains { $0.category == "gpx" && $0.name == "Loop" } }
        nav.followPendingGpx() // nothing pending: no-op
        XCTAssertEqual(h.core.navigation.snapshot.mode, .gpx(name: "Loop"))
    }

    @MainActor
    func testCancelDropsThePreviewAndChangesNothing() async throws {
        let h = AppTestHarness()
        let nav = h.model.navigation
        nav.previewGpx(data: Data(Self.loop.utf8), fileName: "Loop.gpx")
        XCTAssertNotNil(nav.pendingGpx)
        XCTAssertNil(nav.pendingGpxReplaces, "free ride: nothing to replace")
        nav.cancelPendingGpx()
        XCTAssertNil(nav.pendingGpx)
        await settle(0.1)
        XCTAssertEqual(h.core.navigation.snapshot.mode, .freeRide)
        XCTAssertNil(nav.pendingGpxReplaces)
    }

    @MainActor
    func testTheReplacesLineNamesTheTrackBeingFollowed() async throws {
        let h = AppTestHarness()
        let nav = h.model.navigation
        let strings = LogicData.Strings(h.language)
        nav.loadGpx(data: Data(Self.loop.utf8), fileName: "Loop.gpx")
        await LDTest.expect { nav.snapshot.mode == .gpx(name: "Loop") }
        nav.previewGpx(data: Data(Self.loop.replacingOccurrences(of: "<name>Loop</name>", with: "<name>Sierra</name>").utf8),
                       fileName: "Sierra.gpx")
        XCTAssertEqual(nav.pendingGpx?.name, "Sierra")
        XCTAssertEqual(nav.pendingGpxReplaces, strings.gpxReplacesTrack("Loop"))
        // Loading a file directly (the API) supersedes a waiting preview.
        nav.loadGpx(data: Data(Self.loop.utf8), fileName: "Loop.gpx")
        XCTAssertNil(nav.pendingGpx)
    }

    @MainActor
    func testAnUnreadableFileReportsAndKeepsTheEarlierPreview() async throws {
        let h = AppTestHarness()
        let nav = h.model.navigation
        let strings = LogicData.Strings(h.language)
        nav.previewGpx(data: Data(Self.loop.utf8), fileName: "Loop.gpx")
        let first = try XCTUnwrap(nav.pendingGpx)
        nav.previewGpx(data: Data("<gpx version=\"1.1\"></gpx>".utf8), fileName: "empty.gpx")
        XCTAssertEqual(nav.lastError, strings.gpxEmpty)
        XCTAssertEqual(nav.pendingGpx, first)
        // Through AppModel the error is the banner.
        let url = try tempFile("empty.gpx", "<gpx version=\"1.1\"></gpx>")
        nav.dismissError()
        XCTAssertEqual(h.model.handleOpenURL(url), strings.gpxEmpty)
    }

    @MainActor
    func testBigFilesAreParsedOffTheMainActorAndTheNewestFileWins() async throws {
        let h = AppTestHarness()
        let nav = h.model.navigation
        nav.synchronousGpxLimit = 16
        nav.previewGpx(data: Data(Self.loop.utf8), fileName: "Loop.gpx")
        nav.previewGpx(data: Data(Self.loop.replacingOccurrences(of: "<name>Loop</name>", with: "<name>Newer</name>").utf8),
                       fileName: "Newer.gpx")
        await LDTest.expect { nav.pendingGpx?.name == "Newer" }
        await settle(0.2)
        XCTAssertEqual(nav.pendingGpx?.name, "Newer", "the older parse never lands after the newer one")
        // A file still being parsed never replaces the track the rider just chose.
        nav.previewGpx(data: Data(Self.loop.utf8), fileName: "Loop.gpx")
        nav.followPendingGpx() // follows "Newer"
        XCTAssertEqual(h.core.navigation.snapshot.mode, .gpx(name: "Newer"))
        await settle(0.3)
        XCTAssertNil(nav.pendingGpx)
        XCTAssertEqual(h.core.navigation.snapshot.mode, .gpx(name: "Newer"))
    }

    @MainActor
    func testTheSummaryLine() async throws {
        let h = AppTestHarness()
        let nav = h.model.navigation
        let strings = LogicData.Strings(h.language)
        let units = h.core.currentSettings.map.units
        let distance = NavStrings(language: h.language, decimalSeparator: h.language.conventionalDecimalSeparator)
        nav.previewGpx(data: Data(Self.loop.utf8), fileName: "Loop.gpx")
        let preview = try XCTUnwrap(nav.pendingGpx)
        XCTAssertEqual(nav.summary(of: preview),
                       distance.distance(preview.lengthMeters, units) + " \u{00B7} " + strings.gpxWaypoints(2))
        // Waypoints only: no length, the waypoints are what the map draws.
        let wptOnly = #"<gpx version="1.1"><wpt lat="4.65" lon="-74.09"><name>A</name></wpt></gpx>"#
        nav.previewGpx(data: Data(wptOnly.utf8), fileName: "Stops.gpx")
        let stops = try XCTUnwrap(nav.pendingGpx)
        XCTAssertEqual(stops.lengthMeters, 0)
        XCTAssertEqual(stops.outline.count, 1)
        XCTAssertEqual(stops.name, "Stops")
        XCTAssertEqual(nav.summary(of: stops), strings.gpxWaypoints(1))
        // A track without waypoints: the length alone.
        let trackOnly = #"<gpx version="1.1"><trk><trkseg><trkpt lat="4.65" lon="-74.09"/><trkpt lat="4.66" lon="-74.08"/></trkseg></trk></gpx>"#
        nav.previewGpx(data: Data(trackOnly.utf8), fileName: "Line.gpx")
        let line = try XCTUnwrap(nav.pendingGpx)
        XCTAssertEqual(nav.summary(of: line), distance.distance(line.lengthMeters, units))
    }

    func testPreviewStringsAreTranslated() {
        let en = LogicData.Strings(.en), es = LogicData.Strings(.es)
        XCTAssertEqual(en.gpxWaypoints(1), "1 waypoint")
        XCTAssertEqual(en.gpxWaypoints(3), "3 waypoints")
        XCTAssertEqual(es.gpxWaypoints(1), "1 punto de paso")
        XCTAssertEqual(es.gpxWaypoints(3), "3 puntos de paso")
        XCTAssertEqual(en.gpxReplacesRoute("Casa"), "Replaces the route to Casa")
        XCTAssertEqual(es.gpxReplacesRoute("Casa"), "Reemplaza la ruta a Casa")
        XCTAssertEqual(en.gpxReplacesTrack("Loop"), "Replaces the track \u{201C}Loop\u{201D}")
        XCTAssertEqual(es.gpxReplacesTrack("Loop"), "Reemplaza el track \u{00AB}Loop\u{00BB}")
    }
}
