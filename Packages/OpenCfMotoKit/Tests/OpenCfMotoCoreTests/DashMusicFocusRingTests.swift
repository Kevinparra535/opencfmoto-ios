// SPDX-License-Identifier: AGPL-3.0-or-later
// Apple Music (iOS addition), fix F3: the handlebar focus ring parks on the now-playing tile after every
// close of the Music sheet, so on the tile it has no fill and is stroked OUTSIDE the cover (the artwork
// stays clean). On every supported canvas and map state the outset ring stays inside the canvas and the
// safe area and clear of every other widget: hit regions and drawings (FABs, clock, cards, toasts).
// P0 (D09): that outset ring is now the ring of every control — the same 5-dp footprint, black with a white
// core instead of orange.
import XCTest
@testable import OpenCfMotoCore

final class DashMusicFocusRingTests: XCTestCase {
    private let t0 = DashFixtures.musicNow

    /// The canvases of fix F3 (screen margins: the 800×384 worst case of the tile tests; the NK
    /// Advanced's 22-px pull-down zone on 720×704).
    private let canvases: [(String, DashSize, ScreenMargins)] = [
        ("800×384", DashSize(width: 800, height: 384), .zero),
        ("800×384 margins", DashSize(width: 800, height: 384), ScreenMargins(top: 22, bottom: 10, left: 12, right: 14)),
        ("800×400", DashSize(width: 800, height: 400), .zero),
        ("800×944", DashSize(width: 800, height: 944), .zero),
        ("720×704", DashSize(width: 720, height: 704), ScreenMargins(customised: false, top: 22)),
        ("544×512", DashSize(width: 544, height: 512), .zero),
        ("1024×464", DashSize(width: 1024, height: 464), .zero),
        ("1280×576", DashSize(width: 1280, height: 576), .zero),
    ]

    /// Map states in which the tile is focusable, with what can sit next to it.
    private func states(_ size: DashSize) -> [(String, DashModel)] {
        let lap = DashLapTimer(title: "Lap 3 · 1:02.4", meta: "Best 0:59.8 · last 1:01.2")
        var lapFree = DashFixtures.freeRide(size), lapNav = DashFixtures.navigating(size)
        lapFree.lapTimer = lap
        lapNav.lapTimer = lap
        var overlays = DashFixtures.navigating(size)
        overlays.linkBanner = "Reconnecting…"
        overlays.toastText = "Handlebar buttons control the dash again"
        var night = DashFixtures.navigating(size)
        night.isNight = true
        var noClock = DashFixtures.freeRide(size)
        noClock.showClock = false
        return [("free", DashFixtures.freeRide(size)), ("nav", DashFixtures.navigating(size)),
                ("off-route", DashFixtures.navigating(size, offRoute: true)), ("lap", lapFree), ("lap nav", lapNav),
                ("banner+toast", overlays), ("night", night), ("no clock", noClock)]
    }

    private struct Ring {
        /// The stroked path's box and the stroke width.
        var path: DashRect, width: Double
        /// What the stroke paints: from `inner` to `outer`.
        var outer: DashRect { path.insetBy(dx: -width / 2, dy: -width / 2) }
        var inner: DashRect { path.insetBy(dx: width / 2, dy: width / 2) }
    }

    /// The rings' footprints: the black band (its white core is checked to share its path).
    private func rings(_ list: DashDisplayList) -> [Ring] {
        let cores = Set(list.commands.compactMap { cmd -> DashPath? in
            if case let .stroke(p, s) = cmd, s.color == DashPalette.focusStroke, s.join == .round, s.cap == .butt { return p }
            return nil
        })
        return list.commands.compactMap {
            guard case let .stroke(p, s) = $0, s.color == DashPalette.focusEdge, let b = p.controlPointBounds else { return nil }
            XCTAssertTrue(cores.contains(p), "the white core runs on the black band")
            return Ring(path: b, width: s.width)
        }
    }

