// SPDX-License-Identifier: AGPL-3.0-or-later
// Apple Music (iOS addition): the now-playing tile, the Music sheet and their rules in the dash UI
// controller — visibility, focus orders and handlebar flows, touch targets, the safety auto-close
// rules (idle while moving, near the next turn), closing transitions, re-render cadence, menu entry.
import Foundation
import XCTest
@testable import OpenCfMotoCore

final class DashMusicControllerTests: XCTestCase {
    private let t0 = DashFixtures.musicNow

    // MARK: Helpers

    private func region(_ list: DashDisplayList, _ id: String, file: StaticString = #filePath, line: UInt = #line) -> DashHitRegion? {
        let r = list.hitRegions.last(where: { $0.id == id })
        if r == nil { XCTFail("no region \(id)", file: file, line: line) }
        return r
    }

    private func has(_ list: DashDisplayList, _ id: String) -> Bool { list.hitRegions.contains { $0.id == id } }

    private func touch(_ ui: DashUIController, _ a: DashTouch.Action, _ p: DashPoint, _ t: TimeInterval) -> [DashIntent] {
        ui.handle(.touch(DashTouch(action: a, pointerId: 0, x: Int(p.x), y: Int(p.y), time: t)), now: t)
    }

    private func tap(_ ui: DashUIController, _ p: DashPoint, at t: TimeInterval) -> [DashIntent] {
        touch(ui, .down, p, t) + touch(ui, .up, p, t + 0.05)
    }

    private func tapRegion(_ ui: DashUIController, _ id: String, at t: TimeInterval, file: StaticString = #filePath,
                           line: UInt = #line) -> [DashIntent] {
        guard let r = region(ui.displayList(now: t), id, file: file, line: line) else { return [] }
        return tap(ui, r.rect.center, at: t)
    }

    private func controller(_ model: DashModel, options: DashUIController.Options = .init()) -> DashUIController {
        let ui = DashUIController(options: options)
        ui.update(model)
        return ui
    }

    private func texts(_ list: DashDisplayList) -> [String] {
        list.commands.compactMap { if case let .text(s, _, _) = $0 { return s }; return nil }
    }

    private func images(_ list: DashDisplayList) -> [String] {
        list.commands.compactMap { if case let .image(id, _, _) = $0 { return id }; return nil }
    }

    private let fabs = ["fab.recenter", "fab.zoomIn", "fab.zoomOut", "fab.compass", "fab.menu"]

    private func music(_ m: DashModel, _ song: DashNowPlaying = DashFixtures.song()) -> DashModel { DashFixtures.withMusic(m, song) }

    /// Free ride (or `base`) with the fix at `kmh`, music loaded.
    private func moving(_ kmh: Double?, _ base: DashModel = DashFixtures.freeRide()) -> DashModel {
        var m = music(base)
        m.fix = kmh.map { DashFixtures.fix(kmh: $0) }
        return m
    }

    // MARK: Tile visibility and focus orders

    func testTileOnlyWithMusicAndWithoutSheet() {
        XCTAssertFalse(has(controller(DashFixtures.freeRide()).displayList(now: t0), "music.tile"))
        let ui = controller(music(DashFixtures.freeRide()))
        let list = ui.displayList(now: t0)
        let tile = region(list, "music.tile")
        XCTAssertEqual(tile?.rect, DashRect(x: 730, y: 270, width: 64, height: 64))
        XCTAssertEqual(tile?.focusable, true)
        XCTAssertEqual(images(list), ["music.art.p1f"])
        XCTAssertTrue(has(list, "clock"))
        XCTAssertFalse(texts(list).contains("Ruta del Sol (Remastered 2012)"), "no text on the tile")
        // any sheet hides it
        _ = ui.perform(.openMenu, now: t0 + 1)
        XCTAssertFalse(has(ui.displayList(now: t0 + 1), "music.tile"))
        _ = ui.perform(.openSearch, now: t0 + 2)
        XCTAssertFalse(has(ui.displayList(now: t0 + 2), "music.tile"))
        // without artwork: placeholder only
        XCTAssertEqual(images(controller(music(DashFixtures.freeRide(), DashFixtures.song(artworkId: nil))).displayList(now: t0)), [])
    }

    func testFocusOrdersAndOneKnobStepToTheTile() {
        let free = controller(music(DashFixtures.freeRide()))
        XCTAssertEqual(free.state.focusOrder, ["pill", "pill.circuit", "pill.lap"] + fabs + ["music.tile"])
        XCTAssertEqual(free.state.focusedId, "pill")
        XCTAssertEqual(free.handle(.knob(-1), now: t0), [])
        XCTAssertEqual(free.state.focusedId, "music.tile")
        let nav = controller(music(DashFixtures.navigating()))
        XCTAssertEqual(nav.state.focusOrder, ["metrics.end"] + fabs + ["music.tile"])
        XCTAssertEqual(nav.state.focusedId, "metrics.end")
        _ = nav.handle(.key(.left), now: t0) // ◀◀ D-pad left = knob −1
        XCTAssertEqual(nav.state.focusedId, "music.tile")
        // preview / arrival: drawn (tappable) but not in the handlebar lists
        for model in [DashFixtures.preview(), DashFixtures.arrival()] {
            let ui = controller(music(model))
            let list = ui.displayList(now: t0)
            XCTAssertEqual(region(list, "music.tile")?.focusable, false)
            XCTAssertFalse(ui.state.focusOrder.contains("music.tile"))
            XCTAssertEqual(ui.state.focusOrder, controller(model).state.focusOrder)
        }
    }

