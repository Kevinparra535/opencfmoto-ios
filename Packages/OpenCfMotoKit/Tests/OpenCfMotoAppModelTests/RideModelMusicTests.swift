// SPDX-License-Identifier: AGPL-3.0-or-later
// Apple Music on the dash through the whole model layer (AppModel wiring): the dash model carries
// the Music app's song while the own dash UI is live, the dash's ⏮ ⏯ ⏭ reach the Music app, and
// starting music while the phone media remote drives the dash hands the buttons over (toast, the
// Music sheet closes). Tap-by-hit-region tests come with the integration of the dash UI side.

import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class RideModelMusicTests: XCTestCase {
    /// The app over the preview services with a fake Music app on a manual clock.
    @MainActor
    private func harness(playing: Bool = true, enabled: Bool = true,
                         authorization: MusicAuthorizationState = .authorized) -> (AppTestHarness, PreviewMusic, MusicTestClock) {
        let clock = MusicTestClock()
        let fake = PreviewMusic(clock: clock, queue: MusicFixtures.queue, playing: playing, position: 133,
                                authorization: authorization)
        let h = AppTestHarness { services in
            services.clock = clock
            services.music = fake
            if enabled { services.keyValueStore.set(true, forKey: MusicModel.enabledKey) }
        }
        h.model.music.artworkAttemptDelays = [0]
        h.model.music.imageCleanupDelay = 0
        return (h, fake, clock)
    }

    @MainActor
    func testTheDashModelCarriesTheMusicAppsSongWhileTheDashUIIsLive() async {
        let (h, fake, _) = harness()
        fake.artworks["p1a"] = MusicFixtures.art(7)
        h.ride.flushModel()
        XCTAssertFalse(h.ride.isDashUIActive)
        XCTAssertFalse(fake.isObserving, "no dash UI live: the Music app is not followed")
        XCTAssertNil(h.ride.lastModel?.music)
        h.ride.startLocationPreview() // the phone's Dash view
        XCTAssertTrue(h.ride.isDashUIActive)
        XCTAssertTrue(fake.isObserving)
        let carried = await eventually { h.ride.lastModel?.music?.artworkId == "music.art.p1a" }
        XCTAssertTrue(carried)
        let music = h.ride.lastModel?.music
        XCTAssertEqual(music?.title, "Ruta del Sol (Remastered 2012)")
        XCTAssertEqual(music?.artist, "Los Pistones")
        XCTAssertEqual(music?.state, .playing)
        XCTAssertEqual(music?.duration, 364)
        XCTAssertEqual(music?.position, 133)
        XCTAssertEqual(music?.positionAt, 1_000, "the sample is on the dash UI's clock")
        XCTAssertEqual(h.projection.dashImages["music.art.p1a"], MusicFixtures.art(7).data)
        XCTAssertTrue(h.model.music.isShownOnDash)

        fake.simulate(playing: false) // paused in the Music app
        let paused = await eventually { h.ride.lastModel?.music?.state == .paused }
        XCTAssertTrue(paused)

        h.ride.stopLocationPreview()
        XCTAssertFalse(fake.isObserving)
        let gone = await eventually { h.ride.lastModel?.music == nil }
        XCTAssertTrue(gone, "no tile, no menu entry, the sheet closes")
        let removed = await eventually { h.projection.dashImages.isEmpty }
        XCTAssertTrue(removed)
    }

    @MainActor
    func testFeatureOffMeansNoMusicOnTheDash() async {
        let (h, fake, _) = harness(enabled: false)
        h.ride.startLocationPreview()
        h.ride.flushModel()
        XCTAssertFalse(fake.isObserving)
        XCTAssertNil(h.ride.lastModel?.music)
        XCTAssertEqual(fake.authorizationRequests, 0, "the dash never asks for the permission")
        h.ride.performDashIntent(.musicPlayPause)
        XCTAssertEqual(fake.commands, [], "the dash cannot drive what it does not show")
    }

    @MainActor
    func testDashMusicIntentsReachTheMusicApp() async {
        let (h, fake, clock) = harness()
        h.ride.startLocationPreview()
        h.ride.performDashIntent(.musicPlayPause)
        XCTAssertEqual(fake.commands, ["pause"])
        h.ride.performDashIntent(.musicNext)
        XCTAssertEqual(fake.commands, ["pause", "next"])
        clock.advance(1)
        h.ride.performDashIntent(.musicPrevious) // 0 s into the (paused) next song
        XCTAssertEqual(fake.commands, ["pause", "next", "previous"])
        h.ride.performDashIntent(.openMusic)
        XCTAssertEqual(fake.commands.count, 3, "opening the sheet changes nothing in the Music app")
        // The same intents coming from the dash itself (touch / handlebar path).
        h.ride.perform([.musicPlayPause], fromDash: true)
        XCTAssertEqual(fake.commands.last, "play")
        clock.advance(10)
        h.ride.perform([.musicPrevious], fromDash: true)
        XCTAssertEqual(fake.commands.last, "beginning", "10 s in: restart the song")
        XCTAssertEqual(h.ride.dashUIState.sheet, h.ride.ui.state.sheet)
    }

    @MainActor
    func testStartingMusicWhileThePhoneMediaRemoteDrivesTheDashHandsTheButtonsOver() async {
        let (h, fake, clock) = harness(playing: false)
        h.controls.setRemoteEnabled(true)
        XCTAssertTrue(h.handlebar.isEnabled)
        h.ride.startLocationPreview()
        h.ride.performDashIntent(.openMusic) // the Music sheet (dash UI side)
        h.ride.performDashIntent(.musicPlayPause) // ⏯
        XCTAssertEqual(fake.commands, ["play"])
        let toast = await eventually { h.ride.ui.state.toast == SessionText.musicTakesHandlebar(h.language) }
        XCTAssertTrue(toast)
        XCTAssertEqual(h.ride.dashUIState.sheet, .none, "the bars could not close the sheet any more")
        // Music started on the phone (or by Siri) counts the same.
        fake.simulate(playing: false)
        h.ride.ui.showToast("other", now: clock.now())
        fake.simulate(playing: true)
        let again = await eventually { h.ride.ui.state.toast == SessionText.musicTakesHandlebar(h.language) }
        XCTAssertTrue(again)
    }

    @MainActor
    func testNoHandOverWithoutThePhoneMediaRemote() async {
        let (h, fake, _) = harness(playing: false)
        h.ride.startLocationPreview()
        h.ride.performDashIntent(.musicPlayPause)
        XCTAssertEqual(fake.commands, ["play"])
        await settle()
        XCTAssertNotEqual(h.ride.ui.state.toast, SessionText.musicTakesHandlebar(h.language),
                          "capture off: the Music app had the buttons all along")
        XCTAssertEqual(h.handlebar.reclaimRequests, 0)
    }

    @MainActor
    func testFollowingTheMusicAppMatchesTheOwnDashUI() async {
        let (h, fake, _) = harness()
        var reported: [Bool] = []
        let wired = h.ride.onDashActivityChange
        h.ride.onDashActivityChange = { active in
            reported.append(active)
            wired?(active)
        }
        h.ride.startLocationPreview()
        h.ride.startLocationPreview() // Map hub + Dash view
        h.ride.stopLocationPreview()
        XCTAssertTrue(fake.isObserving)
        h.ride.stopLocationPreview()
        XCTAssertFalse(fake.isObserving)
        h.ride.enterRideMode()
        XCTAssertTrue(fake.isObserving)
        h.ride.exitRideMode()
        h.ride.sessionChanged(active: true, mirror: false) // Connect, own UI
        XCTAssertTrue(fake.isObserving)
        h.ride.sessionChanged(active: true, mirror: true) // Mirror: the dash shows the phone screen
        XCTAssertFalse(fake.isObserving)
        h.ride.sessionChanged(active: false, mirror: false)
        XCTAssertEqual(reported, [true, false, true, false, true, false])
        XCTAssertFalse(h.ride.isDashUIActive)
    }

    @MainActor
    func testProblemReportCarriesTheMusicLineWithoutSongNames() async {
        let (h, _, _) = harness()
        h.ride.startLocationPreview()
        var diagnostics: [String: String] = [:]
        let wired = await eventually {
            diagnostics = h.model.logs.diagnostics()
            return diagnostics["music"] == "on/authorized/playing/art=none"
        }
        XCTAssertTrue(wired, "\(diagnostics["music"] ?? "-")")
        for word in MusicFixtures.privateWords {
            XCTAssertFalse(diagnostics.values.contains { $0.contains(word) })
        }
    }
}
