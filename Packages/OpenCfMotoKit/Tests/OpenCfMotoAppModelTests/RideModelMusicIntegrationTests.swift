// SPDX-License-Identifier: AGPL-3.0-or-later
// Apple Music on the dash, end to end through the model layer (contract §8.8-5, the integration of
// the Core dash UI with the AppModel side): taps on the hit regions the scene really draws, the
// handlebar path (knob, Enter, Back) and the menu path reach the fake Music app, and the dash model
// follows what the Music app does — including what iOS reports as other audio around a pause (the
// F1 grace) and what a shared log or problem report says about the songs (F4). The last sections
// ride the review repros end to end while navigating: no stale or vanished Music control ever hands
// the rider's ★ to End (F1 + F2 together, through the real focus engine), the focus returns to the
// tile with the song, so the tile's ★★ stays the tile's (R2-DASH-1), one reading without a song never
// reaches the dash and hands nothing over (R3-FOCUS-1, MusicModel), an open Music sheet outlasts a
// longer vanish, so its ▶ ★ stays the sheet's (R3-FOCUS-1, the dash), and a quick ▶▶ (HOME) from the
// sheet opens the menu on "Music", never on End (R3-FOCUS-3).
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
    /// `quietRideLoop`: the ride loop's UI tick waits a minute, so its slow tick (every 10th tick
    /// rebuilds the dash model) never runs during the test — only model changes redraw the dash.
    @MainActor
    private func iosHarness(playing: Bool = true, lag: TimeInterval = 0.5, quietRideLoop: Bool = false) async
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
        if quietRideLoop { h.ride.tuning.uiTickInterval = 60 }
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
        // The render loop's frame at the new time before the song goes: the dash's 2-s sheet hold counts
        // from the last time it saw (without it, a 3-s jump of this clock would make the hold look over).
        _ = h.ride.displayList(now: clock.now())
        grace.endWaits()
        let reread = await eventually { fake.refreshes == refreshes + 1 }
        XCTAssertTrue(reread, "the player is read again at the end of the grace")
        let hidden = await eventually { h.ride.lastModel?.music == nil }
        XCTAssertTrue(hidden, "Spotify played through the grace: the paused song is stale (D7)")
        _ = list(h)
        XCTAssertEqual(h.ride.dashUIState.sheet, .music, "R3-FOCUS-1: open through a short vanish")
        clock.advance(2)
        let closed = await eventually { h.ride.dashUIState.sheet == .none }
        XCTAssertTrue(closed, "the Music sheet closes once the song stayed gone for 2 s")
        XCTAssertFalse(has(h, "music.tile"))
        fake.simulate(otherAudioPlaying: false) // Spotify stopped
        let back = await eventually { h.ride.lastModel?.music?.state == .paused }
        XCTAssertTrue(back)
        XCTAssertTrue(has(h, "music.tile"))
    }

    /// F1's one re-evaluation at the end of the grace must redraw the dash by itself: parked (a fix,
    /// standing still, not navigating), the Music sheet closed, the paused tile on the map, and a
    /// podcast in another app that simply goes on, so the port reports nothing new. The ride loop's
    /// slow tick rebuilds the dash model too (every 10th UI tick: 1 s on the phone, 5 s in the
    /// pocket, 0.2 s in these tests, with the sheet open or closed), which hides a grace end that
    /// forgets `onDashChange` from every other test here; it is held off, so the stale tile would
    /// stay. Nothing pulls a frame before the checks: the model and the frame are what the app has.
    @MainActor
    func testParkedWithTheSheetClosedTheGraceEndItselfDropsTheStaleTile() async {
        let (h, fake, clock, grace) = await iosHarness(quietRideLoop: true)
        defer { h.ride.stopLocationPreview() } // ends the held-off tick's wait
        h.location.emit(LocationFix(lat: 4.65, lon: -74.05, speedMps: 0, courseDeg: 0, accuracyM: 5,
                                    timeMs: Int64(Date().timeIntervalSince1970 * 1000)))
        let parked = await eventually { h.ride.lastModel?.fix?.isMoving == false }
        XCTAssertTrue(parked, "parked: a fix, standing still")
        XCTAssertFalse(h.core.navigation.snapshot.mode.isNavigating)
        XCTAssertEqual(h.ride.dashUIState.sheet, .none, "the Music sheet is closed: the tile is on the map")
        clock.advance(1)
        fake.simulate(playing: false) // paused on the phone while iOS still counts the fade
        let paused = await eventually { h.ride.lastModel?.music?.state == .paused }
        XCTAssertTrue(paused, "the paused song stays on the dash")
        clock.advance(0.6)
        fake.refresh() // the adapter's settle read: the fade is over
        XCTAssertFalse(h.model.music.snapshot.otherAudioPlaying)
        let idle = await eventually { grace.pendingCount == 0 }
        XCTAssertTrue(idle, "a paused song and no other audio: nothing to wait for")
        clock.advance(1)
        fake.simulate(otherAudioPlaying: true) // the rider starts a podcast in another app
        let waiting = await eventually { grace.requests.count == 2 && grace.pendingCount == 1 }
        XCTAssertTrue(waiting, "one re-evaluation waits for the end of the grace")
        await settle(0.1) // the model update that reading asked for
        XCTAssertEqual(h.ride.lastModel?.music?.state, .paused, "inside the grace: still on the dash")
        let refreshes = fake.refreshes
        let invalidations = h.projection.invalidations
        clock.advance(3)
        await settle(0.1)
        XCTAssertEqual(h.ride.lastModel?.music?.state, .paused, "nothing else rebuilds the dash model here")
        grace.endWaits()
        let hidden = await eventually { h.ride.lastModel?.music == nil }
        XCTAssertTrue(hidden, "the grace end drops the stale paused song (D7) at once")
        XCTAssertEqual(fake.refreshes, refreshes + 1, "the player is read again at the end of the grace")
        XCTAssertGreaterThan(h.projection.invalidations, invalidations, "the dash frame is redrawn")
        XCTAssertFalse(h.ride.displayList(now: clock.now()).hitRegions.contains { $0.id == "music.tile" },
                       "the dash draws no tile")
        XCTAssertEqual(grace.requests, [3, 3], "one wait after the pause, one after the podcast started")
        fake.simulate(otherAudioPlaying: false) // the podcast stopped
        let back = await eventually { h.ride.lastModel?.music?.state == .paused }
        XCTAssertTrue(back, "the paused song comes back")
        XCTAssertTrue(h.ride.displayList(now: clock.now()).hitRegions.contains { $0.id == "music.tile" })
    }

    /// R3-FOCUS-1: the one re-evaluation at the end of MusicModel's 2-s hold must redraw the dash by itself,
    /// like F1's grace end above: parked, the sheet closed, the tile on the map, and the Music app's queue
    /// ends — no song, and no reading comes after that one, so the port reports nothing new. With the ride
    /// loop's slow tick held off, a hold end that forgets `onDashChange` would leave the tile up for good.
    @MainActor
    func testParkedAPlayerLeftEmptyLosesTheTileAtTheEndOfTheHoldByItself() async {
        let (h, fake, clock, grace) = await iosHarness(quietRideLoop: true)
        defer { h.ride.stopLocationPreview() } // ends the held-off tick's wait
        h.location.emit(LocationFix(lat: 4.65, lon: -74.05, speedMps: 0, courseDeg: 0, accuracyM: 5,
                                    timeMs: Int64(Date().timeIntervalSince1970 * 1000)))
        let parked = await eventually { h.ride.lastModel?.fix?.isMoving == false }
        XCTAssertTrue(parked, "parked: a fix, standing still")
        XCTAssertEqual(h.ride.dashUIState.sheet, .none, "the Music sheet is closed: the tile is on the map")
        clock.advance(1)
        fake.queue = [] // the queue ended: no song
        fake.refresh()
        XCTAssertNil(h.model.music.snapshot.track)
        let waiting = await eventually { grace.pendingCount == 1 }
        XCTAssertTrue(waiting, "one re-evaluation waits for the end of the hold")
        await settle(0.1) // the model update that reading asked for
        XCTAssertNotNil(h.ride.lastModel?.music, "inside the hold: still on the dash")
        let refreshes = fake.refreshes
        let invalidations = h.projection.invalidations
        clock.advance(2)
        await settle(0.1)
        XCTAssertNotNil(h.ride.lastModel?.music, "nothing else rebuilds the dash model here")
        grace.endWaits()
        let hidden = await eventually { h.ride.lastModel?.music == nil }
        XCTAssertTrue(hidden, "the end of the hold takes the song off the dash at once")
        XCTAssertEqual(fake.refreshes, refreshes + 1, "the player is read again at the end of the hold")
        XCTAssertGreaterThan(h.projection.invalidations, invalidations, "the dash frame is redrawn")
        XCTAssertFalse(h.ride.displayList(now: clock.now()).hitRegions.contains { $0.id == "music.tile" },
                       "the dash draws no tile")
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
        XCTAssertEqual(order.firstIndex(of: "menu.music"), order.firstIndex(of: "menu.recalc").map { $0 + 1 },
                       "Music comes right after Recenter / reroute, the menu's default item (P0, D01)")
        // 800×384: the menu's second item, in view without a drag (it was below the fold, after Circuit)
        XCTAssertTrue(has(h, "menu.music"))
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
        clock.advance(2) // R3-FOCUS-1: the open sheet outlasts a vanish of up to 2 s
        let closed = await eventually { h.ride.dashUIState.sheet == .none }
        XCTAssertTrue(closed, "the Music sheet closes with the music")
        XCTAssertFalse(has(h, "music.tile"))
        tap(h, clock, "fab.menu")
        XCTAssertFalse(has(h, "menu.music"))
        XCTAssertFalse(fake.isObserving)
    }
}

