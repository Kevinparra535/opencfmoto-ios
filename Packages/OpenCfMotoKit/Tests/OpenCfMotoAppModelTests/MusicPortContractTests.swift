// SPDX-License-Identifier: AGPL-3.0-or-later
// Step 0 of the Apple Music feature: the port, its null object, the fake and the handlebar /
// projection additions behave as the music contract says.
// NOTE (Linux): main-actor tests must be `async` (swift-corelibs-xctest).

import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class MusicPortContractTests: XCTestCase {
    private final class StepClock: MonotonicClock, @unchecked Sendable {
        var t: TimeInterval = 1_000
        func now() -> TimeInterval { t }
    }

    private static let songs = [
        MusicTrack(id: "p1f", title: "Carretera Infinita", artist: "Los Pistones", album: "Ruta Sessions", duration: 222),
        MusicTrack(id: "s1440776549", title: "Mountain Pass", artist: "Gearshift", album: "Twisties", duration: 245,
                   storeID: "1440776549"),
    ]

    @MainActor
    func testServicesDefaultToTheNullPort() async {
        let services = AppServices.preview()
        XCTAssertFalse(services.music.isAvailable)
        XCTAssertEqual(services.music.authorization, .unavailable)
        let asked = await services.music.requestAuthorization()
        XCTAssertEqual(asked, .unavailable)
        services.music.startObserving()
        XCTAssertEqual(services.music.snapshot, .empty)
        let art = await services.music.artwork(trackID: "p1f", maxPixelSize: 600)
        XCTAssertNil(art)
    }

    @MainActor
    func testFakeFollowsTheQueueAndOnlyReportsChanges() async {
        let clock = StepClock()
        let fake = PreviewMusic(clock: clock, queue: Self.songs, playing: true, position: 10, authorization: .notDetermined)
        var seen: [MusicSnapshot] = []
        fake.onChange = { seen.append($0) }
        fake.startObserving()
        XCTAssertFalse(fake.isObserving, "no observing before the grant")
        let answer = await fake.requestAuthorization()
        XCTAssertEqual(answer, .authorized)
        XCTAssertEqual(fake.authorizationRequests, 1)
        fake.startObserving()
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(fake.snapshot.track?.id, "p1f")
        XCTAssertEqual(fake.snapshot.state, .playing)
        XCTAssertEqual(fake.snapshot.sampledAt, 1_000)
        fake.refresh()
        XCTAssertEqual(seen.count, 1, "an identical reading fires no onChange")
        clock.t += 5
        fake.pause()
        XCTAssertEqual(fake.snapshot.state, .paused)
        XCTAssertEqual(fake.snapshot.position, 15, accuracy: 1e-9)
        fake.simulate(otherAudioPlaying: true)
        XCTAssertTrue(fake.snapshot.otherAudioPlaying)
        fake.skipToNext()
        XCTAssertEqual(fake.snapshot.track?.storeID, "1440776549")
        XCTAssertEqual(fake.snapshot.position, 0)
        XCTAssertEqual(fake.commands, ["pause", "next"])
        fake.stopObserving()
        XCTAssertEqual(fake.snapshot, .empty)
    }

    @MainActor
    func testTheFakesIOSModelCountsTheMusicAppsOwnAudio() async {
        let clock = StepClock()
        let plain = PreviewMusic(clock: clock, queue: Self.songs, playing: true)
        plain.startObserving()
        XCTAssertFalse(plain.snapshot.otherAudioPlaying, "default: only simulate(otherAudioPlaying:) sets it")
        plain.pause()
        XCTAssertFalse(plain.snapshot.otherAudioPlaying)

        // F1: iOS counts the Music app's own audio while it plays and for a moment after a pause.
        let fake = PreviewMusic(clock: clock, queue: Self.songs, playing: true)
        fake.otherAudioLag = 1.5
        fake.startObserving()
        XCTAssertTrue(fake.snapshot.otherAudioPlaying, "while the Music app plays")
        clock.t += 10
        fake.pause()
        XCTAssertTrue(fake.snapshot.otherAudioPlaying, "its fade right after the pause")
        clock.t += 1
        fake.refresh()
        XCTAssertTrue(fake.snapshot.otherAudioPlaying)
        clock.t += 0.5
        fake.refresh()
        XCTAssertFalse(fake.snapshot.otherAudioPlaying, "read again after the lag: the fade is over")
        fake.simulate(otherAudioPlaying: true)
        XCTAssertTrue(fake.snapshot.otherAudioPlaying, "another app")
        fake.play()
        XCTAssertFalse(fake.otherAudioPlaying, "the other app stopped when Music started")
        XCTAssertTrue(fake.snapshot.otherAudioPlaying, "the Music app's own audio again")
        fake.simulate(playing: false)
        XCTAssertTrue(fake.snapshot.otherAudioPlaying, "a pause in the Music app fades the same way")

        let paused = PreviewMusic(clock: clock, queue: Self.songs, playing: false)
        paused.otherAudioLag = 1.5
        paused.startObserving()
        XCTAssertFalse(paused.snapshot.otherAudioPlaying, "silent since before: no fade")
    }

    @MainActor
    func testFakeArtworkOnlyForTheCurrentSongAfterTheConfiguredMisses() async {
        let fake = PreviewMusic(queue: Self.songs, playing: true)
        fake.artworks["p1f"] = MusicArtwork(data: Data([0x89, 0x50, 0x4E, 0x47]), source: .mediaItem)
        fake.artworkMisses["p1f"] = 1
        fake.startObserving()
        let first = await fake.artwork(trackID: "p1f", maxPixelSize: 600)
        XCTAssertNil(first, "first attempt misses")
        let second = await fake.artwork(trackID: "p1f", maxPixelSize: 600)
        XCTAssertEqual(second?.source, .mediaItem)
        let other = await fake.artwork(trackID: "s1440776549", maxPixelSize: 600)
        XCTAssertNil(other, "not the current song")
        XCTAssertEqual(fake.artworkRequests, ["p1f", "p1f", "s1440776549"])
        XCTAssertEqual(MusicArtworkSource.mediaItem.rawValue, "mp")
        XCTAssertEqual(MusicArtworkSource.musicKit.rawValue, "musickit")
    }

    @MainActor
    func testHandlebarReclaimDefaultAndFake() async {
        final class Minimal: HandlebarRemoteProviding {
            var isAvailable: Bool { true }
            var isEnabled: Bool { true }
            var volumeButtonsEnabled = false
            var onSignal: ((HandlebarSignal) -> Void)?
            func enable() {}
            func disable() {}
        }
        let minimal: HandlebarRemoteProviding = Minimal()
        XCTAssertEqual(minimal.reclaimIfPossible(), .refused, "the default refuses")
        let fake = PreviewHandlebar()
        let port: HandlebarRemoteProviding = fake
        XCTAssertEqual(port.reclaimIfPossible(), .refused, "capture off")
        fake.enable()
        XCTAssertEqual(port.reclaimIfPossible(), .reclaimed)
        fake.reclaimAnswer = .alreadyClaimed
        XCTAssertEqual(port.reclaimIfPossible(), .alreadyClaimed)
        XCTAssertEqual(fake.reclaimRequests, 3, "dynamic dispatch reaches the fake through the port")
    }

    func testProjectionRecordsDashImages() {
        let projection = PreviewProjection()
        let port: DashProjecting = projection
        port.setDashImage(id: "music.art.p1f", data: Data([1, 2, 3]))
        port.setDashImage(id: "music.art.p0", data: nil)
        XCTAssertEqual(projection.dashImages["music.art.p1f"], Data([1, 2, 3]))
        XCTAssertNil(projection.dashImages["music.art.p0"])
        XCTAssertEqual(projection.dashImageCalls.map(\.id), ["music.art.p1f", "music.art.p0"])
        XCTAssertEqual(projection.dashImageCalls.map(\.registered), [true, false])
    }
}