    // MARK: Sheet: touch and handlebar flows

    func testTapTileOpensTheSheetAndTouchTargets() {
        let ui = controller(music(DashFixtures.freeRide()))
        XCTAssertEqual(tapRegion(ui, "music.tile", at: t0), [.openMusic])
        var st = ui.state
        XCTAssertEqual(st.sheet, .music)
        XCTAssertEqual(st.focusedId, "music.playPause")
        XCTAssertEqual(st.focusOrder, ["music.previous", "music.playPause", "music.next", "music.close"])
        let list = ui.displayList(now: t0 + 1)
        XCTAssertFalse(list.hitRegions.contains { $0.id.hasPrefix("fab.") || $0.id == "music.tile" || $0.id == "pill" })
        let previous = try! XCTUnwrap(region(list, "music.previous")?.rect)
        XCTAssertEqual(previous.minX, 92, accuracy: 0.5)
        XCTAssertEqual(previous.minY, 223, accuracy: 0.5)
        XCTAssertEqual(previous.width, 64, accuracy: 1e-9)
        XCTAssertEqual(tapRegion(ui, "music.previous", at: t0 + 2), [.musicPrevious])
        XCTAssertEqual(tapRegion(ui, "music.playPause", at: t0 + 3), [.musicPlayPause])
        XCTAssertEqual(tapRegion(ui, "music.next", at: t0 + 4), [.musicNext])
        XCTAssertEqual(ui.state.sheet, .music, "transport keeps the sheet open")
        // the sheet background swallows touches: no intent, no map pan
        let camera = ui.state.camera
        XCTAssertEqual(tap(ui, DashPoint(300, 40), at: t0 + 5), [])
        XCTAssertEqual(list.hitTest(DashPoint(300, 40))?.id, "music.sheet")
        _ = touch(ui, .down, DashPoint(300, 40), t0 + 6)
        _ = touch(ui, .move, DashPoint(200, 140), t0 + 6.05)
        XCTAssertEqual(touch(ui, .up, DashPoint(200, 140), t0 + 6.1), [])
        XCTAssertEqual(ui.state.camera, camera)
        XCTAssertEqual(ui.state.sheet, .music)
        // ✕ closes, focus back on the tile
        XCTAssertEqual(tapRegion(ui, "music.close", at: t0 + 7), [.closeSheets])
        st = ui.state
        XCTAssertEqual(st.sheet, .none)
        XCTAssertEqual(st.focusedId, "music.tile")
    }

    func testHandlebarFlow() {
        // ◀ to the tile, ★ opens the sheet on ⏯, ★ toggles, ▶ to ⏭, ★★ back to the tile, ▶▶ menu.
        let ui = controller(music(DashFixtures.navigating()))
        _ = ui.handle(.knob(-1), now: t0)
        XCTAssertEqual(ui.handle(.key(.enter), now: t0 + 1), [.openMusic])
        XCTAssertEqual(ui.state.sheet, .music)
        XCTAssertEqual(ui.state.focusedId, "music.playPause")
        XCTAssertEqual(ui.handle(.key(.enter), now: t0 + 2), [.musicPlayPause])
        XCTAssertEqual(ui.handle(.knob(1), now: t0 + 3), [])
        XCTAssertEqual(ui.state.focusedId, "music.next")
        XCTAssertEqual(ui.handle(.key(.enter), now: t0 + 4), [.musicNext])
        XCTAssertEqual(ui.handle(.knob(1), now: t0 + 5), [])
        XCTAssertEqual(ui.state.focusedId, "music.close")
        XCTAssertEqual(ui.handle(.knob(1), now: t0 + 5.5), [])
        XCTAssertEqual(ui.state.focusedId, "music.previous", "wraps")
        XCTAssertEqual(ui.handle(.key(.enter), now: t0 + 6), [.musicPrevious])
        XCTAssertEqual(ui.handle(.key(.back), now: t0 + 7), [.closeSheets])
        XCTAssertEqual(ui.state.sheet, .none)
        XCTAssertEqual(ui.state.focusedId, "music.tile")
        // ★ on the tile again, then ▶▶ (HOME) swaps the sheet for the menu
        XCTAssertEqual(ui.handle(.key(.enter), now: t0 + 8), [.openMusic])
        XCTAssertEqual(ui.handle(.key(.home), now: t0 + 9), [.openMenu])
        XCTAssertEqual(ui.state.sheet, .menu)
        // phone-side activation works too (the app's `performDashIntent`)
        _ = ui.perform(.closeSheets, now: t0 + 10)
        XCTAssertEqual(ui.perform(.openMusic, now: t0 + 11), [.openMusic])
        XCTAssertEqual(ui.state.sheet, .music)
        XCTAssertEqual(ui.state.focusedId, "music.playPause")
    }