// MARK: - Review round 1 end to end: navigating, the rider's ★ never lands on End (F1 + F2)

// The reviewers' repros (DASH-1, DASH-5, IOS-MUSIC-1) through RideModel → MusicModel → PreviewMusic
// with the iOS model of other audio and the real dash focus engine. On a71c8d5 each of them ended
// with the focus on End: while navigating that is the first item of the map list, and ★ on it ends
// navigation without a confirmation. F1 keeps a song that just paused on the dash through iOS's
// stale "other audio" reading; F2 catches what no grace covers (no item between songs). Every test
// pulls a frame after each model change, as the app's render loop does (flushModel → invalidate).
extension RideModelMusicIntegrationTests {
    /// The app guiding to "Dest" (a moving fix, the route started) with the fake Music app playing
    /// "p1a" (`playing: false`: paused on it), `isOtherAudioPlaying` as iOS reports it (the Music app's
    /// own audio counts while it plays and `lag` s after a pause), the grace ended by hand and no command
    /// re-reads at wall-clock times (the test takes the adapter's settle read itself). `capture`: the
    /// phone media remote drives the dash (input-controls opt-in, claimed by the rider).
    @MainActor
    private func navigatingHarness(capture: Bool = false, lag: TimeInterval = 0.5, playing: Bool = true) async
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
            if capture { services.keyValueStore.set(true, forKey: ControlsModel.remoteOptInKey) }
        }
        let grace = ManualSleeper()
        h.model.music.graceSleeper = { await grace.sleep($0) }
        h.model.music.artworkAttemptDelays = [0]
        h.model.music.imageCleanupDelay = 0
        h.model.music.refreshDelaysAfterCommand = []
        if capture {
            h.controls.musicReclaimDelays = [0.05, 0.15]
            h.controls.setRemoteEnabled(true)
            XCTAssertTrue(h.handlebar.isEnabled, "the phone media remote holds the buttons")
        }
        h.ride.startLocationPreview()
        h.location.emit(LocationFix(lat: 4.65, lon: -74.05, speedMps: 12, courseDeg: 0, accuracyM: 5,
                                    timeMs: Int64(Date().timeIntervalSince1970 * 1000)))
        h.core.navigation.navigate(to: Place(name: "Dest", lat: 4.70, lon: -74.04))
        let navigating = await eventually {
            h.core.navigation.snapshot.mode.isNavigating && h.ride.lastModel?.nav.mode.isNavigating == true
        }
        XCTAssertTrue(navigating, "guiding to Dest")
        let shown = await eventually { h.ride.lastModel?.music?.artworkId == "music.art.p1a" }
        XCTAssertTrue(shown, "the song (with its artwork) is on the dash")
        XCTAssertEqual(h.model.music.snapshot.otherAudioPlaying, playing, "iOS: the playing Music app is other audio for us")
        _ = list(h)
        // P0 (D01): Recenter is the default focus while navigating and End left the map (it is in the menu,
        // behind a confirm card); what was at stake below — a ★ ending navigation — stays pinned anyway.
        XCTAssertEqual(h.ride.dashUIState.focusedId, DashFocusEngine.recenterId,
                       "navigating: Recenter is the default focus")
        return (h, fake, clock, grace)
    }

    @MainActor
    private func texts(_ list: DashDisplayList) -> [String] {
        list.commands.compactMap { if case let .text(s, _, _) = $0 { return s }; return nil }
    }

    /// DASH-1 + IOS-MUSIC-1, handlebar: the knob on the tile and the Music app pauses (on the phone, the
    /// lock screen, AirPods) while iOS still counts its fading audio. The song stays on the dash paused
    /// and the focus stays on the tile, so the rider's ★ opens the Music sheet. On a71c8d5 that one
    /// reading hid the song, the frame moved the focus to End and the same ★ ended navigation.
    @MainActor
    func testNavigatingAPauseWhileIOSStillCountsTheMusicAppKeepsTheKnobOnTheTile() async {
        let (h, fake, clock, grace) = await navigatingHarness()
        h.ride.handleDashInput(.knob(-1)) // ◀ from Recenter wraps to the tile (the last of the map list)
        XCTAssertEqual(h.ride.dashUIState.focusedId, DashFocusEngine.musicTileId)
        clock.advance(1)
        fake.simulate(playing: false)
        XCTAssertEqual(h.model.music.snapshot.state, .paused)
        XCTAssertTrue(h.model.music.snapshot.otherAudioPlaying, "the reading right after the pause still counts it")
        _ = list(h)
        XCTAssertEqual(h.ride.lastModel?.music?.state, .paused, "the paused song stays on the dash")
        XCTAssertTrue(has(h, DashFocusEngine.musicTileId))
        XCTAssertEqual(h.ride.dashUIState.focusedId, DashFocusEngine.musicTileId, "the knob stays on the tile")
        let waiting = await eventually { grace.pendingCount == 1 }
        XCTAssertTrue(waiting, "one re-evaluation waits for the end of the grace")
        clock.advance(0.6)
        fake.refresh() // the adapter's settle read: the fade is over
        XCTAssertFalse(h.model.music.snapshot.otherAudioPlaying)
        let cancelled = await eventually { grace.pendingCount == 0 }
        XCTAssertTrue(cancelled)
        _ = list(h)
        XCTAssertEqual(h.ride.dashUIState.focusedId, DashFocusEngine.musicTileId)
        clock.advance(0.5)
        h.ride.handleDashInput(.key(.enter)) // the rider's ★, meant for the tile
        XCTAssertEqual(h.ride.dashUIState.sheet, .music, "★ on the tile opens the Music sheet")
        XCTAssertEqual(h.ride.dashUIState.focusedId, DashFocusEngine.musicPlayPauseId)
        await settle(0.1)
        XCTAssertTrue(h.core.navigation.snapshot.mode.isNavigating, "★ never ended navigation")
        clock.advance(1)
        h.ride.handleDashInput(.key(.enter)) // ★ on ⏯ resumes
        XCTAssertEqual(fake.commands, ["play"])
        let playing = await eventually { h.ride.lastModel?.music?.state == .playing }
        XCTAssertTrue(playing)
        XCTAssertEqual(h.ride.dashUIState.sheet, .music)
        XCTAssertTrue(h.core.navigation.snapshot.mode.isNavigating)
    }

    /// R3-FOCUS-1 (the root cause), handlebar: the player holds no item for ONE reading between two songs
    /// while the knob is on the tile, on ⏯ of the open sheet or on the menu's "Music". MusicModel keeps
    /// presenting the last song for up to 2 s: no dash model ever lacks it, so nothing on the dash moves —
    /// the tile, the sheet, the menu's "Music" and the knob stay put, through every frame of the gap — and
    /// the rider's next press means what it meant. On bfa6c93 the gap reached the dash: the Music control
    /// vanished under the knob, and from the sheet the knob came back to the tile, next to End.
    @MainActor
    func testNavigatingOneReadingWithoutASongNeverReachesTheDash() async {
        for start in ["tile", "sheet ⏯", "menu Music"] {
            let (h, fake, clock, grace) = await navigatingHarness()
            switch start {
            case "tile":
                h.ride.handleDashInput(.knob(-1)) // ◀ from Recenter wraps to the tile
            case "sheet ⏯":
                h.ride.handleDashInput(.knob(-1))
                clock.advance(0.5)
                h.ride.handleDashInput(.key(.enter))
            default:
                h.ride.handleDashInput(.key(.home))
                let order = h.ride.dashUIState.focusOrder
                guard let from = order.firstIndex(of: h.ride.dashUIState.focusedId ?? ""),
                      let to = order.firstIndex(of: "menu.music") else { return XCTFail("no menu.music in \(order)") }
                clock.advance(0.3)
                h.ride.handleDashInput(.knob(to - from))
            }
            _ = list(h)
            let focus = h.ride.dashUIState.focusedId, sheet = h.ride.dashUIState.sheet
            XCTAssertEqual(focus, ["tile": DashFocusEngine.musicTileId, "sheet ⏯": DashFocusEngine.musicPlayPauseId,
                                   "menu Music": "menu.music"][start], start)
            clock.advance(1)
            let queue = fake.queue
            fake.queue = [] // the Music app between two songs
            fake.refresh()
            XCTAssertNil(h.model.music.snapshot.track, "\(start): the reading has no song")
            for _ in 0 ..< 3 { // the frames the render loop pulls meanwhile
                _ = list(h)
                XCTAssertEqual(h.ride.lastModel?.music?.title, MusicFixtures.ruta.title, "\(start): the dash keeps the song")
                XCTAssertEqual(h.ride.dashUIState.focusedId, focus, start)
                XCTAssertEqual(h.ride.dashUIState.sheet, sheet, start)
                XCTAssertTrue(has(h, focus ?? ""), "\(start): the focused control is drawn")
                clock.advance(0.2)
            }
            let waiting = await eventually { grace.pendingCount == 1 }
            XCTAssertTrue(waiting, "\(start): one re-evaluation waits for the end of the hold")
            fake.queue = queue
            fake.simulate(index: 1) // the adapter's settle read: the next song
            let next = await eventually { h.ride.lastModel?.music?.title == MusicFixtures.pass.title }
            XCTAssertTrue(next, start)
            let cancelled = await eventually { grace.pendingCount == 0 }
            XCTAssertTrue(cancelled, "\(start): a song again, nothing to re-evaluate")
            _ = list(h)
            XCTAssertEqual(h.ride.dashUIState.focusedId, focus, start)
            XCTAssertEqual(h.ride.dashUIState.sheet, sheet, start)
            clock.advance(0.5)
            if start == "sheet ⏯" {
                h.ride.handleDashInput(.knob(1)) // the rider's ▶ ★, meant for ⏭
                clock.advance(0.4)
                h.ride.handleDashInput(.key(.enter))
                XCTAssertEqual(fake.commands, ["next"], "\(start): ▶ ★ is ⏭")
            } else {
                h.ride.handleDashInput(.key(.enter)) // ★, meant for the tile / "Music"
                XCTAssertEqual(h.ride.dashUIState.sheet, .music, "\(start): ★ opens the Music sheet")
            }
            await settle(0.1)
            XCTAssertTrue(h.core.navigation.snapshot.mode.isNavigating, "\(start): navigation goes on")
        }
    }

    /// DASH-1 (F2) + R2-DASH-1 + R3-FOCUS-1, handlebar: the player holds no item for longer than
    /// MusicModel's 2-s hold while the knob is on the tile, or on ⏯ of the open sheet. At the hold's end the
    /// dash model loses the song. The tile goes away under the focus: it moves to the Recenter button (★
    /// there only recenters), never to End, and comes back to the tile with the song, so the rider's ★★
    /// opens the sheet and plays / pauses. The open sheet outlasts the vanish (the dash's own 2 s): with the
    /// song back it is still open on ⏯, and ▶ ★ is ⏭. On a71c8d5 the tile's focus landed on End and ★ ended
    /// navigation; on 1af3c44 it stayed on the Menu button, and ★★ opened the menu on End, then ended
    /// navigation; on bfa6c93 the sheet closed, and ▶ ★ from the tile wrapped to End.
    @MainActor
    func testNavigatingASongGoneLongerThanTheHoldNeverHandsTheRidersStarToEnd() async {
        for sheetOpen in [false, true] {
            let name = sheetOpen ? "sheet ⏯" : "tile"
            let (h, fake, clock, grace) = await navigatingHarness()
            h.ride.handleDashInput(.knob(-1))
            XCTAssertEqual(h.ride.dashUIState.focusedId, DashFocusEngine.musicTileId, name)
            if sheetOpen {
                clock.advance(0.5)
                h.ride.handleDashInput(.key(.enter))
                XCTAssertEqual(h.ride.dashUIState.sheet, .music, name)
                XCTAssertEqual(h.ride.dashUIState.focusedId, DashFocusEngine.musicPlayPauseId, name)
            }
            clock.advance(1)
            let queue = fake.queue
            fake.queue = [] // no item…
            fake.refresh()
            XCTAssertNil(h.model.music.snapshot.track, name)
            _ = list(h)
            XCTAssertNotNil(h.ride.lastModel?.music, "\(name): held for 2 s")
            clock.advance(2) // …for longer than the hold
            _ = h.ride.displayList(now: clock.now()) // the render loop's frame: the dash's time is now
            let gone = await eventually {
                grace.endWaits()
                return h.ride.lastModel?.music == nil
            }
            XCTAssertTrue(gone, "\(name): the hold's end takes the song off the dash")
            _ = list(h)
            if sheetOpen {
                XCTAssertEqual(h.ride.dashUIState.sheet, .music, "\(name): the sheet outlasts a short vanish")
                XCTAssertEqual(h.ride.dashUIState.focusedId, DashFocusEngine.musicPlayPauseId, "\(name): on ⏯")
            } else {
                XCTAssertFalse(has(h, DashFocusEngine.musicTileId), name)
                XCTAssertEqual(h.ride.dashUIState.focusedId, "fab.recenter", "\(name): a harmless neighbour, never End")
            }
            clock.advance(0.3)
            fake.queue = queue
            fake.refresh() // the next reading has the song again
            let back = await eventually { h.ride.lastModel?.music != nil }
            XCTAssertTrue(back, name)
            _ = list(h)
            if sheetOpen {
                XCTAssertEqual(h.ride.dashUIState.sheet, .music, name)
                XCTAssertEqual(h.ride.dashUIState.focusedId, DashFocusEngine.musicPlayPauseId, name)
                clock.advance(1)
                h.ride.handleDashInput(.knob(1)) // the rider's ▶ ★, meant for ⏭
                clock.advance(0.4)
                h.ride.handleDashInput(.key(.enter))
                XCTAssertEqual(fake.commands, ["next"], "\(name): ▶ ★ is ⏭, never End")
                await settle(0.1)
                XCTAssertTrue(h.core.navigation.snapshot.mode.isNavigating, name)
                continue
            }
            XCTAssertTrue(has(h, DashFocusEngine.musicTileId), name)
            XCTAssertEqual(h.ride.dashUIState.focusedId, DashFocusEngine.musicTileId, "\(name): back on the tile with the song")
            XCTAssertEqual(h.ride.dashUIState.sheet, .none, "\(name): a closed sheet stays closed")
            clock.advance(1)
            h.ride.handleDashInput(.key(.enter)) // the rider's ★★, meant for the tile / ⏯
            XCTAssertEqual(h.ride.dashUIState.sheet, .music, "\(name): ★ opens the Music sheet")
            XCTAssertEqual(h.ride.dashUIState.focusedId, DashFocusEngine.musicPlayPauseId, name)
            clock.advance(0.8)
            h.ride.handleDashInput(.key(.enter))
            XCTAssertEqual(fake.commands, ["pause"], "\(name): the second ★ is ⏯ (the song was playing)")
            await settle(0.1)
            XCTAssertTrue(h.core.navigation.snapshot.mode.isNavigating, "\(name): ★★ never ended navigation")
        }
    }

    /// IOS-MUSIC-1 + DASH-5 (F1), touch dash while navigating: ⏯ tapped on the open sheet and the
    /// first reading still counts the Music app's audio. The sheet stays open on the same song, paused
    /// (its time stands still: 2:13), and the next tap resumes it. On a71c8d5 the sheet closed at once
    /// and stayed closed when the song came back.
    @MainActor
    func testNavigatingTouchPauseOnTheOpenSheetKeepsItOnThePausedSong() async {
        let (h, fake, clock, grace) = await navigatingHarness()
        tap(h, clock, DashFocusEngine.musicTileId)
        XCTAssertEqual(h.ride.dashUIState.sheet, .music)
        XCTAssertTrue(texts(list(h)).contains("2:13"), "playing at 2:13")
        tap(h, clock, DashFocusEngine.musicPlayPauseId)
        XCTAssertEqual(fake.commands, ["pause"])
        XCTAssertEqual(h.model.music.snapshot.state, .paused)
        XCTAssertTrue(h.model.music.snapshot.otherAudioPlaying, "the reading right after the pause still counts it")
        let paused = list(h)
        XCTAssertEqual(h.ride.dashUIState.sheet, .music, "the Music sheet stays open")
        XCTAssertEqual(h.ride.lastModel?.music?.state, .paused)
        XCTAssertEqual(h.ride.lastModel?.music?.title, MusicFixtures.ruta.title, "on the same song")
        XCTAssertTrue(paused.hitRegions.contains { $0.id == DashFocusEngine.musicPlayPauseId })
        XCTAssertTrue(texts(paused).contains { $0.contains("Ruta del Sol") }, "the sheet shows the song")
        XCTAssertTrue(texts(paused).contains("2:13"))
        let waiting = await eventually { grace.pendingCount == 1 }
        XCTAssertTrue(waiting)
        clock.advance(0.6)
        fake.refresh() // the adapter's settle read: the fade is over
        clock.advance(2.4)
        let later = list(h)
        XCTAssertEqual(h.ride.dashUIState.sheet, .music)
        XCTAssertEqual(h.ride.lastModel?.music?.state, .paused)
        XCTAssertTrue(texts(later).contains("2:13"), "3 s later: a paused song's time stands still")
        tap(h, clock, DashFocusEngine.musicPlayPauseId) // the rider resumes from where they are
        XCTAssertEqual(fake.commands, ["pause", "play"])
        let playing = await eventually { h.ride.lastModel?.music?.state == .playing }
        XCTAssertTrue(playing)
        XCTAssertEqual(h.ride.dashUIState.sheet, .music)
        XCTAssertTrue(h.core.navigation.snapshot.mode.isNavigating)
    }

    /// DASH-1, the reviewer's end-to-end repro (Skeptic2MusicExperiments.testS2_captureOnPauseThenStar)
    /// in the documented capture-on flow: the phone media remote drives the dash, the knob is on the
    /// tile, and the rider pauses Apple Music with ★ on the bars (the Music app holds Now Playing while
    /// it plays, so that ★ goes to iOS, not to the dash) while iOS still counts its fading audio. R3
    /// claims the buttons back ("back on the dash"), and the rider's next ★ reaches the dash: it opens
    /// the Music sheet. On a71c8d5 the stale reading had moved the focus to End: that ★ ended navigation.
    @MainActor
    func testCaptureOnPausingAppleMusicFromTheBarsThenStarKeepsNavigating() async {
        let (h, fake, clock, _) = await navigatingHarness(capture: true)
        h.ride.handleDashInput(.knob(-1))
        XCTAssertEqual(h.ride.dashUIState.focusedId, DashFocusEngine.musicTileId)
        clock.advance(1)
        fake.simulate(playing: false) // iOS paused the Music app for the bars' ★
        XCTAssertTrue(h.model.music.snapshot.otherAudioPlaying, "its fading audio still counts")
        _ = list(h)
        XCTAssertEqual(h.ride.lastModel?.music?.state, .paused)
        XCTAssertEqual(h.ride.dashUIState.focusedId, DashFocusEngine.musicTileId)
        let backOnTheDash = await eventually { h.ride.ui.state.toast == SessionText.handlebarBackToDash(h.language) }
        XCTAssertTrue(backOnTheDash, "R3: the buttons are claimed back and the dash says so")
        XCTAssertEqual(h.handlebar.reclaimRequests, 1)
        clock.advance(0.6)
        fake.refresh() // the adapter's settle read: the fade is over
        _ = list(h)
        XCTAssertEqual(h.ride.lastModel?.music?.state, .paused)
        XCTAssertEqual(h.ride.dashUIState.focusedId, DashFocusEngine.musicTileId)
        h.ride.handleDashInput(.key(.enter)) // the rider's next ★ (ControlsModel delivers it here)
        XCTAssertEqual(h.ride.dashUIState.sheet, .music, "★ on the tile opens the Music sheet")
        await settle(0.1)
        XCTAssertTrue(h.core.navigation.snapshot.mode.isNavigating, "★ never ended navigation")
        XCTAssertEqual(fake.commands, [], "the dash sent nothing to the Music app")
    }
}

