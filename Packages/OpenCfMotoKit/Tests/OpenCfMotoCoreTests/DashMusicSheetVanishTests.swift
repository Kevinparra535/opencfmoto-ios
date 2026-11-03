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
        ui.update(base)
        _ = ui.displayList(now: t0 + 1.5)
        XCTAssertEqual(ui.handle(.key(.enter), now: t0 + 1.6), [.musicPlayPause], "the app sends it to the player")
        XCTAssertEqual(ui.handle(.key(.back), now: t0 + 1.8), [.closeSheets], "BACK closes it")
        _ = ui.displayList(now: t0 + 1.9)
        XCTAssertEqual(ui.state.focusedId, "fab.recenter", "no tile: parked as F2 says, never End")
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
        XCTAssertEqual(ui.state.focusedId, DashFocusEngine.endId)
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

    func testPreviewSheetGapKeepsGoOutOfReach() {
        // The sheet opened from the menu over a preview, ⏭, one reading with no item: ★ is ⏭ again, not Go.
        var m = DashFixtures.preview()
        m.music = DashFixtures.song()
        let ui = DashUIController()
        ui.update(m)
        _ = ui.displayList(now: t0)
        _ = ui.handle(.key(.home), now: t0 + 0.1)
        let order = ui.state.focusOrder
        let at = order.firstIndex(of: ui.state.focusedId ?? "") ?? 0
        guard let music = order.firstIndex(of: "menu.music") else { return XCTFail("no menu.music in \(order)") }
        _ = ui.handle(.knob(music - at), now: t0 + 0.2)
        XCTAssertEqual(ui.handle(.key(.enter), now: t0 + 0.3), [.openMusic])
        _ = ui.displayList(now: t0 + 0.35)
        _ = ui.handle(.knob(1), now: t0 + 0.5)
        XCTAssertEqual(ui.handle(.key(.enter), now: t0 + 0.8), [.musicNext])
        var gone = m
        gone.music = nil
        ui.update(gone)
        _ = ui.displayList(now: t0 + 1)
        ui.update(m)
        _ = ui.displayList(now: t0 + 1.5)
        XCTAssertEqual(ui.handle(.key(.enter), now: t0 + 2), [.musicNext], "★ is ⏭ again, never Go")
    }
}
