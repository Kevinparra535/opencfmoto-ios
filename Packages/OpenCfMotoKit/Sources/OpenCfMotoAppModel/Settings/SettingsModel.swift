// SPDX-License-Identifier: AGPL-3.0-or-later
// WAVE-2 SKELETON — owner: logic-data. The PUBLIC SURFACE below is the contract the SwiftUI layer
// codes against: implement the bodies, add private helpers / new files freely, add new public
// members only if needed (report them), never rename or remove existing public members.
//
// Settings screen model (docs/spec/app-features.md §2, §3, §8). Values are scoped to the selected
// garage bike through `SettingsStore` (nil scope when the garage is empty). Every setter persists
// through the matching SettingsStore setter (never a blind `update` of all fields), refreshes
// `current`, and notifies `observe` handlers (RideModel / ConnectionModel / ControlsModel react).
//
// Side effects to implement:
// - `setMapPreferences` → also `core.navigation.updatePreferences(_:)`.
// - `setOrsApiKey` → also `core.navigation.setOrsApiKey(_:)`.
// - `setIncludeSecretsInLogs` → `LogRedactor.install(on: .shared, includeSecrets:)`.
// - `setForceTouch(true)` clears forceNonTouch and vice-versa (SettingsStore does it).
// - "applies on next connect" settings (video quality, profile, touch, fit) are just persisted;
//   ConnectionModel reads them at connect time.
// - Import/export: `SettingsBackup.exportJSON(from:bikeId:profileName:appVersion:)` written to
//   `files.exportsDirectory/<SettingsBackup.suggestedFileName(profileOverride:)>`;
//   `SettingsBackup.importJSON(_:into:bikeId:bikeName:)` → refresh. Map data: `MapDataBackup`.

import Foundation
import Observation
import OpenCfMotoCore

@MainActor
@Observable
public final class SettingsModel {
    @ObservationIgnored let core: AppCore
    @ObservationIgnored let garage: GarageModel

    /// Settings of the selected bike (or the global defaults when the garage is empty).
    public private(set) var current: BikeSettings = BikeSettings()
    /// Scope id of `current` (nil = global / no bike).
    public private(set) var bikeId: String?
    /// Handlebar keys the bike was seen to have (learned).
    public private(set) var presence: HandlebarPresence = HandlebarPresence()
    /// Handlebar saved-place slots 1…3 (index 0…2).
    public private(set) var savedPlaces: [SavedPlaceSlot] = []

    public init(core: AppCore, garage: GarageModel) {
        self.core = core
        self.garage = garage
        current = core.currentSettings
        bikeId = garage.selected?.id
        // TODO(logic-data): load presence / savedPlaces; observe garage selection to re-scope.
    }

    // MARK: Screen & display (applies on next connect)
    public func setVideoQuality(_ value: VideoQuality) { /* TODO(logic-data) */ }
    public func setScreenFit(_ value: ScreenFit) { /* TODO(logic-data) */ }
    public func setMirrorOrientation(_ value: MirrorOrientation) { /* TODO(logic-data) */ }
    /// `nil` = Auto (CLIENT_INFO scoring).
    public func setProfileOverride(_ value: BikeProfileID?) { /* TODO(logic-data) */ }
    /// "Disable touchscreen".
    public func setForceNonTouch(_ on: Bool) { /* TODO(logic-data) */ }
    /// "Force touchscreen".
    public func setForceTouch(_ on: Bool) { /* TODO(logic-data) */ }
    public func setScreenMargins(_ margins: ScreenMargins) { /* TODO(logic-data) */ }
    public func resetScreenMargins() { /* TODO(logic-data) */ }
    /// Profile default margins for a profile (800NK Advanced: top 22), for the margins editor.
    public func defaultMargins(for profile: BikeProfileID?) -> ScreenMargins { .zero /* TODO(logic-data) */ }

    // MARK: Battery & power
    public func setPowerMode(_ value: PowerMode) { /* TODO(logic-data) */ }

    // MARK: Map (also pushed to the navigation session)
    public func setMapPreferences(_ value: MapPreferences) { /* TODO(logic-data) */ }
    public func setTileURLTemplate(_ value: String) { /* TODO(logic-data) */ }
    public func setOrsApiKey(_ value: String) { /* TODO(logic-data) */ }

    // MARK: Handlebar mapping & timing (Controls screen)
    public func setButtonTiming(_ value: ButtonTiming) { /* TODO(logic-data) */ }
    /// Master switch "Handlebar control".
    public func setHandlebarControl(_ on: Bool) { /* TODO(logic-data) */ }
    public func setButtonAction(_ action: ButtonAction, for gesture: ButtonGesture) { /* TODO(logic-data) */ }
    /// Back to the iOS default mapping (HandlebarPresets.iosDefaultMapping).
    public func resetButtonMap() { /* TODO(logic-data) */ }
    public func applyClusterPreset(_ preset: ButtonClusterPreset) { /* TODO(logic-data) */ }
    public func clearClusterPreset() { /* TODO(logic-data) */ }
    /// Forget the learned volume-rocker / track-key presence.
    public func resetHandlebarPresence() { /* TODO(logic-data) */ }
    /// Re-reads everything from storage (after imports or engine-side presence changes).
    public func reload() { /* TODO(logic-data) */ }

    // MARK: Startup & recovery
    public func setAutoConnect(_ on: Bool) { /* TODO(logic-data) */ }
    public func setAutoRecovery(_ on: Bool) { /* TODO(logic-data) */ }
    public func setLogTrips(_ on: Bool) { /* TODO(logic-data) */ }
    /// iOS: keep the screen awake while projecting (Ride Mode also disables the idle timer).
    public func setKeepScreenOn(_ on: Bool) { /* TODO(logic-data) */ }

    // MARK: Privacy & logs
    public func setIncludeSecretsInLogs(_ on: Bool) { /* TODO(logic-data) */ }

    // MARK: Saved places (handlebar slots)
    /// `slot` is 0…2.
    public func setSavedPlace(_ slot: Int, name: String, query: String) { /* TODO(logic-data) */ }

    // MARK: Profiles
    /// Choices for the profile picker: nil (Auto) followed by every profile.
    public var profileChoices: [BikeProfileID?] { [nil] + BikeProfileID.allCases.map { Optional($0) } }
    /// Display name ("Auto", "800NK Advanced", …) — Android labels.
    public func profileName(_ id: BikeProfileID?) -> String {
        id.map { BikeProfile.profile($0).name } ?? "Auto" // TODO(logic-data): localize "Auto"
    }

    // MARK: Backup (opencfmoto.settings v1 / opencfmoto.map v1)
    public func exportSettings() throws -> ExportedFile {
        throw CocoaError(.featureUnsupported) // TODO(logic-data)
    }
    /// Returns the localized result message (Android texts).
    public func importSettings(_ text: String) -> (ok: Bool, message: String) {
        (false, "") // TODO(logic-data)
    }
    public func exportMapData() throws -> ExportedFile {
        throw CocoaError(.featureUnsupported) // TODO(logic-data)
    }
    public func importMapData(_ text: String) -> (ok: Bool, message: String) {
        (false, "") // TODO(logic-data)
    }

    // MARK: Model-to-model (internal)

    /// Called after every change of `current` (main actor).
    func observe(_ handler: @escaping @MainActor (BikeSettings) -> Void) {
        handlers.append(handler)
    }

    @ObservationIgnored private var handlers: [@MainActor (BikeSettings) -> Void] = []
}
