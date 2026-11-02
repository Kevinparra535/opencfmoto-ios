// SPDX-License-Identifier: AGPL-3.0-or-later
// Apple Music on the dash (iOS addition, no Android counterpart): the platform-neutral rules the iOS
// adapter (App/Sources/Services/MusicAdapter.swift) and MusicModel share, unit-tested on Linux.
// - `MusicTrackID`: a stable id per song that is safe inside the dash image id "music.art.<id>", and
//   `logToken(_:)`, the only form of it a log line may carry (review fix F4).
// - `MusicSnapshot.differsMeaningfully(from:)`: what counts as a change worth an `onChange` (song,
//   state, other audio, rate, a seek or a drift ≥ 1.5 s) — never the steady advance of the position.
// - `MusicEntryMatch`: is MusicKit's playing entry the song MediaPlayer reports (F5)?
// - `MusicArtworkInfo.pixelSize(of:)`: width × height of PNG / JPEG bytes for the artwork log line,
//   without ImageIO.
// Privacy: none of these helpers logs anything; titles / artists / albums only feed the hash.

import Foundation
import OpenCfMotoCore

/// Stable per-song ids (only `[A-Za-z0-9]`, so "music.art.<id>" stays a valid dash image id).
public enum MusicTrackID {
    /// Longest store id accepted as an id component (catalog ids are ~10 digits).
    static let maxStoreIDLength = 32

    /// "p" + persistentID (lower-case hex) when ≠ 0; else "s" + storeID when it is digits-only (and
    /// not all zeros: "0" means "only in the library"); else "h" + 16 hex digits of FNV-1a 64 over
    /// the UTF-8 of "title|artist|album|<duration rounded to whole seconds>".
    public static func make(persistentID: UInt64, storeID: String?, title: String, artist: String, album: String,
                            duration: TimeInterval) -> String {
        if persistentID != 0 { return "p" + String(persistentID, radix: 16, uppercase: false) }
        if let store = normalizedStoreID(storeID) { return "s" + store }
        let key = "\(title)|\(artist)|\(album)|\(wholeSeconds(duration))"
        return "h" + hex16(fnv1a64(Array(key.utf8)))
    }

