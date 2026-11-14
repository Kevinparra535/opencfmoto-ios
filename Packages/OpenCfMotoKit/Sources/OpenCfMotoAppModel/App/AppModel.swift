// SPDX-License-Identifier: AGPL-3.0-or-later
// WAVE-2 SKELETON — owner: logic-session. The PUBLIC SURFACE below is the contract the SwiftUI
// layer codes against: implement the bodies, add private helpers / new files freely, add new
// public members only if needed (report them), never rename or remove existing public members.
//
// Root of the model layer. The SwiftUI app creates ONE instance (via the platform composition
// root, App/Sources/Services/AppPlatform.swift) and injects it with `.environment(model)`.
// Sub-models are created here in dependency order and are never replaced.
//
// Behaviour to implement:
// - `start()` (once, at launch): restore logs redactor, refresh permissions, prepare the signer in
//   the background (`core.signer()`), wire LogsModel.diagnostics, then
//   `connection.maybeAutoConnect()` if onboarding is complete.
// - `scenePhaseChanged`: forward to ride + connection; on `.active` refresh permissions and retry
//   auto-connect (Android onResume).
// - `handleOpenURL`: `.gpx` files → `navigation.previewGpx` (UI/UX P0, UX-17: a preview with
//   «Seguir este track» / «Cancelar» — an opened track never replaces the route silently); opencfmoto
//   pairing URLs / Wi-Fi URLs → `garage.pair(rawQR:)`; settings / map packs (`.json` with format
//   "opencfmoto.settings" / "opencfmoto.map") → `pendingImport`, applied only by
//   `confirmPendingImport()`. The copy iOS puts in Documents/Inbox is deleted once read. Returns a
//   localized message for a toast.
//
// Ported from OpenCfMoto (Android) OpenCfMotoApp.kt (process start) and MainActivity.kt
// (onCreate / onResume / intent handling).

import Foundation
import Observation
import OpenCfMotoCore

@MainActor
@Observable
public final class AppModel {
    @ObservationIgnored public let core: AppCore

    public let permissions: PermissionsModel
    public let garage: GarageModel
    public let settings: SettingsModel
    public let logs: LogsModel
    public let trips: TripsModel
    public let navigation: NavigationModel
    /// Fuel MVP «Combustible»: range estimate, refuel log, «¿Cuál es tu moto?».
    public let fuel: FuelModel
    public let controls: ControlsModel
    /// Apple Music on the dash (iOS addition).
    public let music: MusicModel
    public let ride: RideModel
    public let connection: ConnectionModel

    /// One-line transient message for the whole app (imports, errors); auto-cleared.
    public private(set) var banner: String?
    /// A settings / map-data pack opened from another app, waiting for the rider's confirmation
    /// before it overwrites anything (app-features §3.5). The UI shows a confirmation dialog.
    public private(set) var pendingImport: PendingImport?

    public var flavor: BuildFlavor { core.services.system.flavor }
    public var appVersion: String { core.services.system.appVersion }
    public var buildNumber: String { core.services.system.buildNumber }

    /// How long `banner` stays visible.
    @ObservationIgnored var bannerDuration: TimeInterval = 3.5
    /// Where iOS copies documents opened from Mail / Files / AirDrop ("copy, don't open in place"):
    /// `Documents/Inbox`. The copies are deleted once read (review IOS-6 / SEC-6). nil outside iOS
    /// (never touch a desktop's ~/Documents); tests set a temp directory.
    @ObservationIgnored var inboxDirectory: URL? = AppModel.defaultInboxDirectory()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    /// Saves the session log every `sessionLogInterval` while a Connect / Mirror session runs (and logs
    /// the `[lock]` line then while the phone is locked during an own-UI session).
    @ObservationIgnored private var sessionLogTask: Task<Void, Never>?
    @ObservationIgnored var sessionLogInterval: TimeInterval = 30
    /// Locked iPhone (Phase 0): the scene phase last reported (`.active` at launch, not logged).
    @ObservationIgnored private(set) var scenePhase: AppScenePhase = .active
    /// Monotonic time (`services.clock`) the scene went to `.background`; nil outside the background.
    @ObservationIgnored private var backgroundSince: TimeInterval?

