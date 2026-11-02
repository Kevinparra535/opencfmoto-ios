// SPDX-License-Identifier: AGPL-3.0-or-later
// Snapshot scenes of the dash UI: every scene is built through `DashUIController`, exported to SVG
// and — when `python3 -c "import cairosvg"` works — converted to PNG in docs/screenshots/dash/.
// Set DASH_SNAPSHOTS=0 to skip writing PNGs. The tests never fail because cairosvg is missing.
import Foundation
import XCTest
@testable import OpenCfMotoCore

final class DashSnapshotTests: XCTestCase {
    static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 5 { u.deleteLastPathComponent() }
        return u
    }()
    static let outDir = repoRoot.appendingPathComponent("docs/screenshots/dash", isDirectory: true)

    static let cairoAvailable: Bool = {
        if ProcessInfo.processInfo.environment["DASH_SNAPSHOTS"] == "0" { return false }
        return run(["python3", "-c", "import cairosvg"]) == 0
    }()

    @discardableResult
    static func run(_ args: [String]) -> Int32 {
        #if os(macOS) || os(Linux)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
        #else
        return -1 // no subprocesses on iOS: snapshots are SVG-only there
        #endif
    }

    /// Exports one frame; returns the SVG text. Writes `<name>.png` when cairosvg is available.
    @discardableResult
    func snapshot(_ name: String, _ list: DashDisplayList, file: StaticString = #filePath, line: UInt = #line) -> String {
        let svg = DashSVGExporter().svg(list)
        XCTAssertTrue(svg.hasPrefix("<svg"), file: file, line: line)
        XCTAssertTrue(svg.hasSuffix("</svg>"), file: file, line: line)
        XCTAssertEqual(svg.components(separatedBy: "<g").count - 1, svg.components(separatedBy: "</g>").count - 1,
                       "balanced groups", file: file, line: line)
        guard Self.cairoAvailable else { return svg }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("opencfmoto-dash-snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Self.outDir, withIntermediateDirectories: true)
        let svgURL = tmp.appendingPathComponent("\(name).svg")
        let pngURL = Self.outDir.appendingPathComponent("\(name).png")
        do {
            try svg.write(to: svgURL, atomically: true, encoding: .utf8)
        } catch {
            XCTFail("cannot write \(svgURL.path): \(error)", file: file, line: line)
            return svg
        }
        let status = Self.run(["python3", "-c",
                               "import sys, cairosvg; cairosvg.svg2png(url=sys.argv[1], write_to=sys.argv[2])",
                               svgURL.path, pngURL.path])
        XCTAssertEqual(status, 0, "cairosvg failed for \(name)", file: file, line: line)
        return svg
    }

    private func frame(_ model: DashModel, now: TimeInterval = 100, setup: (DashUIController) -> Void = { _ in }) -> DashDisplayList {
        let ui = DashUIController()
        ui.update(model)
        setup(ui)
        return ui.displayList(now: now)
    }

    private func assertHas(_ list: DashDisplayList, _ ids: [String], file: StaticString = #filePath, line: UInt = #line) {
        let present = Set(list.hitRegions.map(\.id))
        for id in ids { XCTAssertTrue(present.contains(id), "missing hit region \(id)", file: file, line: line) }
    }

    // MARK: Landscape 800×384

    func testLandscapeFreeRide() {
        let list = frame(DashFixtures.freeRide())
        assertHas(list, ["pill", "pill.circuit", "pill.lap", "fab.recenter", "fab.zoomIn", "fab.zoomOut", "fab.compass", "fab.menu"])
        let svg = snapshot("land-free-ride", list)
        XCTAssertTrue(svg.contains(">Search here<"))
        XCTAssertTrue(svg.contains(">Circuit<"))
        XCTAssertTrue(svg.contains(">50<")) // limit sign
        XCTAssertTrue(svg.contains(">42<")) // speed
    }

    func testLandscapePreviewWithTwoChips() {
        let list = frame(DashFixtures.preview())
        assertHas(list, ["preview.go", "preview.chip.0", "preview.chip.1", "preview.save", "preview.circuit", "preview.cancel"])
        let svg = snapshot("land-preview", list)
        XCTAssertTrue(svg.contains(">★ Fast · 14:14 · 10.2 km<"))
        XCTAssertTrue(svg.contains(">Câmpina<"))
    }

    func testLandscapeNavigatingTurnLanesLimit() {
        let list = frame(DashFixtures.navigating())
        assertHas(list, ["metrics.end", "nav.card", "metrics.card", "speed.chip"])
        let svg = snapshot("land-navigating", list)
        XCTAssertTrue(svg.contains(">350 m<"))
        XCTAssertTrue(svg.contains(">TIME<"))
        XCTAssertTrue(svg.contains(">End<"))
    }

    func testLandscapeOffRoute() {
        snapshot("land-off-route", frame(DashFixtures.navigating(offRoute: true)))
    }

    func testLandscapeMenuOpen() {
        let list = frame(DashFixtures.navigating()) { ui in _ = ui.handle(.key(.home), now: 100) }
        assertHas(list, ["dimmer", "menu.end", "menu.park"])
        snapshot("land-menu", list)
    }

    func testLandscapeSearchOpen() {
        let list = frame(DashFixtures.withSearchResults(DashFixtures.freeRide())) { ui in _ = ui.handle(.key(.assistant), now: 100) }
        assertHas(list, ["search.back", "search.chip.0", "search.typeOnPhone", "search.result.0"])
        snapshot("land-search", list)
    }

    func testLandscapeSearchIdle() {
        let list = frame(DashFixtures.freeRide()) { ui in _ = ui.handle(.key(.assistant), now: 100) }
        assertHas(list, ["search.idle.0"])
        snapshot("land-search-idle", list)
    }

    func testLandscapeArriveCard() {
        let list = frame(DashFixtures.arrival())
        assertHas(list, ["arrive.park", "arrive.find", "arrive.done"])
        snapshot("land-arrive", list)
    }

    func testLandscapeNight() {
        var m = DashFixtures.navigating()
        m.isNight = true
        let list = frame(m)
        XCTAssertTrue(list.commands.contains { if case let .tile(_, _, _, _, inv) = $0 { return inv }; return false })
        snapshot("land-night", list)
    }

    func testLandscapeFocusRing() {
        let list = frame(DashFixtures.freeRide()) { ui in
            _ = ui.handle(.knob(1), now: 100)
            _ = ui.handle(.knob(1), now: 100)
        }
        snapshot("land-focus-ring", list)
    }

    func testLandscapePinSetupAndLap() {
        var m = DashFixtures.freeRide()
        let pin = Place(name: "Dropped pin", lat: 45.1285, lon: 25.7365, category: "pin", subtitle: "45.12850, 25.73650")
        m.nav.preview = RoutePreview(place: pin, meta: pin.subtitle, pinMode: true)
        m.lapTimer = DashLapTimer(title: "LAP 2  0:31.20", meta: "LAST 0:30.00   BEST 0:30.00")
        let list = frame(m)
        assertHas(list, ["preview.home", "preview.marker", "preview.cancel", "lap.card"])
        snapshot("land-pin-setup-lap", list)
    }

    func testLandscapeToastAndBanner() {
        var m = DashFixtures.navigating()
        m.linkBanner = "Reconnecting…"
        let list = frame(m) { ui in ui.showToast("Parking marked", now: 99) }
        snapshot("land-toast-banner", list)
    }

    func testHoldScreen() {
        let ui = DashUIController()
        ui.update(DashFixtures.navigating())
        let list = ui.displayList(forHoldScreen: "Paused — open OpenCfMoto on your phone to resume", now: 100)
        XCTAssertTrue(list.hitRegions.isEmpty)
        snapshot("land-hold", list)
    }

    // MARK: Portrait 800×944

    func testPortraitFreeRide() { snapshot("port-free-ride", frame(DashFixtures.freeRide(DashFixtures.port))) }
    func testPortraitPreview() { snapshot("port-preview", frame(DashFixtures.preview(DashFixtures.port))) }
    func testPortraitNavigating() { snapshot("port-navigating", frame(DashFixtures.navigating(DashFixtures.port))) }
    func testPortraitOffRoute() { snapshot("port-off-route", frame(DashFixtures.navigating(DashFixtures.port, offRoute: true))) }
    func testPortraitMenu() {
        snapshot("port-menu", frame(DashFixtures.navigating(DashFixtures.port)) { ui in _ = ui.handle(.key(.home), now: 100) })
    }
    func testPortraitSearch() {
        snapshot("port-search", frame(DashFixtures.withSearchResults(DashFixtures.freeRide(DashFixtures.port))) { ui in
            _ = ui.handle(.key(.assistant), now: 100)
        })
    }
    func testPortraitArrive() { snapshot("port-arrive", frame(DashFixtures.arrival(DashFixtures.port))) }
    func testPortraitNight() {
        var m = DashFixtures.navigating(DashFixtures.port)
        m.isNight = true
        snapshot("port-night", frame(m))
    }
    func testPortraitFocusRing() {
        snapshot("port-focus-ring", frame(DashFixtures.preview(DashFixtures.port)) { ui in _ = ui.handle(.knob(1), now: 100) })
    }

    // MARK: Other canvases

    func testWide1280Navigating() { snapshot("wide-1280-navigating", frame(DashFixtures.navigating(DashFixtures.wide))) }
    func testWide1280Preview() { snapshot("wide-1280-preview", frame(DashFixtures.preview(DashFixtures.wide))) }
    func testNarrow720Navigating() {
        var m = DashFixtures.navigating(DashSize(width: 720, height: 704))
        m.margins = ScreenMargins(customised: false, top: 22)
        snapshot("nkadv-720-navigating", frame(m))
    }
    func testSpanishNavigating() {
        var m = DashFixtures.navigating()
        m.language = .es
        let svg = snapshot("land-navigating-es", frame(m))
        XCTAssertTrue(svg.contains(">TIEMPO<"))
        XCTAssertTrue(svg.contains(">RESTANTE<"))
        XCTAssertTrue(svg.contains(">Fin<"))
    }

    // MARK: Apple Music (iOS addition) — artwork is the exporter's placeholder (gradient + id)

    private let musicNow = DashFixtures.musicNow

    private func music(_ m: DashModel, _ song: DashNowPlaying = DashFixtures.song()) -> DashModel { DashFixtures.withMusic(m, song) }

    /// The Music sheet open (as after ★ on the tile: focus ring on ⏯ unless `handlebarFocus` is off).
    private func sheet(_ model: DashModel, then: (DashUIController) -> Void = { _ in }) -> DashDisplayList {
        frame(model, now: musicNow) { ui in
            _ = ui.perform(.openMusic, now: self.musicNow)
            then(ui)
        }
    }

    private func touchDash(_ m: DashModel) -> DashModel {
        var t = m
        t.handlebarFocus = false
        return t
    }

    func testLandscapeMusicTile() {
        let list = frame(music(DashFixtures.freeRide()), now: musicNow)
        assertHas(list, ["music.tile", "clock", "fab.menu"])
        let svg = snapshot("land-music-tile", list)
        XCTAssertEqual(svg.components(separatedBy: "<linearGradient").count - 1, 1, "the artwork placeholder")
        XCTAssertFalse(svg.contains(">Ruta del Sol (Remastered 2012)<"), "no text on the tile")
    }

    func testLandscapeMusicTileNavigating() {
        snapshot("land-music-tile-nav", frame(music(DashFixtures.navigating()), now: musicNow))
    }

    func testLandscapeMusicPaused() {
        // focus on the tile (one ◀ from the first item): ring around the dimmed cover + ❚❚ badge
        let list = frame(music(DashFixtures.navigating(), DashFixtures.song(.paused)), now: musicNow) { ui in
            _ = ui.handle(.knob(-1), now: self.musicNow)
        }
        snapshot("land-music-paused", list)
    }

    func testLandscapeMusicSheet() {
        let list = sheet(touchDash(music(DashFixtures.freeRide())))
        assertHas(list, ["music.sheet", "music.previous", "music.playPause", "music.next", "music.close"])
        let svg = snapshot("land-music-sheet", list)
        for s in ["Ruta del Sol (Remastered 2012)", "Los Pistones", "Ruta Sessions", "2:13", "-3:51"] {
            XCTAssertTrue(svg.contains(">\(s)<"), s)
        }
    }

    func testLandscapeMusicSheetNavigating() {
        let list = sheet(touchDash(music(DashFixtures.navigating())))
        assertHas(list, ["nav.card", "music.playPause"])
        let svg = snapshot("land-music-sheet-nav", list)
        XCTAssertTrue(svg.contains(">350 m<"))
    }

    func testLandscapeMusicSheetFocus() {
        snapshot("land-music-sheet-focus", sheet(music(DashFixtures.navigating())))
    }

    func testLandscapeMusicSheetSpanish() {
        var m = music(DashFixtures.navigating(), DashFixtures.song(title: ""))
        m.language = .es
        let svg = snapshot("land-music-sheet-es", sheet(m))
        XCTAssertTrue(svg.contains(">Canción desconocida<"))
    }

    func testLandscapeMusicSheetWithoutArtwork() {
        let svg = snapshot("land-music-sheet-noart", sheet(touchDash(music(DashFixtures.freeRide(), DashFixtures.song(artworkId: nil)))))
        XCTAssertFalse(svg.contains("<linearGradient"), "placeholder drawn by the scene only")
    }

    func testLandscapeMusicSheetRadio() {
        let radio = DashFixtures.song(title: "Radio Ruta 101.5", artist: "En directo", album: "", artworkId: "music.art.h0f3a9c1d22b7e406",
                                      duration: 0)
        let svg = snapshot("land-music-sheet-radio", sheet(touchDash(music(DashFixtures.navigating(), radio))))
        XCTAssertFalse(svg.contains(">-"), "no remaining time")
        XCTAssertFalse(svg.contains(">2:13<"))
    }

    func testLandscapeMusicMenu() {
        // "Music" closes the Ride section (focused: scrolled into view)
        let list = frame(music(DashFixtures.navigating()), now: musicNow) { ui in
            _ = ui.handle(.key(.home), now: self.musicNow)
            _ = ui.handle(.knob(7), now: self.musicNow)
        }
        assertHas(list, ["menu.music"])
        let svg = snapshot("land-music-menu", list)
        XCTAssertTrue(svg.contains(">Music<"))
    }

    func testPortraitMusicTileNavigating() {
        snapshot("port-music-tile-nav", frame(music(DashFixtures.navigating(DashFixtures.port)), now: musicNow))
    }

    func testPortraitMusicSheetNavigating() {
        snapshot("port-music-sheet-nav", sheet(touchDash(music(DashFixtures.navigating(DashFixtures.port)))))
    }

    func testWide1280MusicSheet() {
        snapshot("wide-1280-music-sheet", sheet(touchDash(music(DashFixtures.freeRide(DashFixtures.wide)))))
    }

    func testWide1280MusicTileNavigating() {
        snapshot("wide-1280-music-tile-nav", frame(music(DashFixtures.navigating(DashFixtures.wide)), now: musicNow))
    }

    func testNarrow720MusicSheetNavigating() {
        var m = music(DashFixtures.navigating(DashSize(width: 720, height: 704)))
        m.margins = ScreenMargins(customised: false, top: 22)
        snapshot("nkadv-720-music-sheet-nav", sheet(touchDash(m)))
    }

    func testClc450MusicSheet() {
        snapshot("clc450-544-music-sheet", sheet(touchDash(music(DashFixtures.freeRide(DashSize(width: 544, height: 512))))))
    }

    func testMorini1024MusicSheet() {
        snapshot("morini-1024-music-sheet", sheet(touchDash(music(DashFixtures.freeRide(DashSize(width: 1024, height: 464))))))
    }
}
