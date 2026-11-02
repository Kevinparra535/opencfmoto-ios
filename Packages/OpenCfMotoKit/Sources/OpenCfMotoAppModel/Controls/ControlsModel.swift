// SPDX-License-Identifier: AGPL-3.0-or-later
// WAVE-2 SKELETON — owner: logic-session. The PUBLIC SURFACE below is the contract the SwiftUI
// layer codes against: implement the bodies, add private helpers / new files freely, add new
// public members only if needed (report them), never rename or remove existing public members.
//
// Handlebar buttons at runtime (docs/spec/input-controls.md §7–§9, ios-platform-facts.md
// MPRemoteCommandCenter): the remote is an OPT-IN experiment (silent audio loop, App Review risk),
// off by default and never enabled automatically. Mapping/timing/presets are edited through
// SettingsModel; this model owns the live engine:
// - `HandlebarGestureEngine(configuration: .init(settings: current, snappySingles:), presence:)`,
//   rebuilt when settings change; `services.handlebar.onSignal` → `engine.handle(event, at:, steps:)`;
//   commands → `DashInput` → RideModel.handleDashInput (and `lastCommand` for the UI tester);
//   presence changes → SettingsStore presence setters + `settings.reload()`; presence taught on
//   the Controls screen (SettingsModel setters / reset) → `engine.setPresence` (re-arms the probe).
// - `engine.streamingStarted()/streamingStopped()` follow the link (ConnectionModel calls
//   `linkStreamingChanged`), `engine.tick()` scheduled at `engine.nextDeadlineMs()`.
// - Disabled in mirror mode (the dash cannot drive mirrored apps).
//
// Ported from OpenCfMoto (Android) MediaButtonBridge.kt (capture lifecycle) and
// ButtonPresencePrefs.kt (presence persistence).
//
// Opt-in lifecycle (iOS): the rider's choice is remembered (`ios.handlebar_remote`). Turning it on
// claims the media remote at once (explicit action, foreground). On later launches the remote is
// NOT claimed at startup — only while a dash session runs (so other apps' music is not paused when
// the app is merely opened), and it is released when that session ends. Mirror sessions never
// claim it (input-controls.md §10.6: the bars must control the rider's music there), and neither
// does a bike whose "Handlebar buttons drive the dash" is off (§7.9: capture off = the bars control
// media normally; review SPEC:CL-9) — `syncRemoteClaim()` re-evaluates on every settings change.

import Foundation
import Observation
import OpenCfMotoCore

@MainActor
@Observable
public final class ControlsModel {
    @ObservationIgnored let core: AppCore
    @ObservationIgnored let settings: SettingsModel

    /// Rider opted in to handlebar control through the phone's media remote.
    public private(set) var isRemoteEnabled = false
    public var isRemoteAvailable: Bool { core.services.handlebar.isAvailable }
    /// Last decoded command, e.g. "Double ▶ → Zoom in" (button tester on the Controls screen).
    public private(set) var lastCommand: String?
    /// Last raw signal, e.g. "forward" (tester).
    public private(set) var lastRawEvent: String?
    /// Experimental ▲/▼ path (watch the phone volume): the rider's persisted choice
    /// (`ios.handlebar_volume_buttons`), mirrored from the handlebar port so views observe it.
    public private(set) var volumeButtonsEnabled = false

    /// KeyValueStore keys of the iOS-only opt-ins.
    static let remoteOptInKey = "ios.handlebar_remote"
    static let volumeButtonsKey = "ios.handlebar_volume_buttons"

    @ObservationIgnored let engine: HandlebarGestureEngine
    @ObservationIgnored private var bikeId: String?
    /// The stored presence the engine was last given (or learned and persisted itself). The engine
    /// follows the store only when the STORE changes (Teach / Reset / import), so an unrelated
    /// settings write can never revert a source the engine just learned but has not persisted yet.
    @ObservationIgnored private var syncedPresence: HandlebarPresence
    /// The dash is pulling own-UI video (the volume-rocker probe window runs).
    @ObservationIgnored private var probeStreaming = false
    @ObservationIgnored private var sessionActive = false
    @ObservationIgnored private var mirrorMode = false
    /// The rider claimed the remote explicitly (`setRemoteEnabled(true)`): kept after a ride ends;
    /// dropped by turning the opt-in off and by mirroring.
    @ObservationIgnored private var claimedByRider = false
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    /// Apple Music (contract R3): the pending re-claim of the buttons after the song was paused.
    @ObservationIgnored private var musicReclaimTask: Task<Void, Never>?