    func testSheetKeepsGuidanceOnTopWhileNavigating() {
        let ui = controller(music(DashFixtures.navigating()))
        _ = ui.perform(.openMusic, now: t0)
        let list = ui.displayList(now: t0)
        XCTAssertEqual(list.hitTest(DashPoint(100, 60))?.id, "nav.card")
        XCTAssertEqual(list.hitTest(DashPoint(790, 380))?.id, "music.sheet")
        XCTAssertTrue(texts(list).contains("350 m"))
        XCTAssertTrue(texts(list).contains("Ruta del Sol (Remastered 2012)"))
        XCTAssertTrue(texts(list).contains("Los Pistones"))
        XCTAssertTrue(texts(list).contains("Ruta Sessions"))
        XCTAssertTrue(texts(list).contains("2:13"))
        XCTAssertTrue(texts(list).contains("-3:51"))
        XCTAssertFalse(list.commands.contains { if case .tile = $0 { return true }; return false }, "opaque sheet: no map under it")
        XCTAssertFalse(has(list, "metrics.end"))
        XCTAssertFalse(has(list, "speed.chip"))
        // the nav card is drawn after (above) the sheet's background and artwork
        let sheetFill = list.commands.firstIndex { if case let .fill(_, c, _) = $0 { return c == DashPalette.musicSheet }; return false }
        let navText = list.commands.firstIndex { if case let .text(s, _, _) = $0 { return s == "350 m" }; return false }
        XCTAssertLessThan(try XCTUnwrap(sheetFill), try XCTUnwrap(navText))
        XCTAssertEqual(images(list), ["music.art.p1f"])
    }

    func testPlayPauseGlyphAndPausedTile() {
        func glyphPaths(_ list: DashDisplayList, in rect: DashRect) -> Int {
            list.commands.filter {
                if case let .fill(p, c, _) = $0, c == .white, let b = p.controlPointBounds { return rect.contains(b.center) }
                return false
            }.count
        }
        let playing = controller(music(DashFixtures.freeRide()))
        _ = playing.perform(.openMusic, now: t0)
        let paused = controller(music(DashFixtures.freeRide(), DashFixtures.song(.paused)))
        _ = paused.perform(.openMusic, now: t0)
        let a = playing.displayList(now: t0), b = paused.displayList(now: t0)
        let play = DashRect(x: 176, y: 215, width: 80, height: 80)
        XCTAssertEqual(glyphPaths(a, in: play), 1)
        XCTAssertEqual(glyphPaths(b, in: play), 1)
        XCTAssertNotEqual(a, b, "❚❚ while playing, ▶ while paused")
        // paused tile: dimmed + badge; playing tile: neither
        func dims(_ list: DashDisplayList) -> Bool {
            list.commands.contains { if case let .fill(_, c, _) = $0 { return c == DashPalette.musicPausedDim }; return false }
        }
        XCTAssertFalse(dims(controller(music(DashFixtures.freeRide())).displayList(now: t0)))
        XCTAssertTrue(dims(controller(music(DashFixtures.freeRide(), DashFixtures.song(.paused))).displayList(now: t0)))
    }

    func testNightDimsTheArtworkNeverInverts() {
        var m = music(DashFixtures.freeRide())
        m.isNight = true
        let ui = controller(m)
        let list = ui.displayList(now: t0)
        let image = try! XCTUnwrap(list.commands.firstIndex { if case .image = $0 { return true }; return false })
        let dim = try! XCTUnwrap(list.commands.firstIndex { if case let .fill(_, c, _) = $0 { return c == DashPalette.musicNightDim }; return false })
        XCTAssertLessThan(image, dim, "dimmed after the image")
        _ = ui.perform(.openMusic, now: t0)
        XCTAssertTrue(ui.displayList(now: t0).commands.contains { if case let .fill(_, c, _) = $0 { return c == DashPalette.musicNightDim }; return false })
        XCTAssertFalse(controller(music(DashFixtures.freeRide())).displayList(now: t0).commands.contains {
            if case let .fill(_, c, _) = $0 { return c == DashPalette.musicNightDim }; return false
        })
    }

    // MARK: Safety: idle close while moving

    func testIdleCloseWhileMoving() {
        let ui = controller(moving(36)) // 10 m/s
        XCTAssertEqual(ui.perform(.openMusic, now: 1_000), [.openMusic])
        XCTAssertEqual(ui.tick(now: 1_009.9), [])
        XCTAssertEqual(ui.state.sheet, .music)
        XCTAssertEqual(ui.tick(now: 1_010.1), [.closeSheets])
        XCTAssertEqual(ui.state.sheet, .none)
        XCTAssertEqual(ui.state.focusedId, "music.tile")
        XCTAssertEqual(ui.tick(now: 1_011), [], "closed once")
        // a dash input at 1_005 moves the deadline to 1_015
        _ = ui.perform(.openMusic, now: 2_000)
        _ = ui.handle(.knob(1), now: 2_005)
        XCTAssertEqual(ui.tick(now: 2_010.1), [])
        XCTAssertEqual(ui.tick(now: 2_015.1), [.closeSheets])
        // music intents from any source count as activity (here: the phone)
        _ = ui.perform(.openMusic, now: 3_000)
        _ = ui.perform(.musicNext, now: 3_008)
        XCTAssertEqual(ui.tick(now: 3_010.1), [])
        XCTAssertEqual(ui.tick(now: 3_018.1), [.closeSheets])
        // a touch anywhere on the sheet too
        _ = ui.perform(.openMusic, now: 4_000)
        _ = tap(ui, DashPoint(300, 40), at: 4_009)
        XCTAssertEqual(ui.tick(now: 4_010.1), [])
        XCTAssertEqual(ui.tick(now: 4_019.1), [.closeSheets])
    }