    /// Fills in the focus colours that wash the focused control `r` (covering at least half of it): none,
    /// ever. The controls' own white glyphs (icons, the progress bar) are much smaller and do not count.
    private func focusFills(_ list: DashDisplayList, over r: DashRect) -> [DashRect] {
        list.commands.compactMap {
            guard case let .fill(p, c, _) = $0, c == DashPalette.focusStroke || c == DashPalette.focusEdge,
                  let b = p.controlPointBounds else { return nil }
            let w = min(b.maxX, r.maxX) - max(b.minX, r.minX), h = min(b.maxY, r.maxY) - max(b.minY, r.minY)
            return w > 0 && h > 0 && w * h >= 0.5 * r.width * r.height ? b : nil
        }
    }

    /// What a screen-space command paints (nil: no geometry of its own).
    private func painted(_ c: DashDrawCommand) -> DashRect? {
        switch c {
        case let .fill(p, _, _): return p.controlPointBounds
        case let .stroke(p, s): return p.controlPointBounds?.insetBy(dx: -s.width / 2, dy: -s.width / 2)
        case let .text(_, r, _): return r
        case let .image(_, r, _): return r
        default: return nil
        }
    }

    private func within(_ r: DashRect, _ outer: DashRect, _ eps: Double = 1e-6) -> Bool {
        r.minX >= outer.minX - eps && r.maxX <= outer.maxX + eps && r.minY >= outer.minY - eps && r.maxY <= outer.maxY + eps
    }

    private func same(_ a: DashRect, _ b: DashRect) -> Bool {
        abs(a.minX - b.minX) < 1e-6 && abs(a.minY - b.minY) < 1e-6 && abs(a.maxX - b.maxX) < 1e-6 && abs(a.maxY - b.maxY) < 1e-6
    }

    /// Smallest distance between two disjoint rects (0 when they touch or overlap).
    private func gap(_ a: DashRect, _ b: DashRect) -> Double {
        let dx = max(0, max(a.minX - b.maxX, b.minX - a.maxX)), dy = max(0, max(a.minY - b.maxY, b.minY - a.maxY))
        return hypot(dx, dy)
    }

    /// The chrome: every command from the first one that paints exactly a widget's frame (the first
    /// card, the search pill or the first FAB, drawn right after the map and its markers) to the end,
    /// overlays included. The map layer is under every piece of chrome anyway.
    private func chrome(_ list: DashDisplayList) -> ArraySlice<DashDrawCommand> {
        let frames = list.hitRegions.filter { $0.id != "music.tile" }.map(\.rect)
        let start = list.commands.firstIndex { cmd in painted(cmd).map { p in frames.contains { same($0, p) } } ?? false }
        return list.commands[(start ?? list.commands.count)...]
    }

