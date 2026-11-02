// SPDX-License-Identifier: AGPL-3.0-or-later
// Apple Music "now playing" for the dash UI (iOS addition, no Android counterpart). The app fills
// `DashModel.music` from the system music player; the controller draws the now-playing tile, the
// menu entry and the Music sheet and reports `DashIntent.openMusic / musicPlayPause / musicNext /
// musicPrevious`. The position is a SAMPLE (`position` at `positionAt`) that the scene extrapolates
// to the frame time while playing, so the app does not update the model every frame.

import Foundation

/// What Apple Music is playing, as the dash shows it.
public struct DashNowPlaying: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        case playing
        /// Paused, stopped with a loaded song, interrupted or seeking: the position stands still.
        case paused
    }

    /// Song title ("" → the localized "Unknown song").
    public var title: String
    /// "" = no artist line.
    public var artist: String
    /// "" = no album line.
    public var album: String
    /// Raster image registered with the renderer (`DashDrawCommand.image`); nil = placeholder.
    public var artworkId: String?
    public var state: State
    /// Song length in seconds; ≤ 0 / non-finite = unknown (no progress bar, no times).
    public var duration: TimeInterval
    /// Seconds into the song at `positionAt`.
    public var position: TimeInterval
    /// Monotonic time of the sample — the clock of `DashUIController`'s `now` (AppServices.clock).
    public var positionAt: TimeInterval
    /// Playback rate while playing (1 = normal); ignored while paused.
    public var rate: Double

    public init(title: String, artist: String = "", album: String = "", artworkId: String? = nil,
                state: State = .playing, duration: TimeInterval = 0, position: TimeInterval = 0,
                positionAt: TimeInterval = 0, rate: Double = 1) {
        self.title = title; self.artist = artist; self.album = album; self.artworkId = artworkId
        self.state = state; self.duration = duration; self.position = position
        self.positionAt = positionAt; self.rate = rate
    }

    /// A usable song length (finite, > 0).
    public var knownDuration: TimeInterval? { duration.isFinite && duration > 0 ? duration : nil }

    /// The position at `now`: extrapolated while playing (rate clamped to 0…4), frozen while
    /// paused, clamped to 0…duration (0…∞ without a duration). Non-finite inputs never trap → 0.
    public func position(at now: TimeInterval) -> TimeInterval {
        var p = position.isFinite ? max(0, position) : 0
        if state == .playing, now.isFinite, positionAt.isFinite, rate.isFinite {
            p += max(0, now - positionAt) * min(max(rate, 0), 4)
        }
        if let d = knownDuration { p = min(p, d) }
        return p.isFinite ? p : 0
    }

    /// Whole seconds played at `now` (what the elapsed label prints).
    public func elapsedSeconds(at now: TimeInterval) -> Int { DashFormat.roundHalfUp((position(at: now)).rounded(.down)) }

    /// Progress 0…1 at `now`; nil without a known duration.
    public func fraction(at now: TimeInterval) -> Double? {
        guard let d = knownDuration else { return nil }
        return min(1, max(0, position(at: now) / d))
    }
}

/// Times printed by the Music sheet (POSIX digits, no locale).
public enum DashMusicFormat {
    /// "0:07", "3:51", "1:02:05" for whole seconds (negative values print as 0).
    public static func time(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// "-3:51": time left at `now` = the whole seconds of the song length minus the whole seconds
    /// played, so the elapsed and remaining labels change together (one re-render per second) and
    /// always add up to ⌊length⌋. The position is clamped to the length, so the label reaches "-0:00"
    /// at the end even for a fractional length (245.6 s: "-4:05" … "-0:00"; the rounded length would
    /// start at "-4:06" and stop at "-0:01" — fix F8).
    public static func remaining(_ music: DashNowPlaying, at now: TimeInterval) -> String? {
        guard let d = music.knownDuration else { return nil }
        let left = max(0, DashFormat.roundHalfUp(d.rounded(.down)) - music.elapsedSeconds(at: now))
        return "-" + time(left)
    }
}
