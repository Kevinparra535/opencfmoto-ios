// SPDX-License-Identifier: AGPL-3.0-or-later
// Apple Music on the dash: stable track ids, what counts as a meaningful change of the Music app's
// reading (the adapter only reports those), and the artwork size read from PNG / JPEG headers.

import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class MusicSnapshotRulesTests: XCTestCase {
    // MARK: MusicTrackID

    func testPersistentIDWinsAndIsLowerCaseHex() {
        XCTAssertEqual(MusicTrackID.make(persistentID: 0xABCDEF0123456789, storeID: "1440776549", title: "T",
                                         artist: "A", album: "B", duration: 200), "pabcdef0123456789")
        XCTAssertEqual(MusicTrackID.make(persistentID: 1, storeID: nil, title: "", artist: "", album: "", duration: 0), "p1")
    }

    func testStoreIDWhenThereIsNoPersistentID() {
        XCTAssertEqual(MusicTrackID.make(persistentID: 0, storeID: "1440776549", title: "T", artist: "A", album: "B",
                                         duration: 200), "s1440776549")
        XCTAssertEqual(MusicTrackID.normalizedStoreID(" 100000002 "), "100000002")
        for bad in [nil, "", "0", "000", "12a4", "-5", "１２３", String(repeating: "9", count: 33)] {
            XCTAssertNil(MusicTrackID.normalizedStoreID(bad), "\(String(describing: bad))")
        }
    }

    func testHashFallbackIsStableAndDependsOnEveryField() {
        func id(title: String = "Ruta del Sol", artist: String = "Los Pistones", album: String = "Ruta Sessions",
                duration: TimeInterval = 364, store: String? = "0") -> String {
            MusicTrackID.make(persistentID: 0, storeID: store, title: title, artist: artist, album: album, duration: duration)
        }
        let a = id()
        XCTAssertTrue(a.hasPrefix("h"))
        XCTAssertEqual(a.count, 17)
        XCTAssertEqual(a, id(), "stable")
        XCTAssertEqual(a, id(store: nil), "\"0\" is no store id")
        XCTAssertEqual(a, id(duration: 364.4), "duration rounded to whole seconds")
        XCTAssertNotEqual(a, id(duration: 364.6))
        XCTAssertNotEqual(a, id(title: "Ruta del Sol (Live)"))
        XCTAssertNotEqual(a, id(artist: "Otros"))
        XCTAssertNotEqual(a, id(album: "Otro"))
        // FNV-1a 64 of "|||0" (empty metadata, unknown duration): a fixed value.
        XCTAssertEqual(MusicTrackID.make(persistentID: 0, storeID: nil, title: "", artist: "", album: "", duration: .nan),
                       "h" + MusicTrackID.hex16(MusicTrackID.fnv1a64(Array("|||0".utf8))))
        XCTAssertEqual(MusicTrackID.fnv1a64(Array("a".utf8)), 0xaf63dc4c8601ec8c, "FNV-1a 64 test vector")
        XCTAssertEqual(MusicTrackID.wholeSeconds(.infinity), 0)
        XCTAssertEqual(MusicTrackID.wholeSeconds(-3), 0)
        XCTAssertEqual(MusicTrackID.wholeSeconds(1e300), Int(Int32.max), "saturates, never traps")
    }

    func testEveryIDIsSafeInsideTheDashImageID() {
        let ids = [
            MusicTrackID.make(persistentID: .max, storeID: nil, title: "", artist: "", album: "", duration: 0),
            MusicTrackID.make(persistentID: 0, storeID: "987654321", title: "", artist: "", album: "", duration: 0),
            MusicTrackID.make(persistentID: 0, storeID: nil, title: "Canción ñ / ☃ \"x\"", artist: "Ü", album: "\n", duration: 12),
        ]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        for id in ids {
            let image = MusicModel.imageID(forTrack: id)
            XCTAssertTrue(image.unicodeScalars.allSatisfy { allowed.contains($0) }, image)
            XCTAssertTrue(image.hasPrefix("music.art."))
        }
    }

    // MARK: Meaningful changes

    private let song = MusicTrack(id: "p1a", title: "Ruta del Sol (Remastered 2012)", artist: "Los Pistones",
                                  album: "Ruta Sessions", duration: 364)

    private func reading(_ state: MusicPlaybackState = .playing, position: TimeInterval = 133, at t: TimeInterval = 1_000,
                         rate: Double = 1, other: Bool = false, track: MusicTrack? = nil) -> MusicSnapshot {
        MusicSnapshot(track: track ?? song, state: state, position: position, sampledAt: t, rate: rate, otherAudioPlaying: other)
    }

    func testExtrapolation() {
        XCTAssertEqual(reading().extrapolatedPosition(at: 1_010), 143, accuracy: 1e-9)
        XCTAssertEqual(reading(rate: 2).extrapolatedPosition(at: 1_010), 153, accuracy: 1e-9)
        XCTAssertEqual(reading(.paused, rate: 0).extrapolatedPosition(at: 1_010), 133, accuracy: 1e-9, "paused: frozen")
        XCTAssertEqual(reading(.interrupted).extrapolatedPosition(at: 1_010), 133, accuracy: 1e-9)
        XCTAssertEqual(reading().extrapolatedPosition(at: 990), 133, accuracy: 1e-9, "never below the sample")
        XCTAssertEqual(reading(rate: .nan).extrapolatedPosition(at: 1_010), 133)
        XCTAssertEqual(reading(position: .nan).extrapolatedPosition(at: 1_010), 10, accuracy: 1e-9)
        XCTAssertEqual(reading(at: .infinity).extrapolatedPosition(at: 1_010), 133)
    }

    func testTheSteadyAdvanceIsNotAChange() {
        let old = reading()
        XCTAssertFalse(old.differsMeaningfully(from: old))
        XCTAssertFalse(reading(position: 143, at: 1_010).differsMeaningfully(from: old), "exactly as extrapolated")
        XCTAssertFalse(reading(position: 144.4, at: 1_010).differsMeaningfully(from: old), "1.4 s drift")
        XCTAssertTrue(reading(position: 144.6, at: 1_010).differsMeaningfully(from: old), "1.6 s drift")
        XCTAssertTrue(reading(position: 141.4, at: 1_010).differsMeaningfully(from: old), "1.6 s behind")
        XCTAssertTrue(reading(position: 0, at: 1_010).differsMeaningfully(from: old), "restart / seek")
        let paused = reading(.paused, rate: 0)
        XCTAssertFalse(reading(.paused, position: 133, at: 1_500, rate: 0).differsMeaningfully(from: paused), "paused stays frozen")
        XCTAssertTrue(reading(.paused, position: 200, at: 1_500, rate: 0).differsMeaningfully(from: paused), "seek while paused")
    }

    func testSongStateOtherAudioAndRateChangesAreChanges() {
        let old = reading()
        XCTAssertTrue(reading(.paused, position: 133, rate: 0).differsMeaningfully(from: old))
        XCTAssertTrue(reading(track: MusicTrack(id: "s100000002", title: "Mountain Pass", artist: "Gearshift",
                                                album: "Twisties", duration: 245, storeID: "100000002"))
                        .differsMeaningfully(from: old))
        var retitled = song
        retitled.title = "Ruta del Sol"
        XCTAssertTrue(reading(track: retitled).differsMeaningfully(from: old), "same id, new metadata")
        var longer = song
        longer.duration = 365
        XCTAssertTrue(reading(track: longer).differsMeaningfully(from: old), "the duration became known / changed")
        XCTAssertTrue(reading(other: true).differsMeaningfully(from: old))
        XCTAssertTrue(reading(rate: 1.5).differsMeaningfully(from: old))
        XCTAssertFalse(reading(rate: 1.005).differsMeaningfully(from: old), "rate jitter")
        XCTAssertTrue(MusicSnapshot(track: nil, state: .stopped, position: 0, sampledAt: 1_010, rate: 0)
                        .differsMeaningfully(from: old), "the song went away")
    }

    func testEmptyAgainstAnythingElse() {
        XCTAssertFalse(MusicSnapshot.empty.differsMeaningfully(from: .empty))
        XCTAssertTrue(reading().differsMeaningfully(from: .empty))
        XCTAssertTrue(MusicSnapshot.empty.differsMeaningfully(from: reading()))
        let nothingLoaded = MusicSnapshot(track: nil, state: .stopped, position: 0, sampledAt: 5, rate: 0)
        XCTAssertTrue(nothingLoaded.differsMeaningfully(from: .empty), "the first reading always goes out")
        XCTAssertFalse(MusicSnapshot(track: nil, state: .stopped, position: 0, sampledAt: 9, rate: 0)
                        .differsMeaningfully(from: nothingLoaded))
    }

    // MARK: Artwork size (log line)

    func testPixelSizeOfPNGAndJPEGHeaders() {
        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]
        png += [0, 0, 2, 128, 0, 0, 1, 224, 8, 6, 0, 0, 0] // 640 × 480
        XCTAssertEqual(MusicArtworkInfo.pixelSizeText(of: Data(png)), "640x480")
        // SOI, APP0 (JFIF, 16 bytes), DQT stub, SOF0 640 × 600.
        var jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10] + Array("JFIF\0".utf8) + [1, 1, 0, 0, 1, 0, 1, 0, 0]
        jpeg += [0xFF, 0xDB, 0x00, 0x04, 0x00, 0x00]
        jpeg += [0xFF, 0xC0, 0x00, 0x11, 0x08, 0x02, 0x58, 0x02, 0x80, 0x03, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]
        XCTAssertEqual(MusicArtworkInfo.pixelSize(of: Data(jpeg))?.width, 640)
        XCTAssertEqual(MusicArtworkInfo.pixelSize(of: Data(jpeg))?.height, 600)
        // Progressive (SOF2) after padding bytes.
        let progressive: [UInt8] = [0xFF, 0xD8, 0xFF, 0xFF, 0xC2, 0x00, 0x11, 0x08, 0x00, 0x40, 0x00, 0x30, 3]
        XCTAssertEqual(MusicArtworkInfo.pixelSizeText(of: Data(progressive)), "48x64")
        XCTAssertEqual(MusicArtworkInfo.pixelSizeText(of: Data([1, 2, 3])), "?")
        XCTAssertEqual(MusicArtworkInfo.pixelSizeText(of: Data([0xFF, 0xD8, 0xFF, 0xD9])), "?", "no frame header")
        XCTAssertEqual(MusicArtworkInfo.pixelSizeText(of: Data([0xFF, 0xD8, 0xFF, 0xC4, 0x00, 0x00])), "?", "bad length")
        XCTAssertNil(MusicArtworkInfo.pixelSize(of: Data(png.prefix(20))), "truncated PNG")
    }
}
