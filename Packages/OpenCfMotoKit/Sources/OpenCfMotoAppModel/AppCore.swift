// SPDX-License-Identifier: AGPL-3.0-or-later
// CONTRACT FILE (wave 2). Do not edit; report a contract change request instead.
//
// The process-wide core objects shared by every sub-model (Android: OpenCfMotoApp process
// globals). Created once by `AppModel.init(services:)`; sub-models receive it in their inits.

import Foundation
import OpenCfMotoCore

public final class AppCore: @unchecked Sendable {
    public let services: AppServices

    /// Saved bikes (metadata in the key-value store, raw QR in the secret store).
    public let garage: Garage
    /// Per-bike + global settings (Android-compatible keys).
    public let settings: SettingsStore
    /// Learned dash canvas per SSID, last dash touch.
    public let dashMemory: DashMemory
    /// Favorites / markers / history / home / parked.
    public let places: PlacesStore
    /// Handlebar saved-place slots 1…3 (same keys as `SettingsStore.savedPlace`).
    public let savedSlots: SavedPlaceSlots
    /// Throttled + identified HTTP (public routing / geocoding / Overpass instance policies).
    public let http: HTTPClient
    /// The ONE navigation engine: phone screens and the dash both reflect its snapshots.
    public let navigation: NavigationSession
    public let tripStore: TripStore
    public let tripRecorder: TripRecorder
    /// UI language of the dash, voice and HUD words (follows the phone language).
    public let language: NavLanguage

    private let signerTask = Locked<Task<HuidSigner, Error>?>(nil)

    public init(services: AppServices) {
        self.services = services
        let kv = services.keyValueStore
        garage = Garage(store: kv, secrets: services.secretStore)
        settings = SettingsStore(store: kv)
        dashMemory = DashMemory(store: kv)
        places = PlacesStore(store: kv)
        savedSlots = SavedPlaceSlots(store: kv)
        http = ThrottledHTTPClient(base: services.http, clock: services.clock)
        language = NavLanguage.preferred
        let initial = settings.settings(forBike: garage.selected?.id)
        navigation = NavigationSession(
            http: http,
            places: places,
            preferences: initial.map,
            orsApiKey: initial.orsApiKey,
            configuration: NavigationSession.Configuration(language: language,
                                                           decimalSeparator: language == .es ? "," : "."),
            clock: services.clock,
            wallClock: services.now,
            savedSlots: savedSlots
        )
        tripStore = TripStore(directory: services.files.tripsDirectory)
        tripRecorder = TripRecorder(store: tripStore)
    }

    /// The RSA identity for CLIENT_INFO, created once per process off the main actor (Android keeps
    /// one in-memory key per process, never persisted). Concurrent callers share one generation.
    public func signer() async throws -> HuidSigner {
        let make = services.makeSigner
        let task = signerTask.withLock { slot -> Task<HuidSigner, Error> in
            if let existing = slot { return existing }
            let created = Task.detached(priority: .userInitiated) { try await make() }
            slot = created
            return created
        }
        do {
            return try await task.value
        } catch {
            signerTask.set(nil) // retry next time
            throw error
        }
    }

    /// Current settings of the selected bike (global settings when the garage is empty).
    public var currentSettings: BikeSettings {
        settings.settings(forBike: garage.selected?.id)
    }
}
