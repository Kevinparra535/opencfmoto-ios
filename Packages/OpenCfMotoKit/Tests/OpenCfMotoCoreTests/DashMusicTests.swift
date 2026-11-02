// SPDX-License-Identifier: AGPL-3.0-or-later
// DashNowPlaying: the position is a sample that the dash extrapolates to the frame time.
import XCTest
@testable import OpenCfMotoCore

final class DashMusicTests: XCTestCase {
    private func song(_ state: DashNowPlaying.State = .playing, duration: TimeInterval = 231, position: TimeInterval = 10,
                      at t: TimeInterval = 100, rate: Double = 1) -> DashNowPlaying {
        DashNowPlaying(title: "Carretera Infinita", artist: "Los Pistones", album: "Ruta Sessions", artworkId: "music.art.p1f",
                       state: state, duration: duration, position: position, positionAt: t, rate: rate)
    }

    func testPlayingExtrapolatesPausedStandsStill() {
        XCTAssertEqual(song().position(at: 100), 10, accuracy: 1e-9)
        XCTAssertEqual(song().position(at: 112.5), 22.5, accuracy: 1e-9)
        XCTAssertEqual(song(rate: 0.5).position(at: 110), 15, accuracy: 1e-9)
        XCTAssertEqual(song(.paused).position(at: 500), 10, accuracy: 1e-9)
        XCTAssertEqual(song().position(at: 90), 10, accuracy: 1e-9, "a frame time before the sample never rewinds")
    }

    func testClampsToTheSongAndSurvivesGarbage() {
        XCTAssertEqual(song().position(at: 10_000), 231, accuracy: 1e-9)
        XCTAssertEqual(song(duration: 0).position(at: 10_000), 9_910, accuracy: 1e-9, "unknown length: no upper clamp")
        XCTAssertEqual(song(position: .nan).position(at: 100), 0)
        XCTAssertEqual(song(position: -5).position(at: 100), 0)
        XCTAssertEqual(song(rate: .infinity).position(at: 101), 10)
        XCTAssertEqual(song(at: .nan).position(at: 101), 10)
        XCTAssertNil(song(duration: .nan).fraction(at: 100))
        XCTAssertNil(song(duration: -1).knownDuration)
    }

    func testElapsedFractionAndTimes() {
        let s = song()
        XCTAssertEqual(s.elapsedSeconds(at: 100.99), 10)
        XCTAssertEqual(s.elapsedSeconds(at: 101.0), 11)
        XCTAssertEqual(s.fraction(at: 100)!, 10.0 / 231, accuracy: 1e-12)
        XCTAssertEqual(DashMusicFormat.time(0), "0:00")
        XCTAssertEqual(DashMusicFormat.time(7), "0:07")
        XCTAssertEqual(DashMusicFormat.time(231), "3:51")
        XCTAssertEqual(DashMusicFormat.time(3_725), "1:02:05")
        XCTAssertEqual(DashMusicFormat.time(-3), "0:00")
        XCTAssertEqual(DashMusicFormat.remaining(s, at: 100), "-3:41")
        XCTAssertEqual(DashMusicFormat.remaining(s, at: 100.5), "-3:41", "changes together with the elapsed label")
        XCTAssertEqual(DashMusicFormat.remaining(s, at: 101.0), "-3:40")
        XCTAssertEqual(DashMusicFormat.remaining(song(duration: 231.4), at: 100), "-3:41", "length rounded half up")
        XCTAssertEqual(DashMusicFormat.remaining(s, at: 1_000), "-0:00")
        XCTAssertNil(DashMusicFormat.remaining(song(duration: 0), at: 100))
    }

    func testModelDefaultsAndIntents() {
        XCTAssertNil(DashModel().music)
        XCTAssertTrue(DashIntent.openMusic.isUIOnly)
        XCTAssertFalse(DashIntent.musicPlayPause.isUIOnly)
        XCTAssertFalse(DashIntent.musicNext.isUIOnly)
        XCTAssertFalse(DashIntent.musicPrevious.isUIOnly)
        XCTAssertNotEqual(DashDrawCommand.image(id: "a", rect: .zero, cornerRadius: 0),
                          DashDrawCommand.image(id: "b", rect: .zero, cornerRadius: 0))
    }
}