    public init(services: AppServices) {
        let core = AppCore(services: services)
        self.core = core
        permissions = PermissionsModel(core: core)
        garage = GarageModel(core: core)
        settings = SettingsModel(core: core, garage: garage)
        logs = LogsModel(core: core)
        trips = TripsModel(core: core)
        navigation = NavigationModel(core: core)
        fuel = FuelModel(core: core, garage: garage, settings: settings, navigation: navigation)
        controls = ControlsModel(core: core, settings: settings)
        music = MusicModel(core: core)
        ride = RideModel(core: core, settings: settings, navigation: navigation, trips: trips)
        connection = ConnectionModel(core: core, garage: garage, settings: settings, ride: ride,
                                     controls: controls)
        wire()
    }

    /// Call once when the app launches.
    public func start() {
        guard !started else { return }
        started = true
        let system = core.services.system
        LogRedactor.install(on: .shared, includeSecrets: core.currentSettings.includeSecretsInLogs)
        // The previous session's log (saved on background / while linked) and a pending crash report.
        logs.hydrate()
        startSessionLogSaver()
        Log.i("APP", "OpenCfMoto iOS \(system.appVersion) (\(system.buildNumber)) \u{00B7} \(system.deviceModel) \(system.systemVersion) \u{00B7} \(system.flavor.rawValue) build \u{00B7} lang=\(core.language.rawValue)")
        reportUncleanBackgroundExit()
        let core = self.core
        Task.detached(priority: .utility) {
            do {
                _ = try await core.signer()
                Log.d("APP", "RSA identity ready")
            } catch {
                Log.w("APP", "RSA identity not ready yet: \(error)")
            }
        }
        Task { [weak self] in await self?.permissions.refresh() }
        // Exports of a previous run (trip GPX, logs, settings / map packs) are not needed any more.
        let purged = LogicData.purgeExports(in: core.services.files.exportsDirectory, olderThan: 0)
        if purged > 0 { Log.i("APP", "removed \(purged) old share export(s)") }
        Log.i("APP", "Ready. Tap Connect to project the map to your dash.")
        if permissions.hasCompletedOnboarding { connection.maybeAutoConnect() }
    }

    public func scenePhaseChanged(_ phase: AppScenePhase) {
        noteScenePhase(phase) // L14 and the unclean-exit marker, before the sub-models react
        ride.scenePhaseChanged(phase)
        connection.scenePhaseChanged(phase)
        music.scenePhaseChanged(phase)
        fuel.scenePhaseChanged(phase)
        if phase == .background {
            // A jetsam kill or a force-quit from here on must not lose the ride log (review SPEC:CL-6).
            logs.persistSession()
            // No share sheet is open once the app left the foreground (review SEC-6 / IOS-6). The dash
            // video recording the Logs screen offers stays (the Phase 0 checklist shares it after the
            // unlock) until a new recording replaces it; the next launch clears it with the rest.
            LogicData.purgeExports(in: core.services.files.exportsDirectory, olderThan: LogicData.backgroundExportAge,
                                   now: Date(), except: ride.dashVideoRecordingURL?.lastPathComponent)
            purgeInbox()
        }
        guard phase == .active else { return }
        Task { [weak self] in await self?.permissions.refresh() }
        if started, permissions.hasCompletedOnboarding { connection.maybeAutoConnect() }
    }

    /// Files / URLs opened with the app. Returns a localized message for the banner (or nil).
    @discardableResult
    public func handleOpenURL(_ url: URL) -> String? {
        let message = openURLMessage(url)
        if let message { showBanner(message) }
        return message
    }

