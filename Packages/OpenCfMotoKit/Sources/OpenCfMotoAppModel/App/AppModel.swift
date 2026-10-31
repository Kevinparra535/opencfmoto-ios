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
//   → `garage.pair(rawQR:)`; settings packs (`.json` with format "opencfmoto.settings") →
//   `settings.importSettings`. Returns a localized message for a toast.
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

    public var flavor: BuildFlavor { core.services.system.flavor }
    public var appVersion: String { core.services.system.appVersion }
    public var buildNumber: String { core.services.system.buildNumber }

    /// How long `banner` stays visible.
    @ObservationIgnored var bannerDuration: TimeInterval = 3.5
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
        Log.i("APP", "Ready. Tap Connect to project the map to your dash.")
        if permissions.hasCompletedOnboarding { connection.maybeAutoConnect() }
    }

    public func scenePhaseChanged(_ phase: AppScenePhase) {
        ride.scenePhaseChanged(phase)
        connection.scenePhaseChanged(phase)
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

    public func dismissBanner() {
        bannerTask?.cancel()
        bannerTask = nil
        banner = nil
    }

    // MARK: - Wiring

    private func wire() {
        controls.inputSink = { [weak ride] input in ride?.handleDashInput(input) }
        permissions.onLocationPermissionChange = { [weak ride] p in ride?.locationPermissionChanged(p) }
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
        guard let data = Self.readFile(url) else {
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
        if text.contains("opencfmoto.settings") {
            let result = settings.importSettings(text)
            Log.i("APP", "open: settings pack \(result.ok ? "imported" : "rejected")")
            return result.message.isEmpty ? nil : result.message
        }
        if text.contains("opencfmoto.map") {
            let result = settings.importMapData(text)
            Log.i("APP", "open: map data \(result.ok ? "imported" : "rejected")")
            return result.message.isEmpty ? nil : result.message
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

    private static func looksLikeGPX(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(512), as: UTF8.self)
        return head.contains("<gpx")
    }

    // MARK: - Problem report diagnostics

    /// Keys follow `ProblemReport.Diagnostics` (+ a few iOS extras) for LogsModel.
    private func problemDiagnostics() -> [String: String] {
        let st = core.currentSettings
        let system = core.services.system
        let bike = core.garage.selected
        let diag = connection.diagnostics
        let profileId = diag.dashInfo?.profile ?? st.profileOverride
        let profileDefault = (profileId.map { BikeProfile.profile($0) } ?? .legacy).defaultMargins
        var d: [String: String] = [
            "appVersion": system.appVersion,
            "buildNumber": system.buildNumber,
            "device": system.deviceModel,
            "system": system.systemVersion,
            "flavor": system.flavor.rawValue,
            "profileName": diag.profileName ?? (st.profileOverride.map { BikeProfile.profile($0).name } ?? "Auto"),
            "profileOverride": st.profileOverride?.rawValue ?? "auto",
            "wifiTransport": st.wifiTransport.rawValue,
            "marginsSummary": CanvasFit.marginsSummary(st.screenMargins, profileDefault: profileDefault),
            "forceNonTouch": String(st.forceNonTouch),
            "forceTouch": String(st.forceTouch),
            "phase": SessionText.phaseAndroidName(connection.phase),
            "phaseDetail": connection.detail,
            "mode": connection.mode.rawValue,
            "linkState": diag.state.description,
            "framesSent": String(diag.stats.framesSent),
            "keyframesSent": String(diag.stats.keyframesSent),
            "missedPulls": String(diag.stats.missedPulls),
            "projection": diag.projection.mode,
            "location": permissions.location.rawValue,
            "preciseLocation": String(permissions.isPreciseLocation),
            "localNetwork": permissions.localNetwork.rawValue,
            "powerMode": st.powerMode.rawValue,
            "videoQuality": st.videoQuality.rawValue,
            "thermal": system.thermalLevel.androidName,
            "lowPowerMode": String(system.isLowPowerModeEnabled),
        ]
        if let bike {
            d["ssid"] = bike.ssid
            d["bike"] = bike.name
        }
        if let info = diag.dashInfo {
            d["dash"] = "\(info.huName) sdk=\(info.sdkVersion) ver=\(info.versionName) touch=\(info.supportsScreenTouch)"
        }
        if let c = diag.canvas { d["canvas"] = c.description }
        return d
    }
}