// MARK: - Review round 2 end to end: a song gone while the bars drive the Music app (R2-DASH-1)

extension RideModelMusicIntegrationTests {
    /// R2-DASH-1 + R3-FOCUS-1, the documented capture-on flow (field guide item 6): the phone media remote
    /// drives the dash, the rider plays the paused song from the dash (◀ ★ ★), the Music app takes the bars
    /// and the sheet closes with the knob parked on the tile. Minutes later one reading has no item between
    /// two songs — the rider cannot see or move the dash focus then, the bars drive the Music app. The gap
    /// never reaches the dash (the tile and the knob stay) and hands nothing over: no pause (R3 would claim
    /// the buttons back from the Music app), no start when the next song plays (R2's toast). The rider
    /// pauses from the bars, R3 hands the buttons back to the dash, and the rider resumes the way the tile
    /// always works: ★ (open the sheet), ★ (⏯). On 1af3c44 the gap had left the focus on the Menu button: ★
    /// opened the menu on End and the second ★ ended navigation, with nothing sent to Music.
    @MainActor
    func testCaptureOnASongGapWhileTheBarsDriveMusicHandsNothingOverThenStarStarResumes() async {
        let (h, fake, clock, _) = await navigatingHarness(capture: true, playing: false)
        h.ride.handleDashInput(.knob(-1))
        clock.advance(0.5)
        h.ride.handleDashInput(.key(.enter))
        clock.advance(0.5)
        h.ride.handleDashInput(.key(.enter))
        XCTAssertEqual(fake.commands, ["play"], "◀ ★ ★ from the dash plays the song")
        let handed = await eventually { h.ride.dashUIState.sheet == .none }
        XCTAssertTrue(handed, "the Music app takes the bars: the sheet closes")
        _ = list(h)
        XCTAssertEqual(h.ride.dashUIState.focusedId, DashFocusEngine.musicTileId, "the knob parks on the tile")
        clock.advance(120)
        _ = list(h)
        let takes = SessionText.musicTakesHandlebar(h.language), back = SessionText.handlebarBackToDash(h.language)
        XCTAssertNotEqual(h.ride.ui.state.toast, takes, "R2's toast is long gone")
        let reclaims = h.handlebar.reclaimRequests
        let queue = fake.queue
        fake.queue = [] // one reading with no item between two songs
        fake.refresh()
        _ = list(h)
        XCTAssertTrue(has(h, DashFocusEngine.musicTileId), "the gap never reaches the dash")
        XCTAssertEqual(h.ride.dashUIState.focusedId, DashFocusEngine.musicTileId)
        clock.advance(0.3)
        fake.queue = queue
        fake.simulate(index: 1) // the next song
        let next = await eventually { h.ride.lastModel?.music?.title == MusicFixtures.pass.title }
        XCTAssertTrue(next)
        await settle(0.3) // a misfired R3 claims the buttons back 0.05 s / 0.15 s later
        _ = list(h)
        XCTAssertEqual(h.ride.dashUIState.focusedId, DashFocusEngine.musicTileId, "the knob never moved")
        XCTAssertEqual(h.handlebar.reclaimRequests, reclaims, "no pause: the bars stay with the Music app")
        XCTAssertNotEqual(h.ride.ui.state.toast, back)
        XCTAssertNotEqual(h.ride.ui.state.toast, takes, "no start either: R2's toast does not come back")
        clock.advance(30)
        fake.simulate(playing: false) // the rider pauses from the bars
        let backOnTheDash = await eventually { h.ride.ui.state.toast == back }
        XCTAssertTrue(backOnTheDash, "R3: the buttons are back on the dash")
        XCTAssertEqual(h.handlebar.reclaimRequests, reclaims + 1)
        clock.advance(0.6)
        fake.refresh() // the adapter's settle read: the fade is over
        _ = list(h)
        XCTAssertEqual(h.ride.dashUIState.focusedId, DashFocusEngine.musicTileId)
        clock.advance(20)
        h.ride.handleDashInput(.key(.enter)) // ★: open the sheet
        XCTAssertEqual(h.ride.dashUIState.sheet, .music)
        XCTAssertEqual(h.ride.dashUIState.focusedId, DashFocusEngine.musicPlayPauseId)
        clock.advance(0.8)
        h.ride.handleDashInput(.key(.enter)) // ★: ⏯
        XCTAssertEqual(fake.commands, ["play", "play"], "★★ resumed the song")
        await settle(0.1)
        XCTAssertTrue(h.core.navigation.snapshot.mode.isNavigating, "navigation goes on")
    }
}