    /// Every `sessionLogInterval` while a session is active: the session log goes to disk (off the main
    /// actor), so a crash mid-ride keeps it (app-features §6.4: "every ~30 s while linked").
    private func startSessionLogSaver() {
        sessionLogTask?.cancel()
        let interval = sessionLogInterval
        sessionLogTask = Task { [weak self] in
            while !Task.isCancelled {
                await sleepSeconds(interval)
                guard !Task.isCancelled, let self else { return }
                self.logLockStatus() // before the save: the saved log ends with it
                if self.connection.isSessionActive { self.logs.persistSession(synchronously: false) }
            }
        }
    }

    // MARK: - Locked iPhone diagnostics (Phase 0: L14, L15, L16)

    /// L14 on every scene-phase change, and the unclean-background-exit marker: set at `.background`
    /// during a session, cleared at `.active` (and at the session end and at launch).
    private func noteScenePhase(_ phase: AppScenePhase) {
        let old = scenePhase
        guard phase != old else { return }
        scenePhase = phase
        let now = core.services.clock.now()
        let away = old == .background ? backgroundSince.map { now - $0 } : nil
        Log.i("APP", LockDiagnostics.sceneChange(from: old, to: phase, backgroundSeconds: away, context: lockSessionContext))
        switch phase {
        case .background:
            backgroundSince = now
            if connection.isSessionActive {
                core.services.keyValueStore.set(core.services.now().timeIntervalSince1970,
                                                forKey: LockDiagnostics.backgroundSessionMarkerKey)
            }
        case .active:
            backgroundSince = nil
            clearBackgroundMarker()
        case .inactive:
            backgroundSince = nil
        }
    }

    /// L14's context: what the session is doing right now.
    private var lockSessionContext: String {
        LockDiagnostics.sessionContext(isSessionActive: connection.isSessionActive, mode: connection.mode,
                                       phase: connection.phase)
    }

    /// L15 (`[lock]`), from the session-log saver loop: only while the scene is `.background` and an
    /// own-UI session runs (streaming or not: `link=reconnecting wifi=down` is what a lost link looks like).
    func logLockStatus() {
        guard scenePhase == .background, connection.isSessionActive, connection.mode == .dashUI else { return }
        let services = core.services
        let now = services.clock.now()
        let wall = services.now().timeIntervalSince1970
        let system = services.system
        let status = LockDiagnostics.LockStatus(
            lockedSeconds: backgroundSince.map { now - $0 } ?? 0,
            link: connection.phase,
            bikeWifiLost: connection.isBikeWifiLost,
            projection: services.projection.stats,
            gpsAgeSeconds: ride.lastFix.map { wall - Double($0.timeMs) / 1000 },
            headingAgeSeconds: ride.lastHeadingAt.map { now - $0 },
            battery: system.batteryStatus,
            thermal: system.thermalLevel,
            lowPowerMode: system.isLowPowerModeEnabled)
        Log.i("APP", LockDiagnostics.lockStatus(status))
    }

    /// At launch: the previous run left the marker, so it ended in the background during a session (iOS
    /// stopped it, or the rider swiped it away): L16 first, then the marker goes. That run's restored log
    /// stays in this run's saved log, so a second kill before the rider shares does not lose it.
    private func reportUncleanBackgroundExit() {
        let store = core.services.keyValueStore
        let key = LockDiagnostics.backgroundSessionMarkerKey
        guard let stamp = store.double(forKey: key) else { return }
        if stamp.isFinite {
            Log.w("APP", LockDiagnostics.uncleanBackgroundExit(backgroundedAt: Date(timeIntervalSince1970: stamp),
                                                               timeZone: logs.timeZone))
        }
        logs.carriesRestoredSession = true
        store.removeValue(forKey: key)
    }

    private func clearBackgroundMarker() {
        let store = core.services.keyValueStore
        let key = LockDiagnostics.backgroundSessionMarkerKey
        if store.double(forKey: key) != nil { store.removeValue(forKey: key) }
    }

    public func showBanner(_ text: String) {
        banner = text
        bannerTask?.cancel()
        let duration = bannerDuration
        bannerTask = Task { [weak self] in
            await sleepSeconds(duration)
            guard !Task.isCancelled, let self, self.banner == text else { return }
            self.banner = nil
        }
    }

