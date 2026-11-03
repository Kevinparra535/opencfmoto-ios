// SPDX-License-Identifier: AGPL-3.0-or-later
// Apple Music on the dash (iOS addition), review round 2: blind handlebar input. While the Music app
// holds the bars, or with the eyes on the road, the rider presses ★ and BACK for the Music control
// the focus was left on, without looking at the dash. Exhaustively, from every Music starting state
// (the tile with a playing or a paused song, the open sheet on each of ⏮ ⏯ ⏭ ✕, the menu on "Music"),
// navigating and in free ride, with the song staying, gone for one built frame, or gone for good (F2):
// no sequence of 1–3 ★ / BACK presses returns `.endNavigation`. Knob steps (◀ ▶) do reach End on
// purpose — End is a stop of the map's list — and the shortest such sequences are documented here,
// with what a vanish changes about them: nothing, except the Recenter FAB's documented trade-off.
import Foundation
import XCTest
@testable import OpenCfMotoCore

final class DashMusicBlindInputTests: XCTestCase {
    private static let t0 = DashFixtures.musicNow

    enum Mode: String, CaseIterable { case navigating, freeRide = "free ride" }
    enum Start: String, CaseIterable {
        case tilePlaying = "tile ▶", tilePaused = "tile ❚❚"
        case previous = "sheet ⏮", playPause = "sheet ⏯", next = "sheet ⏭", close = "sheet ✕"
        case menuMusic = "menu Music"
        var isSheet: Bool { [.previous, .playPause, .next, .close].contains(self) }
    }
    enum Vanish: String, CaseIterable { case none = "no vanish", oneFrame = "gone one frame", forGood = "gone for good" }

    struct Config: Hashable, CustomStringConvertible {
        let mode: Mode, start: Start, vanish: Vanish
        var description: String { "\(mode.rawValue), \(start.rawValue), \(vanish.rawValue)" }
    }

    struct Outcome: Equatable {
        /// The shortest sequences that end navigation: `.endNavigation` from their last press and from no
        /// earlier one. Every longer sequence that starts with one of them ends it too; no other does.
        var shortestEnds: Set<String> = []
        /// Where the focus is when the presses start (after the setup and the vanish).
        var focus: String?
        /// Presses other than ★ that returned `.endNavigation` (must stay empty, see `outcomes`).
        var nonStarEnds: Set<String> = []
    }

    /// ★ Enter, B Back, ◀ ▶ one knob step (the D-pad's ◀ ▶ and ▲ ▼ do the same). Index 0 is ★.
    private static let keys: [(name: Character, input: DashInput)] =
        [("★", .key(.enter)), ("B", .key(.back)), ("◀", .knob(-1)), ("▶", .knob(1))]

    private static func base(_ mode: Mode) -> DashModel { mode == .navigating ? DashFixtures.navigating() : DashFixtures.freeRide() }

    private static let configs: [Config] =
        Mode.allCases.flatMap { m in Start.allCases.flatMap { s in Vanish.allCases.map { Config(mode: m, start: s, vanish: $0) } } }

    private static let menuMusicIndex: [Mode: Int] = Dictionary(uniqueKeysWithValues: Mode.allCases.map { mode in
        let ui = DashUIController()
        ui.update(DashFixtures.withMusic(base(mode)))
        _ = ui.handle(.key(.home), now: t0)
        return (mode, ui.state.focusOrder.firstIndex(of: "menu.music") ?? -1)
    })

