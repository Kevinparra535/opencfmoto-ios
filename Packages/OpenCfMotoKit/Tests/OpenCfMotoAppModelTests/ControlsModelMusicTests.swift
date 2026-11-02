// SPDX-License-Identifier: AGPL-3.0-or-later
// Apple Music on the dash, contract R3: when Apple Music is paused while the phone media remote
// should drive the dash, ControlsModel claims the handlebar buttons back (+1 s, once more at +3 s
// when refused); "back on the dash" is shown only after a real re-claim; playing again cancels it;
// nothing happens when the capture policy does not want the remote.

import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class ControlsModelMusicTests: XCTestCase {
    @MainActor
    private func harness(optedIn: Bool = false) -> AppTestHarness {
        let h = AppTestHarness { services in
            if optedIn { services.keyValueStore.set(true, forKey: ControlsModel.remoteOptInKey) }
        }
        h.controls.musicReclaimDelays = [0.02, 0.06]
        return h
    }

    @MainActor
    private func backToDashShown(_ h: AppTestHarness) -> Bool {
        h.ride.ui.state.toast == SessionText.handlebarBackToDash(h.language)
    }

    @MainActor
    func testAPauseClaimsTheButtonsBackAndTellsTheRider() async {
        let h = harness()
        let log = LogCapture()
        defer { log.stop() }
        h.controls.setRemoteEnabled(true)
        h.controls.musicPlaybackPaused()
        XCTAssertEqual(h.handlebar.reclaimRequests, 0, "not at once")
        let reclaimed = await eventually { h.handlebar.reclaimRequests == 1 }
        XCTAssertTrue(reclaimed)
        let toast = await eventually { self.backToDashShown(h) }
        XCTAssertTrue(toast)
        await settle(0.15)
        XCTAssertEqual(h.handlebar.reclaimRequests, 1, "no second attempt after a success")
        let btn = log.messages(tag: "BTN")
        XCTAssertTrue(btn.contains("[BTN] music paused \u{2014} reclaiming the handlebar buttons (attempt 1)"), "\(btn)")
        XCTAssertTrue(btn.contains("[BTN] handlebar buttons back on the dash"), "\(btn)")
    }

    @MainActor
    func testARefusedReclaimIsTriedOnceMoreThenOnlyLogged() async {
        let h = harness()
        let log = LogCapture()
        defer { log.stop() }
        h.handlebar.reclaimAnswer = .refused
        h.controls.setRemoteEnabled(true)
        h.controls.musicPlaybackPaused()
        let twice = await eventually { h.handlebar.reclaimRequests == 2 }
        XCTAssertTrue(twice)
        await settle(0.15)
        XCTAssertEqual(h.handlebar.reclaimRequests, 2)
        XCTAssertFalse(backToDashShown(h))
        let btn = log.messages(tag: "BTN")
        XCTAssertEqual(btn.filter { $0.hasPrefix("[BTN] music paused") }.count, 2, "\(btn)")
        XCTAssertTrue(btn.contains("[BTN] reclaim refused (background or other audio)"), "\(btn)")

        // Refused, then accepted the second time.
        h.handlebar.reclaimAnswer = .refused
        h.controls.musicPlaybackPaused()
        _ = await eventually { h.handlebar.reclaimRequests == 3 }
        h.handlebar.reclaimAnswer = .reclaimed
        let back = await eventually { self.backToDashShown(h) }
        XCTAssertTrue(back)
        XCTAssertEqual(h.handlebar.reclaimRequests, 4)
    }

    @MainActor
    func testAlreadyClaimedNeedsNothing() async {
        let h = harness()
        h.handlebar.reclaimAnswer = .alreadyClaimed
        h.controls.setRemoteEnabled(true)
        h.controls.musicPlaybackPaused()
        _ = await eventually { h.handlebar.reclaimRequests == 1 }
        await settle(0.15)
        XCTAssertEqual(h.handlebar.reclaimRequests, 1)
        XCTAssertFalse(backToDashShown(h), "the buttons never left the dash")
    }

    @MainActor
    func testPlayingAgainCancelsTheReclaim() async {
        let h = harness()
        h.controls.setRemoteEnabled(true)
        h.controls.musicPlaybackPaused()
        h.controls.musicPlaybackStarted() // ★ again within a second: the music plays on
        await settle(0.15)
        XCTAssertEqual(h.handlebar.reclaimRequests, 0, "a re-claim now would pause the music again")
    }

    @MainActor
    func testNoReclaimWhenTheCapturePolicyDoesNotWantTheRemote() async {
        do { // opted out
            let h = harness()
            h.controls.musicPlaybackPaused()
            await settle(0.15)
            XCTAssertEqual(h.handlebar.reclaimRequests, 0)
        }
        do { // opted in on an earlier launch: no session and no claim this launch, then a ride
            let h = harness(optedIn: true)
            XCTAssertFalse(h.handlebar.isEnabled)
            h.controls.musicPlaybackPaused()
            await settle(0.15)
            XCTAssertEqual(h.handlebar.reclaimRequests, 0)
            h.controls.sessionChanged(active: true, mirror: false)
            h.controls.musicPlaybackPaused()
            let reclaimed = await eventually { h.handlebar.reclaimRequests == 1 }
            XCTAssertTrue(reclaimed, "during a ride the remote is wanted")
        }
        do { // "Handlebar buttons drive the dash" switched off for this bike (seen before the release)
            let h = harness()
            h.controls.setRemoteEnabled(true)
            h.core.settings.setHandlebarControl(false, forBike: nil)
            h.controls.musicPlaybackPaused()
            await settle(0.15)
            XCTAssertEqual(h.handlebar.reclaimRequests, 0)
        }
        do { // mirror mode: the bars belong to the media apps
            let h = harness()
            h.controls.setRemoteEnabled(true)
            h.controls.sessionChanged(active: true, mirror: true)
            h.controls.musicPlaybackPaused()
            await settle(0.15)
            XCTAssertEqual(h.handlebar.reclaimRequests, 0)
        }
        do { // the policy changes while the re-claim waits (a mirror session starts)
            let h = harness()
            h.controls.setRemoteEnabled(true)
            h.controls.musicPlaybackPaused()
            h.controls.sessionChanged(active: true, mirror: true)
            await settle(0.15)
            XCTAssertEqual(h.handlebar.reclaimRequests, 0)
        }
    }

    /// The whole chain: the Music app pauses (★ on the bars, the dash ⏯ or the phone) → MusicModel
    /// → ControlsModel re-claims → RideModel shows "back on the dash".
    @MainActor
    func testPausingAppleMusicGivesTheButtonsBackToTheDash() async {
        let clock = MusicTestClock()
        let fake = PreviewMusic(clock: clock, queue: MusicFixtures.queue, playing: true)
        let h = AppTestHarness { services in
            services.clock = clock
            services.music = fake
            services.keyValueStore.set(true, forKey: MusicModel.enabledKey)
        }
        h.model.music.artworkAttemptDelays = [0]
        h.controls.musicReclaimDelays = [0.02, 0.06]
        h.controls.setRemoteEnabled(true)
        h.ride.startLocationPreview()
        XCTAssertTrue(fake.isObserving)
        fake.simulate(playing: false)
        let back = await eventually { self.backToDashShown(h) }
        XCTAssertTrue(back)
        XCTAssertEqual(h.handlebar.reclaimRequests, 1)
        // Playing again (R2) is no pause: no new re-claim.
        fake.simulate(playing: true)
        await settle(0.15)
        XCTAssertEqual(h.handlebar.reclaimRequests, 1)
    }
}
