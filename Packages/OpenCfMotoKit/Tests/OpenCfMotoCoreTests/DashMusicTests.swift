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
        XCTAssertEqual(DashMusicFormat.remaining(song(duration: 231.4), at: 100), "-3:41", "whole seconds of the length")
        XCTAssertEqual(DashMusicFormat.remaining(song(duration: 231.6), at: 100), "-3:41", "never rounded up")
        XCTAssertEqual(DashMusicFormat.remaining(s, at: 1_000), "-0:00")
        XCTAssertNil(DashMusicFormat.remaining(song(duration: 0), at: 100))
    }

    func testRemainingStartsAtTheWholeLengthAndEndsAtZero() {
        // F8: a fractional length (MPMediaItem.playbackDuration, e.g. 245.6 s) used to start at "-4:06"
        // (rounded half up) and stop at "-0:01" (elapsed never passes ⌊length⌋).
        for (d, start) in [(245.6, "-4:05"), (245.613, "-4:05"), (245.5, "-4:05"), (245.4, "-4:05"), (364, "-6:04"), (0.7, "-0:00"),
                           (1.5, "-0:01")] {
            let atStart = song(duration: d, position: 0)
            XCTAssertEqual(DashMusicFormat.remaining(atStart, at: 100), start, "d=\(d) start")
            XCTAssertEqual(DashMusicFormat.time(atStart.elapsedSeconds(at: 100)), "0:00", "d=\(d)")
            let atEnd = song(.paused, duration: d, position: d)
            XCTAssertEqual(DashMusicFormat.remaining(atEnd, at: 100), "-0:00", "d=\(d) end")
            XCTAssertEqual(DashMusicFormat.remaining(song(duration: d, position: 0), at: 100 + d + 5), "-0:00", "d=\(d) played past the end")
            XCTAssertEqual(DashMusicFormat.remaining(song(.paused, duration: d, position: max(0, d - 0.05)), at: 100),
                           d.rounded(.down) == (d - 0.05).rounded(.down) ? "-0:00" : "-0:01", "d=\(d) almost at the end")
            // both labels always add up to the whole length (they change on the same second boundary)
            for t in stride(from: 100.0, through: 100 + d, by: 0.25) {
                let s = song(duration: d, position: 0)
                XCTAssertEqual(s.elapsedSeconds(at: t) + seconds(DashMusicFormat.remaining(s, at: t)!), Int(d.rounded(.down)), "d=\(d) t=\(t)")
            }
        }
        // 364 s (the fixtures' song) is unchanged: "-6:04" → "-3:51" at 2:13 → "-0:00"
        let fixture = song(duration: 364, position: 133)
        XCTAssertEqual(DashMusicFormat.remaining(fixture, at: 100), "-3:51")
        XCTAssertEqual(DashMusicFormat.remaining(fixture, at: 100 + 231), "-0:00")
    }

    /// "-4:05" → 245
    private func seconds(_ label: String) -> Int {
        label.dropFirst().split(separator: ":").reduce(0) { $0 * 60 + Int($1)! }
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