    func testIdleStaysOpenWhileStoppedClosesWithoutFix() {
        let stopped = controller(moving(0))
        _ = stopped.perform(.openMusic, now: 1_000)
        XCTAssertEqual(stopped.tick(now: 1_100), [])
        XCTAssertEqual(stopped.state.sheet, .music)
        let noFix = controller(moving(nil))
        _ = noFix.perform(.openMusic, now: 1_000)
        XCTAssertEqual(noFix.tick(now: 1_009.9), [])
        XCTAssertEqual(noFix.tick(now: 1_010.1), [.closeSheets])
        var never = DashUIController.Options()
        never.musicSheetIdleTimeout = nil
        let off = controller(moving(36), options: never)
        _ = off.perform(.openMusic, now: 1_000)
        XCTAssertEqual(off.tick(now: 5_000), [])
        XCTAssertEqual(off.state.sheet, .music)
        // stopped at a light for a while, then riding on: closes on the first tick while moving
        let light = controller(moving(0))
        _ = light.perform(.openMusic, now: 1_000)
        XCTAssertEqual(light.tick(now: 1_030), [])
        light.update(moving(30))
        XCTAssertEqual(light.tick(now: 1_031), [.closeSheets])
    }

    // MARK: Safety: next turn within 200 m

    func testNearTurnClosesOncePerTurnAfterTheInputGrace() {
        var opts = DashUIController.Options()
        opts.musicSheetIdleTimeout = nil // isolate the near-turn rule
        let ui = controller(music(DashFixtures.navigating(turn: 4, at: 350)), options: opts)
        _ = ui.perform(.openMusic, now: 1_000)
        XCTAssertEqual(ui.tick(now: 1_001), [])
        ui.update(music(DashFixtures.navigating(turn: 4, at: 190)))
        XCTAssertEqual(ui.tick(now: 1_004), [.closeSheets], "turn 4 within 200 m, input 4 s ago")
        XCTAssertEqual(ui.state.sheet, .none)
        XCTAssertEqual(ui.state.focusedId, "music.tile")
        XCTAssertEqual(ui.tick(now: 1_005), [])
        // re-opened next to the same turn: stays open
        _ = ui.perform(.openMusic, now: 1_006)
        XCTAssertEqual(ui.tick(now: 1_010), [])
        ui.update(music(DashFixtures.navigating(turn: 4, at: 60)))
        XCTAssertEqual(ui.tick(now: 1_012), [])
        XCTAssertEqual(ui.state.sheet, .music)
        // the next turn (index 5) at 150 m closes it again
        ui.update(music(DashFixtures.navigating(turn: 5, at: 150)))
        XCTAssertEqual(ui.tick(now: 1_013), [.closeSheets])
        // an input 1 s before: waits until 3 s after the input
        _ = ui.perform(.openMusic, now: 1_020) // turn 5 already near: handled
        ui.update(music(DashFixtures.navigating(turn: 6, at: 100)))
        _ = ui.handle(.knob(1), now: 1_029)
        XCTAssertEqual(ui.tick(now: 1_030), [])
        XCTAssertEqual(ui.tick(now: 1_031.9), [])
        XCTAssertEqual(ui.tick(now: 1_032.1), [.closeSheets])
    }

    func testNearTurnOnlyWhileNavigatingAndCanBeDisabled() {
        var opts = DashUIController.Options()
        opts.musicSheetIdleTimeout = nil
        // free ride with a stale upcoming turn: not navigating → no rule
        var free = music(DashFixtures.freeRide())
        free.nav.progress = DashFixtures.navigating(turn: 2, at: 50).nav.progress
        let ui = controller(free, options: opts)
        _ = ui.perform(.openMusic, now: 1_000)
        XCTAssertEqual(ui.tick(now: 1_100), [])
        opts.musicSheetTurnDistanceM = nil
        let off = controller(music(DashFixtures.navigating(turn: 2, at: 400)), options: opts)
        _ = off.perform(.openMusic, now: 1_000)
        off.update(music(DashFixtures.navigating(turn: 2, at: 50)))
        XCTAssertEqual(off.tick(now: 1_100), [])
        XCTAssertEqual(off.state.sheet, .music)
    }

    // MARK: Closing transitions

    func testSheetClosesWhenMusicGoesAndOnPreviewNavigationArrival() {
        let gone = controller(music(DashFixtures.navigating()))
        _ = gone.perform(.openMusic, now: t0)
        gone.update(DashFixtures.navigating())
        XCTAssertEqual(gone.state.sheet, .none)
        XCTAssertEqual(gone.state.focusedId, "fab.menu", "F2: never End when the song goes away")
        XCTAssertFalse(has(gone.displayList(now: t0), "music.tile"))
        // a change of song keeps it open
        let skip = controller(music(DashFixtures.freeRide()))
        _ = skip.perform(.openMusic, now: t0)
        skip.update(music(DashFixtures.freeRide(), DashFixtures.song(title: "Mountain Pass", artworkId: "music.art.s100000002")))
        XCTAssertEqual(skip.state.sheet, .music)
        XCTAssertEqual(images(skip.displayList(now: t0)), ["music.art.s100000002"])
        for next in [DashFixtures.preview(), DashFixtures.navigating(), DashFixtures.arrival()] {
            let ui = controller(music(DashFixtures.freeRide()))
            _ = ui.perform(.openMusic, now: t0)
            ui.update(music(next))
            XCTAssertEqual(ui.state.sheet, .none, "\(next.nav.mode) preview=\(next.inPreview) arrival=\(next.showsArrival)")
        }
    }