    public init(core: AppCore, settings: SettingsModel) {
        self.core = core
        self.settings = settings
        let store = core.settings
        let bike = core.garage.selected?.id
        bikeId = bike
        let presence = store.presence(forBike: bike)
        syncedPresence = presence
        engine = HandlebarGestureEngine(
            configuration: .init(settings: core.currentSettings, snappySingles: store.snappySingles),
            presence: presence,
            clock: core.services.clock)
        let kv = core.services.keyValueStore
        isRemoteEnabled = kv.bool(forKey: Self.remoteOptInKey) ?? false
        let handlebar = core.services.handlebar
        handlebar.volumeButtonsEnabled = kv.bool(forKey: Self.volumeButtonsKey) ?? false
        volumeButtonsEnabled = handlebar.volumeButtonsEnabled
        handlebar.onSignal = { [weak self] signal in self?.handle(signal) }
        engine.onPresenceChange = { [weak self] _ in
            Task { @MainActor [weak self] in self?.presenceChanged() }
        }
        settings.observe { [weak self] _ in self?.reloadConfiguration() }
        store.subscribe { [weak self] in
            Task { @MainActor [weak self] in self?.reloadConfiguration() }
        }
    }

    public func setRemoteEnabled(_ on: Bool) {
        core.services.keyValueStore.set(on, forKey: Self.remoteOptInKey)
        isRemoteEnabled = on
        let handlebar = core.services.handlebar
        if on {
            guard handlebar.isAvailable else { return }
            if mirrorMode {
                Log.i("BTN", "[BTN] handlebar capture deferred — mirror mode leaves the buttons to the media app")
                return
            }
            claimedByRider = true // the rider's explicit choice: keep it after the ride
            if !core.currentSettings.handlebarControl {
                Log.i("BTN", "[BTN] handlebar capture deferred \u{2014} \u{201C}Handlebar buttons drive the dash\u{201D} is off for this bike")
            }
            syncRemoteClaim()
        } else {
            claimedByRider = false
            if handlebar.isEnabled { handlebar.disable() }
            engine.reset()
            tickTask?.cancel()
            tickTask = nil
        }
    }

    public func setVolumeButtonsEnabled(_ on: Bool) {
        core.services.keyValueStore.set(on, forKey: Self.volumeButtonsKey)
        let handlebar = core.services.handlebar
        handlebar.volumeButtonsEnabled = on
        let effective = handlebar.volumeButtonsEnabled // what the port actually does
        if volumeButtonsEnabled != effective { volumeButtonsEnabled = effective }
        Log.i("BTN", "[BTN] volume buttons \u{25B2}/\u{25BC} \(effective ? "on" : "off")")
    }

    // MARK: Model-to-model (internal)

    /// Where decoded handlebar commands go (RideModel.handleDashInput).
    @ObservationIgnored var inputSink: (@MainActor (DashInput) -> Void)?

    /// Apple Music (contract R3): the re-claim attempts after a pause, in seconds after it (the second
    /// only when the first was refused). Tests shorten them.
    @ObservationIgnored var musicReclaimDelays: [TimeInterval] = [1, 3]
    /// The buttons are back on the dash after a re-claim (RideModel shows the toast).
    @ObservationIgnored var onHandlebarReclaimed: (() -> Void)?

