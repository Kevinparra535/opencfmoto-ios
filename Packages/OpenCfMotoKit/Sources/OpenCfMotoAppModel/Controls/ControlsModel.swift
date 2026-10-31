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

    public init(core: AppCore, settings: SettingsModel) {
        self.core = core
        self.settings = settings
        // TODO(logic-session)
    }

    public func setRemoteEnabled(_ on: Bool) { /* TODO(logic-session) */ }
    public func setVolumeButtonsEnabled(_ on: Bool) { /* TODO(logic-session) */ }
    public var volumeButtonsEnabled: Bool { core.services.handlebar.volumeButtonsEnabled }

    // MARK: Model-to-model (internal)

    /// Where decoded handlebar commands go (RideModel.handleDashInput).
    @ObservationIgnored var inputSink: (@MainActor (DashInput) -> Void)?

    /// ConnectionModel: streaming started/stopped (presence probes, mirror mode disables).
    func linkStreamingChanged(_ streaming: Bool, mirror: Bool) { /* TODO(logic-session) */ }
}