    /// Applies `pendingImport` (the rider confirmed). Shows the result as the banner.
    public func confirmPendingImport() {
        guard let pending = pendingImport else { return }
        pendingImport = nil
        let result = pending.kind == .settings ? settings.importSettings(pending.text) : settings.importMapData(pending.text)
        if !result.message.isEmpty { showBanner(result.message) }
    }

    /// Drops `pendingImport` without changing anything.
    public func cancelPendingImport() { pendingImport = nil }

    /// Holds an opened pack until the rider confirms (used by `handleOpenURL`).
    func requestImportConfirmation(_ pending: PendingImport) { pendingImport = pending }

    public func dismissBanner() {
        bannerTask?.cancel()
        bannerTask = nil
        banner = nil
    }

    // MARK: - Wiring

    private func wire() {
        controls.inputSink = { [weak ride] input in ride?.handleDashInput(input) }
        permissions.onLocationPermissionChange = { [weak ride, weak connection] p in
            ride?.locationPermissionChanged(p)
            connection?.locationPermissionChanged(p)
        }
        permissions.onOnboardingCompleted = { [weak connection] in connection?.maybeAutoConnect() }
        logs.diagnostics = { [weak self] in self?.problemDiagnostics() ?? [:] }
        // Locked iPhone (Phase 0): a session that ended can no longer end "during a dash session".
        connection.onSessionActiveChange = { [weak self] active in
            if !active { self?.clearBackgroundMarker() }
            self?.fuel.sessionChanged(active: active)
        }
        ride.pocketOfferBusyReason = { [weak self] in self?.pocketOfferBusyReason() }
        wireMusic()
        wireFuel()
    }

    /// Fuel MVP: the km counter feed (every RideModel fix, counted only while the session is countable), the
    /// session bike, the live CLIENT_INFO for «¿Cuál es tu moto?», the moving lock, the dash alert and removal.
    private func wireFuel() {
        let fuel = self.fuel
        ride.onLocationFix = { [weak fuel] fix in fuel?.ingest(fix) }
        fuel.sessionBikeProvider = { [weak connection] in connection?.sessionBikeId }
        fuel.isCountableProvider = { [weak connection] in connection?.isFuelCountable ?? false }
        connection.onFuelCountableChange = { [weak fuel] on in fuel?.countableChanged(on) }
        fuel.liveDashInfoProvider = { [weak connection] in connection?.diagnostics.dashInfo }
        fuel.lastFixProvider = { [weak ride] in ride?.lastFix }
        fuel.onDashAlert = { [weak ride] alert in ride?.announceFuel(alert) }
        fuel.onDashAlertCancel = { [weak ride] in ride?.cancelFuelAlert() }
        fuel.onDashAlertUndeliveredDrop = { [weak ride] in ride?.dropFuelAlertIfUndelivered() }
        ride.onFuelAlertDropped = { [weak fuel] alert in fuel?.fuelAlertDropped(alert) }
        garage.observeRemoval { [weak fuel] id in fuel?.bikeRemoved(id) }
    }

    /// Apple Music on the dash (contract §8.3): the dash model / intents ↔ MusicModel, and who holds
    /// the handlebar buttons while the Music app plays (§7 R2 / R3).
    private func wireMusic() {
        let music = self.music
        let handlebar = core.services.handlebar
        ride.nowPlayingProvider = { [weak music] in music?.dashNowPlaying }
        ride.musicCommandSink = { [weak music] command, fromDash in music?.perform(command, fromDash: fromDash) }
        ride.onDashActivityChange = { [weak music] active in music?.setDashActive(active) }
        music.onDashChange = { [weak ride] in ride?.setNeedsModelUpdate() }
        music.onPlaybackStarted = { [weak ride, weak controls] in
            if handlebar.isEnabled { ride?.handlebarHandedToMusic() }
            controls?.musicPlaybackStarted()
        }
        music.onPlaybackPaused = { [weak controls] in controls?.musicPlaybackPaused() }
        controls.onHandlebarReclaimed = { [weak ride] in ride?.handlebarBackToDash() }
        music.setDashActive(ride.isDashUIActive)
    }

