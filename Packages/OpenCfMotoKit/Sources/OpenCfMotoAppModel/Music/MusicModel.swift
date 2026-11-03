// SPDX-License-Identifier: AGPL-3.0-or-later
// Apple Music on the dash (iOS addition, no Android counterpart; scratchpad contract "music" §3.1,
// §8.2, §9): follows the system Music app through the `MusicPlaying` port while the own dash UI is
// live, turns its readings into `DashModel.music` (`dashNowPlaying`), loads the song's artwork into
// the renderer (`DashProjecting.setDashImage`) and performs the dash's ⏮ ⏯ ⏭.
//
// - Opt-in: Settings ▸ "Show Apple Music on the dash" (`ios.dash_music`, default off). Turning it on
//   is the only place the media-library permission is requested (an explicit phone action, never
//   during a ride). Nothing touches the system player before `.authorized`.
// - Observing = dash UI live (session / phone preview / Ride Mode, from RideModel) ∧ enabled ∧
//   authorized. The port reports changes only (song, state, other audio, seeks / drift ≥ 1.5 s);
//   the dash extrapolates the progress itself, so the model does not change every second.
// - A song the Music app is not playing hides while another app's audio plays (contract D7) — only
//   once that outlasted `otherAudioGrace` (review fix F1): right after a pause iOS still counts the
//   Music app's own fading audio as "other audio", and one short sound is no reason to close the
//   rider's Music sheet. A song already silent, or other audio already playing, when observing
//   starts counts as "long ago": Spotify at dash start still hides a paused song at once.
// - Artwork per song: placeholder at once, then the in-memory cache (4 songs) or attempts at 0, +1,
//   +3 and +10 s after the song became current; an image is registered BEFORE its id is published
//   and images no longer referenced are removed AFTER the next dash model went out.
// - Handlebar hand-over (contract §7): `onPlaybackStarted` (→ toast, sheet closed) and
//   `onPlaybackPaused` (→ ControlsModel re-claims the buttons) fire on transitions only, never on the
//   first reading after observing starts.
// - Privacy: logs carry states, artwork sources and keyed per-run song tokens
//   (`MusicTrackID.logToken`, F4) — never titles, artists, albums, track / store / image ids or URLs.

import Foundation
import Observation
import OpenCfMotoCore

/// A transport button of the dash's Music sheet.
public enum MusicCommand: String, Sendable, Equatable {
    case playPause
    case next
    case previous
}

@MainActor
@Observable
public final class MusicModel {
    @ObservationIgnored let core: AppCore

    /// Settings ▸ "Show Apple Music on the dash" (KeyValueStore "ios.dash_music", default false).
    public private(set) var isEnabled: Bool
    /// The media-library permission ("Media & Apple Music").
    public private(set) var authorization: MusicAuthorizationState
    /// A system music player exists (false on the null port).
    public var isAvailable: Bool { core.services.music.isAvailable }
    /// Latest reading of the Music app (`.empty` while not observing).
    public private(set) var snapshot: MusicSnapshot = .empty
    /// The dash shows music right now (tile / menu entry) — for `-uiDashSheet` and the E2E status.
    public var isShownOnDash: Bool { dashNowPlaying != nil }
    /// Last artwork outcome: "mp", "musickit", "none" or nil (no song yet).
    public private(set) var lastArtworkSource: String?

    // MARK: Internal (RideModel / AppModel / tests)

    static let enabledKey = "ios.dash_music"
    static let artworkPixels = 640
    /// Songs whose encoded artwork stays in memory (A → B → A shows A's cover at once).
    static let artworkCacheCapacity = 4
    /// Artwork attempts, in seconds after the song became current (tests shorten them).
    @ObservationIgnored var artworkAttemptDelays: [TimeInterval] = [0, 1, 3, 10]
    /// Re-reads of the player after a dash command, in seconds after it.
    @ObservationIgnored var refreshDelaysAfterCommand: [TimeInterval] = [0.3, 1.0]
    /// How long an image no longer referenced stays registered after the model change that dropped
    /// it (the coalesced dash model update and the frame being rendered still name it).
    @ObservationIgnored var imageCleanupDelay: TimeInterval = 0.5
    /// The waits of the artwork retries and of the re-reads after a command (tests inject one that
    /// records the duration and returns at once).
    @ObservationIgnored var sleeper: @MainActor (TimeInterval) async -> Void = { await sleepSeconds($0) }
    /// F1: a song the Music app stopped making sound for is hidden for another app's audio only once
    /// that lasted this long, counted from the later of "went silent" and "other audio started".
    static let otherAudioGrace: TimeInterval = 3
    /// F1: the wait until the end of the grace — separate from `sleeper`, so the waits tests record
    /// there stay the artwork retries and the command re-reads (tests end this one by hand).
    @ObservationIgnored var graceSleeper: @MainActor (TimeInterval) async -> Void = { await sleepSeconds($0) }