    /// MusicModel (contract R3): Apple Music went from playing to paused / stopped. While the phone
    /// media remote should drive the dash, claim the buttons back — the Music app took Now Playing
    /// when it started, and iOS may never tell HandlebarRemote the interruption ended. One attempt
    /// at +1 s and, if refused (app in the background, other audio still playing), one at +3 s.
    func musicPlaybackPaused() {
        musicReclaimTask?.cancel()
        musicReclaimTask = nil
        guard remoteClaimWanted, core.services.handlebar.isEnabled else { return }
        let delays = musicReclaimDelays
        guard !delays.isEmpty else { return }
        let start = core.services.clock.now()
        musicReclaimTask = Task { [weak self] in
            for (index, delay) in delays.enumerated() {
                guard let wait = self.map({ start + delay - $0.core.services.clock.now() }) else { return }
                if wait > 0 { await sleepSeconds(wait) }
                guard !Task.isCancelled, let self else { return }
                let handlebar = self.core.services.handlebar
                guard self.remoteClaimWanted, handlebar.isEnabled else {
                    self.musicReclaimTask = nil
                    return
                }
                Log.i("BTN", "[BTN] music paused \u{2014} reclaiming the handlebar buttons (attempt \(index + 1))")
                switch handlebar.reclaimIfPossible() {
                case .reclaimed:
                    self.musicReclaimTask = nil
                    Log.i("BTN", "[BTN] handlebar buttons back on the dash")
                    self.onHandlebarReclaimed?()
                    return
                case .alreadyClaimed:
                    self.musicReclaimTask = nil
                    return
                case .refused:
                    continue
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.musicReclaimTask = nil
            Log.i("BTN", "[BTN] reclaim refused (background or other audio)")
        }
    }

    /// MusicModel: Apple Music plays again — a pending re-claim would pause it.
    func musicPlaybackStarted() {
        musicReclaimTask?.cancel()
        musicReclaimTask = nil
    }

    /// ConnectionModel: streaming started/stopped (presence probes, mirror mode disables).
    func linkStreamingChanged(_ streaming: Bool, mirror: Bool) {
        if mirror != mirrorMode {
            mirrorMode = mirror
            if mirror { releaseForMirror() }
        }
        probeStreaming = streaming && !mirror
        if probeStreaming {
            engine.streamingStarted()
        } else {
            engine.streamingStopped()
        }
        scheduleTick()
    }

    /// ConnectionModel: a Connect / Mirror session started or ended.
    func sessionChanged(active: Bool, mirror: Bool) {
        sessionActive = active
        mirrorMode = active && mirror
        if active {
            if mirror {
                releaseForMirror()
            } else {
                syncRemoteClaim()
            }
        } else {
            probeStreaming = false
            engine.streamingStopped()
            engine.reset()
            syncRemoteClaim() // released unless the rider claimed it explicitly
            tickTask?.cancel()
            tickTask = nil
        }
    }

    // MARK: - Private

    private func handle(_ signal: HandlebarSignal) {
        lastRawEvent = signal.steps > 1 ? "\(signal.event.rawValue) \u{00D7}\(signal.steps)" : signal.event.rawValue
        guard !mirrorMode else { return } // mirrored apps cannot be driven from the dash
        if core.garage.selected?.id != bikeId { reloadConfiguration() } // per-bike map / presence
        deliver(engine.handle(signal.event, at: signal.time, steps: signal.steps))
        scheduleTick()
    }

    private func deliver(_ commands: [HandlebarCommand]) {
        guard !commands.isEmpty else { return }
        let l = core.language
        for cmd in commands {
            let text = "\(SessionText.gestureLabel(cmd.gesture, l)) \u{2192} \(SessionText.actionLabel(cmd.action, l))"
            lastCommand = text
            Log.i("BTN", "\(cmd.gesture.englishLabel) \u{2192} \(cmd.action.englishLabel)")
            if let input = cmd.input { inputSink?(input) }
        }
    }

    /// Runs `engine.tick()` at the engine's next deadline (deferred singles, holds, presence probe).
    private func scheduleTick() {
        tickTask?.cancel()
        tickTask = nil
        guard let deadline = engine.nextDeadlineMs() else { return }
        let nowMs = Int64((core.services.clock.now() * 1000).rounded())
        let delay = max(0, Double(deadline - nowMs) / 1000) + 0.001
        tickTask = Task { [weak self] in
            await sleepSeconds(delay)
            guard !Task.isCancelled, let self else { return }
            self.tickTask = nil
            self.deliver(self.engine.tick())
            self.scheduleTick()
        }
    }

    private func releaseForMirror() {
        engine.reset()
        probeStreaming = false
        engine.streamingStopped()
        let handlebar = core.services.handlebar
        if handlebar.isEnabled {
            handlebar.disable()
            Log.i("BTN", "[BTN] mirror mode — handlebar capture released (the bars control media apps)")
        }
        claimedByRider = false // never reclaimed behind the rider's back once mirroring started
    }

    /// Claims or releases the phone media remote to match what is wanted right now: opted in, capture
    /// on for this bike ("Handlebar buttons drive the dash"), not mirroring, and a dash session running
    /// or the rider's explicit claim. Capture off gives the bars back to music: the engine would drop
    /// every event, while the claimed remote (silent non-mixable audio) keeps other audio paused.
    private func syncRemoteClaim() {
        let handlebar = core.services.handlebar
        guard handlebar.isAvailable else { return }
        let capture = core.currentSettings.handlebarControl
        let wanted = remoteClaimWanted
        if wanted, !handlebar.isEnabled {
            handlebar.enable()
            Log.i("BTN", "[BTN] handlebar capture on\(sessionActive ? " for this ride" : "")")
        } else if !wanted, handlebar.isEnabled {
            handlebar.disable()
            let reason = !capture ? "\u{201C}Handlebar buttons drive the dash\u{201D} is off \u{2014} the bars control media"
                : "ride ended"
            Log.i("BTN", "[BTN] handlebar capture released (\(reason))")
        }
    }

    /// The phone media remote should hold the buttons now: opted in, capture on for this bike
    /// ("Handlebar buttons drive the dash"), not mirroring, and a dash session running or the rider's
    /// explicit claim.
    private var remoteClaimWanted: Bool {
        isRemoteEnabled && core.currentSettings.handlebarControl && !mirrorMode && (sessionActive || claimedByRider)
    }

    private func reloadConfiguration() {
        let store = core.settings
        let bike = core.garage.selected?.id
        engine.configuration = .init(settings: core.currentSettings, snappySingles: store.snappySingles)
        syncRemoteClaim() // capture switched on / off, or another bike selected
        let stored = store.presence(forBike: bike)
        if bike != bikeId {
            bikeId = bike
            syncedPresence = stored
            engine.setPresence(stored)
        } else if stored != syncedPresence {
            // Taught on the Controls screen (Present / Absent / Unknown, Reset) or imported: the
            // live engine follows, like Android's refreshVolumePresencePolicy().
            syncedPresence = stored
            let wasUnknown = engine.presence.volumeRocker == .unknown
            engine.setPresence(stored)
            if stored.volumeRocker == .unknown, !wasUnknown, probeStreaming {
                // Back to untested while streaming: a fresh ~90 s window to see a ▲/▼ press.
                engine.streamingStopped()
                engine.streamingStarted()
            }
            Log.i("BTN", "handlebar sources taught: \(stored.summary)")
            scheduleTick()
        }
    }

    /// The engine learned a handlebar source (or marked the rocker absent): persist it for the bike
    /// whose presence the engine holds. The engine's CURRENT presence is stored, not the notified
    /// snapshot, so a value taught (or re-loaded) in between is never overwritten by an older
    /// notification and the engine, the store and the screen always end up agreeing.
    private func presenceChanged() {
        let store = core.settings
        let bike = bikeId
        let current = engine.presence
        syncedPresence = current // the engine already has it: no echo back
        let old = store.presence(forBike: bike)
        guard old != current else { return }
        if old.volumeRocker != current.volumeRocker { store.setVolumeRockerPresence(current.volumeRocker, forBike: bike) }
        if old.trackKeys != current.trackKeys { store.setTrackKeysPresence(current.trackKeys, forBike: bike) }
        Log.i("BTN", "handlebar sources: \(current.summary)")
        settings.reload()
    }
}