    /// What needs the rider on the phone right now, for the «Modo bolsillo» offer (P0, UX-01): no
    /// countdown starts — and none ends in pocket mode — over a dialog, the manual Wi-Fi join, an
    /// opened file waiting for an answer or the dash's "type on the phone" request.
    func pocketOfferBusyReason() -> String? {
        if let issue = connection.issue, issue != .noBikePaired { return "a connection dialog is open" }
        if connection.manualJoin != nil { return "the manual Wi-Fi join is open" }
        if pendingImport != nil { return "an opened settings file waits for an answer" }
        if navigation.pendingGpx != nil, navigation.isGpxPreviewOnScreen { return "an opened GPX track waits for an answer" }
        if navigation.typeOnPhoneRequested { return "the dash asks to type on the phone" }
        return nil
    }

    // MARK: - Opened files

    private func openURLMessage(_ url: URL) -> String? {
        let l = core.language
        guard url.isFileURL else {
            // opencfmoto / Carbit pairing URLs and Wi-Fi QR payloads.
            return pairingMessage(url.absoluteString)
        }
        let ext = url.pathExtension.lowercased()
        let data = Self.readFile(url)
        removeInboxCopy(url) // read into memory (or unreadable): the system's copy is not needed
        guard let data else {
            Log.w("APP", "open: cannot read \(url.lastPathComponent)")
            return SessionText.cannotReadFile(l)
        }
        if ext == "gpx" || Self.looksLikeGPX(data) {
            // A preview first (UX-17): the Map hub shows the track with «Seguir este track» /
            // «Cancelar», and nothing is replaced until the rider follows it. No banner: the preview is
            // the answer (an unreadable file is reported instead).
            let errorBefore = navigation.lastError
            navigation.previewGpx(data: data, fileName: url.lastPathComponent)
            if let err = navigation.lastError, err != errorBefore { return err }
            Log.i("APP", "open: GPX \(url.lastPathComponent) \u{2014} waiting for the rider (preview)")
            return nil
        }
        let text = String(decoding: data, as: UTF8.self)
        // Packs overwrite the bike tuning / map data: like Settings ▸ Import, they wait for the rider's
        // "Import settings?" / "Import map data?" confirmation (app-features §3.5; review SPEC:CL-11).
        if text.contains("opencfmoto.settings") {
            Log.i("APP", "open: settings pack \(url.lastPathComponent) \u{2014} waiting for confirmation")
            requestImportConfirmation(PendingImport(kind: .settings, fileName: url.lastPathComponent, text: text))
            return nil
        }
        if text.contains("opencfmoto.map") {
            Log.i("APP", "open: map data \(url.lastPathComponent) \u{2014} waiting for confirmation")
            requestImportConfirmation(PendingImport(kind: .mapData, fileName: url.lastPathComponent, text: text))
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ext == "txt", !trimmed.isEmpty, trimmed.count < 2048, !trimmed.contains("\n") {
            return pairingMessage(trimmed) // a QR payload saved as text
        }
        Log.w("APP", "open: unsupported file \(url.lastPathComponent)")
        return SessionText.cannotOpenFile(l)
    }

    private func pairingMessage(_ raw: String) -> String? {
        switch garage.pair(rawQR: raw) {
        case let .paired(bike):
            return SessionText.bikeAdded(bike.name, core.language)
        case let .invalid(hint):
            return hint
        }
    }

    private static func readFile(_ url: URL) -> Data? {
        #if canImport(Darwin)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        #endif
        return try? Data(contentsOf: url)
    }

    /// Deletes the copy iOS put in `Documents/Inbox` for an opened document (nothing else would).
    private func removeInboxCopy(_ url: URL) {
        guard Self.isInboxCopy(url, inbox: inboxDirectory) else { return }
        if (try? FileManager.default.removeItem(at: url)) != nil {
            Log.d("APP", "open: removed the Inbox copy of \(url.lastPathComponent)")
        }
    }

    /// Leftover Inbox copies (e.g. from versions that kept them) go when the app leaves the foreground.
    private func purgeInbox() {
        guard let inbox = inboxDirectory else { return }
        let removed = LogicData.purgeExports(in: inbox, olderThan: 0, now: Date())
        if removed > 0 { Log.i("APP", "removed \(removed) opened-file cop(ies) from the Inbox") }
    }

    /// True when `url` is a file directly inside `inbox` (symlinks and the /private prefix ignored).
    nonisolated static func isInboxCopy(_ url: URL, inbox: URL?) -> Bool {
        guard let inbox, url.isFileURL else { return false }
        func normalized(_ u: URL) -> String {
            var p = u.standardizedFileURL.resolvingSymlinksInPath().path
            if p.hasPrefix("/private/") { p.removeFirst("/private".count) }
            while p.count > 1, p.hasSuffix("/") { p.removeLast() }
            return p
        }
        return normalized(url.deletingLastPathComponent()) == normalized(inbox)
    }

    nonisolated static func defaultInboxDirectory() -> URL? {
        #if os(iOS)
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Inbox", isDirectory: true)
        #else
        return nil
        #endif
    }

    private static func looksLikeGPX(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(512), as: UTF8.self)
        return head.contains("<gpx")
    }