    /// The dash model must be rebuilt (RideModel.setNeedsModelUpdate coalesces).
    @ObservationIgnored var onDashChange: (() -> Void)?
    /// Contract R2: the Music app started playing (a transition; never the first reading).
    @ObservationIgnored var onPlaybackStarted: (() -> Void)?
    /// Contract R3: the Music app went from playing to paused / stopped (not interrupted, not seeking).
    @ObservationIgnored var onPlaybackPaused: (() -> Void)?

    /// The port is being followed (dash live ∧ enabled ∧ authorized).
    @ObservationIgnored private(set) var isObserving = false
    @ObservationIgnored private var dashActive = false
    /// false until the first reading after `startObserving` was taken (no R2 / R3 for it).
    @ObservationIgnored private var transitionsArmed = false
    /// The last state that was not transient (seeking / interrupted): R2 / R3 compare with it, so
    /// "playing → seeking → playing" or "playing → interrupted → playing" is no hand-over, while
    /// "playing → interrupted → paused" is a pause. nil = unknown (first reading was transient).
    @ObservationIgnored private var settledState: MusicPlaybackState?
    @ObservationIgnored private var artworkTrackID: String?
    @ObservationIgnored private var artworkGeneration: UInt64 = 0
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// The image published on the dash and the song it belongs to.
    @ObservationIgnored private var published: (trackID: String, imageID: String)?
    /// Every image id handed to the renderer and not removed yet.
    @ObservationIgnored private(set) var registeredImageIDs: Set<String> = []
    /// Most recent first.
    @ObservationIgnored private var artworkCache: [(trackID: String, artwork: MusicArtwork)] = []
    @ObservationIgnored private var cleanupScheduled = false
    /// F1: when the Music app was seen going from audible to silent; nil while audible, or silent
    /// since before observing started ("long ago").
    @ObservationIgnored private var silentSince: TimeInterval?
    /// F1: when another app's audio was seen starting; nil while there is none, or it already played
    /// when observing started ("long ago").
    @ObservationIgnored private var otherSince: TimeInterval?
    /// F1: the one re-evaluation at the end of the grace (every reading reschedules or cancels it).
    @ObservationIgnored private var graceTask: Task<Void, Never>?

    public init(core: AppCore) {
        self.core = core
        let port = core.services.music
        isEnabled = core.services.keyValueStore.bool(forKey: Self.enabledKey) ?? false
        authorization = port.authorization
        port.onChange = { [weak self] reading in self?.portChanged(reading) }
    }

    // MARK: - Phone (Settings)

    /// Persists the choice. Turning it ON asks for the media-library permission when it was never
    /// asked (an explicit phone action), then follows the Music app while the dash UI is live.
    public func setEnabled(_ on: Bool) async {
        core.services.keyValueStore.set(on, forKey: Self.enabledKey)
        isEnabled = on
        if on {
            let port = core.services.music
            if port.authorization == .notDetermined {
                updateAuthorization(await port.requestAuthorization())
            } else {
                updateAuthorization(port.authorization)
            }
            Log.i("MUSIC", "dash music on (authorization=\(authorization.rawValue))")
        } else {
            artworkCache.removeAll()
            Log.i("MUSIC", "dash music off")
        }
        syncObserving()
    }

    /// Re-reads the permission (the rider may have changed it in iOS Settings); also on app active.
    public func refreshAuthorization() {
        updateAuthorization(core.services.music.authorization)
        syncObserving()
    }

    /// Opens OpenCfMoto's page in the Settings app ("Media & Apple Music" lives there).
    public func openAppSettings() {
        core.services.system.openAppSettings()
    }

    // MARK: - Dash (RideModel / AppModel)

    /// `DashModel.music` (contract §3.1): nil unless enabled, authorized, observing and a song is
    /// loaded — and a song the Music app is not playing is hidden once another app's audio played
    /// through the F1 grace (it would be stale: Spotify plays).
    var dashNowPlaying: DashNowPlaying? {
        guard isEnabled, authorization == .authorized, isObserving, let track = snapshot.track else { return nil }
        guard !isHiddenForOtherAudio(at: core.services.clock.now()) else { return nil }
        let playing = snapshot.state == .playing
        let artworkId = published.flatMap { $0.trackID == track.id ? $0.imageID : nil }
        return DashNowPlaying(title: track.title, artist: track.artist, album: track.album, artworkId: artworkId,
                              state: playing ? .playing : .paused, duration: track.duration,
                              position: snapshot.position, positionAt: snapshot.sampledAt,
                              rate: playing ? snapshot.rate : 0)
    }

