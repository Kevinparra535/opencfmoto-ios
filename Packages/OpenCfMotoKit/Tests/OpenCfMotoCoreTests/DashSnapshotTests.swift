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
        XCTAssertTrue(svg.contains(">© OpenStreetMap<")) // the map credit (default OSM tiles, §10.4)
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
        assertHas(list, ["nav.card", "metrics.card", "speed.chip", "fab.recenter"])
        // P0: no End on the map (D01, it is in the menu behind a confirmation), no ALT (D12)
        XCTAssertFalse(list.hitRegions.contains { $0.id == "metrics.end" })
        let svg = snapshot("land-navigating", list)
        XCTAssertTrue(svg.contains(">350 m<"))
        XCTAssertTrue(svg.contains(">TIME<"))
        XCTAssertFalse(svg.contains(">End<"))
        XCTAssertFalse(svg.contains(">ALT<"))
        XCTAssertTrue(svg.contains(">© OpenStreetMap<")) // above the metrics card
    }

    func testLandscapeOffRoute() {
        snapshot("land-off-route", frame(DashFixtures.navigating(offRoute: true)))
    }

    func testLandscapeMenuOpen() {
        let list = frame(DashFixtures.navigating()) { ui in _ = ui.handle(.key(.home), now: 100) }
        assertHas(list, ["dimmer", "menu.recenter", "menu.park"]) // opens on Recenter; End is further down (P0)
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
        XCTAssertTrue(list.commands.contains { if case let .tile(_, _, _, _, t) = $0 { return t == .mutedNight }; return false })
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

    // MARK: Fuel MVP: the low-range toast (the existing toast path, under the top chrome, off the speed / limit)

    /// The visible text of an SVG: every `<text>` element's content (tspans removed), joined by spaces.
    private func svgText(_ svg: String) -> String {
        var out: [String] = []
        var rest = svg[...]
        while let open = rest.range(of: "<text "), let close = rest.range(of: "</text>", range: open.upperBound ..< rest.endIndex) {
            let element = rest[open.upperBound ..< close.lowerBound]
            if let gt = element.firstIndex(of: ">") {
                let body = String(element[element.index(after: gt)...])
                    .replacingOccurrences(of: "<tspan[^>]*>", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "</tspan>", with: "")
                out.append(body)
            }
            rest = rest[close.upperBound...]
        }
        return out.joined(separator: " ")
    }

    func testLandscapeFuelLowToastSpanish() {
        var m = DashFixtures.navigating()
        m.language = .es
        let text = DashStrings.fuelToast(.low, range: FuelFormat.range(70, units: .metric), .es)
        XCTAssertEqual(text, "Autonomía baja: ~70 km hasta la reserva")
        let svg = snapshot("land-fuel-low-es", frame(m) { ui in ui.showToast(text, now: 99, duration: 6) })
        XCTAssertTrue(svgText(svg).contains(text), "the whole toast text is drawn: \(svgText(svg))")
    }

    func testLandscapeFuelReserveToast() {
        let text = DashStrings.fuelToast(.reserve, range: FuelFormat.range(0, units: .metric), .en)
        let svg = snapshot("land-fuel-reserve", frame(DashFixtures.freeRide()) { ui in ui.showToast(text, now: 99, duration: 6) })
        XCTAssertTrue(svgText(svg).contains("On reserve: refuel soon"), "the whole toast text is drawn")
    }

    func testClc450FuelLowToastSpanish() {
        var m = DashFixtures.navigating(DashSize(width: 544, height: 512))
        m.language = .es
        let text = DashStrings.fuelToast(.low, range: FuelFormat.range(8, units: .metric), .es)
        let svg = snapshot("clc450-544-fuel-low-es", frame(m) { ui in ui.showToast(text, now: 99, duration: 6) })
        XCTAssertTrue(svgText(svg).contains(text), "the whole (longest) toast text is drawn: \(svgText(svg))")
    }

    func testHoldScreen() {
        // P0 (D17): what the app serves (no message of its own): «Map paused», no map and no stale numbers.
        let ui = DashUIController()
        ui.update(DashFixtures.navigating())
        let list = ui.displayList(forHoldScreen: nil, now: 100)
        XCTAssertTrue(list.hitRegions.isEmpty)
        let svg = snapshot("land-hold", list)
        XCTAssertTrue(svg.contains(">Map paused<"))
        XCTAssertTrue(svg.contains(">Voice keeps guiding<"))
        XCTAssertFalse(list.commands.contains { if case .tile = $0 { return true }; return false }, "no map")
        let texts = list.commands.compactMap { if case let .text(s, _, _) = $0 { return s }; return nil }
        XCTAssertFalse(texts.contains { $0.contains(where: \.isNumber) }, "no numbers: \(texts)")
    }

    // MARK: P0 (D01, D06): the confirm card, End in the menu, the night search surfaces

    /// From the map while navigating: HOME, the knob to «End route…» (scrolled clear of the speed gauge).
    private func focusMenuEnd(_ ui: DashUIController) {
        _ = ui.handle(.key(.home), now: 100)
        let order = ui.state.focusOrder
        let at = ui.state.focusedId.flatMap { order.firstIndex(of: $0) } ?? 0
        _ = ui.handle(.knob((order.firstIndex(of: DashFocusEngine.menuEndId) ?? at) - at), now: 100)
        XCTAssertEqual(ui.state.focusedId, DashFocusEngine.menuEndId)
    }

    func testLandscapeMenuEndFocused() {
        snapshot("land-menu-end", frame(DashFixtures.navigating()) { ui in self.focusMenuEnd(ui) })
    }

    func testLandscapeConfirmEnd() {
        let list = frame(DashFixtures.navigating()) { ui in
            self.focusMenuEnd(ui)
            XCTAssertEqual(ui.handle(.key(.enter), now: 100), [])
            XCTAssertEqual(ui.state.focusedId, DashFocusEngine.confirmKeepId)
        }
        assertHas(list, [DashFocusEngine.confirmKeepId, DashFocusEngine.confirmActId, "speed.chip", "nav.card"])
        let svg = snapshot("land-confirm-end", list)
        XCTAssertTrue(svg.contains(">End the route?<"))
        XCTAssertTrue(svg.contains(">Keep going<"))
    }

    func testPortraitConfirmEndSpanish() {
        var m = DashFixtures.navigating(DashFixtures.port)
        m.language = .es
        let svg = snapshot("port-confirm-end-es", frame(m) { ui in
            self.focusMenuEnd(ui)
            _ = ui.handle(.key(.enter), now: 100)
        })
        XCTAssertTrue(svg.contains(">¿Terminar la ruta?<"))
        XCTAssertTrue(svg.contains(">Seguir<"))
        XCTAssertTrue(svg.contains(">Terminar<"))
    }

    func testLandscapeConfirmChange() {
        var m = DashFixtures.navigating()
        m.nav.preview = DashFixtures.preview().nav.preview
        let list = frame(m) { ui in XCTAssertEqual(ui.handle(.key(.enter), now: 100), []) }
        let svg = snapshot("land-confirm-change", list)
        XCTAssertTrue(svg.contains(">Change route?<"))
    }

    func testLandscapeNightFreeRide() {
        var m = DashFixtures.freeRide()
        m.isNight = true
        let list = frame(m)
        // the dark search pill (D06): no white surface after dark
        XCTAssertFalse(list.commands.contains { if case let .fill(_, c, _) = $0 { return c == DashPalette.searchDay.pillFill }; return false })
        snapshot("land-night-free-ride", list)
    }

    func testLandscapeNightSearch() {
        var m = DashFixtures.withSearchResults(DashFixtures.freeRide())
        m.isNight = true
        let list = frame(m) { ui in _ = ui.handle(.key(.assistant), now: 100) }
        XCTAssertTrue(list.commands.contains { if case let .fill(_, c, _) = $0 { return c == DashPalette.searchNight.sheetBackground }; return false })
        XCTAssertFalse(list.commands.contains { if case let .fill(_, c, _) = $0 { return c == DashPalette.searchDay.sheetBackground }; return false })
        snapshot("land-night-search", list)
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
        XCTAssertFalse(svg.contains(">Fin<"), "P0 (D01): no End on the map")
        XCTAssertFalse(svg.contains(">ALT<"), "P0 (D12): no ALT")
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

    /// Fix F3: the ring on the tile has no fill and runs OUTSIDE the cover (the artwork stays clean).
    private func focusedTile(_ model: DashModel, _ state: DashNowPlaying.State) -> DashDisplayList {
        let list = frame(music(model, DashFixtures.song(state)), now: musicNow) { ui in
            _ = ui.handle(.knob(-1), now: self.musicNow)
            XCTAssertEqual(ui.state.focusedId, "music.tile")
        }
        let tile = try! XCTUnwrap(list.hitRegions.last { $0.id == "music.tile" }).rect
        // a wash = a fill in the ring's colours over at least half the cover (its own white glyphs are smaller)
        XCTAssertFalse(list.commands.contains {
            if case let .fill(p, c, _) = $0, c == DashPalette.focusStroke || c == DashPalette.focusEdge, let b = p.controlPointBounds {
                let w = min(b.maxX, tile.maxX) - max(b.minX, tile.minX), h = min(b.maxY, tile.maxY) - max(b.minY, tile.minY)
                return w > 0 && h > 0 && w * h >= 0.5 * tile.width * tile.height
            }
            return false
        }, "no wash over the cover")
        return list
    }

    func testLandscapeMusicTileFocus() {
        snapshot("land-music-tile-focus", focusedTile(DashFixtures.navigating(), .playing))
    }

    func testLandscapeMarginsMusicTileFocus() {
        // the tightest landscape case: 1 px from the safe area's right edge, 3 px under the Menu FAB,
        // the clock gives way
        var m = DashFixtures.navigating()
        m.margins = ScreenMargins(top: 22, bottom: 10, left: 12, right: 14)
        snapshot("land-margins-music-tile-focus", focusedTile(m, .playing))
    }

    func testPortraitMusicPausedFocus() {
        // portrait: the ring ends 3 px under the clock chip
        snapshot("port-music-paused-focus", focusedTile(DashFixtures.navigating(DashFixtures.port), .paused))
    }

    func testLandscapeMusicSheet() {
        let list = sheet(touchDash(music(DashFixtures.freeRide())))
        assertHas(list, ["music.sheet", "music.previous", "music.playPause", "music.next", "music.close"])
        let svg = snapshot("land-music-sheet", list)
        for s in ["Ruta del Sol (Remastered 2012)", "Los Pistones", "Ruta Sessions", "2:13", "-3:51"] {
            XCTAssertTrue(svg.contains(">\(s)<"), s)
        }
        XCTAssertFalse(svg.contains("OpenStreetMap"), "no map under the opaque sheet, so no map credit")
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
        // "Music" right after the menu's default item, Recenter (P0, D01), focused
        let list = frame(music(DashFixtures.navigating()), now: musicNow) { ui in
            _ = ui.handle(.key(.home), now: self.musicNow)
            _ = ui.handle(.knob(1), now: self.musicNow)
            XCTAssertEqual(ui.state.focusedId, "menu.music")
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