    // MARK: A Music control vanishes under the focus (fix F2)

    /// One model without the song and the frame the render loop builds right after it (the app always
    /// renders in between: flushModel → projection.invalidate()), then the song again and a frame.
    private func blink(_ ui: DashUIController, _ without: DashModel, _ with: DashModel, at t: TimeInterval,
                       whileGone: (DashUIState) -> Void = { _ in }) {
        ui.update(without)
        _ = ui.displayList(now: t)
        whileGone(ui.state)
        ui.update(with)
        _ = ui.displayList(now: t + 0.6)
    }

    private let bases: [(String, DashModel)] = [("navigating", DashFixtures.navigating()), ("free ride", DashFixtures.freeRide())]

    func testTileThatBlinksNeverHandsTheFocusToEnd() {
        for (name, base) in bases {
            let withSong = music(base, DashFixtures.song(.paused))
            let ui = controller(withSong)
            _ = ui.handle(.knob(-1), now: t0) // ◀ from the default item → the tile
            XCTAssertEqual(ui.state.focusedId, "music.tile", name)
            blink(ui, base, withSong, at: t0 + 0.1) { st in
                XCTAssertEqual(st.focusedId, "fab.menu", "\(name): the tile is gone")
            }
            XCTAssertEqual(ui.state.focusedId, "fab.menu", "\(name): stays put when the tile is back")
            // the tile is one ▶ away again (it closes the map list)
            _ = ui.handle(.knob(1), now: t0 + 1)
            XCTAssertEqual(ui.state.focusedId, "music.tile", name)
            _ = ui.handle(.knob(-1), now: t0 + 1.2)
            let star = ui.handle(.key(.enter), now: t0 + 1.5)
            XCTAssertFalse(star.contains(.endNavigation), name)
            XCTAssertEqual(star, [.openMenu], name)
        }
    }

    func testSheetClosedByAVanishedSongNeverHandsTheFocusToEnd() {
        for (name, base) in bases {
            let playing = music(base), paused = music(base, DashFixtures.song(.paused))
            let ui = controller(playing)
            _ = ui.handle(.knob(-1), now: t0)
            XCTAssertEqual(ui.handle(.key(.enter), now: t0 + 0.5), [.openMusic], name)
            XCTAssertEqual(ui.state.focusedId, "music.playPause", name)
            XCTAssertEqual(ui.handle(.key(.enter), now: t0 + 1), [.musicPlayPause], name) // ★ pauses
            // the stale "other audio" reading right after the pause hides the song: the sheet closes
            blink(ui, base, paused, at: t0 + 1.1) { st in
                XCTAssertEqual(st.sheet, .none, name)
                XCTAssertEqual(st.focusedId, "fab.menu", name)
            }
            XCTAssertEqual(ui.state.sheet, .none, "\(name): a closed sheet stays closed")
            XCTAssertEqual(ui.state.focusedId, "fab.menu", name)
            let star = ui.handle(.key(.enter), now: t0 + 2.5)
            XCTAssertFalse(star.contains(.endNavigation), name)
            XCTAssertEqual(star, [.openMenu], name)
        }
    }

    func testMenuMusicEntryThatBlinksNeverHandsTheFocusToEnd() {
        for (name, base) in bases {
            let withSong = music(base, DashFixtures.song(.paused))
            let ui = controller(withSong)
            _ = ui.handle(.key(.home), now: t0)
            let i = try! XCTUnwrap(ui.state.focusOrder.firstIndex(of: "menu.music"), name)
            _ = ui.handle(.knob(i), now: t0 + 0.1)
            XCTAssertEqual(ui.state.focusedId, "menu.music", name)
            blink(ui, base, withSong, at: t0 + 1) { st in
                XCTAssertEqual(st.sheet, .menu, name)
                XCTAssertFalse(st.focusOrder.contains("menu.music"), name)
                XCTAssertEqual(st.focusedId, "menu.circuit", "\(name): not menu.end (End navigation)")
            }
            XCTAssertEqual(ui.state.focusedId, "menu.circuit", name)
            let star = ui.handle(.key(.enter), now: t0 + 2)
            XCTAssertFalse(star.contains(.endNavigation), name)
            XCTAssertEqual(star, [.startCircuit], name) // without a previewed place: a hint only
        }
    }

    func testFocusSurvivesWhenNoFrameIsBuiltWhileTheSongIsGone() {
        let withSong = music(DashFixtures.navigating(), DashFixtures.song(.paused))
        let ui = controller(withSong)
        _ = ui.handle(.knob(-1), now: t0)
        ui.update(DashFixtures.navigating())
        ui.update(withSong) // no scene was built without the tile
        XCTAssertEqual(ui.state.focusedId, "music.tile")
        XCTAssertEqual(ui.handle(.key(.enter), now: t0 + 1), [.openMusic])
    }