    /// D7 with the F1 grace: the Music app makes no sound, another app's does, and that has lasted
    /// `otherAudioGrace` since the later of "went silent" and "other audio started".
    private func isHiddenForOtherAudio(at now: TimeInterval) -> Bool {
        guard !Self.isAudible(snapshot.state), snapshot.otherAudioPlaying else { return false }
        return now - graceAnchor >= Self.otherAudioGrace
    }

    /// F1: the later of `silentSince` and `otherSince`; −∞ when both are "long ago".
    private var graceAnchor: TimeInterval { max(silentSince ?? -.infinity, otherSince ?? -.infinity) }

    /// RideModel: the own dash UI is live (Connect session in own-UI mode, the phone Dash preview /
    /// Map hub, Ride Mode).
    func setDashActive(_ active: Bool) {
        guard active != dashActive else { return }
        dashActive = active
        syncObserving()
    }

    /// `.active` → the permission and the player are read again.
    func scenePhaseChanged(_ phase: AppScenePhase) {
        guard phase == .active else { return }
        refreshAuthorization()
        if isObserving { core.services.music.refresh() }
    }

    /// A dash ⏮ ⏯ ⏭ (or the phone acting for it). The state comes back through the port (re-read
    /// at `refreshDelaysAfterCommand`); nothing is changed optimistically.
    func perform(_ command: MusicCommand, fromDash: Bool) {
        guard isObserving else {
            Log.d("MUSIC", "command \(command.rawValue) ignored (not following Apple Music)")
            return
        }
        let action: TransportAction
        switch command {
        case .playPause:
            action = snapshot.state == .playing ? .pause : .play
        case .next:
            action = .next
        case .previous:
            let now = core.services.clock.now()
            let position = dashNowPlaying?.position(at: now) ?? snapshot.extrapolatedPosition(at: now)
            action = position > 3 ? .beginning : .previous
        }
        Log.i("MUSIC", "command \(action.rawValue) (from \(fromDash ? "dash" : "phone"))")
        let port = core.services.music
        switch action {
        case .play: port.play()
        case .pause: port.pause()
        case .next: port.skipToNext()
        case .previous: port.skipToPrevious()
        case .beginning: port.skipToBeginning()
        }
        scheduleRefreshes()
    }

    /// What a dash command does to the player (log names of contract §9).
    private enum TransportAction: String {
        case play, pause, next, previous, beginning
    }

    /// Problem report line `music=on/authorized/playing/art=mp`.
    var diagnostics: String {
        "\(isEnabled ? "on" : "off")/\(authorization.rawValue)/\(snapshot.state.rawValue)/art=\(lastArtworkSource ?? "-")"
    }

    /// Dash image id of a song's artwork.
    nonisolated static func imageID(forTrack id: String) -> String { "music.art." + id }

    // MARK: - Observing

    private func updateAuthorization(_ new: MusicAuthorizationState) {
        guard new != authorization else { return }
        Log.i("MUSIC", "authorization \(authorization.rawValue) -> \(new.rawValue)")
        authorization = new
    }

    private func syncObserving() {
        let wanted = dashActive && isEnabled && authorization == .authorized
        guard wanted != isObserving else { return }
        let port = core.services.music
        resetGrace() // F1: whatever was seen before is "long ago" for the next observation
        if wanted {
            isObserving = true
            transitionsArmed = false
            settledState = nil
            Log.i("MUSIC", "observing on (poll 2s/5s)")
            port.startObserving()
            portChanged(port.snapshot) // when the port reported nothing (an empty player)
        } else {
            isObserving = false
            port.stopObserving()
            cancelArtwork()
            refreshTask?.cancel()
            refreshTask = nil
            artworkTrackID = nil
            published = nil
            if snapshot != .empty { snapshot = .empty }
            Log.i("MUSIC", "observing off")
            onDashChange?()
            scheduleImageCleanup()
        }
    }

