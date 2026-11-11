// SPDX-License-Identifier: AGPL-3.0-or-later
// Apple Music on the dash (iOS addition), review round 3 (R3-FOCUS-1): the open Music sheet outlasts a
// song that goes away for a moment (`Options.musicSheetVanishGrace`, 2 s), drawn with the song it showed
// and with the focus on the control the rider left. Closed at once, as before, the sheet handed the knob
// back to the tile — the last item of the map list — and the rider's next blind ▶ ★, meant for ⏭, wrapped
// to End and ended navigation without a confirmation (likewise ⏮ then ▶ ★, and ◀ ★ ★). A song gone for
// good still closes the sheet, 2 s later, onto Recenter as F2 says; arrival, preview and navigation
// start still close it at once, and the idle / near-turn rules still count from the rider's last input.
// (The app holds the song through one reading without one too — MusicModel's `trackGapGrace` — so the
// dash sees a vanish only once that outlasted 2 s; these tests feed the dash model directly.)
import Foundation
import XCTest
@testable import OpenCfMotoCore

final class DashMusicSheetVanishTests: XCTestCase {
    private let t0 = DashFixtures.musicNow

    /// Navigating (or `base`), ◀ ★ from End: the sheet on ⏯ (`step` moves the knob on it, `activate` presses ★).
    private func sheetOpen(_ base: DashModel = DashFixtures.navigating(), step: Int = 0, activate: Bool = false)
        -> (DashUIController, DashModel, DashModel) {
        let with = DashFixtures.withMusic(base)
        let ui = DashUIController()
        ui.update(with)
        _ = ui.displayList(now: t0)
        _ = ui.handle(.knob(-1), now: t0 + 0.1)
        XCTAssertEqual(ui.handle(.key(.enter), now: t0 + 0.4), [.openMusic])
        _ = ui.displayList(now: t0 + 0.45)
        if step != 0 { _ = ui.handle(.knob(step), now: t0 + 0.8); _ = ui.displayList(now: t0 + 0.85) }
        if activate { _ = ui.handle(.key(.enter), now: t0 + 1.2); _ = ui.displayList(now: t0 + 1.25) }
        return (ui, base, with)
    }

    /// One reading with no item: the model without the song, a frame built during it (and ticks, as the
    /// render loop does) when `framed`, then the song back.
    private func gap(_ ui: DashUIController, _ base: DashModel, _ with: DashModel, framed: Bool = true,
                     file: StaticString = #filePath, line: UInt = #line) {
        let before = ui.state.focusedId
        ui.update(base)
        if framed {
            XCTAssertEqual(ui.tick(now: t0 + 1.5), [], file: file, line: line)
            _ = ui.displayList(now: t0 + 1.5)
            XCTAssertEqual(ui.state.sheet, .music, "a short vanish keeps the sheet open", file: file, line: line)
            XCTAssertEqual(ui.state.focusedId, before, "on the same control", file: file, line: line)
            XCTAssertTrue(ui.displayList(now: t0 + 1.6).hitRegions.contains { $0.id == DashFocusEngine.musicPlayPauseId },
                          "drawn with the song it showed", file: file, line: line)
            XCTAssertEqual(ui.tick(now: t0 + 2.0), [], file: file, line: line)
        }
        ui.update(with)
        _ = ui.displayList(now: t0 + 2.1)
        XCTAssertEqual(ui.state.sheet, .music, file: file, line: line)
        XCTAssertEqual(ui.state.focusedId, before, file: file, line: line)
    }

    /// The rider's presses, one every 0.4 s from t0 + 3, a frame after each.
    private func presses(_ ui: DashUIController, _ inputs: [DashInput]) -> [[DashIntent]] {
        inputs.enumerated().map { i, p in
            let now = t0 + 3 + Double(i) * 0.4
            defer { _ = ui.displayList(now: now + 0.1) }
            return ui.handle(p, now: now)
        }
    }