    func testSheetClosingWithoutATileNeverHandsTheFocusToEnd() {
        // BACK on the sheet, and the song goes away before the next frame: the tile the focus was
        // promised to is not there.
        let ui = controller(music(DashFixtures.navigating()))
        _ = ui.perform(.openMusic, now: t0)
        XCTAssertEqual(ui.handle(.key(.back), now: t0 + 1), [.closeSheets])
        ui.update(DashFixtures.navigating())
        XCTAssertEqual(ui.state.focusedId, "fab.menu")
        XCTAssertFalse(ui.handle(.key(.enter), now: t0 + 2).contains(.endNavigation))
        // ✕ while a lap card leaves no room for the tile (navigating): the Menu FAB, not End
        var lap = music(DashFixtures.navigating())
        lap.lapTimer = DashLapTimer(title: String(repeating: "LAP 12  1:31.20 ", count: 6), meta: "LAST 1:30.00   BEST 1:30.00")
        let noTile = controller(lap)
        XCTAssertFalse(noTile.state.focusOrder.contains("music.tile"))
        _ = noTile.perform(.openMusic, now: t0)
        XCTAssertEqual(tapRegion(noTile, "music.close", at: t0 + 1), [.closeSheets])
        XCTAssertEqual(noTile.state.focusedId, "fab.menu")
        // preview / arrival (tile not focusable): their own first item, as before
        for (model, first) in [(DashFixtures.preview(), "preview.go"), (DashFixtures.arrival(), "arrive.park")] {
            let ui = controller(music(model))
            _ = ui.perform(.openMusic, now: t0)
            _ = ui.handle(.key(.back), now: t0 + 1)
            XCTAssertEqual(ui.state.focusedId, first)
            _ = ui.perform(.openMusic, now: t0 + 2)
            ui.update(model) // the song goes away: the sheet closes
            XCTAssertEqual(ui.state.sheet, .none)
            XCTAssertEqual(ui.state.focusedId, first)
        }
    }

    func testOpenMusicWithoutMusicToasts() {
        let ui = controller(DashFixtures.freeRide())
        XCTAssertEqual(ui.perform(.openMusic, now: t0), [.openMusic])
        XCTAssertEqual(ui.state.sheet, .none)
        XCTAssertEqual(ui.state.toast, "Nothing playing in Apple Music")
        var es = DashFixtures.freeRide()
        es.language = .es
        let ui2 = controller(es)
        _ = ui2.perform(.openMusic, now: t0)
        XCTAssertEqual(ui2.state.toast, "Apple Music no está reproduciendo nada")
    }

    // MARK: Re-render cadence

    func testSheetChangesOncePerSecondWhilePlaying() {
        let ui = controller(music(DashFixtures.freeRide()))
        _ = ui.perform(.openMusic, now: t0)
        let a = ui.displayList(now: t0 + 0.1), b = ui.displayList(now: t0 + 0.5)
        XCTAssertEqual(a, b, "same second")
        XCTAssertTrue(texts(a).contains("2:13"))
        let c = ui.displayList(now: t0 + 0.95), d = ui.displayList(now: t0 + 1.05)
        XCTAssertEqual(a, c)
        XCTAssertNotEqual(c, d, "next second")
        XCTAssertTrue(texts(d).contains("2:14"))
        XCTAssertTrue(texts(d).contains("-3:50"))
        // paused: nothing moves
        let paused = controller(music(DashFixtures.freeRide(), DashFixtures.song(.paused)))
        _ = paused.perform(.openMusic, now: t0)
        XCTAssertEqual(paused.displayList(now: t0), paused.displayList(now: t0 + 10))
    }

    func testTileChangesOnlyWithAWholePixel() {
        // 52-px track, 364 s: one px every 7 s; 2:13 = 19.0 px, 20 px at 2:20 (t0 + 7)
        let ui = controller(music(DashFixtures.freeRide()))
        let a = ui.displayList(now: t0 + 0.5)
        XCTAssertEqual(a, ui.displayList(now: t0 + 3))
        XCTAssertEqual(a, ui.displayList(now: t0 + 6.9))
        XCTAssertNotEqual(a, ui.displayList(now: t0 + 7.1))
        let paused = controller(music(DashFixtures.freeRide(), DashFixtures.song(.paused)))
        XCTAssertEqual(paused.displayList(now: t0), paused.displayList(now: t0 + 60))
        // unknown duration: no bar, nothing moves
        let radio = controller(music(DashFixtures.freeRide(), DashFixtures.song(duration: 0)))
        XCTAssertEqual(radio.displayList(now: t0), radio.displayList(now: t0 + 60))
    }

    func testShortSongStepsAtMostOncePerSecond() {
        // 30 s on a 52-px bar: the bar would gain ~1.7 px per second; it moves with whole seconds only.
        let jingle = DashNowPlaying(title: "Jingle", duration: 30, position: 13, positionAt: t0)
        let ui = controller(music(DashFixtures.freeRide(), jingle))
        let a = ui.displayList(now: t0 + 0.05)
        XCTAssertEqual(a, ui.displayList(now: t0 + 0.5))
        XCTAssertEqual(a, ui.displayList(now: t0 + 0.95))
        XCTAssertNotEqual(a, ui.displayList(now: t0 + 1.05))
        XCTAssertEqual(DashSceneBuilder.musicFill(jingle, width: 52, now: t0 + 0.95), 22) // 13 s × 52 / 30 = 22.5
        XCTAssertEqual(DashSceneBuilder.musicFill(jingle, width: 52, now: t0 + 1.05), 24) // 14 s → 24.3
    }