// MARK: - Review round 3 end to end: the open sheet outlasts a short vanish (R3-FOCUS-1)

extension RideModelMusicIntegrationTests {
    /// R3-FOCUS-1, handlebar while navigating: the sheet on ⏮; ★ at 2:13 restarts the song, ★ again within
    /// 3 s goes to the previous one, and the Music app holds no item on the way — for one reading, or for
    /// 2.5 s. The rider then presses ▶ ★, meant for ⏯ (pause). One reading never reaches the dash (MusicModel
    /// holds the song); a longer gap does, at the end of that 2-s hold, and the open sheet outlasts it (the
    /// dash's own 2 s). Either way the sheet is still open on ⏮, so ▶ is ⏯ and ★ pauses. On bfa6c93 the gap
    /// closed the sheet and the knob came back to the tile, the last item of the map list: ▶ wrapped to End
    /// and ★ ended navigation, with nothing more sent to the Music app.
    @MainActor
    func testNavigatingPreviousTwiceAcrossAnEmptyReadingThenRightStarPausesAndKeepsNavigating() async {
        for gap in [nil, 0, 2.5] as [TimeInterval?] {
            let name = gap.map { $0 == 0 ? "one reading with no item" : "no item for \($0) s" } ?? "no gap"
            let (h, fake, clock, grace) = await navigatingHarness()
            h.ride.handleDashInput(.knob(-1))
            clock.advance(0.4)
            h.ride.handleDashInput(.key(.enter))
            _ = list(h)
            XCTAssertEqual(h.ride.dashUIState.focusedId, DashFocusEngine.musicPlayPauseId, name)
            clock.advance(0.4)
            h.ride.handleDashInput(.knob(-1))
            _ = list(h)
            XCTAssertEqual(h.ride.dashUIState.focusedId, "music.previous", name)
            clock.advance(0.4)
            h.ride.handleDashInput(.key(.enter)) // ⏮ at 2:13: back to the beginning
            XCTAssertEqual(fake.commands, ["beginning"], name)
            _ = list(h)
            clock.advance(1)
            let queue = fake.queue
            if gap != nil { fake.queue = [] } // the Music app is between two songs when the command lands
            h.ride.handleDashInput(.key(.enter)) // ⏮ within 3 s: the previous song
            XCTAssertEqual(fake.commands, ["beginning", "previous"], name)
            if let gap {
                fake.refresh() // the reading with no item
                _ = list(h)
                XCTAssertNotNil(h.ride.lastModel?.music, "\(name): MusicModel holds the song")
                if gap > 0 {
                    clock.advance(2)
                    _ = h.ride.displayList(now: clock.now()) // the render loop's frame: the dash's time is now
                    let gone = await eventually {
                        grace.endWaits()
                        return h.ride.lastModel?.music == nil
                    }
                    XCTAssertTrue(gone, "\(name): off the dash at the end of the hold")
                    _ = list(h)
                    clock.advance(gap - 2)
                }
                XCTAssertEqual(h.ride.dashUIState.sheet, .music, "\(name): the sheet stays open")
                XCTAssertEqual(h.ride.dashUIState.focusedId, "music.previous", "\(name): on the control the rider left")
                clock.advance(0.1)
                fake.queue = queue
                fake.simulate(index: 2) // the adapter's settle read: the previous song (the queue wraps)
                let back = await eventually { h.ride.lastModel?.music?.title == MusicFixtures.night.title }
                XCTAssertTrue(back, name)
            }
            _ = list(h)
            XCTAssertEqual(h.ride.dashUIState.sheet, .music, name)
            clock.advance(0.8)
            h.ride.handleDashInput(.knob(1)) // ▶, meant for ⏯
            _ = list(h)
            XCTAssertEqual(h.ride.dashUIState.focusedId, DashFocusEngine.musicPlayPauseId, "\(name): ▶ from ⏮ is ⏯")
            clock.advance(0.4)
            h.ride.handleDashInput(.key(.enter)) // ★: pause the song
            await settle(0.1)
            XCTAssertTrue(h.core.navigation.snapshot.mode.isNavigating, "\(name): ▶ ★ never ends navigation")
            XCTAssertEqual(fake.commands, ["beginning", "previous", "pause"], "\(name): ▶ ★ paused the song")
        }
    }

