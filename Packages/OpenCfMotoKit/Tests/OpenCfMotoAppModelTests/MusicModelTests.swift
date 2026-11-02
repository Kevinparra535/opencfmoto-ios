// SPDX-License-Identifier: AGPL-3.0-or-later
// MusicModel (Apple Music on the dash): opt-in + permission, when the Music app is followed, the
// mapping to DashModel.music, the artwork pipeline (order, retries, stale results, memory cache,
// cleanup), the dash commands, the hand-over callbacks, diagnostics and log privacy.

import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class MusicModelTests: XCTestCase {
    private typealias F = MusicFixtures

    // MARK: Opt-in and permission

    @MainActor
    func testEnablingAsksForThePermissionOnceAndOnlyWhenUndetermined() async {
        let rig = MusicRig(enabled: false) {
            PreviewMusic(clock: $0, queue: F.queue, playing: true, authorization: .notDetermined)
        }
        let fake = rig.preview
        XCTAssertFalse(rig.model.isEnabled)
        XCTAssertEqual(rig.model.authorization, .notDetermined)
        rig.model.setDashActive(true)
        rig.model.refreshAuthorization()
        XCTAssertEqual(fake.authorizationRequests, 0, "nothing is asked at launch, by the dash or on app active")
        XCTAssertFalse(fake.isObserving)
        await rig.model.setEnabled(true)
        XCTAssertEqual(fake.authorizationRequests, 1)
        XCTAssertEqual(rig.model.authorization, .authorized)
        XCTAssertTrue(fake.isObserving)
        await rig.model.setEnabled(false)
        await rig.model.setEnabled(true)
        XCTAssertEqual(fake.authorizationRequests, 1, "never asked again once answered")
    }

    @MainActor
    func testDeniedMeansNoObservingUntilTheRiderAllowsItInSettings() async {
        let rig = MusicRig(enabled: false) {
            PreviewMusic(clock: $0, queue: F.queue, playing: true, authorization: .notDetermined)
        }
        let fake = rig.preview
        fake.answerToRequest = .denied
        rig.model.setDashActive(true)
        await rig.model.setEnabled(true)
        XCTAssertTrue(rig.model.isEnabled)
        XCTAssertEqual(rig.model.authorization, .denied)
        XCTAssertFalse(fake.isObserving)
        XCTAssertNil(rig.model.dashNowPlaying)
        XCTAssertFalse(rig.model.isShownOnDash)
        rig.model.openAppSettings()
        XCTAssertEqual(rig.system.openedSettingsCount, 1)
        // Allowed later in iOS Settings ▸ OpenCfMoto: picked up when the app is active again.
        fake.authorization = .authorized
        rig.model.scenePhaseChanged(.active)
        XCTAssertEqual(rig.model.authorization, .authorized)
        XCTAssertTrue(fake.isObserving)
        XCTAssertTrue(rig.model.isShownOnDash, "the tile comes without a relaunch")
    }

    @MainActor
    func testTheChoiceIsPersisted() async {
        let rig = MusicRig(enabled: false) { PreviewMusic(clock: $0, queue: F.queue) }
        XCTAssertNil(rig.services.keyValueStore.bool(forKey: "ios.dash_music"), "default off")
        await rig.model.setEnabled(true)
        XCTAssertEqual(rig.services.keyValueStore.bool(forKey: "ios.dash_music"), true)
        XCTAssertTrue(MusicModel(core: AppCore(services: rig.services)).isEnabled, "remembered by the next launch")
        await rig.model.setEnabled(false)
        XCTAssertEqual(rig.services.keyValueStore.bool(forKey: "ios.dash_music"), false)
    }

    @MainActor
    func testObservingFollowsTheDashUIEnabledAndAuthorized() async {
        let rig = MusicRig { PreviewMusic(clock: $0, queue: F.queue, playing: true, position: 133) }
        let fake = rig.preview
        XCTAssertFalse(fake.isObserving, "no dash UI live yet")
        XCTAssertEqual(rig.model.snapshot, .empty)
        rig.model.setDashActive(true)
        XCTAssertTrue(fake.isObserving)
        XCTAssertEqual(rig.model.snapshot.track?.id, "p1a")
        XCTAssertTrue(rig.model.isShownOnDash)
        rig.model.setDashActive(false)
        XCTAssertFalse(fake.isObserving)
        XCTAssertEqual(rig.model.snapshot, .empty)
        XCTAssertNil(rig.model.dashNowPlaying)
        rig.model.setDashActive(true)
        await rig.model.setEnabled(false)
        XCTAssertFalse(fake.isObserving)
        await rig.model.setEnabled(true)
        XCTAssertTrue(fake.isObserving)
        fake.authorization = .restricted
        rig.model.refreshAuthorization()
        XCTAssertEqual(rig.model.authorization, .restricted)
        XCTAssertFalse(fake.isObserving)
        XCTAssertNil(rig.model.dashNowPlaying)
    }

    @MainActor
    func testTheNullPortIsUnavailable() async {
        var services = AppServices.preview()
        services.music = UnavailableMusic()
        let model = MusicModel(core: AppCore(services: services))
        XCTAssertFalse(model.isAvailable)
        XCTAssertEqual(model.authorization, .unavailable)
        model.setDashActive(true)
        await model.setEnabled(true)
        XCTAssertNil(model.dashNowPlaying)
        XCTAssertEqual(model.diagnostics, "on/unavailable/stopped/art=-")
    }

    // MARK: Mapping to the dash

    @MainActor
    func testMappingToDashNowPlaying() async throws {
        let rig = MusicRig { _ in ScriptedMusic() }
        let port = rig.scripted
        port.pending = F.reading(F.ruta, .playing, position: 133, at: 1_000)
        rig.model.setDashActive(true)
        let np = try XCTUnwrap(rig.model.dashNowPlaying)
        XCTAssertEqual(np, DashNowPlaying(title: "Ruta del Sol (Remastered 2012)", artist: "Los Pistones",
                                          album: "Ruta Sessions", artworkId: nil, state: .playing, duration: 364,
                                          position: 133, positionAt: 1_000, rate: 1))
        XCTAssertEqual(np.elapsedSeconds(at: 1_000), 133)
        XCTAssertEqual(DashMusicFormat.remaining(np, at: 1_000), "-3:51")
        for state: MusicPlaybackState in [.paused, .interrupted, .seekingForward, .seekingBackward, .stopped] {
            port.emit(MusicSnapshot(track: F.ruta, state: state, position: 140, sampledAt: 1_007, rate: 1))
            XCTAssertEqual(rig.model.dashNowPlaying?.state, .paused, "\(state)")
            XCTAssertEqual(rig.model.dashNowPlaying?.rate, 0, "\(state): the position stands still")
            XCTAssertEqual(rig.model.dashNowPlaying?.position(at: 1_100), 140, "\(state)")
        }
        port.emit(MusicSnapshot(track: F.pass, state: .playing, position: 2, sampledAt: 1_010, rate: 1.5))
        XCTAssertEqual(rig.model.dashNowPlaying?.rate, 1.5)
        XCTAssertEqual(rig.model.dashNowPlaying?.title, "Mountain Pass")
        port.emit(F.reading(nil, .playing, at: 1_020))
        XCTAssertNil(rig.model.dashNowPlaying, "nothing loaded / a Home Sharing item")
        let radio = MusicTrack(id: "h0123456789abcdef", title: "", duration: .nan)
        port.emit(F.reading(radio, .playing, at: 1_030))
        XCTAssertEqual(rig.model.dashNowPlaying?.title, "", "Core prints \"Unknown song\"")
        XCTAssertNil(rig.model.dashNowPlaying?.knownDuration, "radio: no bar, no times")
    }

    @MainActor
    func testAPausedSongHidesWhileAnotherAppPlaysButAPlayingOneStays() async {
        let rig = MusicRig { PreviewMusic(clock: $0, queue: F.queue, playing: false, position: 40) }
        let fake = rig.preview
        rig.model.setDashActive(true)
        XCTAssertEqual(rig.model.dashNowPlaying?.state, .paused, "a paused song stays: the dash's way to start music")
        fake.simulate(otherAudioPlaying: true)
        XCTAssertNil(rig.model.dashNowPlaying, "Spotify plays: the paused Music song is stale")
        XCTAssertFalse(rig.model.isShownOnDash)
        fake.simulate(playing: true)
        XCTAssertTrue(rig.model.snapshot.otherAudioPlaying)
        XCTAssertEqual(rig.model.dashNowPlaying?.state, .playing, "shown while it plays, whatever else plays")
        fake.simulate(playing: false, otherAudioPlaying: false)
        XCTAssertEqual(rig.model.dashNowPlaying?.state, .paused)
    }

    // MARK: Artwork

    @MainActor
    func testArtworkIsRegisteredBeforeItsIdIsPublishedAndTheOldOneRemovedAfter() async {
        let rig = MusicRig { PreviewMusic(clock: $0, queue: F.queue, playing: true) }
        let fake = rig.preview
        fake.artworks = ["p1a": F.art(1), "s100000002": F.art(2, .musicKit)]
        rig.model.setDashActive(true)
        let shown = await eventually { rig.model.dashNowPlaying?.artworkId == "music.art.p1a" }
        XCTAssertTrue(shown)
        XCTAssertEqual(rig.publications.first?.artworkId, nil, "the placeholder first")
        XCTAssertEqual(rig.projection.dashImages["music.art.p1a"], F.art(1).data)
        XCTAssertEqual(rig.model.lastArtworkSource, "mp")

        let changesBeforeSkip = rig.publications.count
        fake.skipToNext()
        let next = await eventually { rig.model.dashNowPlaying?.artworkId == "music.art.s100000002" }
        XCTAssertTrue(next)
        let removed = await eventually { rig.projection.dashImages["music.art.p1a"] == nil }
        XCTAssertTrue(removed, "the previous song's image goes")
        XCTAssertEqual(rig.model.lastArtworkSource, "musickit")
        XCTAssertEqual(Set(rig.imageCalls), ["+music.art.p1a", "+music.art.s100000002", "-music.art.p1a"])
        XCTAssertEqual(rig.imageCalls.count, 3)
        XCTAssertEqual(Set(rig.projection.dashImages.keys), ["music.art.s100000002"])

        // Every id the dash was given had been registered before.
        for p in rig.publications {
            if let id = p.artworkId { XCTAssertTrue(p.registered.contains(id), "\(id) published before registration") }
        }
        // The old image was removed only after the model without it had been published.
        let skipPublished = rig.publications[changesBeforeSkip]
        XCTAssertNil(skipPublished.artworkId, "the new song starts on the placeholder")
        let removal = rig.projection.dashImageCalls.firstIndex { $0.id == "music.art.p1a" && !$0.registered }
        XCTAssertNotNil(removal)
        XCTAssertGreaterThanOrEqual(removal ?? -1, skipPublished.calls)
    }

    @MainActor
    func testArtworkRetriesAtZeroOneThreeAndTenSecondsThenGivesUp() async {
        let rig = MusicRig { PreviewMusic(clock: $0, queue: F.queue, playing: true) }
        let fake = rig.preview
        fake.artworks = ["p1a": F.art(1), "s100000002": F.art(2)]
        fake.artworkMisses = ["p1a": 3, "s100000002": 4]
        rig.model.setDashActive(true)
        let shown = await eventually { rig.model.dashNowPlaying?.artworkId == "music.art.p1a" }
        XCTAssertTrue(shown, "the 4th attempt finds it")
        XCTAssertEqual(fake.artworkRequests, ["p1a", "p1a", "p1a", "p1a"])
        XCTAssertEqual(rig.sleeps, [1, 2, 7], "attempts at 0, +1, +3 and +10 s after the song became current")

        rig.sleeps = []
        fake.skipToNext()
        let gaveUp = await eventually { rig.model.lastArtworkSource == "none" }
        XCTAssertTrue(gaveUp)
        XCTAssertEqual(Array(fake.artworkRequests.dropFirst(4)), Array(repeating: "s100000002", count: 4))
        XCTAssertEqual(rig.sleeps, [1, 2, 7])
        XCTAssertEqual(rig.model.dashNowPlaying?.title, "Mountain Pass")
        XCTAssertNil(rig.model.dashNowPlaying?.artworkId, "the placeholder stays")
        let cleaned = await eventually { rig.projection.dashImages.isEmpty }
        XCTAssertTrue(cleaned, "the previous cover is not kept for a song without one")
    }

    @MainActor
    func testAStaleArtworkAfterAQuickSkipIsDropped() async {
        let rig = MusicRig { _ in ScriptedMusic() }
        let port = rig.scripted
        let gate = ArtworkGate()
        port.artworkHandler = { id in id == "p1a" ? await gate.wait() : nil }
        rig.model.artworkAttemptDelays = [0]
        port.pending = F.reading(F.ruta, .playing)
        rig.model.setDashActive(true)
        let waiting = await eventually { gate.isWaiting }
        XCTAssertTrue(waiting, "the first song's artwork is loading")
        port.emit(F.reading(F.pass, .playing, at: 1_001)) // the rider skipped
        gate.open(with: F.art(1)) // the first song's artwork arrives late
        await settle()
        XCTAssertTrue(rig.projection.dashImageCalls.isEmpty, "never registered")
        XCTAssertNil(rig.model.dashNowPlaying?.artworkId)
        XCTAssertEqual(rig.model.dashNowPlaying?.title, "Mountain Pass")
        XCTAssertEqual(port.artworkRequests, ["p1a", "s100000002"])
    }

    @MainActor
    func testRecentCoversComeBackFromMemory() async {
        let rig = MusicRig { PreviewMusic(clock: $0, queue: F.queue, playing: true) }
        let fake = rig.preview
        fake.artworks = ["p1a": F.art(1), "s100000002": F.art(2)]
        rig.model.setDashActive(true)
        _ = await eventually { rig.model.dashNowPlaying?.artworkId == "music.art.p1a" }
        fake.skipToNext()
        _ = await eventually { rig.model.dashNowPlaying?.artworkId == "music.art.s100000002" }
        let requests = fake.artworkRequests.count
        fake.skipToPrevious() // A → B → A
        XCTAssertEqual(rig.model.dashNowPlaying?.artworkId, "music.art.p1a", "at once, from memory")
        XCTAssertEqual(rig.projection.dashImages["music.art.p1a"], F.art(1).data)
        XCTAssertEqual(fake.artworkRequests.count, requests, "no new request")
        XCTAssertEqual(rig.model.lastArtworkSource, "mp")
    }

    @MainActor
    func testTheMemoryCacheKeepsFourSongs() async {
        let rig = MusicRig { _ in ScriptedMusic() }
        let port = rig.scripted
        port.artworkHandler = { id in MusicArtwork(data: Data(id.utf8), source: .mediaItem) }
        let songs = (1 ... 5).map { MusicTrack(id: "p\($0)", title: "Song \($0)", duration: 200) }
        port.pending = F.reading(songs[0], .playing)
        rig.model.setDashActive(true)
        for (i, song) in songs.enumerated() {
            port.emit(F.reading(song, .playing, at: 1_000 + Double(i)))
            _ = await eventually { rig.model.dashNowPlaying?.artworkId == "music.art.\(song.id)" }
        }
        XCTAssertEqual(port.artworkRequests, ["p1", "p2", "p3", "p4", "p5"])
        port.emit(F.reading(songs[1], .playing, at: 1_010)) // p2: still cached
        XCTAssertEqual(rig.model.dashNowPlaying?.artworkId, "music.art.p2")
        port.emit(F.reading(songs[0], .playing, at: 1_011)) // p1: evicted by the 5th song
        _ = await eventually { rig.model.dashNowPlaying?.artworkId == "music.art.p1" }
        XCTAssertEqual(port.artworkRequests, ["p1", "p2", "p3", "p4", "p5", "p1"])
    }

    @MainActor
    func testDisablingRemovesTheImagesAndStopsFollowing() async {
        let rig = MusicRig { PreviewMusic(clock: $0, queue: F.queue, playing: true) }
        let fake = rig.preview
        fake.artworks = ["p1a": F.art(1)]
        rig.model.setDashActive(true)
        _ = await eventually { rig.model.dashNowPlaying?.artworkId != nil }
        let dashChanges = rig.publications.count
        await rig.model.setEnabled(false)
        XCTAssertFalse(fake.isObserving)
        XCTAssertNil(rig.model.dashNowPlaying)
        XCTAssertGreaterThan(rig.publications.count, dashChanges, "the dash hears about it")
        let gone = await eventually { rig.projection.dashImages.isEmpty }
        XCTAssertTrue(gone)
        XCTAssertEqual(rig.imageCalls, ["+music.art.p1a", "-music.art.p1a"])
        // Turned on again: nothing of the music was kept, the cover is read again.
        await rig.model.setEnabled(true)
        _ = await eventually { rig.projection.dashImages["music.art.p1a"] != nil }
        XCTAssertEqual(fake.artworkRequests, ["p1a", "p1a"])
        // The dash UI stopping removes the images too, but keeps the covers in memory.
        rig.model.setDashActive(false)
        let goneAgain = await eventually { rig.projection.dashImages.isEmpty }
        XCTAssertTrue(goneAgain)
        rig.model.setDashActive(true)
        XCTAssertEqual(rig.model.dashNowPlaying?.artworkId, "music.art.p1a", "at once, from memory")
        XCTAssertEqual(fake.artworkRequests, ["p1a", "p1a"])
    }

    @MainActor
    func testTheCurrentSongsImageStaysWhileTheTileIsHidden() async {
        let rig = MusicRig { PreviewMusic(clock: $0, queue: F.queue, playing: false) }
        let fake = rig.preview
        fake.artworks = ["p1a": F.art(1)]
        rig.model.setDashActive(true)
        _ = await eventually { rig.model.dashNowPlaying?.artworkId != nil }
        fake.simulate(otherAudioPlaying: true)
        XCTAssertNil(rig.model.dashNowPlaying)
        await settle()
        XCTAssertNotNil(rig.projection.dashImages["music.art.p1a"], "kept for when the tile comes back")
        fake.simulate(otherAudioPlaying: false)
        XCTAssertEqual(rig.model.dashNowPlaying?.artworkId, "music.art.p1a")
    }

    // MARK: Commands

    @MainActor
    func testDashCommandsDriveThePlayerWithoutOptimisticState() async {
        let rig = MusicRig { PreviewMusic(clock: $0, queue: F.queue, playing: true, position: 10) }
        let fake = rig.preview
        rig.model.artworkAttemptDelays = [0] // no artwork retries among the recorded waits
        rig.model.perform(.playPause, fromDash: true)
        XCTAssertEqual(fake.commands, [], "nothing while the Music app is not followed")
        rig.model.setDashActive(true)
        rig.model.perform(.playPause, fromDash: true)
        XCTAssertEqual(fake.commands, ["pause"])
        rig.model.perform(.playPause, fromDash: true)
        XCTAssertEqual(fake.commands, ["pause", "play"])
        rig.clock.advance(5) // 15 s into the song
        rig.model.perform(.previous, fromDash: true)
        XCTAssertEqual(fake.commands.last, "beginning", "more than 3 s in: restart the song")
        rig.clock.advance(2) // 2 s into the restarted song
        rig.model.perform(.previous, fromDash: false)
        XCTAssertEqual(fake.commands.last, "previous", "3 s or less: the previous song")
        rig.model.perform(.next, fromDash: true)
        XCTAssertEqual(fake.commands, ["pause", "play", "beginning", "previous", "next"])
        let reread = await eventually { fake.refreshes >= 2 }
        XCTAssertTrue(reread, "the player is read again after a command")
        XCTAssertEqual(rig.sleeps.map { ($0 * 10).rounded() / 10 }, [0.3, 0.7],
                       "+0.3 s and +1.0 s after the last command (earlier re-reads were superseded)")
    }

    // MARK: Hand-over callbacks (contract R2 / R3)

    @MainActor
    func testPlaybackCallbacksFireOnTransitionsOnly() async {
        let rig = MusicRig { _ in ScriptedMusic() }
        let port = rig.scripted
        port.pending = F.reading(F.ruta, .playing)
        rig.model.setDashActive(true)
        XCTAssertEqual([rig.started, rig.paused], [0, 0], "the first reading is no transition")
        port.emit(F.reading(F.ruta, .playing, position: 30, at: 1_030)) // a seek while playing
        port.emit(F.reading(F.ruta, .seekingForward, position: 40, at: 1_031))
        port.emit(F.reading(F.ruta, .playing, position: 60, at: 1_032))
        port.emit(F.reading(F.ruta, .interrupted, position: 61, at: 1_033))
        port.emit(F.reading(F.ruta, .playing, position: 62, at: 1_040))
        XCTAssertEqual([rig.started, rig.paused], [0, 0], "seeking and interruptions are no hand-over")
        port.emit(F.reading(F.ruta, .paused, position: 70, at: 1_048))
        XCTAssertEqual([rig.started, rig.paused], [0, 1])
        port.emit(F.reading(F.pass, .paused, at: 1_050)) // another song, still paused
        XCTAssertEqual([rig.started, rig.paused], [0, 1])
        port.emit(F.reading(F.pass, .playing, at: 1_060))
        XCTAssertEqual([rig.started, rig.paused], [1, 1])
        port.emit(F.reading(F.pass, .interrupted, at: 1_070))
        port.emit(F.reading(F.pass, .paused, at: 1_080))
        XCTAssertEqual([rig.started, rig.paused], [1, 2], "an interruption that ends paused is a pause")
        port.emit(F.reading(nil, .stopped, at: 1_090))
        port.emit(F.reading(F.night, .playing, at: 1_100))
        XCTAssertEqual([rig.started, rig.paused], [2, 2])
        port.emit(F.reading(nil, .stopped, at: 1_110))
        XCTAssertEqual([rig.started, rig.paused], [2, 3], "playing → stopped")

        // Observing again: the first reading is no transition, even if the state differs.
        rig.model.setDashActive(false)
        port.pending = F.reading(F.ruta, .playing, at: 1_200)
        rig.model.setDashActive(true)
        XCTAssertEqual([rig.started, rig.paused], [2, 3])
        port.emit(F.reading(F.ruta, .paused, at: 1_210))
        XCTAssertEqual([rig.started, rig.paused], [2, 4])
    }

    // MARK: Diagnostics and privacy

    @MainActor
    func testDiagnosticsLine() async {
        let rig = MusicRig { PreviewMusic(clock: $0, queue: F.queue, playing: true) }
        XCTAssertEqual(rig.model.diagnostics, "on/authorized/stopped/art=-")
        rig.preview.artworks["p1a"] = F.art(1)
        rig.model.setDashActive(true)
        _ = await eventually { rig.model.lastArtworkSource != nil }
        XCTAssertEqual(rig.model.diagnostics, "on/authorized/playing/art=mp")
        await rig.model.setEnabled(false)
        XCTAssertEqual(rig.model.diagnostics, "off/authorized/stopped/art=mp")
    }

    @MainActor
    func testNoLogLineCarriesATitleAnArtistOrAnAlbum() async {
        let capture = LogCapture()
        defer { capture.stop() }
        let rig = MusicRig(enabled: false) {
            PreviewMusic(clock: $0, queue: F.queue, playing: true, authorization: .notDetermined)
        }
        let fake = rig.preview
        fake.artworks = ["p1a": F.art(1)]
        rig.model.setDashActive(true)
        await rig.model.setEnabled(true)
        _ = await eventually { rig.model.lastArtworkSource == "mp" }
        rig.model.perform(.next, fromDash: true)
        rig.model.perform(.playPause, fromDash: false)
        rig.model.artworkAttemptDelays = [0]
        fake.skipToNext()
        _ = await eventually { rig.model.lastArtworkSource == "none" }
        await rig.model.setEnabled(false)
        let lines = capture.all.map(\.message)
        for word in F.privateWords {
            XCTAssertFalse(lines.contains { $0.contains(word) }, "a log line names \"\(word)\"")
        }
        let music = capture.messages(tag: "MUSIC")
        XCTAssertTrue(music.contains("dash music on (authorization=authorized)"), "\(music)")
        XCTAssertTrue(music.contains("authorization notDetermined -> authorized"), "\(music)")
        XCTAssertTrue(music.contains("observing on (poll 2s/5s)"))
        XCTAssertTrue(music.contains("state playing track=p1a other=0"), "\(music)")
        XCTAssertTrue(music.contains { $0.hasPrefix("artwork source=mp kind=library attempt=1 ms=0 px=? bytes=5 track=p1a") },
                      "\(music)")
        XCTAssertTrue(music.contains("command next (from dash)"))
        XCTAssertTrue(music.contains("command pause (from phone)"))
        XCTAssertTrue(music.contains { $0.hasPrefix("artwork source=none kind=library attempt=1 ") && $0.hasSuffix("track=p3c") },
                      "\(music)")
        XCTAssertTrue(music.contains("observing off"))
        XCTAssertTrue(music.contains("dash music off"))
    }
}