    /// The review's sequences: after one reading with no item each keeps its sheet meaning (on bfa6c93 the
    /// first three ended navigation: the knob was back on the tile).
    func testAfterAOneReadingGapTheSheetsSequencesKeepTheirMeaning() {
        for framed in [true, false] {
            var (ui, base, with) = sheetOpen()
            gap(ui, base, with, framed: framed)
            XCTAssertEqual(presses(ui, [.knob(1), .key(.enter)]), [[], [.musicNext]], "▶ ★ is ⏭ (framed \(framed))")
            (ui, base, with) = sheetOpen(step: -1, activate: true)
            gap(ui, base, with, framed: framed)
            XCTAssertEqual(presses(ui, [.knob(1), .key(.enter)]), [[], [.musicPlayPause]], "⏮ then ▶ ★ is ⏯ (framed \(framed))")
            (ui, base, with) = sheetOpen()
            gap(ui, base, with, framed: framed)
            XCTAssertEqual(presses(ui, [.knob(-1), .key(.enter), .key(.enter)]), [[], [.musicPrevious], [.musicPrevious]],
                           "◀ ★ ★ is ⏮ twice (framed \(framed))")
            (ui, base, with) = sheetOpen()
            gap(ui, base, with, framed: framed)
            XCTAssertEqual(presses(ui, [.key(.enter), .key(.enter)]), [[.musicPlayPause], [.musicPlayPause]],
                           "★ ★ is ⏯ twice (R2-DASH-1, framed \(framed))")
            (ui, base, with) = sheetOpen(step: 1, activate: true)
            gap(ui, base, with, framed: framed)
            XCTAssertEqual(presses(ui, [.knob(-1), .key(.enter)]), [[], [.musicPlayPause]], "⏭ then ◀ ★ is ⏯ (framed \(framed))")
        }
    }

    func testInputDuringTheVanishIsTheSheets() {
        let (ui, base, _) = sheetOpen()
        ui.update(base) // the hold counts from the last frame's time, t0 + 0.45
        _ = ui.displayList(now: t0 + 1.5)
        XCTAssertEqual(ui.handle(.key(.enter), now: t0 + 1.6), [.musicPlayPause], "the app sends it to the player")
        XCTAssertEqual(ui.handle(.key(.back), now: t0 + 1.8), [.closeSheets], "BACK closes it")
        _ = ui.displayList(now: t0 + 1.9)
        XCTAssertEqual(ui.state.focusedId, DashFocusEngine.musicTileId, "onto the tile, held with the song (R4-FOCUS-2)")
        XCTAssertEqual(ui.tick(now: t0 + 2.4), [])
        XCTAssertEqual(ui.state.focusedId, DashFocusEngine.musicTileId)
        XCTAssertEqual(ui.tick(now: t0 + 2.5), [], "the hold's end closes nothing")
        _ = ui.displayList(now: t0 + 2.6)
        XCTAssertEqual(ui.state.focusedId, "fab.recenter", "the song stayed gone: parked as F2 says, never End")
    }

