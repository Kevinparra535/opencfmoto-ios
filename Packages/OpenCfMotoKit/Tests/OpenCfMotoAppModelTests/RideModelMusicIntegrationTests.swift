// SPDX-License-Identifier: AGPL-3.0-or-later
// Apple Music on the dash, end to end through the model layer (contract §8.8-5, the integration of
// the Core dash UI with the AppModel side): taps on the hit regions the scene really draws, the
// handlebar path (knob, Enter, Back) and the menu path reach the fake Music app, and the dash model
// follows what the Music app does.
// NOTE (Linux): main-actor tests must be `async` (swift-corelibs-xctest).

import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class RideModelMusicIntegrationTests: XCTestCase {
    /// The app over the preview services with a fake Music app (playing "p1a" at 2:13) on a manual
    /// clock, the feature on, the phone's Dash view open (own dash UI live, 800×384 preview canvas)
    /// and the song on the dash.
    @MainActor
    private func harness(playing: Bool = true) async -> (AppTestHarness, PreviewMusic, MusicTestClock) {
        let clock = MusicTestClock()
        let fake = PreviewMusic(clock: clock, queue: MusicFixtures.queue, playing: playing, position: 133,
                                authorization: .authorized)
        fake.artworks["p1a"] = MusicFixtures.art(1)
        fake.artworks["s100000002"] = MusicFixtures.art(2)
        let h = AppTestHarness { services in
            services.clock = clock
            services.music = fake
            services.keyValueStore.set(true, forKey: MusicModel.enabledKey)
        }
        h.model.music.artworkAttemptDelays = [0]
        h.model.music.imageCleanupDelay = 0
        h.ride.startLocationPreview()
        let shown = await eventually { h.ride.lastModel?.music?.artworkId == "music.art.p1a" }
        XCTAssertTrue(shown, "the song (with its artwork) is on the dash")
        return (h, fake, clock)
    }

    @MainActor
    private func list(_ h: AppTestHarness) -> DashDisplayList {
        h.ride.flushModel()
        return h.ride.displayList(now: h.core.services.clock.now())
    }

    @MainActor
    private func has(_ h: AppTestHarness, _ id: String) -> Bool {
        list(h).hitRegions.contains { $0.id == id }
    }

    /// A rider's tap on the centre of the hit region `id` (what the scene drew last).
    @MainActor
    private func tap(_ h: AppTestHarness, _ clock: MusicTestClock, _ id: String,
                     file: StaticString = #filePath, line: UInt = #line) {
        guard let r = list(h).hitRegions.last(where: { $0.id == id }) else {
            XCTFail("no hit region \(id)", file: file, line: line)
            return
        }
        let x = Int(r.rect.midX)
        let y = Int(r.rect.midY)
        h.ride.handleDashTouch(DashTouch(action: .down, x: x, y: y, time: clock.now()))
        clock.advance(0.05)
        h.ride.handleDashTouch(DashTouch(action: .up, x: x, y: y, time: clock.now()))
        clock.advance(0.5)
    }

    @MainActor
    private func images(_ h: AppTestHarness) -> [String] {
        list(h).commands.compactMap { if case let .image(id, _, _) = $0 { return id }; return nil }
    }

    // MARK: Touch dash

    @MainActor
    func testTouchTheTileThenTheTransportButtons() async {
        let (h, fake, clock) = await harness()
        XCTAssertTrue(has(h, "music.tile"))
        XCTAssertEqual(images(h), ["music.art.p1a"], "the tile draws the registered artwork")
        XCTAssertNotNil(h.projection.dashImages["music.art.p1a"])

        tap(h, clock, "music.tile")
        XCTAssertEqual(h.ride.dashUIState.sheet, .music)
        XCTAssertEqual(h.ride.dashUIState.focusedId, "music.playPause")
        XCTAssertFalse(has(h, "music.tile"), "the sheet covers the map")
        XCTAssertEqual(images(h), ["music.art.p1a"], "the sheet draws the same artwork")
        XCTAssertEqual(fake.commands, [], "opening the sheet changes nothing in the Music app")

        tap(h, clock, "music.playPause")
        XCTAssertEqual(fake.commands, ["pause"])
        let paused = await eventually { h.ride.lastModel?.music?.state == .paused }
        XCTAssertTrue(paused, "the dash follows the Music app (no optimistic state)")
        XCTAssertEqual(h.ride.dashUIState.sheet, .music, "a transport tap keeps the sheet open")

        tap(h, clock, "music.next")
        XCTAssertEqual(fake.commands, ["pause", "next"])
        let next = await eventually { h.ride.lastModel?.music?.artworkId == "music.art.s100000002" }
        XCTAssertTrue(next, "the next song's artwork replaces the first one")
        XCTAssertEqual(images(h), ["music.art.s100000002"])

        tap(h, clock, "music.previous") // 0 s into the next song: the previous song, not its beginning
        XCTAssertEqual(fake.commands, ["pause", "next", "previous"])

        tap(h, clock, "music.close")
        XCTAssertEqual(h.ride.dashUIState.sheet, .none)
        XCTAssertTrue(has(h, "music.tile"))
    }

    @MainActor
    func testATapOnTheSheetBackgroundDoesNothing() async {
        let (h, fake, clock) = await harness()
        tap(h, clock, "music.tile")
        XCTAssertEqual(h.ride.dashUIState.sheet, .music)
        // The text column's lower-left corner: neither a control nor the map underneath.
        let before = h.ride.dashUIState.camera
        h.ride.handleDashTouch(DashTouch(action: .down, x: 20, y: 376, time: clock.now()))
        clock.advance(0.05)
        h.ride.handleDashTouch(DashTouch(action: .up, x: 20, y: 376, time: clock.now()))
        XCTAssertEqual(h.ride.dashUIState.sheet, .music)
        XCTAssertEqual(h.ride.dashUIState.camera, before, "no map pan under the sheet")
        XCTAssertEqual(fake.commands, [])
    }

    // MARK: Handlebar (non-touch dash)

    @MainActor
    func testHandlebarKnobToTheTileEnterTwiceThenBack() async {
        let (h, fake, clock) = await harness()
        XCTAssertTrue(has(h, "music.tile"))
        XCTAssertEqual(h.ride.dashUIState.focusedId, "pill", "free ride: the search pill is the default focus")
        h.ride.handleDashInput(.knob(-1)) // from the default first item, one step back wraps to the tile
        XCTAssertEqual(h.ride.dashUIState.focusedId, "music.tile")
        clock.advance(1)
        h.ride.handleDashInput(.key(.enter))
        XCTAssertEqual(h.ride.dashUIState.sheet, .music)
        XCTAssertEqual(h.ride.dashUIState.focusedId, "music.playPause")
        clock.advance(1)
        h.ride.handleDashInput(.key(.enter))
        XCTAssertEqual(fake.commands, ["pause"])
        clock.advance(1)
        h.ride.handleDashInput(.knob(1))
        XCTAssertEqual(h.ride.dashUIState.focusedId, "music.next")
        h.ride.handleDashInput(.key(.enter))
        XCTAssertEqual(fake.commands, ["pause", "next"])
        clock.advance(1)
        h.ride.handleDashInput(.key(.back))
        XCTAssertEqual(h.ride.dashUIState.sheet, .none)
        XCTAssertEqual(h.ride.dashUIState.focusedId, "music.tile", "Back returns the focus to the tile")
    }

    @MainActor
    func testStartingAPausedSongFromTheDash() async {
        let (h, fake, clock) = await harness(playing: false)
        XCTAssertEqual(h.ride.lastModel?.music?.state, .paused, "a paused song stays on the dash: the entry point")
        XCTAssertTrue(has(h, "music.tile"))
        h.ride.handleDashInput(.knob(-1))
        XCTAssertEqual(h.ride.dashUIState.focusedId, "music.tile")
        h.ride.handleDashInput(.key(.enter))
        clock.advance(1)
        h.ride.handleDashInput(.key(.enter))
        XCTAssertEqual(fake.commands, ["play"], "only a rider action starts music")
        let playing = await eventually { h.ride.lastModel?.music?.state == .playing }
        XCTAssertTrue(playing)
    }

    // MARK: Menu

    @MainActor
    func testMenuEntryOpensTheMusicSheetByTouch() async {
        let (h, fake, clock) = await harness()
        tap(h, clock, "fab.menu")
        XCTAssertEqual(h.ride.dashUIState.sheet, .menu)
        let order = h.ride.dashUIState.focusOrder
        XCTAssertEqual(order.firstIndex(of: "menu.music"), order.firstIndex(of: "menu.circuit").map { $0 + 1 },
                       "Music comes right after Circuit")
        // 800×384: the entry is below the fold — the rider drags the menu up first.
        XCTAssertFalse(has(h, "menu.music"))
        let x = 660
        h.ride.handleDashTouch(DashTouch(action: .down, x: x, y: 330, time: clock.now()))
        for y in stride(from: 310, through: 90, by: -20) {
            clock.advance(0.02)
            h.ride.handleDashTouch(DashTouch(action: .move, x: x, y: y, time: clock.now()))
        }
        clock.advance(0.02)
        h.ride.handleDashTouch(DashTouch(action: .up, x: x, y: 90, time: clock.now()))
        clock.advance(0.5)
        XCTAssertGreaterThan(h.ride.dashUIState.menuScroll, 0)
        XCTAssertEqual(h.ride.dashUIState.sheet, .menu, "a drag scrolls, it activates nothing")
        tap(h, clock, "menu.music")
        XCTAssertEqual(h.ride.dashUIState.sheet, .music)
        XCTAssertEqual(h.ride.dashUIState.focusedId, "music.playPause")
        XCTAssertEqual(fake.commands, [])
    }

    @MainActor
    func testMenuEntryOpensTheMusicSheetByHandlebar() async {
        let (h, fake, clock) = await harness()
        h.ride.handleDashInput(.key(.home))
        XCTAssertEqual(h.ride.dashUIState.sheet, .menu)
        let order = h.ride.dashUIState.focusOrder
        guard let from = order.firstIndex(of: h.ride.dashUIState.focusedId ?? ""),
              let to = order.firstIndex(of: "menu.music") else {
            XCTFail("menu.music not in the menu focus order \(order)")
            return
        }
        for _ in from ..< to {
            clock.advance(0.3)
            h.ride.handleDashInput(.knob(1))
        }
        XCTAssertEqual(h.ride.dashUIState.focusedId, "menu.music")
        XCTAssertTrue(has(h, "menu.music"), "the focused entry is scrolled into view")
        clock.advance(0.3)
        h.ride.handleDashInput(.key(.enter))
        XCTAssertEqual(h.ride.dashUIState.sheet, .music)
        XCTAssertEqual(h.ride.dashUIState.focusedId, "music.playPause")
        clock.advance(0.3)
        h.ride.handleDashInput(.key(.enter))
        XCTAssertEqual(fake.commands, ["pause"])
    }

    @MainActor
    func testNoMenuEntryAndNoTileWhenTheFeatureIsTurnedOff() async {
        let (h, fake, clock) = await harness()
        tap(h, clock, "music.tile")
        XCTAssertEqual(h.ride.dashUIState.sheet, .music)
        await h.model.music.setEnabled(false)
        let gone = await eventually { h.ride.lastModel?.music == nil }
        XCTAssertTrue(gone)
        XCTAssertEqual(h.ride.dashUIState.sheet, .none, "the Music sheet closes with the music")
        XCTAssertFalse(has(h, "music.tile"))
        tap(h, clock, "fab.menu")
        XCTAssertFalse(has(h, "menu.music"))
        XCTAssertFalse(fake.isObserving)
    }
}
