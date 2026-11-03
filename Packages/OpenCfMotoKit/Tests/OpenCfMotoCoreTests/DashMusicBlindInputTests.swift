// SPDX-License-Identifier: AGPL-3.0-or-later
// Apple Music on the dash (iOS addition), review round 2: blind handlebar input. While the Music app
// holds the bars, or with the eyes on the road, the rider presses ★ and BACK for the Music control
// the focus was left on, without looking at the dash. Exhaustively, from every Music starting state
// (the tile with a playing or a paused song, the open sheet on each of ⏮ ⏯ ⏭ ✕, the menu on "Music"),
// navigating and in free ride, with the song staying, gone for one built frame, or gone for good (F2):
// no sequence of 1–3 ★ / BACK presses returns `.endNavigation`. (The vanishes are what the dash model
// sees: one reading without a song never gets there — MusicModel holds the song 2 s — and an open sheet
// outlasts a short vanish, review round 3.) Knob steps (◀ ▶) are not blind-safe:
// End is a stop of the map's list, and from where a vanish parked the focus a knob step lands on other
// neighbours than from the vanished control. The shortest sequences to End are documented here (a vanish
// adds only the Recenter FAB's trade-off), and so are the other actions a knob step reaches (review
// round 3): the pill's Lap / Stop in free ride and Record in the menu. From End or the Menu FAB nothing
// parks or returns: the tile must be listed at the knob step (`testFromEndTheTileMustBeListed`).
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

    /// When the presses start: after the setup and the vanish (a song gone for good closes an open sheet
    /// only at the end of its 2-s grace, R3-FOCUS-1).
    private static let pressStart = t0 + 3

    /// A fresh controller in state `c`, then `presses` (indices into `keys`), one every 0.4 s; `frames`:
    /// a frame after every press, as the render loop usually builds (without, as when the gesture engine
    /// hands over two presses at once). Returns, per press, whether it ended navigation (none past the
    /// first that did), and the focus when the presses start.
    private static func replay(_ c: Config, _ presses: [Int], frames: Bool) -> (ends: [Bool], focus: String?) {
        let ui = controller(c)
        let focus = presses.isEmpty ? ui.state.focusedId : nil
        var ends: [Bool] = []
        for (i, k) in presses.enumerated() {
            let now = pressStart + Double(i) * 0.4
            ends.append(ui.handle(keys[k].input, now: now).contains(.endNavigation))
            if ends.last == true { break }
            if frames { _ = ui.displayList(now: now + 0.1) }
        }
        return (ends, focus)
    }

    /// A fresh controller in state `c`: the setup, then the vanish.
    private static func controller(_ c: Config) -> DashUIController {
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
        return ui
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

    // MARK: Preview and arrival (R3-FOCUS-2)

    /// Over a route preview (free ride, or over a running navigation) or the arrival card no Music control
    /// exists: no menu entry, an inert tile, no sheet. So no blind sequence starts from a Music state there,
    /// and a song gone for one frame or for good changes nothing for any 1–3 presses of ★, BACK, HOME, ◀, ▶:
    /// same intents, same focus, same sheet. (A sheet there used to close onto Go / Park: ★ meant for ⏭
    /// replaced the navigation.)
    func testPreviewAndArrivalHaveNoMusicStateAndAVanishChangesNothing() {
        let all: [DashInput] = [.key(.enter), .key(.back), .key(.home), .knob(-1), .knob(1)]
        var navPreview = DashFixtures.navigating()
        navPreview.nav.preview = DashFixtures.preview().nav.preview
        var sequences: [[Int]] = all.indices.map { [$0] }
        for _ in 0 ..< 2 { sequences += sequences.filter { $0.count == sequences.last!.count }.flatMap { s in all.indices.map { s + [$0] } } }
        XCTAssertEqual(sequences.count, 5 + 25 + 125)
        for (name, base) in [("preview", DashFixtures.preview()), ("preview over a navigation", navPreview),
                             ("arrival", DashFixtures.arrival())] {
            let with = DashFixtures.withMusic(base)
            func run(_ presses: [Int], vanish: Vanish) -> [String] {
                let ui = DashUIController()
                ui.update(with)
                _ = ui.displayList(now: Self.t0)
                switch vanish {
                case .none: break
                case .oneFrame:
                    ui.update(base); _ = ui.displayList(now: Self.t0 + 0.5)
                    ui.update(with); _ = ui.displayList(now: Self.t0 + 1)
                case .forGood:
                    ui.update(base); _ = ui.displayList(now: Self.t0 + 0.5)
                }
                return presses.enumerated().map { i, k in
                    let now = Self.t0 + 1.5 + Double(i) * 0.4
                    let out = ui.handle(all[k], now: now)
                    _ = ui.displayList(now: now + 0.1)
                    let st = ui.state
                    XCTAssertNotEqual(st.sheet, .music, "\(name) \(presses): a Music sheet")
                    XCTAssertFalse(st.focusOrder.contains { DashFocusEngine.isMusicControl($0) }, "\(name) \(presses)")
                    return "\(out) \(st.focusedId ?? "-") \(st.sheet)"
                }
            }
            for p in sequences {
                let reference = run(p, vanish: .none)
                XCTAssertEqual(run(p, vanish: .oneFrame), reference, "\(name) \(p): gone one frame")
                XCTAssertEqual(run(p, vanish: .forGood), reference, "\(name) \(p): gone for good")
            }
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

    // MARK: Other actions a knob step reaches (review round 3)

    /// Actions of consequence besides End: the pill's Lap / Stop (stops a running lap timer and clears its
    /// laps, or arms one where the bike is), Record / Stop recording (stops and saves the trip log; a log that
    /// started by itself then stays off for the session), Park here, Set home here, Go home, Go, the voice.
    private static func otherAction(_ intents: [DashIntent]) -> String? {
        for i in intents {
            switch i {
            case .toggleLapTimer: return "Lap"
            case .toggleRecording: return "Record"
            case .parkHere: return "Park here"
            case .setHomeHere: return "Set home"
            case .goHome: return "Go home"
            case .go: return "Go"
            case .toggleVoice: return "Voice"
            default: continue
            }
        }
        return nil
    }

    /// Every config × every sequence of 1–3 presses: the shortest ones whose last press returns one of
    /// `otherAction` and no earlier press any action (End included), with that action.
    private static func otherOutcomes(frames: Bool) -> [Config: [String: String]] {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var all: [Config: [String: String]] = [:]
        }
        let box = Box()
        let all = configs
        DispatchQueue.concurrentPerform(iterations: all.count) { item in
            let c = all[item]
            var found: [String: String] = [:]
            func run(_ p: [Int]) -> String?? { // nil: nothing; .some(nil): End; .some(a): action a
                let ui = controller(c)
                for (i, k) in p.enumerated() {
                    let now = pressStart + Double(i) * 0.4
                    let intents = ui.handle(keys[k].input, now: now)
                    if intents.contains(.endNavigation) { return .some(nil) }
                    if let a = otherAction(intents) { return i == p.count - 1 ? .some(a) : .some(nil) }
                    if frames { _ = ui.displayList(now: now + 0.1) }
                }
                return nil
            }
            func name(_ p: [Int]) -> String { String(p.map { keys[$0].name }) }
            for a in keys.indices {
                if let r = run([a]) { if let x = r { found[name([a])] = x }; continue }
                for b in keys.indices {
                    if let r = run([a, b]) { if let x = r { found[name([a, b])] = x }; continue }
                    for d in keys.indices { if let x = run([a, b, d]) ?? nil { found[name([a, b, d])] = x } }
                }
            }
            box.lock.lock(); box.all[c] = found; box.lock.unlock()
        }
        return box.all
    }

    /// Navigating: from the menu's Music, ◀◀★ is Record (two items up); where a vanish parked the menu's
    /// focus (Circuit, the item above Music), ◀★. Nothing else within three presses.
    private static let navigatingOther: [String: [String: String]] = [
        "tile": [:], "sheet": [:], "sheet ✕": [:],
        "menu Music": ["◀◀★": "Record"],
        "parked Recenter": [:],
        "parked Circuit": ["◀★": "Record"],
    ]

    /// Free ride: the map's list is the pill, its Circuit, its Lap / Stop, then Recenter … Menu and the tile.
    /// Where a vanish parked the focus, Recenter's ◀ neighbour is the pill's Lap (End while navigating): ◀★,
    /// B◀★ / ★◀★ (BACK and ★ keep the focus parked), ◀B★ (BACK at idle in free ride keeps Lap) press Lap /
    /// Stop — the free-ride side of the Recenter trade-off. In the menu as navigating, plus Circuit's B◀★ /
    /// ★◀★ (BACK or ★ there close the menu onto Recenter, parked again).
    private static let freeRideOther: [String: [String: String]] = [
        "tile": [:], "sheet": [:], "sheet ✕": [:],
        "menu Music": ["◀◀★": "Record"],
        "parked Recenter": ["◀★": "Lap", "B◀★": "Lap", "★◀★": "Lap", "◀B★": "Lap"],
        "parked Circuit": ["◀★": "Record", "B◀★": "Lap", "★◀★": "Lap"],
    ]

    func testOtherActionsAKnobStepReachesAreDocumented() {
        let all = Self.otherOutcomes(frames: false)
        XCTAssertEqual(all.count, Self.configs.count)
        for (c, found) in all {
            let row = Self.expected(c).row
            let table = c.mode == .navigating ? Self.navigatingOther : Self.freeRideOther
            XCTAssertEqual(found, table[row], "\(c) (\(row))")
            // ★ and BACK alone reach none of them either
            XCTAssertEqual(found.keys.filter { !$0.contains("◀") && !$0.contains("▶") }, [], "\(c)")
        }
        XCTAssertEqual(Self.otherOutcomes(frames: true), all, "a frame between the presses changes nothing")
    }

    // MARK: From End or the Menu FAB (the field guide's ◀ ★ ★), the tile must be listed

    /// The tile closes the map's list, one knob step back from End (the field guide: ◀ to the tile, ★ the
    /// sheet, ★ play / pause). From a control that is not a Music control nothing parks or returns: while
    /// the tile is not listed — gone, or gone at the very knob step and back before the ★ (a gap that
    /// outlasted MusicModel's 2-s hold) — ◀ is the Menu FAB and ◀★★ Android's path to End (the menu opens
    /// on End); ▶★ from the Menu FAB too.
    func testFromEndTheTileMustBeListed() {
        let base = DashFixtures.navigating()
        let with = DashFixtures.withMusic(base, DashFixtures.song(.paused))
        for gap in ["tile shown", "no music", "gone", "blink at the knob step"] {
            let ui = DashUIController()
            ui.update(gap == "no music" ? base : with)
            _ = ui.displayList(now: Self.t0)
            XCTAssertEqual(ui.state.focusedId, DashFocusEngine.endId)
            if gap == "gone" || gap == "blink at the knob step" { ui.update(base) }
            _ = ui.handle(.knob(-1), now: Self.t0 + 1)
            if gap == "blink at the knob step" { ui.update(with); _ = ui.displayList(now: Self.t0 + 1.2) }
            let a = ui.handle(.key(.enter), now: Self.t0 + 1.5)
            let b = ui.handle(.key(.enter), now: Self.t0 + 2)
            XCTAssertEqual(a + b, gap == "tile shown" ? [.openMusic, .musicPlayPause] : [.openMenu, .endNavigation], gap)
        }
        for gone in [false, true] {
            let ui = DashUIController()
            ui.update(with)
            _ = ui.handle(.knob(-2), now: Self.t0) // End → the tile → the Menu FAB
            if gone { ui.update(base) }
            _ = ui.handle(.knob(1), now: Self.t0 + 1)
            XCTAssertEqual(ui.handle(.key(.enter), now: Self.t0 + 1.5), gone ? [.endNavigation] : [.openMusic], "gone=\(gone)")
        }
    }
}