    /// R4-FOCUS-2: HOME (▶▶ on back_set and custom maps; unmapped on the iOS default since P0) from the held sheet
    /// opens the menu with the held song, on "Music" as without the vanish: ◀ ★ is the menu's default item,
    /// Recenter / reroute (P0 order; Circuit's hint before), and ★ re-opens the held sheet. Without the hold
    /// reaching the menu it had no "Music": the knob parked on Circuit, whose ◀ ★ was Record (the trip log
    /// stops), and BACK / HOME closed it onto the parked Recenter, whose ◀ ★ ended navigation before P0.
    func testHomeDuringTheHoldOpensTheMenuOnTheHeldMusic() {
        for base in [DashFixtures.navigating(), DashFixtures.freeRide()] {
            let name = base.navigating ? "navigating" : "free ride"
            var (ui, b, _) = sheetOpen(base)
            ui.update(b) // held until t0 + 2.45
            _ = ui.displayList(now: t0 + 1.5)
            XCTAssertEqual(ui.handle(.key(.home), now: t0 + 1.6), [.openMenu], name)
            _ = ui.displayList(now: t0 + 1.65)
            XCTAssertEqual(ui.state.focusedId, "menu.music", name)
            XCTAssertEqual(ui.handle(.knob(-1), now: t0 + 1.8), [], name)
            XCTAssertEqual(ui.handle(.key(.enter), now: t0 + 2.0), [.recalc], "\(name): Recenter / reroute, never Record")
            (ui, b, _) = sheetOpen(base)
            ui.update(b)
            _ = ui.displayList(now: t0 + 1.5)
            _ = ui.handle(.key(.home), now: t0 + 1.6)
            XCTAssertEqual(ui.handle(.key(.back), now: t0 + 1.8), [.closeSheets], name)
            XCTAssertEqual(ui.state.focusedId, DashFocusEngine.musicTileId, "\(name): closing it lands on the held tile")
            XCTAssertEqual(ui.handle(.knob(-1), now: t0 + 2.0), [], name)
            XCTAssertEqual(ui.handle(.key(.enter), now: t0 + 2.2), [.openMenu], "\(name): ◀ ★ from the tile, never End or Lap")
            (ui, b, _) = sheetOpen(base)
            ui.update(b)
            _ = ui.displayList(now: t0 + 1.5)
            _ = ui.handle(.key(.home), now: t0 + 1.6)
            XCTAssertEqual(ui.handle(.key(.enter), now: t0 + 1.8), [.openMusic], name)
            XCTAssertEqual(ui.state.sheet, .music, "\(name): ★ on the held \"Music\" re-opens the held sheet")
            XCTAssertEqual(ui.tick(now: t0 + 2.5), [.closeSheets], "\(name): the song stayed gone")
            _ = ui.displayList(now: t0 + 2.6)
            XCTAssertEqual(ui.state.focusedId, "fab.recenter", name)
            (ui, b, _) = sheetOpen(base)
            ui.update(b)
            _ = ui.displayList(now: t0 + 1.5)
            _ = ui.handle(.key(.home), now: t0 + 1.6)
            XCTAssertEqual(ui.tick(now: t0 + 2.5), [], name)
            _ = ui.displayList(now: t0 + 2.6)
            XCTAssertEqual(ui.state.sheet, .menu, name)
            XCTAssertEqual(ui.state.focusedId, "menu.circuit", "\(name): \"Music\" goes at the hold's end, parked as F2 says")
        }
    }

    /// R4-FOCUS-2: while the sheet's song is held, a vanish is invisible to every press. From ⏯ and ✕, navigating
    /// and in free ride, every sequence of 1–3 presses over ★, BACK, HOME, ◀, ▶ (0.3 s apart, a tick and a frame
    /// after each) returns the same intents and leaves the same focus and sheet as with the song.
    func testEveryPressDuringTheHoldMeansWhatItWouldWithTheSong() {
        let keys: [DashInput] = [.key(.enter), .key(.back), .key(.home), .knob(-1), .knob(1)]
        var seqs: [[Int]] = keys.indices.map { [$0] }
        for _ in 0 ..< 2 { seqs += seqs.filter { $0.count == seqs.last!.count }.flatMap { s in keys.indices.map { s + [$0] } } }
        XCTAssertEqual(seqs.count, 5 + 25 + 125)
        for base in [DashFixtures.navigating(), DashFixtures.freeRide()] {
            for step in [0, 2] {
                func run(_ p: [Int], vanish: Bool) -> [String] {
                    let (ui, b, _) = sheetOpen(base, step: step)
                    _ = ui.displayList(now: t0 + 1.0)
                    if vanish { ui.update(b) } // held until t0 + 3
                    _ = ui.displayList(now: t0 + 1.1)
                    return p.enumerated().map { i, k in
                        let now = t0 + 1.3 + Double(i) * 0.3
                        let out = ui.handle(keys[k], now: now) + ui.tick(now: now + 0.1)
                        _ = ui.displayList(now: now + 0.1)
                        return "\(out) \(ui.state.focusedId ?? "-") \(ui.state.sheet)"
                    }
                }
                for p in seqs {
                    XCTAssertEqual(run(p, vanish: true), run(p, vanish: false), "\(base.navigating ? "navigating" : "free ride") step \(step) \(p)")
                }
            }
        }
    }

