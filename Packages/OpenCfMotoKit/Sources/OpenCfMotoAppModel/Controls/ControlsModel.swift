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
//   presence changes → SettingsStore presence setters + `settings.reload()`.
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
// claim it (input-controls.md §10.6: the bars must control the rider's music there).

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

    /// KeyValueStore keys of the iOS-only opt-ins.
    static let remoteOptInKey = "ios.handlebar_remote"
    static let volumeButtonsKey = "ios.handlebar_volume_buttons"

    @ObservationIgnored let engine: HandlebarGestureEngine
    @ObservationIgnored private var bikeId: String?
    @ObservationIgnored private var sessionActive = false
    @ObservationIgnored private var mirrorMode = false
    /// The remote was claimed because a session started (released when it ends).
    @ObservationIgnored private var claimedForSession = false
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    public init(core: AppCore, settings: SettingsModel) {
        self.core = core
        self.settings = settings
        let store = core.settings
        let bike = core.garage.selected?.id
        bikeId = bike
        engine = HandlebarGestureEngine(
            configuration: .init(settings: core.currentSettings, snappySingles: store.snappySingles),
            presence: store.presence(forBike: bike),
            clock: core.services.clock)
        let kv = core.services.keyValueStore
        isRemoteEnabled = kv.bool(forKey: Self.remoteOptInKey) ?? false
        let handlebar = core.services.handlebar
        handlebar.volumeButtonsEnabled = kv.bool(forKey: Self.volumeButtonsKey) ?? false
        handlebar.onSignal = { [weak self] signal in self?.handle(signal) }
        engine.onPresenceChange = { [weak self] presence in
            Task { @MainActor [weak self] in self?.presenceChanged(presence) }
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
            if !handlebar.isEnabled { handlebar.enable() }
            claimedForSession = false // the rider's explicit choice: keep it after the ride
        } else {
            if handlebar.isEnabled { handlebar.disable() }
            claimedForSession = false
            engine.reset()
            tickTask?.cancel()
            tickTask = nil
        }
    }

    public func setVolumeButtonsEnabled(_ on: Bool) {
        core.services.keyValueStore.set(on, forKey: Self.volumeButtonsKey)
        core.services.handlebar.volumeButtonsEnabled = on
    }

    public var volumeButtonsEnabled: Bool { core.services.handlebar.volumeButtonsEnabled }

    // MARK: Model-to-model (internal)

    /// Where decoded handlebar commands go (RideModel.handleDashInput).
    @ObservationIgnored var inputSink: (@MainActor (DashInput) -> Void)?

    /// ConnectionModel: streaming started/stopped (presence probes, mirror mode disables).
    func linkStreamingChanged(_ streaming: Bool, mirror: Bool) {
        if mirror != mirrorMode {
            mirrorMode = mirror
            if mirror { releaseForMirror() }
        }
        if streaming && !mirror {
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
        let handlebar = core.services.handlebar
        if active {
            if mirror {
                releaseForMirror()
            } else if isRemoteEnabled, handlebar.isAvailable, !handlebar.isEnabled {
                handlebar.enable()
                claimedForSession = true
                Log.i("BTN", "[BTN] handlebar capture on for this ride")
            }
        } else {
            engine.streamingStopped()
            engine.reset()
            if claimedForSession, handlebar.isEnabled {
                handlebar.disable()
                Log.i("BTN", "[BTN] ride ended — handlebar capture released")
            }
            claimedForSession = false
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
        engine.streamingStopped()
        let handlebar = core.services.handlebar
        if handlebar.isEnabled {
            handlebar.disable()
            Log.i("BTN", "[BTN] mirror mode — handlebar capture released (the bars control media apps)")
        }
        claimedForSession = false
    }

    private func reloadConfiguration() {
        let store = core.settings
        let bike = core.garage.selected?.id
        engine.configuration = .init(settings: core.currentSettings, snappySingles: store.snappySingles)
        if bike != bikeId {
            bikeId = bike
            engine.setPresence(store.presence(forBike: bike))
        }
    }

    /// The engine learned a handlebar source (or marked the rocker absent): persist it per bike.
    private func presenceChanged(_ presence: HandlebarPresence) {
        let store = core.settings
        let bike = core.garage.selected?.id
        let old = store.presence(forBike: bike)
        guard old != presence else { return }
        if old.volumeRocker != presence.volumeRocker { store.setVolumeRockerPresence(presence.volumeRocker, forBike: bike) }
        if old.trackKeys != presence.trackKeys { store.setTrackKeysPresence(presence.trackKeys, forBike: bike) }
        Log.i("BTN", "handlebar sources: \(presence.summary)")
        settings.reload()
    }
}
