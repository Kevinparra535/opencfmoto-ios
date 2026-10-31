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
    }

    /// Call once when the app launches.
    public func start() { /* TODO(logic-session) */ }

    public func scenePhaseChanged(_ phase: AppScenePhase) { /* TODO(logic-session) */ }

    /// Files / URLs opened with the app. Returns a localized message for the banner (or nil).
    @discardableResult
    public func handleOpenURL(_ url: URL) -> String? {
        nil // TODO(logic-session)
    }

    public func showBanner(_ text: String) { banner = text /* TODO(logic-session): auto-clear */ }
    public func dismissBanner() { banner = nil }
}
