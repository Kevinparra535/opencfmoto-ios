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

    // MARK: Internal state

    @ObservationIgnored var tuning = ConnectionTuning()
    @ObservationIgnored private let phone: PhoneIdentity
    @ObservationIgnored private(set) var session: ConnectionSession?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private(set) var link: EasyConnLink?
    @ObservationIgnored private var linkEventsTask: Task<Void, Never>?
    @ObservationIgnored private var wifiWatchTask: Task<Void, Never>?
    @ObservationIgnored private var parkTask: Task<Void, Never>?
    @ObservationIgnored private var autoConnectTask: Task<Void, Never>?
    @ObservationIgnored private var manualJoinSignal: AsyncStream<WifiNetworkInfo?>.Continuation?
    @ObservationIgnored private var manualJoinToken: UInt64 = 0
    @ObservationIgnored private(set) var linkState: LinkState = .idle
    @ObservationIgnored private var wifiLostAt: TimeInterval?
    @ObservationIgnored private(set) var isParked = false
    @ObservationIgnored private var lastFrameSentAt: TimeInterval?
    @ObservationIgnored private(set) var autoConnectLatched = false
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
        if phase.showsStop { stop() } else { connect() }
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
        guard let bike = core.garage.selected else {
            if !loggedAutoConnectIdle {
                loggedAutoConnectIdle = true
                Log.i("APP", "→ Auto-connect idle: no bike paired.")
            }
            return
        }
        autoConnectLatched = true
        Log.i("APP", "→ Auto-connect: '\(bike.name)' (range unknown \u{2014} trying anyway). Disable in Setup \u{25B8} Startup.")
        let delay = tuning.autoConnectDelay
        autoConnectTask?.cancel()
        autoConnectTask = Task { [weak self] in
            await sleepSeconds(delay)
            guard !Task.isCancelled, let self else { return }
            self.autoConnectTask = nil
            guard !self.phase.isBusy, !self.phase.isLive, self.session == nil else { return }
            self.begin(mode: .dashUI, trigger: .auto)
        }
    }

    func scenePhaseChanged(_ phase: AppScenePhase) {
        switch phase {
        case .background:
            // Android unlatches when the activity died before the delayed connect ran.
            cancelAutoConnect(unlatch: true)
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
        // Hard switch: the previous projection and link die first; the Wi-Fi association stays.
        teardownSession(keepWifi: true)
        forgetLingeringWifi(except: qr.ssid)
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
        manualJoin = nil
        wifiLostAt = nil
        isParked = false
        lastFrameSentAt = nil
        linkState = .idle
        diagnostics = LinkDiagnostics()
        mode = newMode
        session = ConnectionSession(bike: bike, qr: qr, mode: newMode, trigger: trigger)
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
        guard let s = session else { return }
        session = nil
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
            guard gen == generation else { return nil }
            switch result {
            case .joined, .alreadyJoined:
                Log.i("WIFI", result == .joined ? "Wi-Fi joined: \(s.qr.ssid)"
                    : "Wi-Fi already joined: \(s.qr.ssid) \u{2014} skipping re-join")
                let info = await wifi.currentNetwork()
                return gen == generation ? info : nil
            case .manualJoinRequired:
                let current = await wifi.currentNetwork()
                guard gen == generation else { return nil }
                if Self.isConfirmedBikeNetwork(current, ssid: s.qr.ssid) {
                    Log.i("WIFI", "Wi-Fi already joined: \(s.qr.ssid) \u{2014} skipping re-join")
                    return current
                }
                if s.trigger == .auto {
                    Log.i("APP", "→ Auto-connect: join '\(s.qr.ssid)' in Settings \u{25B8} Wi-Fi, then tap Connect")
                    endSession(.idle, detail: "", issue: nil)
                    return nil
                }
                return await awaitManualJoin(gen, message: SessionText.manualJoinMessage(ssid: s.qr.ssid, l))
            }
        } catch let failure as WifiJoinFailure {
            guard gen == generation else { return nil }
            Log.w("WIFI", "[wifi] join failed: \(failure.message)")
            if failure.userCancelled || s.trigger == .auto {
                endSession(.error, detail: failure.message, issue: nil)
                return nil
            }
            if failure.suggestsManualJoin {
                return await awaitManualJoin(gen, message: failure.message)
            }
            endSession(.error, detail: failure.message, issue: .wifiJoinFailed(message: failure.message))
            return nil
        } catch {
            guard gen == generation, !(error is CancellationError) else { return nil }
            Log.e("WIFI", "[wifi] join error: \(error)")
            let message = s.trigger == .auto ? SessionText.autoConnectFailed(l) : SessionText.connectFailed(l)
            endSession(.error, detail: message, issue: s.trigger == .auto ? nil : .other(message))
            return nil
        }
    }

    /// Shows the manual-join prompt and waits for the bike network (or the rider's confirmation).
    private func awaitManualJoin(_ gen: UInt64, message: String) async -> WifiNetworkInfo? {
        guard let s = session else { return nil }
        let l = core.language
        manualJoin = ManualWifiJoinPrompt(ssid: s.qr.ssid, password: s.qr.password.isEmpty ? nil : s.qr.password,
                                          message: message)
        setPhase(.joiningWifi, detail: SessionText.joinInSettings(ssid: s.qr.ssid, l))
        Log.i("WIFI", "[wifi] waiting for the rider to join \(s.qr.ssid) in Settings \u{25B8} Wi-Fi")
        let baseline = await core.services.wifi.currentNetwork()
        guard gen == generation else { return nil }
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
        if Self.isOnBikeNetwork(info, ssid: s.qr.ssid) {
            guard wifiLostAt != nil else { return }
            wifiLostAt = nil
            parkTask?.cancel()
            parkTask = nil
            let resumed = isParked
            isParked = false
            if linkState == .streaming, link != nil {
                // A path blip: the link never stopped streaming.
                Log.i("WIFI", "Wi-Fi back: \(s.qr.ssid) \u{2014} the link kept streaming")
                ride.setLinkBanner(nil)
                setPhase(s.mode == .mirror ? .mirroring : .streaming, detail: s.bike.name)
                return
            }
            Log.i("WIFI", "Wi-Fi re-acquired: \(s.qr.ssid) \u{2014} restarting bike link on fresh network\(resumed ? " (resume)" : "")")
            ride.setLinkBanner(SessionText.reconnectingBanner(l))
            Task { [weak self] in await self?.startLink(info: info, gen: gen, afterWifiLoss: true) }
        } else {
            guard wifiLostAt == nil else { return }
            wifiLostAt = core.services.clock.now()
            Log.w("WIFI", "Wi-Fi lost: bike network gone (\(Self.describe(info)))")
            if !isParked {
                setPhase(.reconnecting, detail: SessionText.waitingForBikeWifi(l))
                ride.setLinkBanner(SessionText.waitingForWifiBanner(l))
            }
            let grace = tuning.wifiParkGrace
            parkTask?.cancel()
            parkTask = Task { [weak self] in
                await sleepSeconds(grace)
                guard !Task.isCancelled, let self, gen == self.generation, self.wifiLostAt != nil else { return }
                self.wifiGraceExpired()
            }
        }
    }

    /// The bike Wi-Fi stayed away for the whole grace period (iOS battery policy, §11.6).
    private func wifiGraceExpired() {
        guard let s = session, !isParked else { return }
        let seconds = Int(tuning.wifiParkGrace)
        guard core.currentSettings.autoRecovery else {
            Log.i("WIFI", "bike Wi-Fi gone > \(seconds)s and auto-recovery is off \u{2014} stopping")
            stop()
            return
        }
        isParked = true
        Log.i("WIFI", "bike Wi-Fi gone > \(seconds)s \u{2014} pausing the dash link to save battery; watching for the bike")
        stopLink()
        if s.mode == .dashUI { core.services.projection.stop() }
        ride.setLinkBanner(nil)
        setPhase(.waitingForBike, detail: SessionText.willResume(core.language))
    }

    // MARK: - Link

    private func startLink(info: WifiNetworkInfo, gen: UInt64, afterWifiLoss: Bool) async {
        guard let s = session, gen == generation else { return }
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
        guard gen == generation, let s = session else { return }
        stopLink()
        let st = core.currentSettings
        let ownUI = s.mode == .dashUI
        let config = LinkConfiguration(
            qr: s.qr, profileOverride: st.profileOverride,
            learnedCanvas: core.dashMemory.learnedCanvas(forSSID: s.qr.ssid), forceTouchscreen: st.forceTouch,
            phone: phone, localHost: info.phoneIPv4, dashHost: nil,
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
        let id = ObjectIdentifier(newLink)
        let events = newLink.events
        linkEventsTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handleLinkEvent(event, gen: gen, linkID: id)
            }
        }
        Log.i("LINK", "→ starting PXC link (\(ownUI ? "own dash UI" : "mirror")) on \(Self.describe(info))")
        newLink.start()
    }

    private func stopLink() {
        linkEventsTask?.cancel()
        linkEventsTask = nil
        if let l = link {
            link = nil
            l.stop()
        }
        linkState = .idle
    }

    private func handleLinkEvent(_ event: LinkEvent, gen: UInt64, linkID: ObjectIdentifier) {
        guard gen == generation, let link, ObjectIdentifier(link) == linkID, let s = session else { return }
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
        if st == .streaming, wifiLostAt != nil {
            // The dash is back on its own: the Wi-Fi loss was a blip.
            wifiLostAt = nil
            parkTask?.cancel()
            parkTask = nil
        }
        if wifiLostAt != nil || isParked {
            return // the Wi-Fi supervisor owns the status line meanwhile
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
                issue = .localNetworkDenied
                setPhase(.error, detail: d)
            } else {
                endSession(.error, detail: d, issue: .localNetworkDenied)
            }
        case .noWifiAddress:
            endSession(.error, detail: SessionText.noWifiAddress(l), issue: .wifiUnavailable)
        case .dashNotFound:
            let d = SessionText.easyConnOffline(l)
            if recovery { setPhase(.error, detail: d) } else { endSession(.error, detail: d, issue: .dashNotFound) }
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

    /// On the bike Wi-Fi with an address (SSID unknown → any Wi-Fi with an IPv4 counts).
    nonisolated static func isOnBikeNetwork(_ info: WifiNetworkInfo, ssid: String) -> Bool {
        guard info.isWifiAvailable, info.phoneIPv4 != nil else { return false }
        guard let current = info.ssid else { return true }
        return current == ssid
    }

    /// Positively on the bike Wi-Fi (the SSID is known and matches).
    nonisolated static func isConfirmedBikeNetwork(_ info: WifiNetworkInfo, ssid: String) -> Bool {
        info.isWifiAvailable && info.phoneIPv4 != nil && info.ssid == ssid
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