    func testASongGoneForGoodClosesTheSheetAtTheEndOfTheGraceOnly() {
        let (ui, base, with) = sheetOpen()
        _ = ui.displayList(now: t0 + 1.0) // the vanish counts from the last frame's time
        ui.update(base)
        XCTAssertEqual(ui.tick(now: t0 + 2.9), [], "1.9 s: still open")
        XCTAssertEqual(ui.state.sheet, .music)
        XCTAssertEqual(ui.tick(now: t0 + 3.0), [.closeSheets], "2 s: the song stayed gone")
        _ = ui.displayList(now: t0 + 3.0)
        XCTAssertEqual(ui.state.sheet, .none)
        XCTAssertEqual(ui.state.focusedId, "fab.recenter", "F2: a harmless neighbour, never End")
        XCTAssertEqual(ui.handle(.key(.enter), now: t0 + 3.5), [.recenter])
        _ = ui.displayList(now: t0 + 3.6)
        ui.update(with)
        _ = ui.displayList(now: t0 + 4)
        XCTAssertEqual(ui.state.sheet, .none, "a closed sheet stays closed")
    }

    /// R4-FOCUS-1: once the hold ended and the sheet closed onto Recenter (the song gone for good), HOME there
    /// takes the Music path: the menu has no "Music", so the knob parks on its stand-in Circuit, whose ★ is only a
    /// hint without a preview. Before, it was the map's HOME (menu on End, ★ ended navigation). With the song
    /// back first, the knob is on the tile and HOME lands on "Music".
    func testHomeAfterTheHoldEndedTakesTheMusicPathNeverEnd() {
        for base in [DashFixtures.navigating(), DashFixtures.freeRide()] {
            let name = base.navigating ? "navigating" : "free ride"
            var (ui, b, with) = sheetOpen(base)
            ui.update(b) // held from t0 + 0.45
            XCTAssertEqual(ui.tick(now: t0 + 2.5), [.closeSheets], name)
            _ = ui.displayList(now: t0 + 2.55)
            XCTAssertEqual(ui.state.focusedId, "fab.recenter", name)
            XCTAssertEqual(ui.handle(.key(.home), now: t0 + 3), [.openMenu], name)
            _ = ui.displayList(now: t0 + 3.05)
            XCTAssertEqual(ui.state.focusedId, "menu.circuit", "\(name): \"Music\" is not listed, its stand-in")
            XCTAssertEqual(ui.handle(.key(.enter), now: t0 + 3.5), [.startCircuit], "\(name): a hint, never End")
            // the song back first: the knob returns to the tile, and HOME lands on "Music"
            (ui, b, with) = sheetOpen(base)
            ui.update(b)
            XCTAssertEqual(ui.tick(now: t0 + 2.5), [.closeSheets], name)
            _ = ui.displayList(now: t0 + 2.55)
            ui.update(with)
            _ = ui.displayList(now: t0 + 2.6)
            XCTAssertEqual(ui.state.focusedId, DashFocusEngine.musicTileId, name)
            XCTAssertEqual(ui.handle(.key(.home), now: t0 + 3), [.openMenu], name)
            XCTAssertEqual(ui.state.focusedId, "menu.music", name)
            XCTAssertEqual(ui.handle(.key(.enter), now: t0 + 3.5), [.openMusic], name)
        }
    }