    /// A fresh controller in state `c`, then `presses` (indices into `keys`), one every 0.4 s; `frames`:
    /// a frame after every press, as the render loop usually builds (without, as when the gesture engine
    /// hands over two presses at once). Returns, per press, whether it ended navigation (none past the
    /// first that did), and the focus when the presses start.
    private static func replay(_ c: Config, _ presses: [Int], frames: Bool) -> (ends: [Bool], focus: String?) {
        let base = base(c.mode)
        let with = DashFixtures.withMusic(base, DashFixtures.song(c.start == .tilePaused ? .paused : .playing))
        let ui = DashUIController()
        ui.update(with)
        switch c.start {
        case .tilePlaying, .tilePaused:
            _ = ui.handle(.knob(-1), now: t0) // ◀ from the default item: the tile closes the map list
        case .menuMusic:
            _ = ui.handle(.key(.home), now: t0)
            _ = ui.handle(.knob(menuMusicIndex[c.mode]!), now: t0 + 0.05)
        case .previous, .playPause, .next, .close:
            _ = ui.handle(.knob(-1), now: t0)
            _ = ui.handle(.key(.enter), now: t0 + 0.05) // ★ on the tile: the sheet, on ⏯
            let step = [Start.previous: -1, .next: 1, .close: 2][c.start] ?? 0
            if step != 0 { _ = ui.handle(.knob(step), now: t0 + 0.1) }
        }
        switch c.vanish {
        case .none: break
        case .oneFrame:
            ui.update(base); _ = ui.displayList(now: t0 + 0.5)
            ui.update(with); _ = ui.displayList(now: t0 + 1)
        case .forGood: // past the open sheet's vanish grace (R3-FOCUS-1)
            ui.update(base); _ = ui.displayList(now: t0 + 0.5)
            _ = ui.tick(now: t0 + 2.6); _ = ui.displayList(now: t0 + 2.7)
        }
        let focus = presses.isEmpty ? ui.state.focusedId : nil
        var ends: [Bool] = []
        for (i, k) in presses.enumerated() {
            let now = t0 + 3 + Double(i) * 0.4
            ends.append(ui.handle(keys[k].input, now: now).contains(.endNavigation))
            if ends.last == true { break }
            if frames { _ = ui.displayList(now: now + 0.1) }
        }
        return (ends, focus)
    }

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var byConfig: [Config: Outcome] = [:]
        func merge(_ c: Config, _ o: Outcome) {
            lock.lock(); defer { lock.unlock() }
            var r = byConfig[c] ?? Outcome()
            r.shortestEnds.formUnion(o.shortestEnds)
            r.nonStarEnds.formUnion(o.nonStarEnds)
            if let f = o.focus { r.focus = f }
            byConfig[c] = r
        }
        var all: [Config: Outcome] { lock.lock(); defer { lock.unlock() }; return byConfig }
    }

    /// Every config × every sequence of 1–3 presses over `alphabet` (indices into `keys`, ★ included).
    /// Only ★ activates a control, so only ★ can return `.endNavigation` (BACK closes a sheet or does
    /// nothing, the knob only moves the focus): a sequence ends navigation with its third press only when
    /// that press is ★, and a press's intents never depend on later presses. Replaying a, b, ★ for every
    /// a, b (and nothing past an end) therefore answers all of them; every press other than ★ is checked
    /// never to return `.endNavigation`. Configs run in parallel, each on its own controllers.
    private static func outcomes(alphabet: [Int], frames: Bool) -> [Config: Outcome] {
        let results = Results()
        let all = configs
        DispatchQueue.concurrentPerform(iterations: all.count * alphabet.count) { item in
            let c = all[item / alphabet.count], first = alphabet[item % alphabet.count]
            var out = Outcome()
            if item % alphabet.count == 0 { out.focus = replay(c, [], frames: frames).focus }
            func name(_ p: [Int]) -> String { String(p.map { keys[$0].name }) }
            for second in alphabet {
                let p = [first, second, 0]
                let ends = replay(c, p, frames: frames).ends
                for (i, e) in ends.enumerated() where e && p[i] != 0 { out.nonStarEnds.insert(name(Array(p[...i]))) }
                if ends.first == true { out.shortestEnds.insert(name([first])); break }
                if ends.count > 1, ends[1] { out.shortestEnds.insert(name([first, second])) }
                else if ends.count > 2, ends[2] { out.shortestEnds.insert(name(p)) }
            }
            results.merge(c, out)
        }
        return results.all
    }

    /// All four keys, a press every 0.4 s with no frame in between (computed once for the tests below).
    private static let everyKey = outcomes(alphabet: Array(keys.indices), frames: false)

    /// True when `s` ends navigation in an outcome (it starts with one of its shortest ends).
    private static func ends(_ s: String, _ o: Outcome) -> Bool { o.shortestEnds.contains { s.hasPrefix($0) } }

    // MARK: ★ and BACK alone never end navigation

    func testBlindStarAndBackNeverEndNavigation() {
        let all = Self.everyKey
        XCTAssertEqual(all.count, Self.configs.count) // 2 modes × 7 starts × 3 vanishes
        for (c, o) in all {
            // every shortest end takes the knob, so no sequence of ★ and BACK alone ends navigation
            XCTAssertEqual(o.shortestEnds.filter { !$0.contains("◀") && !$0.contains("▶") }, [], "\(c): ★ / BACK reached End")
            XCTAssertEqual(o.nonStarEnds, [], "\(c): only ★ may return .endNavigation")
        }
    }

    func testAFrameBetweenThePressesChangesNothing() {
        // The render loop usually builds frames between two presses; the gesture engine can also hand
        // over two presses at once. Every outcome is the same either way.
        let framed = Self.outcomes(alphabet: Array(Self.keys.indices), frames: true)
        XCTAssertEqual(framed, Self.everyKey)
    }

    // MARK: Knob paths to End, documented

    /// Navigating. The map's list is End, Recenter, Zoom in, Zoom out, Compass, Menu, the tile (◀ ▶ wrap);
    /// the sheet's ⏮ ⏯ ⏭ ✕; the menu's End … Circuit, Music, Follow … ✕.
    /// - tile: ▶★ (▶ wraps from the tile to End); ◀★★ (◀ is the Menu FAB, ★ opens the menu on End);
    ///   ◀B★ / ▶B★ (BACK at idle on a control the rider moved to: End, Android); B▶★ (BACK keeps the tile).
    /// - sheet ⏮ ⏯ ⏭: B▶★ (BACK closes the sheet onto the tile); ✕ also ★▶★ (★ on ✕ closes it too).
    /// - menu Music: ◀★★ (◀ is Circuit, whose ★ closes the menu onto End); ◀B★ / ▶B★ (BACK from Circuit /
    ///   Follow closes the menu onto End, Android); B▶★ (BACK from Music closes it onto the tile).
    /// - Recenter, where a vanish parked the focus (gone for good, from the tile or the sheet): ◀★, B◀★,
    ///   ★◀★ — Recenter follows End in the list, and BACK / ★ there keep the focus parked: the trade-off of
    ///   the safe target (★ there only recenters; ▶★ from the tile is the same two presses) — and ◀B★ /
    ///   ▶B★ as above.
    /// - Circuit, where a vanish parked the menu's focus (gone for good): B◀★ / ★◀★ (BACK or ★ there
    ///   close the menu onto Recenter, parked again, then the trade-off); ◀B★ / ▶B★ as above.
    private static let navigatingEnds: [String: Set<String>] = [
        "tile": ["▶★", "◀★★", "◀B★", "▶B★", "B▶★"],
        "sheet": ["B▶★"],
        "sheet ✕": ["B▶★", "★▶★"],
        "menu Music": ["◀★★", "◀B★", "▶B★", "B▶★"],
        "parked Recenter": ["◀★", "B◀★", "★◀★", "◀B★", "▶B★"],
        "parked Circuit": ["B◀★", "★◀★", "◀B★", "▶B★"],
    ]

    /// Free ride: no End on the map. ◀★★ from the tile is the Menu FAB, then the menu's first item "End
    /// navigation", which the session answers with "already free ride". Nothing else.
    private static let freeRideEnds: [String: Set<String>] = [
        "tile": ["◀★★"], "sheet": [], "sheet ✕": [], "menu Music": [], "parked Recenter": [], "parked Circuit": [],
    ]

    /// The only paths a vanish adds (navigating, the song gone for good): ◀ from where it parked the focus.
    private static let recenterTradeOff: Set<String> = ["◀★", "B◀★", "★◀★"]

    /// Where the knob is when the presses start, and its documented row.
    private static func expected(_ c: Config) -> (focus: String, row: String) {
        switch (c.start, c.vanish) {
        case (.menuMusic, .forGood): return ("menu.circuit", "parked Circuit")
        case (.menuMusic, _): return ("menu.music", "menu Music")
        case (_, .forGood): return ("fab.recenter", "parked Recenter")
        case (.tilePlaying, _), (.tilePaused, _): return ("music.tile", "tile")
        case (.previous, _): return ("music.previous", "sheet") // a one-frame vanish keeps the sheet open (R3-FOCUS-1)
        case (.playPause, _): return ("music.playPause", "sheet")
        case (.next, _): return ("music.next", "sheet")
        case (.close, _): return ("music.close", "sheet ✕")
        }
    }

    func testKnobPathsToEndAreDocumentedAndAVanishAddsOnlyTheRecenterTradeOff() {
        let all = Self.everyKey
        for (c, o) in all {
            let (focus, row) = Self.expected(c)
            XCTAssertEqual(o.focus, focus, "\(c): the focus when the presses start")
            let table = c.mode == .navigating ? Self.navigatingEnds : Self.freeRideEnds
            XCTAssertEqual(o.shortestEnds, table[row], "\(c) (\(row))")
            guard c.vanish != .none else { continue }
            // A vanish adds no path to End: each one also ends navigation without any vanish, from the same
            // start (a one-frame vanish leaves an open sheet open: R3-FOCUS-1) or, when the song stayed gone
            // and the sheet closed 2 s later, from the tile (where the knob comes back to, as after any close
            // of the sheet) — except the Recenter trade-off while the song stays gone.
            let reference = all[Config(mode: c.mode, start: c.start.isSheet && c.vanish == .forGood ? .tilePlaying : c.start, vanish: .none)]!
            for s in o.shortestEnds where !Self.ends(s, reference) {
                XCTAssertTrue(c.vanish == .forGood && c.mode == .navigating && Self.recenterTradeOff.contains(s),
                              "\(c): \(s) ends navigation only because of the vanish")
            }
            // the song back after one frame gives the knob back exactly: the same paths as without a vanish
            if c.vanish == .oneFrame { XCTAssertEqual(o.shortestEnds, reference.shortestEnds, "\(c)") }
        }
    }
}
