// SPDX-License-Identifier: AGPL-3.0-or-later
// In-memory Music app for unit tests, SwiftUI previews, the demo mode (`-demoSeed`) and the E2E run
// (`-e2eMusic`): a small queue the commands walk through, playback simulated on the injected clock.
// ADDITION (music) — the port is `MusicPlaying` (Contract/AppPorts.swift).
// `otherAudioLag` (opt-in, review fix F1) models what iOS reports: `isOtherAudioPlaying` counts the
// Music app's own audio while it plays and for a moment after a pause. The default leaves the flag
// to `simulate(otherAudioPlaying:)` alone, so the demo and the E2E run stay deterministic.

import Foundation
import OpenCfMotoCore

@MainActor
public final class PreviewMusic: MusicPlaying {
    public var isAvailable = true
    public var authorization: MusicAuthorizationState
    /// What `requestAuthorization()` answers while undetermined.
    public var answerToRequest: MusicAuthorizationState = .authorized
    public private(set) var snapshot: MusicSnapshot = .empty
    public var onChange: ((MusicSnapshot) -> Void)?
    public private(set) var isObserving = false
    public private(set) var authorizationRequests = 0
    /// Every command, in order: "play", "pause", "next", "previous", "beginning".
    public private(set) var commands: [String] = []
    /// `refresh()` calls.
    public private(set) var refreshes = 0
    /// Artwork per track id (what `artwork(trackID:maxPixelSize:)` returns for the current song).
    public var artworks: [String: MusicArtwork] = [:]
    /// Per track id: how many more `artwork` calls answer nil before the stored artwork is returned
    /// (tests of the retry schedule).
    public var artworkMisses: [String: Int] = [:]
    /// Every `artwork` call: the track id asked for.
    public private(set) var artworkRequests: [String] = []
    /// The queue; `index` is the loaded song.
    public var queue: [MusicTrack]
    public private(set) var index = 0
    public private(set) var isPlaying: Bool
    /// Another app's audio (`simulate(otherAudioPlaying:)`; Music starting stops it). The snapshot's
    /// `otherAudioPlaying` is this, or, with `otherAudioLag`, the Music app's own audio too.
    public private(set) var otherAudioPlaying = false
    /// The iOS model (F1, opt-in): `isOtherAudioPlaying` is also true while the Music app plays and
    /// for this many seconds after it stopped (its fade-out iOS still counts). Re-evaluated on every
    /// reading — commands, `simulate`, `refresh`. nil = only `otherAudioPlaying`.
    public var otherAudioLag: TimeInterval?
    /// When the Music app last stopped playing (nil: playing, or silent since the start).
    private var stoppedPlayingAt: TimeInterval?
    private var position: TimeInterval
    private var positionAt: TimeInterval
    private let clock: MonotonicClock

    public init(clock: MonotonicClock = SystemMonotonicClock(), queue: [MusicTrack] = [], playing: Bool = false,
                position: TimeInterval = 0, authorization: MusicAuthorizationState = .authorized) {
        self.clock = clock
        self.queue = queue
        self.isPlaying = playing
        self.position = position
        self.authorization = authorization
        positionAt = clock.now()
    }

    public func requestAuthorization() async -> MusicAuthorizationState {
        authorizationRequests += 1
        if authorization == .notDetermined { authorization = answerToRequest }
        return authorization
    }

    public func startObserving() {
        guard authorization == .authorized, !isObserving else { return }
        isObserving = true
        publish()
    }

    public func stopObserving() {
        isObserving = false
        snapshot = .empty
    }

    public func refresh() {
        refreshes += 1
        publish()
    }

    public func artwork(trackID: String, maxPixelSize: Int) async -> MusicArtwork? {
        artworkRequests.append(trackID)
        guard queue.indices.contains(index), queue[index].id == trackID else { return nil }
        if let misses = artworkMisses[trackID], misses > 0 {
            artworkMisses[trackID] = misses - 1
            return nil
        }
        return artworks[trackID]
    }

    public func play() { commands.append("play"); settle(); setPlaying(true); otherAudioPlaying = false; publish() }
    public func pause() { commands.append("pause"); settle(); setPlaying(false); publish() }
    public func skipToNext() { commands.append("next"); move(1) }
    public func skipToPrevious() { commands.append("previous"); move(-1) }
    public func skipToBeginning() {
        commands.append("beginning")
        position = 0
        positionAt = clock.now()
        publish()
    }

    /// Tests / demo: jump to a state as if the rider used the Music app or another app (fires
    /// `onChange` while observing).
    public func simulate(index: Int? = nil, playing: Bool? = nil, position: TimeInterval? = nil,
                         otherAudioPlaying: Bool? = nil) {
        settle()
        if let index, queue.indices.contains(index) {
            self.index = index
            self.position = 0
        }
        if let playing { setPlaying(playing) }
        if let position { self.position = position }
        if let otherAudioPlaying { self.otherAudioPlaying = otherAudioPlaying }
        positionAt = clock.now()
        publish()
    }

    private func settle() {
        let now = clock.now()
        if isPlaying { position += max(0, now - positionAt) }
        positionAt = now
    }

    private func setPlaying(_ playing: Bool) {
        if isPlaying, !playing { stoppedPlayingAt = clock.now() }
        if playing { stoppedPlayingAt = nil }
        isPlaying = playing
    }

    /// What `AVAudioSession.isOtherAudioPlaying` would say now.
    private var reportedOtherAudio: Bool {
        if otherAudioPlaying { return true }
        guard let lag = otherAudioLag else { return false }
        if isPlaying { return true }
        guard let stopped = stoppedPlayingAt else { return false }
        return clock.now() - stopped < lag
    }

    private func move(_ delta: Int) {
        guard !queue.isEmpty else { return }
        index = ((index + delta) % queue.count + queue.count) % queue.count
        position = 0
        positionAt = clock.now()
        publish()
    }

    private func publish() {
        guard isObserving else { return }
        let track = queue.indices.contains(index) ? queue[index] : nil
        let state: MusicPlaybackState = track == nil ? .stopped : (isPlaying ? .playing : .paused)
        let next = MusicSnapshot(track: track, state: state, position: position, sampledAt: positionAt,
                                 rate: isPlaying ? 1 : 0, otherAudioPlaying: reportedOtherAudio)
        guard next != snapshot else { return } // like the adapter: no onChange for an identical reading
        snapshot = next
        onChange?(next)
    }
}