    /// R4-FOCUS-1 through the real gesture engine: the hold ends between the two ▶ of a quick ▶▶. The first ▶ is
    /// a knob step on the sheet (⏯ → ⏭), the hold's end closes the sheet onto Recenter. On back_set the second ▶
    /// is HOME from that stand-in: the menu parks on Circuit and ★ is its hint. On the iOS default maps ▶▶ is
    /// unmapped since P0 (D02): the second ▶ is swallowed and ★ only recenters.
    func testQuickRightRightAcrossTheHoldsEndNeverEndsNavigation() {
        for preset in ButtonClusterPreset.allCases {
            let (ui, base, _) = sheetOpen()
            ui.update(base) // held from t0 + 0.45: the hold ends at t0 + 2.45
            let engine = HandlebarGestureEngine(configuration: .init(buttonMap: HandlebarPresets.iosMapping(for: preset)))
            var out: [DashIntent] = []
            func press(_ channel: HandlebarGestureEngine.Channel, _ t: TimeInterval) {
                for c in engine.tap(channel, atMs: Int64((t * 1000).rounded())) {
                    if let input = c.input { out += ui.handle(input, now: Double(c.timeMs) / 1000) }
                }
                _ = ui.displayList(now: t + 0.02)
            }
            press(.forward, t0 + 2.3)
            XCTAssertEqual(ui.tick(now: t0 + 2.5), [.closeSheets], preset.rawValue)
            _ = ui.displayList(now: t0 + 2.51)
            press(.forward, t0 + 2.55) // 0.25 s after the first: HOME
            press(.select, t0 + 3.5)
            XCTAssertFalse(out.contains(.endNavigation), "\(preset.rawValue): \(out)")
            let home = HandlebarPresets.iosMapping(for: preset)[.navFwdDouble] == .home
            XCTAssertEqual(out, home ? [.openMenu, .startCircuit] : [.recenter], preset.rawValue)
        }
    }

    func testTheGraceRestartsWithEachVanishAndNilKeepsTheOldRule() {
        let (ui, base, with) = sheetOpen()
        _ = ui.displayList(now: t0 + 1.0)
        ui.update(base)
        _ = ui.displayList(now: t0 + 1.5)
        ui.update(with)
        _ = ui.displayList(now: t0 + 2.5)
        ui.update(base)
        XCTAssertEqual(ui.tick(now: t0 + 4.4), [], "the second vanish counts from 2.5")
        XCTAssertEqual(ui.tick(now: t0 + 4.5), [.closeSheets])
        var o = DashUIController.Options()
        o.musicSheetVanishGrace = nil
        let old = DashUIController(options: o)
        old.update(with)
        _ = old.displayList(now: t0)
        _ = old.handle(.knob(-1), now: t0 + 0.1)
        _ = old.handle(.key(.enter), now: t0 + 0.4)
        old.update(base)
        XCTAssertEqual(old.state.sheet, .none, "nil: closes at once (the rule before R3-FOCUS-1)")
    }

    func testArrivalAndNavigationStartStillCloseAtOnce() {
        var (ui, base, _) = sheetOpen()
        var arrival = base
        arrival.nav.arrival = ArrivalCard(title: "Arrived", meta: "")
        ui.update(arrival)
        XCTAssertEqual(ui.state.sheet, .none, "arrival keeps its own rule")
        (ui, base, _) = sheetOpen(DashFixtures.freeRide())
        ui.update(DashFixtures.navigating()) // no music, navigation starts
        XCTAssertEqual(ui.state.sheet, .none)
        XCTAssertEqual(ui.state.focusedId, DashFocusEngine.recenterId) // P0 (D01): never End
    }

    func testIdleAndNearTurnRulesStillCountFromTheRidersLastInput() {
        let (ui, base, with) = sheetOpen()
        ui.update(base)
        _ = ui.displayList(now: t0 + 9.5)
        ui.update(with)
        _ = ui.displayList(now: t0 + 10)
        XCTAssertEqual(ui.tick(now: t0 + 10.5), [.closeSheets], "10 s after ★: the idle close, gap or not")
        _ = ui.displayList(now: t0 + 10.6)
        XCTAssertEqual(ui.state.focusedId, DashFocusEngine.musicTileId)
    }
}