    func testTheRingAroundTheTileStaysOutsideTheCoverAndClearOfEverythingOnEveryCanvas() {
        for (name, size, margins) in canvases {
            var closest = (Double.infinity, ""), closestEdge = (Double.infinity, "")
            for (state, base) in states(size) {
                for song in [DashFixtures.song(.playing), DashFixtures.song(.paused)] {
                    let tag = "\(name) \(state) \(song.state)"
                    var m = DashFixtures.withMusic(base, song)
                    m.margins = margins
                    let ui = DashUIController()
                    ui.update(m)
                    _ = ui.handle(.knob(-1), now: t0) // one ◀ from the default item
                    XCTAssertEqual(ui.state.focusedId, "music.tile", tag)
                    let list = ui.displayList(now: t0)
                    guard let tile = list.hitRegions.last(where: { $0.id == "music.tile" })?.rect else {
                        XCTFail("\(tag): no tile")
                        continue
                    }
                    // no wash over the cover, one ring whose inner edge is the cover's edge
                    XCTAssertEqual(focusFills(list, over: tile), [], tag)
                    let found = rings(list)
                    XCTAssertEqual(found.count, 1, tag)
                    guard let ring = found.first else { continue }
                    let ctx = DashLayoutContext(model: m, measurer: ApproximateTextMeasurer())
                    XCTAssertEqual(ring.width, ctx.dp(DashPalette.focusEdgeWidth), accuracy: 1e-9, tag)
                    XCTAssertTrue(same(ring.inner, tile), "\(tag): ring inner edge \(ring.inner) ≠ cover \(tile)")
                    // inside the canvas and the safe area
                    let canvas = DashRect(x: 0, y: 0, width: size.width, height: size.height)
                    XCTAssertTrue(within(ring.outer, canvas), "\(tag): \(ring.outer) leaves the canvas")
                    XCTAssertTrue(within(ring.outer, m.safeRect), "\(tag): \(ring.outer) leaves the safe area \(m.safeRect)")
                    // clear of every other hit region…
                    for r in list.hitRegions where r.id != "music.tile" {
                        XCTAssertFalse(ring.outer.intersects(r.rect), "\(tag): ring \(ring.outer) on \(r.id) \(r.rect)")
                        if gap(ring.outer, r.rect) < closest.0 { closest = (gap(ring.outer, r.rect), "\(r.id) (\(state))") }
                    }
                    // … and of every other drawing (the tile's own drawing lies inside the cover); the
                    // checked commands start at the first card and include every neighbour
                    let drawn = chrome(list).compactMap(painted)
                    for id in ["pill", "nav.card", "lap.card", "metrics.card", "fab.recenter", "fab.menu", "clock"] {
                        guard let r = list.hitRegions.last(where: { $0.id == id })?.rect else { continue }
                        XCTAssertTrue(drawn.contains { same($0, r) }, "\(tag): the drawing check misses \(id)")
                    }
                    if let r = list.hitRegions.last(where: { $0.id == "speed.chip" })?.rect { // gauge ∪ limit sign
                        XCTAssertTrue(drawn.contains { within($0, r) }, "\(tag): the drawing check misses speed.chip")
                    }
                    for cmd in chrome(list) {
                        guard let p = painted(cmd), !within(p, tile) else { continue }
                        if case let .stroke(_, s) = cmd, s.color == DashPalette.focusStroke || s.color == DashPalette.focusEdge { continue }
                        XCTAssertFalse(ring.outer.intersects(p), "\(tag): ring \(ring.outer) on a drawing \(p): \(cmd)")
                    }
                    let edges = [ring.outer.minY - m.safeRect.minY, m.safeRect.maxX - ring.outer.maxX, m.safeRect.maxY - ring.outer.maxY]
                    if let e = edges.min(), e < closestEdge.0 { closestEdge = (e, state) }
                }
            }
            // how close the ring comes (for the review): ≥ 1 px from the safe edge, ≥ 3 px from a widget
            XCTAssertGreaterThanOrEqual(closestEdge.0, 1 - 1e-9, name)
            XCTAssertGreaterThanOrEqual(closest.0, 3 - 1e-9, name)
            print("F3 ring \(name): \(String(format: "%.2f", closest.0)) px from \(closest.1), "
                + "\(String(format: "%.2f", closestEdge.0)) px from the safe-area edge (\(closestEdge.1))")
        }
    }

