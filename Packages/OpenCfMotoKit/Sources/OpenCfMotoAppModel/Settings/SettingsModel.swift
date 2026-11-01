// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) SetupActivity.kt, ScreenMarginsActivity.kt, ButtonMappingActivity.kt
//
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
//
// Implementation notes:
// - Fields without an individual SettingsStore setter (map preferences, timing, startup toggles,
//   iOS keys, ORS key) go through `SettingsStore.update` with a body that changes ONLY that field
//   (the store writes the diff, i.e. that one key).
// - `observe` handlers run after every change of `current` and after every re-scope to another bike
//   (presence and other per-bike state may differ even when the settings values are equal).
// - `setScreenMargins` always stores custom margins (Android: every slider change persists all four
//   edges with `customised = true`); use `resetScreenMargins()` to go back to the profile default.

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
    /// Compatibility (global, iOS-only): send an Android phone's brand/model in CLIENT_INFO instead of
    /// "Apple"/<device model>. Everything else is already spoofed exactly like the Android app
    /// (docs/spec/control-plane.md §18.7); this is the only CLIENT_INFO difference found by the
    /// differential test (docs/verification/pxc-differential.md). Off by default.
    public private(set) var identifyAsAndroidPhone = false

    /// KeyValueStore key of `identifyAsAndroidPhone`.
    static let identifyAsAndroidKey = "ios.identify_as_android_phone"

    /// Time zone of the export time stamps (`exportedAt`, map file name). Tests pin it.
    @ObservationIgnored var timeZone: TimeZone = .current

    public init(core: AppCore, garage: GarageModel) {
        self.core = core
        self.garage = garage
        bikeId = garage.selected?.id
        current = Self.effectiveSettings(core.settings, bikeId: garage.selected?.id)
        presence = core.settings.presence(forBike: bikeId)
        savedPlaces = core.settings.savedPlaces
        identifyAsAndroidPhone = core.services.keyValueStore.bool(forKey: Self.identifyAsAndroidKey) ?? false
        garage.observeSelection { [weak self] bike in
            self?.rescope(to: bike?.id)
        }
    }

    // MARK: Screen & display (applies on next connect)
    public func setVideoQuality(_ value: VideoQuality) {
        core.settings.setVideoQuality(value, forBike: bikeId)
        logChange("video quality \(value.rawValue) (applies next connect)")
        refreshCurrent()
    }

    public func setScreenFit(_ value: ScreenFit) {
        core.settings.setScreenFit(value, forBike: bikeId)
        logChange("screen fit \(value.rawValue) (mirror: applies right away; otherwise next connect)")
        refreshCurrent()
    }

    public func setMirrorOrientation(_ value: MirrorOrientation) {
        core.settings.setMirrorOrientation(value, forBike: bikeId)
        logChange("mirror orientation \(value.rawValue) (applies next connect)")
        refreshCurrent()
    }

    /// `nil` = Auto (CLIENT_INFO scoring).
    public func setProfileOverride(_ value: BikeProfileID?) {
        core.settings.setProfileOverride(value, forBike: bikeId)
        logChange("bike profile \(SettingsBackup.overrideShortLabel(value)) (applies next connect)")
        refreshCurrent()
    }

    /// "Disable touchscreen".
    public func setForceNonTouch(_ on: Bool) {
        core.settings.setForceNonTouch(on)
        logChange("disable touchscreen: \(on ? "on" : "off") (applies next connect)")
        refreshCurrent()
    }

    /// "Force touchscreen".
    public func setForceTouch(_ on: Bool) {
        core.settings.setForceTouch(on)
        logChange("force touchscreen: \(on ? "on" : "off") (applies next connect)")
        refreshCurrent()
    }

    public func setScreenMargins(_ margins: ScreenMargins) {
        core.settings.setScreenMargins(top: margins.top, bottom: margins.bottom, left: margins.left, right: margins.right)
        refreshCurrent()
    }

    public func resetScreenMargins() {
        core.settings.resetScreenMargins()
        logChange("screen margins reset to the profile default")
        refreshCurrent()
    }

    /// Profile default margins for a profile (800NK Advanced: top 22), for the margins editor.
    /// `nil` (Auto) → the profile the selected bike was identified as at its last connect, if any.
    public func defaultMargins(for profile: BikeProfileID?) -> ScreenMargins {
        CanvasFit.profileDefaultMargins(profile ?? garage.selected?.profileHint)
    }

    // MARK: Battery & power
    public func setPowerMode(_ value: PowerMode) {
        core.settings.setPowerMode(value, forBike: bikeId)
        logChange("power mode \(value.rawValue)")
        refreshCurrent()
    }

    // MARK: Map (also pushed to the navigation session)
    public func setMapPreferences(_ value: MapPreferences) {
        core.settings.update(forBike: bikeId) { $0.map = value }
        refreshCurrent()
        // Push what was persisted (the store clamps the circuit length).
        core.navigation.updatePreferences(current.map)
    }

    public func setTileURLTemplate(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = trimmed.isEmpty ? BikeSettings().tileURLTemplate : trimmed
        core.settings.update(forBike: bikeId) { $0.tileURLTemplate = template }
        refreshCurrent()
        core.services.projection.setTileURLTemplate(current.tileURLTemplate)
    }

    public func setOrsApiKey(_ value: String) {
        core.settings.update(forBike: bikeId) { $0.orsApiKey = value }
        refreshCurrent()
        // Never log the key itself.
        logChange(current.orsApiKey.isEmpty ? "ORS API key cleared" : "ORS API key set")
        core.navigation.setOrsApiKey(current.orsApiKey)
    }

    // MARK: Handlebar mapping & timing (Controls screen)
    public func setButtonTiming(_ value: ButtonTiming) {
        core.settings.update(forBike: bikeId) { $0.buttonTiming = value }
        logChange("handlebar timing double=\(value.doubleTapMs) ms holds=\(value.holdsEnabled ? "on" : "off") hold=\(value.holdMs) ms")
        refreshCurrent()
    }

    /// Master switch "Handlebar control".
    public func setHandlebarControl(_ on: Bool) {
        core.settings.setHandlebarControl(on, forBike: bikeId)
        logChange("handlebar control \(on ? "on" : "off")")
        refreshCurrent()
    }

    public func setButtonAction(_ action: ButtonAction, for gesture: ButtonGesture) {
        core.settings.setButtonAction(action, for: gesture, forBike: bikeId)
        logChange("button \(gesture.rawValue) → \(action.rawValue)")
        refreshCurrent()
    }

    /// Back to the iOS default mapping (HandlebarPresets.iosDefaultMapping).
    public func resetButtonMap() {
        // Resetting also forgets an active cluster preset (its mapping is gone).
        core.settings.clearClusterPreset(forBike: bikeId)
        // Removing the scoped keys can expose an older global map (Android quirk): pin the iOS
        // defaults where that happened so the documented result always holds.
        let target = HandlebarPresets.iosDefaultMapping
        let resolved = core.settings.settings(forBike: bikeId).buttonMap
        for gesture in ButtonGesture.allCases {
            if let action = target[gesture], resolved[gesture] != action {
                core.settings.setButtonAction(action, for: gesture, forBike: bikeId)
            }
        }
        logChange("button map reset to defaults")
        refreshCurrent()
    }

    public func applyClusterPreset(_ preset: ButtonClusterPreset) {
        core.settings.applyClusterPreset(preset, forBike: bikeId)
        logChange("cluster preset \(preset.rawValue) applied")
        refreshCurrent()
    }

    public func clearClusterPreset() {
        core.settings.clearClusterPreset(forBike: bikeId)
        logChange("cluster preset cleared")
        refreshCurrent()
    }

    /// Forget the learned volume-rocker / track-key presence.
    public func resetHandlebarPresence() {
        core.settings.resetPresence(forBike: bikeId)
        logChange("handlebar presence reset to untested")
        reload()
    }

    /// "Teach my handlebar" for the selected bike: does its ▲/▼ volume rocker reach the phone?
    /// (Android `▲/▼ works` = present, `▲/▼ absent` = absent; unknown lets the ~90 s probe decide.)
    /// ControlsModel's live engine follows the stored value.
    public func setVolumeRockerPresence(_ presence: ButtonPresence) {
        core.settings.setVolumeRockerPresence(presence, forBike: bikeId)
        logChange("handlebar \u{25B2}/\u{25BC} rocker taught \(presence.rawValue)")
        refreshPresence()
    }

    /// "Teach my handlebar" for the selected bike: do its ◀/▶/★ track keys reach the phone?
    public func setTrackKeysPresence(_ presence: ButtonPresence) {
        core.settings.setTrackKeysPresence(presence, forBike: bikeId)
        logChange("handlebar \u{25C0}/\u{25B6} track keys taught \(presence.rawValue)")
        refreshPresence()
    }

    /// Re-reads everything from storage (after imports or engine-side presence changes).
    public func reload() {
        let selectedId = core.garage.selected?.id
        if selectedId != bikeId {
            rescope(to: selectedId)
            return
        }
        refreshSecondary()
        refreshCurrent()
    }

    // MARK: Startup & recovery
    public func setAutoConnect(_ on: Bool) {
        core.settings.update(forBike: bikeId) { $0.autoConnect = on }
        logChange("auto-connect \(on ? "on" : "off")")
        refreshCurrent()
    }

    public func setAutoRecovery(_ on: Bool) {
        core.settings.update(forBike: bikeId) { $0.autoRecovery = on }
        logChange("auto-recovery \(on ? "on" : "off")")
        refreshCurrent()
    }

    public func setLogTrips(_ on: Bool) {
        core.settings.update(forBike: bikeId) { $0.logTrips = on }
        logChange("trip logging \(on ? "on" : "off")")
        refreshCurrent()
    }

    /// iOS: keep the screen awake while projecting (Ride Mode also disables the idle timer).
    public func setKeepScreenOn(_ on: Bool) {
        core.settings.update(forBike: bikeId) { $0.keepScreenOn = on }
        logChange("keep screen on \(on ? "on" : "off")")
        refreshCurrent()
    }

    // MARK: Privacy & logs
    public func setIncludeSecretsInLogs(_ on: Bool) {
        core.settings.update(forBike: bikeId) { $0.includeSecretsInLogs = on }
        refreshCurrent()
        LogRedactor.install(on: .shared, includeSecrets: current.includeSecretsInLogs)
        // Android toasts, kept as log lines (they also make the logs screen re-render).
        logChange(current.includeSecretsInLogs
                  ? "Shared logs will include secrets \u{2014} turn off before posting publicly"
                  : "Log redaction on")
    }

    // MARK: Compatibility
    /// Applies on the next connect.
    public func setIdentifyAsAndroidPhone(_ on: Bool) {
        core.services.keyValueStore.set(on, forKey: Self.identifyAsAndroidKey)
        identifyAsAndroidPhone = on
        logChange("identify as \(on ? "an Android phone" : "an iPhone") (applies next connect)")
    }

    // MARK: Saved places (handlebar slots)
    /// `slot` is 0…2.
    public func setSavedPlace(_ slot: Int, name: String, query: String) {
        guard (0 ..< SavedPlaceSlots.count).contains(slot) else { return }
        core.settings.setSavedPlace(slot, name: name, query: query)
        let updated = core.settings.savedPlaces
        if updated != savedPlaces { savedPlaces = updated }
    }

    // MARK: Profiles
    /// Choices for the profile picker: nil (Auto) followed by every profile.
    public var profileChoices: [BikeProfileID?] { [nil] + BikeProfileID.allCases.map { Optional($0) } }
    /// Display name ("Auto", "800NK Advanced", …) — Android labels.
    public func profileName(_ id: BikeProfileID?) -> String {
        id.map { BikeProfile.profile($0).name } ?? strings.auto
    }

    // MARK: Backup (opencfmoto.settings v1 / opencfmoto.map v1)
    public func exportSettings() throws -> ExportedFile {
        let settings = core.settings.settings(forBike: bikeId)
        // `bikeHint.profile`: the selected bike's profile (override, else the one identified at the
        // last connect) — Android writes the legacy profile when nothing is known yet.
        let profile = settings.profileOverride ?? garage.selected?.profileHint ?? .legacy
        let text = SettingsBackup.exportJSON(from: core.settings, bikeId: bikeId,
                                             profileName: BikeProfile.profile(profile).name,
                                             appVersion: core.services.system.appVersion,
                                             date: core.services.now(), timeZone: timeZone)
        do {
            let file = try LogicData.writeExport(text, fileName: SettingsBackup.suggestedFileName(profileOverride: settings.profileOverride),
                                                 typeIdentifier: "public.json",
                                                 in: core.services.files.exportsDirectory)
            Log.i(Self.tag, "settings exported: \(file.fileName) (\(text.utf8.count) bytes)")
            return file
        } catch {
            Log.w(Self.tag, "settings export failed: \(LogicData.detail(of: error))")
            throw LogicData.UserError(strings.exportFailed(LogicData.detail(of: error)))
        }
    }

    /// Returns the localized result message (Android texts).
    public func importSettings(_ text: String) -> (ok: Bool, message: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (false, strings.emptyFile)
        }
        let bikeName = garage.selected?.name
        let result = SettingsBackup.importJSON(text, into: core.settings, bikeId: bikeId, bikeName: bikeName)
        Log.i(Self.tag, "settings import: \(result.message)")
        if result.ok { reload() }
        return (result.ok, strings.settingsImportMessage(result.message, ontoEnglish: bikeName))
    }

    public func exportMapData() throws -> ExportedFile {
        let now = core.services.now()
        let text = MapDataBackup.exportJSON(places: core.places, preferences: current.map, buildings3d: true,
                                            appVersion: core.services.system.appVersion, now: now, timeZone: timeZone)
        do {
            let file = try LogicData.writeExport(text, fileName: MapDataBackup.suggestedFileName(now: now, timeZone: timeZone),
                                                 typeIdentifier: "public.json",
                                                 in: core.services.files.exportsDirectory)
            Log.i(Self.tag, "map data exported: \(file.fileName) (\(text.utf8.count) bytes)")
            return file
        } catch {
            Log.w(Self.tag, "map data export failed: \(LogicData.detail(of: error))")
            throw LogicData.UserError(strings.exportFailed(LogicData.detail(of: error)))
        }
    }

    public func importMapData(_ text: String) -> (ok: Bool, message: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (false, strings.emptyFile)
        }
        let result = MapDataBackup.importJSON(text, into: core.places, preferences: current.map)
        Log.i(Self.tag, "map data import: \(result.message)")
        if result.ok, let prefs = result.preferences {
            core.settings.update(forBike: bikeId) { $0.map = prefs }
            refreshCurrent()
            core.navigation.updatePreferences(current.map)
        }
        return (result.ok, strings.mapImportMessage(result.message))
    }

    // MARK: Model-to-model (internal)

    /// The Screen fit mirror mode uses: the stored choice, or FIT while the rider never chose one
    /// (media-video.md §15.7 — iOS cannot rotate other apps; FILL would show only a slice of a portrait
    /// phone). The stored / exported default stays FILL (Android settings packs). Review MED:MP-4.
    nonisolated static func mirrorScreenFit(_ store: SettingsStore, bikeId: String?) -> ScreenFit {
        store.hasStoredScreenFit(forBike: bikeId) ? store.settings(forBike: bikeId).screenFit : .fit
    }

    /// The store's settings with the iOS effective Screen fit, so the picker shows what mirroring uses.
    nonisolated static func effectiveSettings(_ store: SettingsStore, bikeId: String?) -> BikeSettings {
        var s = store.settings(forBike: bikeId)
        s.screenFit = mirrorScreenFit(store, bikeId: bikeId)
        return s
    }

    /// Called after every change of `current` (main actor).
    func observe(_ handler: @escaping @MainActor (BikeSettings) -> Void) {
        handlers.append(handler)
    }

    @ObservationIgnored private var handlers: [@MainActor (BikeSettings) -> Void] = []

    // MARK: Private

    private static let tag = "settings"

    private var strings: LogicData.Strings { LogicData.Strings(core.language) }

    private func logChange(_ text: String) {
        Log.i(Self.tag, text)
    }

    /// Follows the garage selection: per-bike values, presence and the handlers' view change. The
    /// handlers run on every change of scope (another bike) even when the values are equal; a
    /// selection update of the same bike (rename, photo) only notifies when `current` changed.
    private func rescope(to id: String?) {
        let scopeChanged = id != bikeId
        bikeId = id
        refreshSecondary()
        let fresh = Self.effectiveSettings(core.settings, bikeId: id)
        let valuesChanged = fresh != current
        if valuesChanged { current = fresh }
        if valuesChanged || scopeChanged { notifyHandlers() }
    }

    /// Re-reads `current`; notifies the handlers when it changed.
    private func refreshCurrent() {
        let fresh = Self.effectiveSettings(core.settings, bikeId: bikeId)
        guard fresh != current else { return }
        current = fresh
        notifyHandlers()
    }

    private func refreshSecondary() {
        refreshPresence()
        let places = core.settings.savedPlaces
        if places != savedPlaces { savedPlaces = places }
    }

    private func refreshPresence() {
        let p = core.settings.presence(forBike: bikeId)
        if p != presence { presence = p }
    }

    private func notifyHandlers() {
        let value = current
        for handler in handlers { handler(value) }
    }
}
