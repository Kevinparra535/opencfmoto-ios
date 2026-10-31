// SPDX-License-Identifier: AGPL-3.0-or-later
// WAVE-2 SKELETON — owner: logic-session. The PUBLIC SURFACE below is the contract the SwiftUI
// layer codes against: implement the bodies, add private helpers / new files freely, add new
// public members only if needed (report them), never rename or remove existing public members.
//
// Connect / Stop / Mirror / recovery (docs/spec/app-features.md §7.2–§7.5, session-network.md §3–§7,
// ARCHITECTURE.md §5). Owns at most ONE `EasyConnLink` at a time.
//
// Behaviour to implement:
// - `connect()`: no bike → `issue = .noBikePaired` (UI opens the scanner). Else: phase
//   `.joiningWifi` (detail = bike name) → `services.wifi.join(ssid:passphrase:)`
//   (`.manualJoinRequired` → `manualJoin` prompt; wait for `networkUpdates()` to show the bike
//   SSID / a dash subnet, or `confirmManualJoin()`); `setPreferCellular(true)`;
//   `.linking` → build `LinkConfiguration(qr:, profileOverride:, learnedCanvas: dashMemory,
//   forceTouchscreen:, phone:)` + `LinkOptions` (forceNonTouch, wifiInterfaceName,
//   encoderParameters = EncoderPlanner) → `EasyConnLink(configuration:network:frameSource:
//   ride.frameSource, signer: await core.signer(), discovery:, gateway: info.gateway, clock:,
//   options:)` → consume `link.events` in ONE task → `link.start()`.
// - Link events: `.state` → phase mapping (streaming → `.streaming`, reconnecting → `.reconnecting`
//   "attempt N", failed(portInUse) → `.error` + `issue = .portsInUse` (detail "close the official
//   CFMoto app, then reconnect"), failed(localNetworkDenied) → `.localNetworkDenied`,
//   failed(dashNotFound/lostLink) → `.error` (the link re-arms itself every 20 s while auto-recovery
//   is on; otherwise stop); `.canvas` → `core.dashMemory.observe(ssid:canvas:)` +
//   `ride.canvasNegotiated`; `.dashIdentified` → `garage` profile hint + `ride.profileIdentified`;
//   `.touch` → `ride.handleDashTouch`; `.stats` → `diagnostics`.
// - Wi-Fi supervision: bike Wi-Fi lost → `.reconnecting` "waiting for bike Wi-Fi"; after 180 s
//   → `.waitingForBike` "will resume when the bike is back"; Wi-Fi back → `link.start()` (clean
//   restart). Auto-recovery off → stop instead.
// - `startMirror()`: `services.mirror.start()` (+ setFit from settings) → mode `.mirror`, phase
//   `.mirroring` (detail bike name) → same join/link flow with `frameSource: services.mirror.frameSource`;
//   the UI presents the ReplayKit broadcast picker. Duplicate tap guard: ignore if already
//   mirroring and a frame was sent < 15 s ago (toast text in `detail`).
// - `stop()`: "Stop everything": link.stop(), projection/mirror stop, ride.projectionChanged(false),
//   forget the Wi-Fi unless kept, `setPreferCellular(false)`, phase `.stopped`, detail "".
// - Auto-connect at launch / foreground (§7.5.3): settings.autoConnect && a saved bike && not busy
//   → after 1.2 s `connect()` once per process (latched); iOS cannot scan Wi-Fi: "range unknown".
// - Every phase change: `ride.linkPhaseChanged`, `controls.linkStreamingChanged`, log with the
//   Android labels (`ConnectionPhase` EN log label).

import Foundation
import Observation
import OpenCfMotoCore

@MainActor
@Observable
public final class ConnectionModel {
    @ObservationIgnored let core: AppCore
    @ObservationIgnored let garage: GarageModel
    @ObservationIgnored let settings: SettingsModel
    @ObservationIgnored let ride: RideModel
    @ObservationIgnored let controls: ControlsModel

    public private(set) var phase: ConnectionPhase = .idle
    /// Second status line (Android detail strings, localized), "" when none.
    public private(set) var detail: String = ""
    public private(set) var mode: ProjectionMode = .none
    /// Problem that deserves a dialog; cleared by `dismissIssue()` or the next connect.
    public private(set) var issue: ConnectionIssue?
    /// Non-nil while the rider must join the bike Wi-Fi manually.
    public private(set) var manualJoin: ManualWifiJoinPrompt?
    /// Live link + projection diagnostics (≈ every 5 s while linked).
    public private(set) var diagnostics = LinkDiagnostics()
    /// True once the ReplayKit extension connected to the relay socket.
    public private(set) var isMirrorExtensionConnected = false

    public init(core: AppCore, garage: GarageModel, settings: SettingsModel, ride: RideModel,
                controls: ControlsModel) {
        self.core = core
        self.garage = garage
        self.settings = settings
        self.ride = ride
        self.controls = controls
        // TODO(logic-session)
    }

    /// Home "Connect" (own dash UI). While busy/live the same button means `stop()`.
    public func connect() { /* TODO(logic-session) */ }
    /// Home "Mirror": prepares the relay; the UI then shows the broadcast picker.
    public func startMirror() { /* TODO(logic-session) */ }
    /// "Stop everything".
    public func stop() { /* TODO(logic-session) */ }
    /// Connect if idle/stopped/error, stop otherwise (the big button).
    public func toggle() {
        if phase.showsStop { stop() } else { connect() }
    }
    /// The rider says they joined the bike Wi-Fi in Settings.
    public func confirmManualJoin() { /* TODO(logic-session) */ }
    public func cancelManualJoin() { /* TODO(logic-session) */ }
    public func dismissIssue() { issue = nil }
    /// Drop the bike sockets and re-probe now (diagnostics screen).
    public func forceReconnect() { /* TODO(logic-session) */ }

    // MARK: Model-to-model (internal)

    /// AppModel at launch and on every foreground (auto-connect rules).
    func maybeAutoConnect() { /* TODO(logic-session) */ }
    func scenePhaseChanged(_ phase: AppScenePhase) { /* TODO(logic-session) */ }
}