    /// The catalog id when `raw` is a usable one: ASCII digits only, not all zeros, ≤ 32 digits.
    /// MediaPlayer reports "0" (or "") for songs that only exist in the rider's library.
    public static func normalizedStoreID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.count <= maxStoreIDLength,
              s.unicodeScalars.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              s.unicodeScalars.contains(where: { $0 != "0" }) else { return nil }
        return s
    }

    /// What a log line may say about a song (F4): its kind letter ("p" library item, "s" catalog id,
    /// "h" hash) + 8 hex digits of FNV-1a 64 over (a random per-process salt ‖ the id). Equal within
    /// one run of the app, so a log still shows "the same song again" — but a raw id never reaches a
    /// log or a shared problem report: a catalog id ("s" + ~10 digits) names the song on
    /// music.apple.com, and an unsalted hash of one is brute-forced in seconds. The salt is never
    /// stored, so the tokens of two runs cannot be matched either.
    public static func logToken(_ id: String) -> String { logToken(id, salt: logSalt) }

    /// `logToken(_:)` with an explicit salt (tests).
    static func logToken(_ id: String, salt: UInt64) -> String {
        let kind = id.first.map(String.init) ?? "-"
        let saltBytes = (0 ..< 8).map { UInt8(truncatingIfNeeded: salt >> (8 * $0)) }
        return kind + String(hex16(fnv1a64(saltBytes + Array(id.utf8))).prefix(8))
    }

    /// Random once per process, never persisted (F4: a known salt would make the ~10-digit catalog
    /// ids brute-forceable again).
    static let logSalt = UInt64.random(in: .min ... .max)

    /// FNV-1a 64-bit.
    static func fnv1a64(_ bytes: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in bytes {
            hash ^= UInt64(b)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    static func hex16(_ v: UInt64) -> String {
        let s = String(v, radix: 16, uppercase: false)
        return String(repeating: "0", count: max(0, 16 - s.count)) + s
    }

    /// Whole seconds (half up), 0 for non-finite or negative values, saturated (never traps).
    static func wholeSeconds(_ t: TimeInterval) -> Int {
        guard t.isFinite, t > 0 else { return 0 }
        let r = (t + 0.5).rounded(.down)
        return r >= Double(Int32.max) ? Int(Int32.max) : Int(r)
    }
}

public extension MusicSnapshot {
    /// A position difference from the extrapolation at least this large is a seek (or a drift
    /// the dash must follow); smaller ones are sampling jitter.
    static let driftTolerance: TimeInterval = 1.5

    /// The position at monotonic time `t`: while playing, `position + (t − sampledAt) × rate` (never
    /// below `position`); otherwise frozen at `position`. Non-finite inputs never trap.
    func extrapolatedPosition(at t: TimeInterval) -> TimeInterval {
        let base = position.isFinite ? position : 0
        guard state == .playing, t.isFinite, sampledAt.isFinite, rate.isFinite else { return base }
        let p = base + (t - sampledAt) * rate
        return p.isFinite ? max(base, p) : base
    }

    /// True when the dash must hear about this reading compared with `old`: the song (id or any
    /// metadata) changed, the state, `otherAudioPlaying` or the rate (by more than 0.01) changed, or
    /// the position moved ≥ `driftTolerance` away from `old` extrapolated to this sample's time (a
    /// seek, a restart, a stall). `.empty` against anything else is always a change.
    func differsMeaningfully(from old: MusicSnapshot) -> Bool {
        let isEmpty = self == .empty, wasEmpty = old == .empty
        if isEmpty || wasEmpty { return isEmpty != wasEmpty }
        if track != old.track || state != old.state || otherAudioPlaying != old.otherAudioPlaying { return true }
        let r0 = old.rate.isFinite ? old.rate : 0, r1 = rate.isFinite ? rate : 0
        if abs(r1 - r0) > 0.01 { return true }
        let expected = old.extrapolatedPosition(at: sampledAt)
        let now = position.isFinite ? position : 0
        return abs(now - expected) >= Self.driftTolerance
    }
}

/// F5: is MusicKit's playing entry (`SystemMusicPlayer.shared.queue.currentEntry`) the song MediaPlayer
/// reports? The two update independently, so right after a song change the entry can still be the
/// previous song — and two songs in a row can share a title (covers, "Intro" tracks). The entry's
/// artwork is used only when the titles AND the artists match, and the catalog ids too when both
/// sides have one; otherwise the song keeps the placeholder (never another song's cover).
public enum MusicEntryMatch {
    /// - `entryTitle`, `entrySubtitle`: the queue entry's.
    /// - `songArtist`, `songID`: the entry's `Song` (`artistName`, `id.rawValue`); nil when the entry
    ///   holds no song (a music video, a station).
    /// - `itemTitle`, `itemArtist`, `itemStoreID`: MediaPlayer's item (`title`, `artist ?? albumArtist`,
    ///   `playbackStoreID`).
    public static func matches(entryTitle: String, entrySubtitle: String?, songArtist: String?, songID: String?,
                               itemTitle: String, itemArtist: String, itemStoreID: String?) -> Bool {
        let title = normalized(itemTitle)
        guard !title.isEmpty, normalized(entryTitle) == title else { return false }
        let artist = normalized(itemArtist)
        if !artist.isEmpty { // only when MediaPlayer names no artist do the title (and ids) decide alone
            if let songArtist {
                guard normalized(songArtist) == artist else { return false }
            } else {
                guard let subtitle = entrySubtitle, normalized(subtitle).contains(artist) else { return false }
            }
        }
        // Catalog ids only: a song added from Apple Music has a library id ("i.…") in MusicKit and its
        // catalog `playbackStoreID` in MediaPlayer — no reason to reject it (it would lose its cover).
        if let songID, isCatalogID(songID), let store = MusicTrackID.normalizedStoreID(itemStoreID) {
            return songID == store
        }
        return true
    }

    /// Case-, diacritic- and surrounding-whitespace-insensitive.
    public static func normalized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// A MusicKit catalog id: ASCII digits only (library ids look like "i.…").
    static func isCatalogID(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy { $0 >= "0" && $0 <= "9" }
    }
}

/// Facts about encoded artwork bytes, for the log line only.
public enum MusicArtworkInfo {
    /// Width × height of PNG (IHDR) or JPEG (first SOF marker) bytes; nil for anything else.
    public static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        let b = [UInt8](data.prefix(256 * 1024))
        if b.count >= 24, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47,
           b[12] == 0x49, b[13] == 0x48, b[14] == 0x44, b[15] == 0x52 { // "\x89PNG" … "IHDR"
            let w = be32(b, 16), h = be32(b, 20)
            return w > 0 && h > 0 ? (w, h) : nil
        }
        guard b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        while i + 3 < b.count {
            guard b[i] == 0xFF else { return nil }
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue } // fill byte
            if marker == 0xD8 || marker == 0x01 || (0xD0 ... 0xD7).contains(marker) { i += 2; continue }
            if marker == 0xD9 || marker == 0xDA { return nil } // end / scan data before any frame header
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length >= 2 else { return nil }
            let isFrame = (0xC0 ... 0xCF).contains(marker) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
            if isFrame {
                guard i + 8 < b.count else { return nil }
                let h = Int(b[i + 5]) << 8 | Int(b[i + 6])
                let w = Int(b[i + 7]) << 8 | Int(b[i + 8])
                return w > 0 && h > 0 ? (w, h) : nil
            }
            i += 2 + length
        }
        return nil
    }

    /// "640x640", or "?" when the size cannot be read.
    public static func pixelSizeText(of data: Data) -> String {
        guard let s = pixelSize(of: data) else { return "?" }
        return "\(s.width)x\(s.height)"
    }

    private static func be32(_ b: [UInt8], _ at: Int) -> Int {
        Int(b[at]) << 24 | Int(b[at + 1]) << 16 | Int(b[at + 2]) << 8 | Int(b[at + 3])
    }
}
