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
//
// Ported from OpenCfMoto (Android) MainActivity.kt (connect / stopEverything / maybeAutoConnect /
// mirror guard), ConnectionState.kt, BikeWifi.kt (join, re-acquire, release) and
// AndroidAutoService.kt (180 s Wi-Fi supervisor, adapted to the own-UI path).
//
// iOS decisions (session-network.md §11):
// - Every session gets a generation number; tasks, callbacks and link events of an older session
//   are ignored (Android's stop→start race, §6.9).
// - "Wi-Fi back" builds a fresh `EasyConnLink` with the new address / gateway (a clean restart:
//   Android `prober.stop()` + `prober.start(newNetwork)`).
// - STREAMING always shows the bike name as detail (Android keeps "attempt N", §6.1 quirk).
// - Errors that the link re-arms by itself (dash not found, lost link, Local Network denied) keep
//   the session alive while auto-recovery is on; terminal errors end it (Wi-Fi stays associated
//   until Stop, like Android).
// - Auto-connect never prompts: a free-flavor manual join or a failed join ends quietly.

import Foundation
import Observation
import OpenCfMotoCore

/// Timers of the session supervisor (Android values by default; tests shorten them).
struct ConnectionTuning {
    /// Delay between the auto-connect decision and Connect (MainActivity.kt:785-800).
    var autoConnectDelay: TimeInterval = 1.2
    /// Bike Wi-Fi gone this long → WAITING_FOR_BIKE (AndroidAutoService GRACE_MS).
    var wifiParkGrace: TimeInterval = 180
    /// Duplicate Mirror tap guard (MainActivity.kt:1497-1508).
    var mirrorDuplicateGuard: TimeInterval = 15
    /// Engine timers (LinkTimings.standard = Android).
    var linkTimings: LinkTimings = .standard
    var connectBackTimeout: TimeInterval = 10
    var stallTimeout: TimeInterval = 8
    var stallReconnectCooldown: TimeInterval = 20
    var maxReconnectAttempts: Int = 20
    var framePullTimeout: TimeInterval = 3
    /// Local IPv4 source for the link (nil = getifaddrs).
    var interfaceProvider: (@Sendable () -> [InterfaceAddress])?
}

/// What started a session.
enum ConnectionTrigger: Equatable {
    case user
    case auto
}