    func testFillHelper() {
        let song = DashFixtures.song() // 364 s
        XCTAssertEqual(DashSceneBuilder.musicFill(song, width: 52, now: t0), 19, "133 × 52 / 364 = 19 exactly")
        XCTAssertEqual(DashSceneBuilder.musicFill(song, width: 52, now: t0 + 6.99), 19)
        XCTAssertEqual(DashSceneBuilder.musicFill(song, width: 52, now: t0 + 7), 20)
        XCTAssertEqual(DashSceneBuilder.musicFill(song, width: 52, now: t0 + 10_000), 52, "clamped at the end")
        XCTAssertEqual(DashSceneBuilder.musicFill(DashFixtures.song(.paused), width: 52, now: t0 + 60), 19, "frozen while paused")
        XCTAssertNil(DashSceneBuilder.musicFill(DashFixtures.song(duration: 0), width: 52, now: t0))
        XCTAssertNil(DashSceneBuilder.musicFill(song, width: 0, now: t0))
        XCTAssertNil(DashSceneBuilder.musicFill(song, width: .nan, now: t0))
        XCTAssertEqual(DashSceneBuilder.musicFill(DashFixtures.song(duration: 364.4), width: 59.15, now: t0 + 1_000), 59)
    }

    func testTimeKey() {
        let song = DashFixtures.song()
        XCTAssertNil(DashSceneBuilder.musicTimeKey(nil, sheetOpen: true, tileBarWidth: 52, now: t0))
        XCTAssertNil(DashSceneBuilder.musicTimeKey(DashFixtures.song(.paused), sheetOpen: true, tileBarWidth: 52, now: t0))
        XCTAssertNil(DashSceneBuilder.musicTimeKey(DashFixtures.song(duration: 0), sheetOpen: true, tileBarWidth: 52, now: t0))
        XCTAssertEqual(DashSceneBuilder.musicTimeKey(song, sheetOpen: true, tileBarWidth: nil, now: t0 + 0.5), 133)
        XCTAssertEqual(DashSceneBuilder.musicTimeKey(song, sheetOpen: false, tileBarWidth: 52, now: t0 + 0.5), 19)
        XCTAssertEqual(DashSceneBuilder.musicTimeKey(song, sheetOpen: false, tileBarWidth: 52, now: t0 + 7.1), 20)
        XCTAssertNil(DashSceneBuilder.musicTimeKey(song, sheetOpen: false, tileBarWidth: nil, now: t0))
    }

    func testOlderTimestampNeverRewindsTheProgress() {
        let ui = controller(music(DashFixtures.freeRide()))
        _ = ui.perform(.openMusic, now: t0)
        XCTAssertTrue(texts(ui.displayList(now: t0 + 1.2)).contains("2:14"))
        _ = ui.handle(.knob(1), now: t0 + 0.9) // a late input event (older timestamp)
        let late = texts(ui.displayList(now: t0 + 0.95))
        XCTAssertTrue(late.contains("2:14"))
        XCTAssertFalse(late.contains("2:13"))
    }

    // MARK: Menu, hold, Spanish

    func testMenuEntryOnlyWithMusic() {
        for reach in [true, false] {
            var opts = DashUIController.Options()
            opts.handlebarReachesSettings = reach
            let ui = controller(music(DashFixtures.navigating()), options: opts)
            _ = ui.handle(.key(.home), now: t0)
            let order = ui.state.focusOrder
            let i = try! XCTUnwrap(order.firstIndex(of: "menu.music"), "reach \(reach)")
            XCTAssertEqual(order[i - 1], "menu.circuit")
            XCTAssertEqual(order[i + 1], "menu.follow")
            // below the fold of the 384-px panel: focusing it scrolls it into view
            _ = ui.handle(.knob(i), now: t0 + 1)
            XCTAssertEqual(ui.state.focusedId, "menu.music")
            XCTAssertTrue(texts(ui.displayList(now: t0 + 1)).contains("Music"))
            XCTAssertEqual(ui.handle(.key(.enter), now: t0 + 2), [.openMusic])
            XCTAssertEqual(ui.state.sheet, .music)
            XCTAssertEqual(ui.state.focusedId, "music.playPause")
            let plain = controller(DashFixtures.navigating(), options: opts)
            _ = plain.handle(.key(.home), now: t0)
            XCTAssertFalse(plain.state.focusOrder.contains("menu.music"))
            XCTAssertFalse(has(plain.displayList(now: t0), "menu.music"))
        }
        // touch: scroll the menu, tap "Music"
        let ui = controller(music(DashFixtures.navigating()))
        _ = ui.perform(.openMenu, now: t0)
        _ = touch(ui, .down, DashPoint(660, 300), t0 + 1)
        _ = touch(ui, .move, DashPoint(660, 250), t0 + 1.05)
        _ = touch(ui, .move, DashPoint(660, 200), t0 + 1.1)
        _ = touch(ui, .up, DashPoint(660, 200), t0 + 1.15)
        XCTAssertEqual(tapRegion(ui, "menu.music", at: t0 + 2), [.openMusic])
        XCTAssertEqual(ui.state.sheet, .music)
    }