    /// R3-FOCUS-3, the physical presses (PreviewHandlebar → ControlsModel's gesture engine → RideModel →
    /// NavigationModel): capture on, a paused song, navigating, the sheet open on ⏯ (◀ ★). Two quick ▶ are
    /// the rider's way to ✕. On the iOS default map ▶▶ inside the 300-ms window is unmapped since P0 (D02): the
    /// first ▶ moved the knob to ⏭ and the second is swallowed, so the ★ meant for ✕ is ⏭ (it was HOME, the
    /// menu on "Music", and on bfa6c93 the menu opened on End and that ★ ended navigation); slower, ▶ ▶ reach
    /// ✕ and ★ closes the sheet onto the tile. Navigation goes on either way.
    @MainActor
    func testCaptureOnQuickRightRightFromTheSheetThenStarNeverEndsNavigation() async {
        for gap in [0.25, 0.6] {
            let name = "▶ ▶ \(gap) s apart"
            let (h, fake, clock, _) = await navigatingHarness(capture: true, playing: false)
            func press(_ e: HandlebarRawEvent) {
                h.handlebar.emit(HandlebarSignal(event: e, time: clock.now(), steps: 1))
                _ = list(h)
            }
            press(.backward)
            clock.advance(0.8)
            press(.select)
            XCTAssertEqual(h.ride.dashUIState.sheet, .music, name)
            XCTAssertEqual(h.ride.dashUIState.focusedId, DashFocusEngine.musicPlayPauseId, name)
            clock.advance(1.2)
            press(.forward)
            clock.advance(gap)
            press(.forward)
            if gap < 0.3 {
                XCTAssertEqual(h.ride.dashUIState.sheet, .music, "\(name): no HOME")
                XCTAssertEqual(h.ride.dashUIState.focusedId, "music.next", "\(name): one step, the second ▶ swallowed")
            } else {
                XCTAssertEqual(h.ride.dashUIState.focusedId, "music.close", "\(name): ✕")
            }
            clock.advance(1)
            press(.select) // the ★ meant for ✕
            XCTAssertEqual(h.ride.dashUIState.sheet, gap < 0.3 ? .music : .none, name)
            if gap >= 0.3 { XCTAssertEqual(h.ride.dashUIState.focusedId, DashFocusEngine.musicTileId, name) }
            await settle(0.2)
            XCTAssertTrue(h.core.navigation.snapshot.mode.isNavigating, "\(name): navigation goes on")
            XCTAssertEqual(fake.commands, gap < 0.3 ? ["next"] : [], "\(name): what the Music app got")
        }
    }
}
