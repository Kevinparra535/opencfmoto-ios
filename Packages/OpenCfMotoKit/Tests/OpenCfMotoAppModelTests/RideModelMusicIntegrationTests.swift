// SPDX-License-Identifier: AGPL-3.0-or-later
// Apple Music on the dash, end to end through the model layer (contract §8.8-5, the integration of
// the Core dash UI with the AppModel side): taps on the hit regions the scene really draws, the
// handlebar path (knob, Enter, Back) and the menu path reach the fake Music app, and the dash model
// follows what the Music app does — including what iOS reports as other audio around a pause (the
// F1 grace) and what a shared log or problem report says about the songs (F4).
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

    /// `harness` with the iOS model of `isOtherAudioPlaying` (F1): the Music app's own audio counts
    /// while it plays and `lag` seconds after a pause. The grace waits end when the test says so,
    /// and the test reads the player itself (no command re-reads at wall-clock times).
    @MainActor
    private func iosHarness(playing: Bool = true, lag: TimeInterval = 0.5) async
        -> (AppTestHarness, PreviewMusic, MusicTestClock, ManualSleeper) {
        let clock = MusicTestClock()
        let fake = PreviewMusic(clock: clock, queue: MusicFixtures.queue, playing: playing, position: 133,
                                authorization: .authorized)
        fake.otherAudioLag = lag
        fake.artworks["p1a"] = MusicFixtures.art(1)
        let h = AppTestHarness { services in
            services.clock = clock
            services.music = fake
            services.keyValueStore.set(true, forKey: MusicModel.enabledKey)
        }
        let grace = ManualSleeper()
        h.model.music.graceSleeper = { await grace.sleep($0) }
        h.model.music.artworkAttemptDelays = [0]
        h.model.music.imageCleanupDelay = 0
        h.model.music.refreshDelaysAfterCommand = []
        h.ride.startLocationPreview()
        let shown = await eventually { h.ride.lastModel?.music?.artworkId == "music.art.p1a" }
        XCTAssertTrue(shown, "the song (with its artwork) is on the dash")
        return (h, fake, clock, grace)
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

    // MARK: Other audio around a pause (F1, iOS model)

    @MainActor
    func testPausingFromTheOpenSheetKeepsItOpenWhileIOSStillCountsTheMusicApp() async {
        let (h, fake, clock, grace) = await iosHarness()
        XCTAssertTrue(h.model.music.snapshot.otherAudioPlaying, "iOS: the playing Music app is other audio for us")
        tap(h, clock, "music.tile")
        XCTAssertEqual(h.ride.dashUIState.sheet, .music)
        tap(h, clock, "music.playPause")
        XCTAssertEqual(fake.commands, ["pause"])
        XCTAssertEqual(h.model.music.snapshot.state, .paused)
        XCTAssertTrue(h.model.music.snapshot.otherAudioPlaying, "the reading right after the pause still counts it")
        let paused = await eventually { h.ride.lastModel?.music?.state == .paused }
        XCTAssertTrue(paused, "the song stays on the dash, paused")
        XCTAssertEqual(h.ride.dashUIState.sheet, .music, "the Music sheet stays open")
        XCTAssertEqual(h.ride.dashUIState.focusedId, "music.playPause", "the knob stays on ⏯")
        XCTAssertTrue(has(h, "music.playPause"))
        let waiting = await eventually { grace.pendingCount == 1 }
        XCTAssertTrue(waiting, "one re-evaluation waits for the end of the grace")
        fake.refresh() // the adapter's settle read: the fade is over (0.5 s; the tap took 0.55 s)
        XCTAssertFalse(h.model.music.snapshot.otherAudioPlaying)
        let cancelled = await eventually { grace.pendingCount == 0 }
        XCTAssertTrue(cancelled)
        clock.advance(4) // past the grace (and well inside the sheet's 10 s idle close)
        _ = list(h)
        XCTAssertEqual(h.ride.lastModel?.music?.state, .paused)
        XCTAssertEqual(h.ride.dashUIState.sheet, .music)
        tap(h, clock, "music.playPause") // the rider resumes from where they are
        XCTAssertEqual(fake.commands, ["pause", "play"])
        let playing = await eventually { h.ride.lastModel?.music?.state == .playing }
        XCTAssertTrue(playing)
        XCTAssertEqual(grace.requests, [3])
    }

    @MainActor
    func testOtherAudioThatOutlastsTheGraceHidesTheSongAndClosesTheSheet() async {
        let (h, fake, clock, grace) = await iosHarness()
        tap(h, clock, "music.tile")
        tap(h, clock, "music.playPause")
        fake.simulate(otherAudioPlaying: true) // the rider started Spotify right after
        let paused = await eventually { h.ride.lastModel?.music?.state == .paused }
        XCTAssertTrue(paused)
        XCTAssertEqual(h.ride.dashUIState.sheet, .music, "inside the grace: still open")
        let waiting = await eventually { grace.pendingCount == 1 }
        XCTAssertTrue(waiting)
        let refreshes = fake.refreshes
        clock.advance(3)
        grace.endWaits()
        let reread = await eventually { fake.refreshes == refreshes + 1 }
        XCTAssertTrue(reread, "the player is read again at the end of the grace")
        let hidden = await eventually { h.ride.lastModel?.music == nil }
        XCTAssertTrue(hidden, "Spotify played through the grace: the paused song is stale (D7)")
        _ = list(h)
        XCTAssertEqual(h.ride.dashUIState.sheet, .none, "the Music sheet closes with the song")
        XCTAssertFalse(has(h, "music.tile"))
        fake.simulate(otherAudioPlaying: false) // Spotify stopped
        let back = await eventually { h.ride.lastModel?.music?.state == .paused }
        XCTAssertTrue(back)
        XCTAssertTrue(has(h, "music.tile"))
    }

    @MainActor
    func testAShortBlipWhilePausedNeverHidesTheSongOrClosesTheSheet() async {
        let (h, fake, clock, grace) = await iosHarness(playing: false)
        XCTAssertFalse(h.model.music.snapshot.otherAudioPlaying, "paused since before: no fade")
        tap(h, clock, "music.tile")
        XCTAssertEqual(h.ride.dashUIState.sheet, .music)
        fake.simulate(otherAudioPlaying: true) // another app's short sound
        let waiting = await eventually { grace.pendingCount == 1 }
        XCTAssertTrue(waiting)
        _ = list(h)
        XCTAssertEqual(h.ride.lastModel?.music?.state, .paused)
        XCTAssertEqual(h.ride.dashUIState.sheet, .music)
        clock.advance(1)
        fake.simulate(otherAudioPlaying: false)
        let cancelled = await eventually { grace.pendingCount == 0 }
        XCTAssertTrue(cancelled)
        clock.advance(3) // 4 s after the blip started
        _ = list(h)
        XCTAssertEqual(h.ride.lastModel?.music?.state, .paused)
        XCTAssertEqual(h.ride.dashUIState.sheet, .music, "never closed")
        XCTAssertEqual(h.ride.dashUIState.focusedId, "music.playPause")
    }

    @MainActor
    func testSpotifyAtDashStartHidesAPausedSongAtOnce() async {
        let clock = MusicTestClock()
        let fake = PreviewMusic(clock: clock, queue: MusicFixtures.queue, playing: false, position: 133,
                                authorization: .authorized)
        fake.otherAudioLag = 0.5
        fake.artworks["p1a"] = MusicFixtures.art(1)
        fake.simulate(otherAudioPlaying: true) // Spotify plays before the dash goes live
        let h = AppTestHarness { services in
            services.clock = clock
            services.music = fake
            services.keyValueStore.set(true, forKey: MusicModel.enabledKey)
        }
        let grace = ManualSleeper()
        h.model.music.graceSleeper = { await grace.sleep($0) }
        h.model.music.artworkAttemptDelays = [0]
        h.model.music.imageCleanupDelay = 0
        h.ride.startLocationPreview()
        let observing = await eventually { h.model.music.snapshot.track != nil }
        XCTAssertTrue(observing)
        XCTAssertTrue(h.model.music.snapshot.otherAudioPlaying)
        _ = list(h)
        XCTAssertNil(h.ride.lastModel?.music, "no stale paused tile, not even for the grace")
        XCTAssertFalse(has(h, "music.tile"))
        XCTAssertEqual(grace.requests, [], "nothing to wait for")
        fake.simulate(otherAudioPlaying: false) // Spotify stopped
        let shown = await eventually { h.ride.lastModel?.music?.state == .paused }
        XCTAssertTrue(shown)
        XCTAssertTrue(has(h, "music.tile"))
    }

    // MARK: Privacy (F4)

    @MainActor
    func testTheSharedLogAndTheProblemReportNameNoSong() async throws {
        let (h, fake, _) = await harness()
        fake.skipToNext() // "s100000002": the catalog song (its id names it on music.apple.com)
        let next = await eventually { h.ride.lastModel?.music?.artworkId == "music.art.s100000002" }
        XCTAssertTrue(next)
        let report = try h.model.logs.problemReport(problem: "the dash froze", bikeModel: "450MT", bikeYear: "2025")
        let exported = try h.model.logs.exportLogs()
        let reportText = try String(contentsOf: report.url, encoding: .utf8)
        XCTAssertTrue(reportText.contains("music=on/authorized/playing/art="), "the diagnostics line")
        for file in [report.url, exported.url] {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertTrue(text.contains("state playing track=\(MusicTrackID.logToken("s100000002")) other=0"),
                          "\(file.lastPathComponent): the token tells the songs apart")
            for word in MusicFixtures.privateWords + ["s100000002", "music.art."] {
                XCTAssertFalse(text.contains(word), "\(file.lastPathComponent) names \"\(word)\"")
            }
        }
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