    // MARK: - Problem report diagnostics

    /// For LogsModel's problem report: `phase` / `detail` / `profile` / `ssid` fill the Android SETUP
    /// block (LogsModel computes the settings lines itself); every other key is an extra
    /// `key=value` line (link, projection, permissions, power).
    private func problemDiagnostics() -> [String: String] {
        let st = core.currentSettings
        let system = core.services.system
        let diag = connection.diagnostics
        var d: [String: String] = [
            "phase": SessionText.phaseAndroidName(connection.phase),
            "detail": connection.detail,
            "mode": connection.mode.rawValue,
            "linkState": diag.state.description,
            "framesSent": String(diag.stats.framesSent),
            "keyframesSent": String(diag.stats.keyframesSent),
            "missedPulls": String(diag.stats.missedPulls),
            "projection": diag.projection.mode,
            "location": permissions.location.rawValue + (permissions.isPreciseLocation ? "" : " (approximate)"),
            "localNetwork": permissions.localNetwork.rawValue,
            "powerMode": st.powerMode.rawValue,
            "videoQuality": st.videoQuality.rawValue,
            "thermal": system.thermalLevel.androidName,
            "lowPowerMode": String(system.isLowPowerModeEnabled),
        ]
        if let name = diag.profileName { d["profile"] = name }
        if let ssid = connection.session?.qr.ssid ?? core.garage.selected?.ssid { d["ssid"] = ssid }
        if let bike = core.garage.selected { d["bike"] = bike.name }
        if let info = diag.dashInfo {
            d["dash"] = "\(info.huName) sdk=\(info.sdkVersion) ver=\(info.versionName) touch=\(info.supportsScreenTouch)"
        }
        if let c = diag.canvas { d["canvas"] = c.description }
        d["music"] = music.diagnostics
        // Fuel MVP (promote catalog rows from field reports): the stored QR's model id (no connect needed), the
        // 4-character dash family prefix of the HUID (never the serial) and the fuel set-up — no litres, prices
        // or positions.
        if let id = connection.sessionBikeId ?? core.garage.selected?.id {
            d["modelId"] = core.garage.qr(for: id)?.modelId ?? "none"
            let fuelState = fuel.state(for: id)
            let kind = fuelState.profile.map { $0.catalogId.map { "catalog:\($0)" } ?? "manual" } ?? "none"
            d["fuel"] = kind + (fuelState.log.isEmpty ? "" : ", log \(fuelState.log.count)")
        }
        if let huid = diag.dashInfo?.huid, !huid.isEmpty, connection.sessionBikeId != nil {
            d["huidPrefix"] = String(huid.prefix(4))
        }
        return d
    }
}