    private func portChanged(_ reading: MusicSnapshot) {
        guard isObserving else { return }
        let old = snapshot
        let first = !transitionsArmed
        guard reading != old || first else { return }
        transitionsArmed = true
        snapshot = reading
        noteAudio(reading, old: old, first: first)
        // Also when only `other` flips (F1): the field log then shows how long iOS still reported
        // the Music app's own audio after a pause.
        if first || reading.track?.id != old.track?.id || reading.state != old.state
            || reading.otherAudioPlaying != old.otherAudioPlaying {
            let token = reading.track.map { MusicTrackID.logToken($0.id) } ?? "none"
            Log.i("MUSIC", "state \(reading.state.rawValue) track=\(token) other=\(reading.otherAudioPlaying ? 1 : 0)")
        }
        let songChanged = reading.track?.id != artworkTrackID
        if songChanged { startArtwork(for: reading.track) }
        let before = settledState
        if !Self.isTransient(reading.state) { settledState = reading.state }
        if !first, let before {
            if before != .playing, reading.state == .playing {
                onPlaybackStarted?()
            } else if before == .playing, reading.state == .paused || reading.state == .stopped {
                onPlaybackPaused?()
            }
        }
        onDashChange?()
        if songChanged { scheduleImageCleanup() } // the previous song's image, once the model moved on
    }

    // MARK: - Other audio grace (F1)

    /// The two times the grace counts from. The first reading after observing starts sets neither:
    /// a song already silent, or other audio already playing, counts as "long ago" — so a paused song
    /// still hides at once when the dash goes live while Spotify plays.
    private func noteAudio(_ reading: MusicSnapshot, old: MusicSnapshot, first: Bool) {
        let now = core.services.clock.now()
        if Self.isAudible(reading.state) {
            silentSince = nil
        } else if !first, Self.isAudible(old.state) {
            silentSince = now
        }
        if !reading.otherAudioPlaying {
            otherSince = nil
        } else if !first, !old.otherAudioPlaying {
            otherSince = now
        }
        scheduleGraceEnd()
    }

    /// While a song is shown only thanks to the grace: ONE re-evaluation at its end. The port reports
    /// changes only, so other audio that simply goes on would never hide the song without it: read the
    /// player again, then rebuild the dash model.
    private func scheduleGraceEnd() {
        graceTask?.cancel()
        graceTask = nil
        guard isObserving, snapshot.track != nil, !Self.isAudible(snapshot.state), snapshot.otherAudioPlaying else { return }
        let wait = graceAnchor + Self.otherAudioGrace - core.services.clock.now()
        guard wait > 0 else { return } // "long ago" (−∞) or over: already hidden
        let sleep = graceSleeper
        graceTask = Task { @MainActor [weak self] in
            await sleep(wait)
            guard !Task.isCancelled, let self, self.isObserving else { return }
            self.graceTask = nil
            self.core.services.music.refresh() // a reading that changed reschedules or cancels by itself
            self.onDashChange?()
            if self.isHiddenForOtherAudio(at: self.core.services.clock.now()) {
                Log.i("MUSIC", "other audio for \(Int(Self.otherAudioGrace)) s: song hidden")
            } else if self.graceTask == nil {
                self.scheduleGraceEnd() // woke before the end (the sleep's clock is not the uptime clock)
            }
        }
    }

    /// Observing turned on or off: nothing seen before counts.
    private func resetGrace() {
        graceTask?.cancel()
        graceTask = nil
        silentSince = nil
        otherSince = nil
    }

    private func scheduleRefreshes() {
        refreshTask?.cancel()
        let delays = refreshDelaysAfterCommand
        guard !delays.isEmpty else { return }
        let clock = core.services.clock
        let start = clock.now()
        let sleep = sleeper
        refreshTask = Task { @MainActor [weak self] in
            for delay in delays {
                guard !Task.isCancelled else { return }
                let wait = start + delay - clock.now()
                if wait > 0 { await sleep(wait) }
                guard !Task.isCancelled, let self, self.isObserving else { return }
                self.core.services.music.refresh()
            }
        }
    }

    // MARK: - Artwork

    private func cancelArtwork() {
        artworkTask?.cancel()
        artworkTask = nil
        artworkGeneration &+= 1
    }

