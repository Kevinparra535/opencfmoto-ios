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
// - `handleOpenURL`: `.gpx` files → `navigation.loadGpx`; opencfmoto pairing URLs / Wi-Fi URLs
//   → `garage.pair(rawQR:)`; settings / map packs (`.json` with format "opencfmoto.settings" /
//   "opencfmoto.map") → `pendingImport`, applied only by `confirmPendingImport()`. The copy iOS
//   puts in Documents/Inbox is deleted once read. Returns a localized message for a toast.
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
    public let controls: ControlsModel
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

    public init(services: AppServices) {
        let core = AppCore(services: services)
        self.core = core
        permissions = PermissionsModel(core: core)
        garage = GarageModel(core: core)
        settings = SettingsModel(core: core, garage: garage)
        logs = LogsModel(core: core)
        trips = TripsModel(core: core)
        navigation = NavigationModel(core: core)
        controls = ControlsModel(core: core, settings: settings)
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
        Log.i("APP", "OpenCfMoto iOS \(system.appVersion) (\(system.buildNumber)) \u{00B7} \(system.deviceModel) \(system.systemVersion) \u{00B7} \(system.flavor.rawValue) build \u{00B7} lang=\(core.language.rawValue)")
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
        ride.scenePhaseChanged(phase)
        connection.scenePhaseChanged(phase)
        if phase == .background {
            // No share sheet is open once the app left the foreground (review SEC-6 / IOS-6).
            LogicData.purgeExports(in: core.services.files.exportsDirectory, olderThan: LogicData.backgroundExportAge,
                                   now: Date())
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
            let errorBefore = navigation.lastError
            navigation.loadGpx(data: data, fileName: url.lastPathComponent)
            if let err = navigation.lastError, err != errorBefore { return err }
            Log.i("APP", "open: GPX \(url.lastPathComponent)")
            return SessionText.gpxLoaded(url.deletingPathExtension().lastPathComponent, l)
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
        return d
    }
}