    func testEveryFocusRingIsAnOutlineOutsideTheControl() {
        // P0 (D09): FABs (circular) and rectangular controls get the tile's ring — no fill over the control,
        // the band starts at its edge (Android: a 40 % orange fill and a stroke inside the control).
        let ui = DashUIController()
        ui.update(DashFixtures.withMusic(DashFixtures.navigating(), DashFixtures.song()))
        let recenter = ui.displayList(now: t0) // default focus while navigating: Recenter (P0, D01)
        XCTAssertEqual(ui.state.focusedId, "fab.recenter")
        let recenterRect = try! XCTUnwrap(recenter.hitRegions.last { $0.id == "fab.recenter" }?.rect)
        XCTAssertEqual(focusFills(recenter, over: recenterRect), [])
        XCTAssertTrue(same(try! XCTUnwrap(rings(recenter).first).inner, recenterRect))
        _ = ui.handle(.knob(-2), now: t0) // ◀◀ → the tile → fab.menu
        XCTAssertEqual(ui.state.focusedId, "fab.menu")
        let fab = ui.displayList(now: t0)
        let fabRect = try! XCTUnwrap(fab.hitRegions.last { $0.id == "fab.menu" }?.rect)
        XCTAssertEqual(focusFills(fab, over: fabRect), [])
        XCTAssertTrue(same(try! XCTUnwrap(rings(fab).first).inner, fabRect))
        // a rectangular control: the menu's first item
        _ = ui.handle(.key(.enter), now: t0 + 1)
        XCTAssertEqual(ui.state.focusedId, "menu.recalc")
        let menu = ui.displayList(now: t0 + 1)
        let item = try! XCTUnwrap(menu.hitRegions.last { $0.id == "menu.recalc" }?.rect)
        XCTAssertEqual(focusFills(menu, over: item), [])
        XCTAssertTrue(same(try! XCTUnwrap(rings(menu).first).inner, item))
    }

    func testTheCoverIsNotWashedOutAfterTheSheetCloses() {
        // The reported case: touch dash, tap the tile, tap ✕ → the focus parks on the tile; once the ring
        // shows again (5 s after the touch, or on a non-touch dash at once) it must not tint the cover.
        let ui = DashUIController()
        ui.update(DashFixtures.withMusic(DashFixtures.freeRide(), DashFixtures.song(.paused)))
        func tap(_ id: String, _ t: TimeInterval) {
            let p = try! XCTUnwrap(ui.displayList(now: t).hitRegions.last { $0.id == id }).rect.center
            _ = ui.handle(.touch(DashTouch(action: .down, pointerId: 0, x: Int(p.x), y: Int(p.y), time: t)), now: t)
            _ = ui.handle(.touch(DashTouch(action: .up, pointerId: 0, x: Int(p.x), y: Int(p.y), time: t + 0.05)), now: t + 0.05)
        }
        tap("music.tile", t0)
        tap("music.close", t0 + 2)
        XCTAssertEqual(ui.state.focusedId, "music.tile")
        XCTAssertTrue(rings(ui.displayList(now: t0 + 3)).isEmpty, "hidden for 5 s after a touch")
        for t in [t0 + 7.2, t0 + 62] {
            let list = ui.displayList(now: t)
            let tile = try! XCTUnwrap(list.hitRegions.last { $0.id == "music.tile" }).rect
            XCTAssertEqual(focusFills(list, over: tile), [], "t+\(t - t0)")
            // exactly the ring's two strokes: the cover's rounded rect (radius 10 dp) grown by half the 5-dp
            // band, so the band starts at the cover's edge and follows its corners — black, then its white core
            let sw = DashPalette.focusEdgeWidth
            let path = DashPath.roundedRect(tile.insetBy(dx: -sw / 2, dy: -sw / 2), radius: DashDimens.musicTileRadius + sw / 2)
            let expected: [DashDrawCommand] = [
                .stroke(path, DashStroke(width: sw, color: DashPalette.focusEdge, cap: .butt, join: .round)),
                .stroke(path, DashStroke(width: DashPalette.focusStrokeWidth, color: DashPalette.focusStroke, cap: .butt, join: .round)),
            ]
            XCTAssertEqual(list.commands.filter {
                if case let .stroke(_, s) = $0 { return (s.color == DashPalette.focusStroke || s.color == DashPalette.focusEdge) && s.join == .round && s.cap == .butt }
                return false
            }, expected, "t+\(t - t0)")
            XCTAssertTrue(same(try! XCTUnwrap(rings(list).first).inner, tile))
        }
    }
}