    func testHoldScreenShowsTheDimmedTile() {
        var m = music(DashFixtures.navigating())
        m.holdMessage = "Phone locked"
        let ui = controller(m)
        let list = ui.displayList(now: t0)
        XCTAssertTrue(list.hitRegions.isEmpty)
        XCTAssertEqual(images(list), ["music.art.p1f"])
        XCTAssertTrue(texts(list).contains("Phone locked"))
        let dimmer = list.commands.firstIndex { if case let .fill(_, c, _) = $0 { return c == DashPalette.holdDimmer }; return false }
        let image = list.commands.firstIndex { if case .image = $0 { return true }; return false }
        XCTAssertLessThan(try XCTUnwrap(image), try XCTUnwrap(dimmer))
        XCTAssertEqual(tap(ui, DashPoint(760, 300), at: t0), [], "the tile is not tappable on the hold picture")
    }

    func testSpanishLabels() {
        var m = music(DashFixtures.navigating(), DashFixtures.song(title: ""))
        m.language = .es
        let ui = controller(m)
        _ = ui.handle(.key(.home), now: t0)
        _ = ui.handle(.knob(try! XCTUnwrap(ui.state.focusOrder.firstIndex(of: "menu.music"))), now: t0)
        XCTAssertTrue(texts(ui.displayList(now: t0)).contains("Música"))
        _ = ui.perform(.openMusic, now: t0)
        let t = texts(ui.displayList(now: t0))
        XCTAssertTrue(t.contains("Canción desconocida"))
        XCTAssertTrue(t.contains("2:13"))
        XCTAssertTrue(t.contains("-3:51"))
    }

    // MARK: Layout invariants inside the controller

    func testClockGivesWayWithMarginsAndTileAvoidsCards() {
        var m = music(DashFixtures.freeRide())
        m.margins = ScreenMargins(top: 22, bottom: 10, left: 12, right: 14)
        let list = controller(m).displayList(now: t0)
        XCTAssertEqual(region(list, "music.tile")?.rect, DashRect(x: 716, y: 292, width: 64, height: 64))
        XCTAssertFalse(has(list, "clock"))
        // a lap card wide enough to reach the FAB lane drops the tile instead of overlapping
        var lap = music(DashFixtures.freeRide())
        lap.lapTimer = DashLapTimer(title: String(repeating: "LAP 12  1:31.20 ", count: 6), meta: "LAST 1:30.00   BEST 1:30.00")
        let lapList = controller(lap).displayList(now: t0)
        let card = try! XCTUnwrap(region(lapList, "lap.card")).rect
        XCTAssertGreaterThan(card.maxX, 730)
        XCTAssertFalse(has(lapList, "music.tile"))
        XCTAssertTrue(has(lapList, "clock"), "no tile: the clock stays")
        XCTAssertFalse(controller(lap).state.focusOrder.contains("music.tile"))
    }

    func testFocusPreferences() {
        var f = DashFocusEngine()
        f.ensure(["a", "music.playPause", "b"], prefer: .musicPlayPause)
        XCTAssertEqual(f.focusedId, "music.playPause")
        f.ensure(["a", "music.tile"], prefer: .musicTile)
        XCTAssertEqual(f.focusedId, "music.tile")
        f.ensure(["x", "y"], prefer: .musicTile) // not listed → default (first)
        XCTAssertEqual(f.focusedId, "x")
        f.ensure(["y", "x"], prefer: .musicPlayPause) // keeps a listed focus
        XCTAssertEqual(f.focusedId, "x")
        XCTAssertEqual(DashFocusEngine.musicTileId, "music.tile")
        XCTAssertEqual(DashFocusEngine.musicPlayPauseId, "music.playPause")
        // F2: a vanished Music control → a harmless neighbour, never the first item (End)
        let map = ["metrics.end"] + fabs
        f = DashFocusEngine(focusedId: "music.tile")
        f.ensure(map, prefer: .musicGone)
        XCTAssertEqual(f.focusedId, "fab.menu")
        f = DashFocusEngine(focusedId: "menu.music")
        f.ensure(["menu.end", "menu.park", "menu.circuit", "menu.follow"], prefer: .musicGone)
        XCTAssertEqual(f.focusedId, "menu.circuit")
        f = DashFocusEngine(focusedId: "music.close")
        f.ensure(map, prefer: .musicTile) // the tile is not listed
        XCTAssertEqual(f.focusedId, "fab.menu")
        f.ensure(map + ["music.tile"], prefer: .musicTile)
        XCTAssertEqual(f.focusedId, "music.tile")
        f = DashFocusEngine(focusedId: "music.close")
        f.ensure(["preview.go", "preview.cancel"], prefer: .musicGone) // neither listed → first
        XCTAssertEqual(f.focusedId, "preview.go")
        f.ensure(["preview.cancel", "preview.go"], prefer: .musicGone) // … keeping a listed focus
        XCTAssertEqual(f.focusedId, "preview.go")
        XCTAssertTrue(DashFocusEngine.isMusicControl("music.tile"))
        XCTAssertTrue(DashFocusEngine.isMusicControl("music.playPause"))
        XCTAssertTrue(DashFocusEngine.isMusicControl("menu.music"))
        XCTAssertFalse(DashFocusEngine.isMusicControl("menu.circuit"))
        XCTAssertFalse(DashFocusEngine.isMusicControl("metrics.end"))
    }
}