    /// A new song became current: the placeholder shows until its artwork is registered.
    private func startArtwork(for track: MusicTrack?) {
        cancelArtwork()
        artworkTrackID = track?.id
        guard let track else { return }
        let generation = artworkGeneration
        let startedAt = core.services.clock.now()
        if let cached = cachedArtwork(track.id) {
            publish(cached, track: track, attempt: 0, startedAt: startedAt)
            return
        }
        let delays = artworkAttemptDelays
        let port = core.services.music
        let clock = core.services.clock
        let sleep = sleeper
        artworkTask = Task { @MainActor [weak self] in
            for (index, delay) in delays.enumerated() {
                guard !Task.isCancelled else { return }
                let wait = startedAt + delay - clock.now()
                if wait > 0 { await sleep(wait) }
                guard !Task.isCancelled, self?.artworkGeneration == generation else { return }
                let artwork = await port.artwork(trackID: track.id, maxPixelSize: Self.artworkPixels)
                // A newer song (or observing off) while loading: this result is stale.
                guard !Task.isCancelled, let self, self.artworkGeneration == generation else { return }
                if let artwork {
                    self.remember(artwork, for: track.id)
                    self.publish(artwork, track: track, attempt: index + 1, startedAt: startedAt)
                    return
                }
            }
            guard !Task.isCancelled, let self, self.artworkGeneration == generation else { return }
            self.artworkTask = nil
            self.lastArtworkSource = "none"
            let ms = Self.milliseconds(since: startedAt, now: self.core.services.clock.now())
            Log.i("MUSIC", "artwork source=none kind=\(Self.kind(track)) attempt=\(delays.count) ms=\(ms) track=\(MusicTrackID.logToken(track.id))")
        }
    }

    /// Registers the image (1), publishes its id (2) and lets the cleanup drop the others after the
    /// model went out (3).
    private func publish(_ artwork: MusicArtwork, track: MusicTrack, attempt: Int, startedAt: TimeInterval) {
        let imageID = Self.imageID(forTrack: track.id)
        core.services.projection.setDashImage(id: imageID, data: artwork.data)
        registeredImageIDs.insert(imageID)
        published = (track.id, imageID)
        artworkTask = nil
        lastArtworkSource = artwork.source.rawValue
        let ms = Self.milliseconds(since: startedAt, now: core.services.clock.now())
        // attempt=0: from the in-memory cache (the song played a moment ago).
        Log.i("MUSIC", "artwork source=\(artwork.source.rawValue) kind=\(Self.kind(track)) attempt=\(attempt) ms=\(ms) px=\(MusicArtworkInfo.pixelSizeText(of: artwork.data)) bytes=\(artwork.data.count) track=\(MusicTrackID.logToken(track.id))")
        onDashChange?()
        scheduleImageCleanup()
    }

    /// Removes, a moment later, every registered image the dash no longer shows.
    private func scheduleImageCleanup() {
        guard !cleanupScheduled else { return }
        cleanupScheduled = true
        let delay = imageCleanupDelay
        Task { @MainActor [weak self] in
            await sleepSeconds(delay) // after the coalesced model update (queued before this task)
            guard let self else { return }
            self.cleanupScheduled = false
            self.removeUnusedImages()
        }
    }

    private func removeUnusedImages() {
        // The current song's image stays while the tile is merely hidden (paused + other audio).
        let current = snapshot.track?.id
        let keep = isObserving ? published.flatMap { $0.trackID == current ? $0.imageID : nil } : nil
        for id in registeredImageIDs.sorted() where id != keep {
            core.services.projection.setDashImage(id: id, data: nil)
            registeredImageIDs.remove(id)
        }
    }

    private func cachedArtwork(_ trackID: String) -> MusicArtwork? {
        guard let i = artworkCache.firstIndex(where: { $0.trackID == trackID }) else { return nil }
        let entry = artworkCache.remove(at: i)
        artworkCache.insert(entry, at: 0)
        return entry.artwork
    }

    private func remember(_ artwork: MusicArtwork, for trackID: String) {
        artworkCache.removeAll { $0.trackID == trackID }
        artworkCache.insert((trackID, artwork), at: 0)
        if artworkCache.count > Self.artworkCacheCapacity {
            artworkCache.removeLast(artworkCache.count - Self.artworkCacheCapacity)
        }
    }

    /// The Music app makes sound (F1): it plays, or it scans — seeking plays audio too.
    static func isAudible(_ state: MusicPlaybackState) -> Bool {
        state == .playing || state == .seekingForward || state == .seekingBackward
    }

    /// Seeking and interruptions pass: the song is still "playing" for the hand-over rules.
    private static func isTransient(_ state: MusicPlaybackState) -> Bool {
        state == .interrupted || state == .seekingForward || state == .seekingBackward
    }

    /// "catalog" for an Apple Music catalog song (it has a store id), "library" otherwise.
    private static func kind(_ track: MusicTrack) -> String { track.storeID == nil ? "library" : "catalog" }

    private static func milliseconds(since start: TimeInterval, now: TimeInterval) -> Int {
        let ms = (now - start) * 1000
        guard ms.isFinite, ms > 0 else { return 0 }
        return ms >= Double(Int32.max) ? Int(Int32.max) : Int(ms.rounded())
    }
}