/// The running Connect / Mirror session.
struct ConnectionSession {
    var bike: GarageBike
    var qr: BikeQR
    var mode: ProjectionMode
    var trigger: ConnectionTrigger
}

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
    /// A Connect / Mirror session exists (joining, linking, streaming, reconnecting, parked, or an
    /// .error phase whose link keeps re-arming). The big button must offer Stop whenever this is true,
    /// not only when `phase.showsStop` (review finding CL-1).
    public private(set) var isSessionActive = false

    // MARK: Internal state

    @ObservationIgnored var tuning = ConnectionTuning()
    @ObservationIgnored private let phone: PhoneIdentity
    @ObservationIgnored private(set) var session: ConnectionSession?
    @ObservationIgnored private(set) var generation: UInt64 = 0
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private(set) var link: EasyConnLink?
    @ObservationIgnored private var linkEventsTask: Task<Void, Never>?
    /// Identifies the current link's events. Bumped for every new link and by `stopLink()`: a Wi-Fi-back
    /// restart keeps the session generation, and a freed link's ObjectIdentifier can be reused by its
    /// replacement, so an event already dequeued by the old consumer must not pass for the new link's.
    @ObservationIgnored private(set) var linkSerial: UInt64 = 0
    @ObservationIgnored private var wifiWatchTask: Task<Void, Never>?
    @ObservationIgnored private var parkTask: Task<Void, Never>?
    @ObservationIgnored private var autoConnectTask: Task<Void, Never>?
    @ObservationIgnored private var manualJoinSignal: AsyncStream<WifiNetworkInfo?>.Continuation?
    @ObservationIgnored private var manualJoinToken: UInt64 = 0
    @ObservationIgnored private(set) var linkState: LinkState = .idle
    @ObservationIgnored private var wifiLostAt: TimeInterval?
    @ObservationIgnored private(set) var isParked = false
    /// The Wi-Fi the session actually joined (gateway + phone /24): the fingerprint that recognises the
    /// bike network when the SSID is unknown (free flavor; no precise location for networks the app
    /// did not configure). Refreshed by every SSID-confirmed re-acquire.
    @ObservationIgnored private(set) var sessionNetwork: WifiNetworkInfo?
    /// A link was started on this network although it only matches the fingerprint (SSID unknown): the
    /// Wi-Fi loss and its grace / park stay in force until the dash actually streams on it.
    @ObservationIgnored private(set) var unconfirmedNetwork: WifiNetworkInfo?
    /// The look-alike network on which the last unconfirmed attempt found no dash: repeated updates of
    /// the same network start no new attempt (any other network clears it).
    @ObservationIgnored private var dashlessNetwork: WifiNetworkInfo?
    /// Invalidates a Wi-Fi-back link start that is still waiting for the signer when the Wi-Fi changes again.
    @ObservationIgnored private var resumeToken: UInt64 = 0
    @ObservationIgnored private var lastFrameSentAt: TimeInterval?
    @ObservationIgnored private(set) var autoConnectLatched = false
    /// An auto-connect ended quietly (join failed / no dash on an unconfirmed network): the latch is
    /// released when the app goes to the background, so the next foreground retries once (§13.12:
    /// "stay idle and retry on scenePhase == .active; never loop"). The iOS join alert's own
    /// inactive → active bounce never passes through .background.
    @ObservationIgnored private(set) var retryAutoConnectAfterBackground = false
    @ObservationIgnored private var loggedNotOnBikeWifi = false
    /// The session reached STREAMING at least once.
    @ObservationIgnored private var sessionEverStreamed = false
    /// `issue = .localNetworkDenied` was raised in this episode (since the session began or last
    /// streamed). The link re-arms every 20 s while auto-recovery is on and fails the same way each
    /// time: raising the issue again would bring the dialog back after every Dismiss (CON:CL-1).
    @ObservationIgnored private var localNetworkIssueRaised = false
    @ObservationIgnored private var loggedAutoConnectIdle = false
    /// Bike Wi-Fi configuration kept after a failed session (Android keeps the network until Stop);
    /// forgotten by Stop, by a session to another bike, or when the app leaves the foreground idle.
    @ObservationIgnored private(set) var lingeringWifiSSID: String?

    public init(core: AppCore, garage: GarageModel, settings: SettingsModel, ride: RideModel,
                controls: ControlsModel) {
        self.core = core
        self.garage = garage
        self.settings = settings
        self.ride = ride
        self.controls = controls
        // CLIENT_INFO identity: one random phoneUUID per process (Android parity, control-plane §8.2).
        phone = PhoneIdentity(phoneBrand: "Apple", phoneModel: core.services.system.deviceModel)
        core.services.mirror.onExtensionConnectionChange = { [weak self] connected in
            Task { @MainActor [weak self] in self?.mirrorExtensionChanged(connected) }
        }
    }

    /// Home "Connect" (own dash UI). While busy/live the same button means `stop()`.
    public func connect() {
        cancelAutoConnect(unlatch: false)
        begin(mode: .dashUI, trigger: .user)
    }

    /// Home "Mirror": prepares the relay; the UI then shows the broadcast picker.
    public func startMirror() {
        if mode == .mirror, phase == .mirroring || phase == .reconnecting {
            let last = link?.stats.lastFrameAt ?? lastFrameSentAt
            if let last, core.services.clock.now() - last < tuning.mirrorDuplicateGuard {
                detail = SessionText.alreadyMirroring(core.language)
                Log.i("APP", "Mirror tap ignored \u{2014} already mirroring (last frame \(Int((core.services.clock.now() - last) * 1000))ms ago)")
                return
            }
        }
        cancelAutoConnect(unlatch: false)
        begin(mode: .mirror, trigger: .user)
    }

    /// "Stop everything".
    public func stop() {
        cancelAutoConnect(unlatch: false)
        let had = session != nil
        teardownSession(keepWifi: false)
        forgetLingeringWifi(except: nil)
        ride.sessionChanged(active: false, mirror: false)
        controls.sessionChanged(active: false, mirror: false)
        core.services.setPreferCellular(false)
        mode = .none
        manualJoin = nil
        if had { Log.i("APP", "Stop everything") }
        setPhase(.stopped, detail: "")
    }

    /// Connect if idle/stopped/error, stop otherwise (the big button).
    public func toggle() {
        if isSessionActive || phase.showsStop { stop() } else { connect() }
    }

    /// The rider says they joined the bike Wi-Fi in Settings.
    public func confirmManualJoin() {
        guard manualJoin != nil else { return }
        manualJoinSignal?.yield(nil)
    }

    public func cancelManualJoin() {
        guard manualJoin != nil else { return }
        Log.i("WIFI", "[wifi] manual join cancelled")
        stop()
    }

    public func dismissIssue() { issue = nil }

    /// Drop the bike sockets and re-probe now (diagnostics screen).
    public func forceReconnect() {
        guard let link else { return }
        Log.i("APP", "→ reconnect requested (diagnostics)")
        link.forceReconnect()
    }

    // MARK: Model-to-model (internal)

    /// AppModel at launch and on every foreground (auto-connect rules).
    func maybeAutoConnect() {
        guard !autoConnectLatched else { return }
        guard core.currentSettings.autoConnect else { return }
        guard !phase.isBusy, !phase.isLive, session == nil else { return }
        guard core.garage.selected != nil else {
            if !loggedAutoConnectIdle {
                loggedAutoConnectIdle = true
                Log.i("APP", "→ Auto-connect idle: no bike paired.")
            }
            return
        }
        autoConnectLatched = true
        retryAutoConnectAfterBackground = false
        let delay = tuning.autoConnectDelay
        let wifi = core.services.wifi
        autoConnectTask?.cancel()
        autoConnectTask = Task { [weak self] in
            await sleepSeconds(delay)
            guard !Task.isCancelled else { return }
            // §11.8: iOS cannot scan, and applying the hotspot configuration at every launch prompts
            // (and fails after ~15 s when the bike is off). Auto-start only when iOS already joined
            // the bike Wi-Fi; otherwise stay idle and check again on the next foreground.
            let current = await wifi.currentNetwork()
            guard !Task.isCancelled, let self else { return }
            self.autoConnectTask = nil
            guard !self.phase.isBusy, !self.phase.isLive, self.session == nil else { return }
            guard let bike = self.core.garage.selected, let qr = self.core.garage.qr(for: bike.id) else { return }
            guard Self.isAlreadyOnBikeNetwork(current, ssid: qr.ssid) else {
                self.autoConnectLatched = false
                if !self.loggedNotOnBikeWifi {
                    self.loggedNotOnBikeWifi = true
                    Log.i("APP", "→ Auto-connect idle: '\(bike.name)' \u{2014} not on its Wi-Fi (\(Self.describe(current))). Tap Connect, or open the app on the bike Wi-Fi.")
                }
                return
            }
            Log.i("APP", "→ Auto-connect: '\(bike.name)' \u{2014} already on its Wi-Fi (\(Self.describe(current))). Disable in Setup \u{25B8} Startup.")
            self.begin(mode: .dashUI, trigger: .auto)
        }
    }

    func scenePhaseChanged(_ phase: AppScenePhase) {
        switch phase {
        case .background:
            // Android unlatches when the activity died before the delayed connect ran.
            cancelAutoConnect(unlatch: true)
            if retryAutoConnectAfterBackground, session == nil {
                retryAutoConnectAfterBackground = false
                autoConnectLatched = false
                Log.i("APP", "→ Auto-connect will retry when the app returns")
            }
            // A failed session's bike Wi-Fi must not keep auto-joining once the rider left the app.
            if session == nil { forgetLingeringWifi(except: nil) }
        case .active:
            // Back from Settings ▸ Wi-Fi: re-check the network at once.
            if manualJoin != nil, let signal = manualJoinSignal {
                let wifi = core.services.wifi
                Task { signal.yield(await wifi.currentNetwork()) }
            }
        case .inactive:
            break
        }
    }

    // MARK: - Session lifecycle

    private func begin(mode newMode: ProjectionMode, trigger: ConnectionTrigger) {
        let l = core.language
        guard let bike = core.garage.selected else {
            Log.i("APP", "→ no bike paired \u{2014} scan the dash QR first")
            issue = .noBikePaired
            return
        }
        guard let qr = core.garage.qr(for: bike.id) else {
            Log.w("APP", "→ '\(bike.name)': pairing data unreadable \u{2014} re-scan the dash QR")
            issue = .noBikePaired
            return
        }
        // Hard switch: the previous projection and link die first; the Wi-Fi association stays
        // (unless the previous session was for another bike).
        let previousSSID = session?.qr.ssid
        teardownSession(keepWifi: true)
        forgetLingeringWifi(except: qr.ssid)
        if let previousSSID, previousSSID != qr.ssid, core.services.wifi.supportsAutomaticJoin {
            core.services.wifi.forget(ssid: previousSSID)
        }
        if newMode == .mirror {
            do {
                try core.services.mirror.start()
            } catch {
                Log.e("MIRROR", "relay start failed: \(error)")
                ride.sessionChanged(active: false, mirror: false)
                controls.sessionChanged(active: false, mirror: false)
                mode = .none
                let message = SessionText.mirrorUnavailable(l)
                issue = .other(message)
                setPhase(.error, detail: message)
                return
            }
            let st = core.currentSettings
            let early = BikeProfiles.selectByQR(qr, override: st.profileOverride,
                                                learnedCanvas: core.dashMemory.learnedCanvas(forSSID: qr.ssid))
            applyMirrorFit(profile: early)
        }
        generation &+= 1
        let gen = generation
        issue = nil
        localNetworkIssueRaised = false
        sessionEverStreamed = false
        loggedNotOnBikeWifi = false
        if trigger == .user { retryAutoConnectAfterBackground = false }
        manualJoin = nil
        wifiLostAt = nil
        isParked = false
        unconfirmedNetwork = nil
        dashlessNetwork = nil
        lastFrameSentAt = nil
        linkState = .idle
        diagnostics = LinkDiagnostics()
        mode = newMode
        session = ConnectionSession(bike: bike, qr: qr, mode: newMode, trigger: trigger)
        isSessionActive = true
        Log.i("APP", "→ \(newMode == .mirror ? "Mirror" : "Connect")\(trigger == .auto ? " (auto)" : ""): '\(bike.name)'")
        ride.sessionChanged(active: true, mirror: newMode == .mirror)
        controls.sessionChanged(active: true, mirror: newMode == .mirror)
        setPhase(newMode == .mirror ? .mirroring : .joiningWifi, detail: bike.name)
        sessionTask = Task { [weak self] in await self?.runSession(gen) }
    }

    /// Stops everything of the current session (link, projection / relay, Wi-Fi watch, timers)
    /// without touching the phase. `keepWifi == false` also forgets the bike Wi-Fi configuration.
    private func teardownSession(keepWifi: Bool) {
        generation &+= 1
        sessionTask?.cancel()
        sessionTask = nil
        wifiWatchTask?.cancel()
        wifiWatchTask = nil
        parkTask?.cancel()
        parkTask = nil
        finishManualJoinSignal()
        stopLink()
        wifiLostAt = nil
        isParked = false
        unconfirmedNetwork = nil
        dashlessNetwork = nil
        sessionNetwork = nil
        guard let s = session else { return }
        session = nil
        isSessionActive = false
        switch s.mode {
        case .mirror:
            core.services.mirror.stop()
            isMirrorExtensionConnected = false
        case .dashUI:
            core.services.projection.stop()
        case .none:
            break
        }
        ride.setLinkBanner(nil)
        ride.projectionChanged(active: false)
        controls.linkStreamingChanged(false, mirror: false)
        let wifi = core.services.wifi
        if !keepWifi, wifi.supportsAutomaticJoin {
            wifi.forget(ssid: s.qr.ssid)
        }
    }

    /// A terminal failure: the session ends (Wi-Fi stays associated until Stop, like Android).
    private func endSession(_ newPhase: ConnectionPhase, detail newDetail: String, issue newIssue: ConnectionIssue?) {
        if let s = session, core.services.wifi.supportsAutomaticJoin { lingeringWifiSSID = s.qr.ssid }
        teardownSession(keepWifi: true)
        ride.sessionChanged(active: false, mirror: false)
        controls.sessionChanged(active: false, mirror: false)
        mode = .none
        manualJoin = nil
        if let newIssue { issue = newIssue }
        setPhase(newPhase, detail: newDetail)
    }

    private func runSession(_ gen: UInt64) async {
        guard let s = session, gen == generation else { return }
        if phase != .joiningWifi { setPhase(.joiningWifi, detail: s.bike.name) }
        guard let info = await joinBikeWifi(gen), gen == generation else { return }
        sessionNetwork = info
        core.services.setPreferCellular(true)
        if info.isLocalNetworkDenied {
            Log.w("WIFI", "[wifi] Local Network access denied for this app \u{2014} the dash cannot be reached")
        }
        watchWifi(gen)
        await startLink(info: info, gen: gen, afterWifiLoss: false)
    }

    private func forgetLingeringWifi(except ssid: String?) {
        guard let lingering = lingeringWifiSSID else { return }
        lingeringWifiSSID = nil
        guard lingering != ssid else { return }
        core.services.wifi.forget(ssid: lingering)
    }

    private func setPhase(_ newPhase: ConnectionPhase, detail newDetail: String? = nil) {
        let d = newDetail ?? detail
        guard newPhase != phase || d != detail else { return }
        let phaseChanged = newPhase != phase
        phase = newPhase
        detail = d
        Log.i("STATE", "[state] \(SessionText.phaseLogLabel(newPhase))" + (d.isEmpty ? "" : " \u{2014} \(d)"))
        if phaseChanged {
            ride.linkPhaseChanged(newPhase)
            let streaming = linkState == .streaming && (newPhase == .streaming || newPhase == .mirroring)
            controls.linkStreamingChanged(streaming, mirror: mode == .mirror)
        }
    }

    private func cancelAutoConnect(unlatch: Bool) {
        guard let t = autoConnectTask else { return }
        t.cancel()
        autoConnectTask = nil
        if unlatch {
            autoConnectLatched = false
            Log.i("APP", "→ Auto-connect postponed (app left the foreground)")
        }
    }

    // MARK: - Wi-Fi

    private func joinBikeWifi(_ gen: UInt64) async -> WifiNetworkInfo? {
        guard let s = session else { return nil }
        let wifi = core.services.wifi
        let l = core.language
        do {
            let result = try await wifi.join(ssid: s.qr.ssid, passphrase: s.qr.password.isEmpty ? nil : s.qr.password)
            guard gen == generation else {
                // Stop was tapped while iOS was still applying the configuration: forget it again.
                if session == nil, phase == .stopped, wifi.supportsAutomaticJoin, result == .joined {
                    wifi.forget(ssid: s.qr.ssid)
                }
                return nil
            }
            switch result {
            case .joined, .alreadyJoined:
                Log.i("WIFI", result == .joined ? "Wi-Fi joined: \(s.qr.ssid)"
                    : "Wi-Fi already joined: \(s.qr.ssid) \u{2014} skipping re-join")
                let info = await wifi.currentNetwork()
                return gen == generation ? info : nil
            case .manualJoinRequired:
                let current = await wifi.currentNetwork()
                guard gen == generation else { return nil }
                if Self.isAlreadyOnBikeNetwork(current, ssid: s.qr.ssid) {
                    // The free flavor never knows the SSID: an address on a known dash subnet means
                    // iOS already joined the bike (a mode switch, a retry, an auto-join at ignition).
                    // Discovery confirms it (and fails fast when this is not the dash).
                    Log.i("WIFI", current.ssid == nil
                          ? "Wi-Fi already on a dash network (\(Self.describe(current)), SSID unknown) \u{2014} skipping the manual join"
                          : "Wi-Fi already joined: \(s.qr.ssid) \u{2014} skipping re-join")
                    return current
                }
                if s.trigger == .auto {
                    Log.i("APP", "→ Auto-connect: join '\(s.qr.ssid)' in Settings \u{25B8} Wi-Fi, then tap Connect")
                    endSession(.idle, detail: "", issue: nil)
                    return nil
                }
                return await awaitManualJoin(gen, message: SessionText.manualJoinMessage(ssid: s.qr.ssid, l), baseline: current)
            }
        } catch let failure as WifiJoinFailure {
            guard gen == generation else { return nil }
            Log.w("WIFI", "[wifi] join failed: \(failure.message)")
            if s.trigger == .auto, !failure.userCancelled {
                // §13.12: an auto-connect that cannot join stays idle (no stale red error) and retries
                // on the next foreground. A cancelled system prompt is not repeated (latched).
                endAutoConnectQuietly("join failed (\(failure.message))")
                return nil
            }
            if failure.userCancelled || s.trigger == .auto {
                endSession(.error, detail: failure.message, issue: nil)
                return nil
            }
            if failure.suggestsManualJoin {
                let baseline = await wifi.currentNetwork()
                guard gen == generation else { return nil }
                return await awaitManualJoin(gen, message: failure.message, baseline: baseline)
            }
            endSession(.error, detail: failure.message, issue: .wifiJoinFailed(message: failure.message))
            return nil
        } catch {
            guard gen == generation, !(error is CancellationError) else { return nil }
            Log.e("WIFI", "[wifi] join error: \(error)")
            if s.trigger == .auto {
                endAutoConnectQuietly("join error")
                return nil
            }
            let message = SessionText.connectFailed(l)
            endSession(.error, detail: message, issue: .other(message))
            return nil
        }
    }

    /// An auto-connect that failed with "not found" / "cannot join": back to idle without a dialog or
    /// a stale error, retried once on the next foreground (app-features §13.12, Android "retry on
    /// next resume").
    private func endAutoConnectQuietly(_ reason: String) {
        Log.i("APP", "→ Auto-connect: \(reason) \u{2014} staying idle; will retry when the app returns")
        retryAutoConnectAfterBackground = true
        endSession(.idle, detail: "", issue: nil)
    }

    /// Shows the manual-join prompt and waits for the bike network (or the rider's confirmation).
    /// `baseline` is the network read BEFORE the prompt is published: read after it, a switch the
    /// rider makes as soon as the sheet appears could become the baseline and never count as a change.
    private func awaitManualJoin(_ gen: UInt64, message: String, baseline: WifiNetworkInfo) async -> WifiNetworkInfo? {
        guard let s = session, gen == generation else { return nil }
        let l = core.language
        manualJoin = ManualWifiJoinPrompt(ssid: s.qr.ssid, password: s.qr.password.isEmpty ? nil : s.qr.password,
                                          message: message)
        setPhase(.joiningWifi, detail: SessionText.joinInSettings(ssid: s.qr.ssid, l))
        Log.i("WIFI", "[wifi] waiting for the rider to join \(s.qr.ssid) in Settings \u{25B8} Wi-Fi")
        let info = await waitForManualJoin(ssid: s.qr.ssid, baseline: baseline)
        guard gen == generation, let info else { return nil }
        manualJoin = nil
        Log.i("WIFI", "Wi-Fi joined: \(s.qr.ssid) (manual, \(Self.describe(info)))")
        setPhase(.joiningWifi, detail: s.bike.name)
        return info
    }

    private func waitForManualJoin(ssid: String, baseline: WifiNetworkInfo) async -> WifiNetworkInfo? {
        var continuation: AsyncStream<WifiNetworkInfo?>.Continuation?
        let stream = AsyncStream<WifiNetworkInfo?>(bufferingPolicy: .bufferingNewest(16)) { continuation = $0 }
        guard let signal = continuation else { return nil }
        manualJoinToken &+= 1
        let token = manualJoinToken
        manualJoinSignal = signal
        let wifi = core.services.wifi
        let feeder = Task.detached {
            for await info in wifi.networkUpdates() {
                if Task.isCancelled { break }
                signal.yield(info)
            }
        }
        defer {
            feeder.cancel()
            signal.finish()
            if manualJoinToken == token { manualJoinSignal = nil }
        }
        for await item in stream {
            if Task.isCancelled { return nil }
            guard let info = item else {
                Log.i("WIFI", "[wifi] rider confirmed the manual join")
                return await wifi.currentNetwork()
            }
            if Self.matchesManualJoin(info, ssid: ssid, baseline: baseline) { return info }
        }
        return nil
    }

    private func finishManualJoinSignal() {
        manualJoinSignal?.finish()
        manualJoinSignal = nil
    }

    /// Supervises the bike Wi-Fi for the whole session (BikeWifi onLost / onAvailable).
    private func watchWifi(_ gen: UInt64) {
        wifiWatchTask?.cancel()
        let updates = core.services.wifi.networkUpdates()
        wifiWatchTask = Task { [weak self] in
            for await info in updates {
                guard let self, gen == self.generation else { return }
                self.wifiChanged(info, gen: gen)
            }
        }
    }

    private func wifiChanged(_ info: WifiNetworkInfo, gen: UInt64) {
        guard let s = session else { return }
        let l = core.language
        if let d = dashlessNetwork, d != info { dashlessNetwork = nil }
        if Self.isOnBikeNetwork(info, ssid: s.qr.ssid, joined: sessionNetwork) {
            guard wifiLostAt != nil else { return }
            if linkState == .streaming, link != nil {
                // A path blip: the link never stopped streaming.
                clearWifiLoss()
                Log.i("WIFI", "Wi-Fi back: \(s.qr.ssid) \u{2014} the link kept streaming")
                ride.setLinkBanner(nil)
                setPhase(s.mode == .mirror ? .mirroring : .streaming, detail: s.bike.name)
                return
            }
            let resumed = isParked
            if info.ssid == s.qr.ssid {
                sessionNetwork = info
                clearWifiLoss()
                Log.i("WIFI", "Wi-Fi re-acquired: \(s.qr.ssid) \u{2014} restarting bike link on fresh network\(resumed ? " (resume)" : "")")
            } else {
                // SSID unknown: this network only LOOKS like the bike's (same gateway and /24 as the one
                // the session joined, CON:CL-3 / SEC-3). Try the dash, but keep the loss in force until
                // it streams: a fresh grace bounds the attempt, then the session parks (again) instead
                // of hosting the PXC listeners on, say, a home LAN with the same address plan.
                guard unconfirmedNetwork == nil, dashlessNetwork == nil else { return } // already tried
                unconfirmedNetwork = info
                armParkTimer(gen)
                Log.i("WIFI", "Wi-Fi looks like the bike's again (\(Self.describe(info)), SSID unknown) \u{2014} restarting bike link; waiting for the dash to confirm\(resumed ? " (resume)" : "")")
            }
            ride.setLinkBanner(SessionText.reconnectingBanner(l))
            resumeToken &+= 1
            let token = resumeToken
            Task { [weak self] in await self?.startLink(info: info, gen: gen, afterWifiLoss: true, resume: token) }
        } else if wifiLostAt == nil {
            resumeToken &+= 1
            wifiLostAt = core.services.clock.now()
            Log.w("WIFI", "Wi-Fi lost: bike network gone (\(Self.describe(info)))")
            if !isParked {
                setPhase(.reconnecting, detail: SessionText.waitingForBikeWifi(l))
                ride.setLinkBanner(SessionText.waitingForWifiBanner(l))
            }
            armParkTimer(gen)
        } else if unconfirmedNetwork != nil {
            // The look-alike network went away again before the dash answered: drop that attempt.
            unconfirmedNetwork = nil
            resumeToken &+= 1
            Log.w("WIFI", "Wi-Fi lost again before the dash answered (\(Self.describe(info)))")
            stopLink()
            if isParked {
                setPhase(.waitingForBike, detail: SessionText.willResume(l))
                ride.setLinkBanner(nil)
            } else {
                setPhase(.reconnecting, detail: SessionText.waitingForBikeWifi(l))
                ride.setLinkBanner(SessionText.waitingForWifiBanner(l))
            }
        }
    }

    /// (Re)starts the grace timer: the bike Wi-Fi must be confirmed (re-acquired by SSID, or the dash
    /// streaming again) before it fires, or the session parks.
    private func armParkTimer(_ gen: UInt64) {
        let grace = tuning.wifiParkGrace
        parkTask?.cancel()
        parkTask = Task { [weak self] in
            await sleepSeconds(grace)
            guard !Task.isCancelled, let self, gen == self.generation, self.wifiLostAt != nil else { return }
            self.wifiGraceExpired()
        }
    }

    /// The bike network is confirmed back: no loss, no park, no pending confirmation.
    private func clearWifiLoss() {
        wifiLostAt = nil
        parkTask?.cancel()
        parkTask = nil
        isParked = false
        unconfirmedNetwork = nil
        dashlessNetwork = nil
    }

    /// The bike Wi-Fi stayed away for the whole grace period (iOS battery policy, §11.6), or a link on a
    /// look-alike network (SSID unknown) never reached the dash within its grace.
    private func wifiGraceExpired() {
        guard let s = session else { return }
        if isParked {
            // Already parked: only an unconfirmed resume attempt can be running. It found no dash.
            guard unconfirmedNetwork != nil || link != nil else { return }
            dashlessNetwork = unconfirmedNetwork
            unconfirmedNetwork = nil
            resumeToken &+= 1
            Log.i("WIFI", "no dash answered on this Wi-Fi within \(Int(tuning.wifiParkGrace))s \u{2014} pausing the dash link again; watching for the bike")
            stopLink()
            if s.mode == .dashUI { core.services.projection.stop() }
            ride.setLinkBanner(nil)
            setPhase(.waitingForBike, detail: SessionText.willResume(core.language))
            return
        }
        let seconds = Int(tuning.wifiParkGrace)
        guard core.currentSettings.autoRecovery else {
            Log.i("WIFI", "bike Wi-Fi gone > \(seconds)s and auto-recovery is off \u{2014} stopping")
            stop()
            return
        }
        isParked = true
        if let u = unconfirmedNetwork { dashlessNetwork = u }
        unconfirmedNetwork = nil
        Log.i("WIFI", "bike Wi-Fi gone > \(seconds)s \u{2014} pausing the dash link to save battery; watching for the bike")
        stopLink()
        if s.mode == .dashUI {
            core.services.projection.stop()
            // The own UI is off the dash while parked: the trip auto-log stops and saves, the "Live"
            // label and Ride Mode follow. The resumed link's .streaming starts a new projection (CON:CL-2).
            ride.projectionChanged(active: false)
        }
        ride.setLinkBanner(nil)
        setPhase(.waitingForBike, detail: SessionText.willResume(core.language))
    }

    // MARK: - Link

    /// `resume`: the `resumeToken` of a Wi-Fi-back restart (nil for the session's first link).
    private func startLink(info: WifiNetworkInfo, gen: UInt64, afterWifiLoss: Bool, resume: UInt64? = nil) async {
        guard let s = session, gen == generation, resume == nil || resume == resumeToken else { return }
        let l = core.language
        setPhase(.linking, detail: afterWifiLoss ? SessionText.reconnecting(l) : s.bike.name)
        let signer: HuidSigner
        do {
            signer = try await core.signer()
        } catch {
            guard gen == generation else { return }
            Log.e("LINK", "RSA identity unavailable: \(error)")
            endSession(.error, detail: SessionText.connectFailed(l), issue: .other(SessionText.connectFailed(l)))
            return
        }
        guard gen == generation, let s = session, resume == nil || resume == resumeToken else { return }
        stopLink()
        let st = core.currentSettings
        let ownUI = s.mode == .dashUI
        let config = LinkConfiguration(
            qr: s.qr, profileOverride: st.profileOverride,
            learnedCanvas: core.dashMemory.learnedCanvas(forSSID: s.qr.ssid), forceTouchscreen: st.forceTouch,
            phone: phoneIdentity(), localHost: info.phoneIPv4, dashHost: nil,
            connectBackTimeout: tuning.connectBackTimeout,
            stallTimeout: st.autoRecovery ? tuning.stallTimeout : .greatestFiniteMagnitude,
            stallReconnectCooldown: tuning.stallReconnectCooldown, maxReconnectAttempts: tuning.maxReconnectAttempts,
            framePullTimeout: tuning.framePullTimeout)
        var options = LinkOptions()
        options.timings = tuning.linkTimings
        if !st.autoRecovery { options.timings.errorRearmInterval = nil }
        options.forceNonTouch = st.forceNonTouch
        options.wifiInterfaceName = info.interfaceName
        options.encoderParameters = ride.encoderParametersProvider(ownUI: ownUI)
        if let provider = tuning.interfaceProvider { options.interfaceProvider = provider }
        let source = ownUI ? ride.frameSource : core.services.mirror.frameSource
        let newLink = EasyConnLink(configuration: config, network: core.services.network, frameSource: source,
                                   signer: signer, discovery: core.services.discovery, gateway: info.gateway,
                                   clock: core.services.clock, options: options)
        link = newLink
        linkState = .idle
        diagnostics = LinkDiagnostics(profileName: newLink.currentProfile.name, projection: projectionSummary())
        linkSerial &+= 1
        let serial = linkSerial
        let events = newLink.events
        linkEventsTask = Task { [weak self] in
            for await event in events {
                // Cancelling does not stop an element already handed to this consumer.
                guard !Task.isCancelled, let self else { return }
                self.handleLinkEvent(event, gen: gen, serial: serial)
            }
        }
        Log.i("LINK", "→ starting PXC link (\(ownUI ? "own dash UI" : "mirror")) on \(Self.describe(info))")
        newLink.start()
    }

    private func stopLink() {
        linkEventsTask?.cancel()
        linkEventsTask = nil
        linkSerial &+= 1
        if let l = link {
            link = nil
            l.stop()
        }
        linkState = .idle
    }

    /// Internal for tests (stale-event filtering).
    func handleLinkEvent(_ event: LinkEvent, gen: UInt64, serial: UInt64) {
        guard gen == generation, serial == linkSerial, let link, let s = session else { return }
        switch event {
        case let .state(st):
            linkStateChanged(st, session: s)
        case let .dashIdentified(info):
            let profile = link.currentProfile
            diagnostics.dashInfo = info
            diagnostics.profileName = profile.name
            core.garage.setProfileHint(s.bike.id, info.profile)
            garage.reload()
            let st = core.currentSettings
            core.dashMemory.setLastDashTouch(!st.forceNonTouch && (st.forceTouch || profile.supportsScreenTouch))
            Log.i("APP", "dash identified: \(info.huName.isEmpty ? info.huid : info.huName) \u{2192} \(profile.name)")
            if s.mode == .dashUI { ride.profileIdentified(profile) } else { applyMirrorFit(profile: profile) }
        case let .canvas(c):
            diagnostics.canvas = c
            core.dashMemory.observe(ssid: s.qr.ssid, canvas: c)
            if s.mode == .dashUI { ride.canvasNegotiated(c) }
        case .mediaStarted:
            Log.d("APP", "dash (re)started pulling video")
        case let .touch(t):
            if s.mode == .dashUI { ride.handleDashTouch(t) } // mirrored apps get no dash touch
        case let .stats(st):
            if let at = st.lastFrameAt { lastFrameSentAt = at }
            diagnostics.stats = st
            diagnostics.projection = projectionSummary()
        }
    }

    private func linkStateChanged(_ st: LinkState, session s: ConnectionSession) {
        linkState = st
        diagnostics.state = st
        let l = core.language
        if st == .streaming, wifiLostAt != nil || isParked {
            // The dash streams again: the Wi-Fi loss was a blip, or a look-alike network (SSID unknown)
            // is confirmed to be the bike's.
            if unconfirmedNetwork != nil { Log.i("WIFI", "the dash answered \u{2014} this Wi-Fi is the bike's") }
            clearWifiLoss()
        }
        if wifiLostAt != nil || isParked {
            // The Wi-Fi supervisor owns the status line meanwhile. A terminal failure of an unconfirmed
            // attempt (auto-recovery off: nothing re-arms) still ends the session like any other.
            if unconfirmedNetwork != nil, case let .failed(f) = st, !core.currentSettings.autoRecovery {
                linkFailed(f, session: s)
            }
            return
        }
        switch st {
        case .idle, .stopped:
            break
        case .startingServers, .probing, .awaitingCallback:
            // While the link re-arms itself after an error, keep the error and its hint on screen
            // until the dash actually calls back.
            if phase != .linking, phase != .error { setPhase(.linking, detail: s.bike.name) }
        case .handshaking, .awaitingMedia:
            if phase != .linking { setPhase(.linking, detail: s.bike.name) }
        case .streaming:
            setPhase(s.mode == .mirror ? .mirroring : .streaming, detail: s.bike.name)
            // Phase may already be .mirroring (mirror start): still tell the handlebar engine.
            controls.linkStreamingChanged(true, mirror: s.mode == .mirror)
            ride.setLinkBanner(nil)
            if s.mode == .dashUI { ride.projectionChanged(active: true) }
            localNetworkIssueRaised = false
            sessionEverStreamed = true
            switch issue {
            case .dashNotFound?, .lostLink?, .localNetworkDenied?, .wifiUnavailable?: issue = nil
            default: break
            }
        case let .reconnecting(n):
            setPhase(.reconnecting, detail: SessionText.attempt(n, l))
            ride.setLinkBanner(SessionText.reconnectingBanner(l))
        case let .failed(f):
            linkFailed(f, session: s)
        }
    }

    private func linkFailed(_ f: LinkFailure, session s: ConnectionSession) {
        let l = core.language
        let recovery = core.currentSettings.autoRecovery
        ride.setLinkBanner(nil)
        switch f {
        case let .portInUse(port):
            Log.e("APP", "link ports are held by another app (:\(port)) \u{2014} close the official CFMoto / Carbit app")
            endSession(.error, detail: SessionText.officialAppInTheWay(l), issue: .portsInUse)
        case .localNetworkDenied:
            let d = SessionText.localNetworkDenied(l)
            if recovery {
                // Once per episode: the watchdog re-arm fails the same way every 20 s.
                if !localNetworkIssueRaised {
                    localNetworkIssueRaised = true
                    issue = .localNetworkDenied
                }
                setPhase(.error, detail: d)
            } else {
                endSession(.error, detail: d, issue: .localNetworkDenied)
            }
        case .noWifiAddress:
            endSession(.error, detail: SessionText.noWifiAddress(l), issue: .wifiUnavailable)
        case .dashNotFound:
            let d = SessionText.easyConnOffline(l)
            if s.trigger == .auto, !sessionEverStreamed, sessionNetwork?.ssid == nil {
                // An auto-connect on a network recognised only by its address plan (SSID unknown) may
                // be a home LAN on the dash's plan: never re-arm there unattended (§13.12, SEC-3).
                endAutoConnectQuietly("no dash answered on this Wi-Fi (SSID unknown)")
            } else if recovery {
                setPhase(.error, detail: d)
            } else {
                endSession(.error, detail: d, issue: .dashNotFound)
            }
        case .lostLink:
            let d = SessionText.lostLink(l)
            if recovery { setPhase(.error, detail: d) } else { endSession(.error, detail: d, issue: .lostLink) }
        case let .other(message):
            Log.e("LINK", "link failed: \(message)")
            let d = SessionText.connectFailed(l)
            endSession(.error, detail: d, issue: .other(d))
        }
    }

    // MARK: - Mirror

    private func applyMirrorFit(profile: BikeProfile) {
        let st = core.currentSettings
        let margins = CanvasFit.effectiveMargins(st.screenMargins, profileDefault: profile.defaultMargins)
        core.services.mirror.setFit(st.screenFit, margins: margins)
    }

    private func mirrorExtensionChanged(_ connected: Bool) {
        guard connected != isMirrorExtensionConnected else { return }
        isMirrorExtensionConnected = connected
        Log.i("MIRROR", connected ? "broadcast extension connected" : "broadcast extension disconnected")
    }

    private func projectionSummary() -> ProjectionStatsSummary {
        if session?.mode == .mirror {
            return ProjectionStatsSummary(mode: isMirrorExtensionConnected ? "mirror" : "mirror-waiting")
        }
        return core.services.projection.stats
    }

    // MARK: - Network helpers

    /// Known dash address plans (session-network.md §4.3): 192.168.0.x (CFDL16/26 SoftAP),
    /// 192.168.49.x (Wi-Fi Direct group owners), 192.168.4.x (Morini).
    nonisolated static let dashSubnetPrefixes = ["192.168.0.", "192.168.49.", "192.168.4."]

    nonisolated static func isOnDashSubnet(_ info: WifiNetworkInfo) -> Bool {
        let addresses = [info.phoneIPv4, info.gateway].compactMap { $0 }
        return addresses.contains { a in dashSubnetPrefixes.contains { a.hasPrefix($0) } }
    }

    /// On the bike Wi-Fi with an address. SSID known → it must match. SSID unknown (free flavor, or no
    /// precise location for a network the app did not configure) → only the network the session
    /// actually `joined` counts (same gateway and phone /24); without one, a known dash subnet. Any
    /// other Wi-Fi (home, café) is "bike gone": the grace / park apply and the link never restarts
    /// there (review CON:CL-3, SPEC:CL-5, SEC-3).
    nonisolated static func isOnBikeNetwork(_ info: WifiNetworkInfo, ssid: String, joined: WifiNetworkInfo? = nil) -> Bool {
        guard info.isWifiAvailable, info.phoneIPv4 != nil else { return false }
        if let current = info.ssid { return current == ssid }
        guard let joined else { return isOnDashSubnet(info) }
        return isSameNetwork(info, as: joined)
    }

    /// Same IPv4 /24 for the phone and the same gateway (both unknown counts as the same).
    nonisolated static func isSameNetwork(_ info: WifiNetworkInfo, as other: WifiNetworkInfo) -> Bool {
        guard let ip = info.phoneIPv4, let otherIP = other.phoneIPv4,
              let subnet = subnet24(ip), subnet == subnet24(otherIP) else { return false }
        return info.gateway == other.gateway
    }

    /// "192.168.0.23" → "192.168.0" (nil if not a dotted IPv4 address).
    nonisolated static func subnet24(_ ipv4: String) -> String? {
        let parts = ipv4.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        return parts[0 ... 2].joined(separator: ".")
    }

    /// Positively on the bike Wi-Fi (the SSID is known and matches).
    nonisolated static func isConfirmedBikeNetwork(_ info: WifiNetworkInfo, ssid: String) -> Bool {
        info.isWifiAvailable && info.phoneIPv4 != nil && info.ssid == ssid
    }

    /// iOS already joined the bike Wi-Fi: the SSID is known and matches, or (SSID unknown: free flavor,
    /// no precise location) the phone has an address on a known dash subnet. Auto-connect starts only
    /// then (§11.8), and a Connect skips the manual-join sheet (review CON:CL-4, SPEC:CL-4). Known
    /// limitation: an SSID-less home LAN on the dash's address plan looks the same — discovery then
    /// finds no dash, and an auto-connect ends quietly instead of re-arming there.
    nonisolated static func isAlreadyOnBikeNetwork(_ info: WifiNetworkInfo, ssid: String) -> Bool {
        if isConfirmedBikeNetwork(info, ssid: ssid) { return true }
        return info.ssid == nil && info.isWifiAvailable && info.phoneIPv4 != nil && isOnDashSubnet(info)
    }

    /// The rider joined the bike network in Settings: the SSID matches, or (SSID unknown) a NEW
    /// address appeared on a known dash subnet.
    nonisolated static func matchesManualJoin(_ info: WifiNetworkInfo, ssid: String, baseline: WifiNetworkInfo) -> Bool {
        guard info.isWifiAvailable, info.phoneIPv4 != nil else { return false }
        if let current = info.ssid { return current == ssid }
        let changed = !baseline.isWifiAvailable || baseline.phoneIPv4 != info.phoneIPv4 || baseline.gateway != info.gateway
        return changed && isOnDashSubnet(info)
    }

    nonisolated static func describe(_ info: WifiNetworkInfo) -> String {
        var parts = ["wifi=\(info.isWifiAvailable ? "up" : "down")"]
        if let s = info.ssid { parts.append("ssid=\(s)") }
        if let i = info.interfaceName { parts.append("iface=\(i)") }
        if let ip = info.phoneIPv4 { parts.append("ip=\(ip)") }
        if let gw = info.gateway { parts.append("gw=\(gw)") }
        if info.isLocalNetworkDenied { parts.append("localNetworkDenied") }
        return parts.joined(separator: " ")
    }
}

extension ConnectionModel {
    /// Brand/model sent in CLIENT_INFO when "Identify as an Android phone" is on (the values of the
    /// spec's Android example, control-plane.md §8). The UUID / OS version / Bluetooth name stay the same.
    static let androidCompatBrand = "samsung"
    static let androidCompatModel = "SM-G991B"

    /// The phone identity for the next link (per-process UUID, compatibility option applied).
    func phoneIdentity() -> PhoneIdentity {
        guard settings.identifyAsAndroidPhone else { return phone }
        var p = phone
        p.phoneBrand = Self.androidCompatBrand
        p.phoneModel = Self.androidCompatModel
        return p
    }
}
