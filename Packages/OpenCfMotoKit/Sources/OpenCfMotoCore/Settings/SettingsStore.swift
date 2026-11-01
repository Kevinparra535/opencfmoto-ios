// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) BikeScope.kt, VideoPrefs.kt, AppSettings.kt, ProfileOverride.kt,
// ScreenMargins.kt, ButtonMap.kt, ButtonMode.kt, ButtonClusterPreset.kt, ButtonPresencePrefs.kt,
// ButtonTimingPrefs.kt, MapPrefs.kt, NightPrefs.kt, RemotePad.kt, SavedPlaces.kt
//
// Settings persistence over the `KeyValueStore` contract (app-features.md §2, session-network.md §8).
// Per-bike values use Android's scoped keys `"<base>#<bikeId>"` with the exact fallback chain
// scoped → global → default; writes go to the scoped key (global key when no bike is selected).
// Android key names are kept; keys that lived in Android prefs files other than `opencfmoto_bike`
// are prefixed with `"<file>."` because iOS uses one flat key-value namespace (App Group suite).

import Foundation

/// Persisted key names (see the file header for the naming rule).
public enum SettingsKeys {
    // opencfmoto_bike — per bike
    public static let videoQuality = "video_quality"
    public static let screenFit = "screen_fit"
    public static let powerMode = "power_mode"
    public static let resolutionMode = "resolution_mode"
    public static let mirrorOrientation = "mirror_orientation"
    public static let aaDpiOverride = "aa_dpi_override"
    public static let profileOverride = "profile_override"
    // opencfmoto_bike — global
    public static let forceNonTouch = "force_non_touch"
    public static let forceTouch = "force_touch"
    public static let wifiTransport = "wifi_transport"
    public static let autoConnect = "auto_connect"
    public static let autoRecovery = "auto_recovery"
    public static let logTrips = "log_trips"
    public static let includeSecretsInLogs = "include_secrets_in_logs"
    public static let mapTheme = "map_theme"
    // button_mode / button_map / button_cluster_preset / button_presence — per bike
    public static let controlAa = "button_mode.controlAa"
    public static func buttonMap(_ gesture: ButtonGesture) -> String { "button_map." + gesture.rawValue }
    public static let clusterPreset = "button_cluster_preset.active"
    public static let volumeRocker = "button_presence.volume_rocker"
    public static let trackKeys = "button_presence.track_keys"
    // screen_margins — global
    public static let marginsCustomised = "screen_margins.customised"
    public static let marginsTop = "screen_margins.top"
    public static let marginsBottom = "screen_margins.bottom"
    public static let marginsLeft = "screen_margins.left"
    public static let marginsRight = "screen_margins.right"
    // opencfmoto_btn_timing — global
    public static let doubleTapMs = "opencfmoto_btn_timing.double_tap_ms"
    public static let longPressMs = "opencfmoto_btn_timing.long_press_ms"
    public static let holdsEnabled = "opencfmoto_btn_timing.holds_enabled"
    public static let snappySingles = "opencfmoto_btn_timing.snappy_singles"
    // opencfmoto_remote_pad — global
    public static let remotePad = "opencfmoto_remote_pad.remote_pad_on"
    // opencfmoto_map — global
    public static let units = "opencfmoto_map.units"
    public static let voicePrompts = "opencfmoto_map.voice_prompts"
    public static let showNextStop = "opencfmoto_map.show_next_stop"
    public static let autoFinishArrive = "opencfmoto_map.auto_finish_arrive"
    public static let chrome = "opencfmoto_map.chrome"
    public static let routeMode = "opencfmoto_map.route_mode"
    public static let avoidTolls = "opencfmoto_map.avoid_tolls"
    public static let avoidHighways = "opencfmoto_map.avoid_highways"
    public static let funCircuitKm = "opencfmoto_map.fun_circuit_km"
    public static let orsApiKey = "opencfmoto_map.ors_api_key"
    // saved_places — global
    public static func savedPlaceName(_ slot: Int) -> String { "saved_places.name\(slot)" }
    public static func savedPlaceQuery(_ slot: Int) -> String { "saved_places.query\(slot)" }
    // iOS-only — global
    public static let iosKeepScreenOn = "ios.keep_screen_on"
    public static let iosTileURLTemplate = "ios.tile_url_template"

    /// Every per-bike (scopable) base key.
    public static var perBikeBases: [String] {
        [videoQuality, screenFit, powerMode, resolutionMode, mirrorOrientation, aaDpiOverride, profileOverride,
         controlAa, clusterPreset, volumeRocker, trackKeys] + ButtonGesture.allCases.map(buttonMap)
    }
}

/// Android Auto resolution choice — Android-only, persisted per bike and round-tripped in the pack.
public enum AndroidAutoResolutionMode: String, Sendable, Codable, CaseIterable {
    case auto = "AUTO", landscapeSD = "LANDSCAPE_SD", landscapeHD = "LANDSCAPE_HD"
    case portraitSD = "PORTRAIT_SD", portraitHD = "PORTRAIT_HD"
}

/// Settings that only matter on Android but must survive an Android → iOS → Android settings-pack
/// round trip (app-features.md §3.7.3). Not part of the `BikeSettings` contract.
public struct AndroidOnlySettings: Sendable, Equatable, Codable {
    /// Per bike (`resolution_mode`).
    public var resolutionMode: AndroidAutoResolutionMode = .auto
    /// Per bike (`aa_dpi_override`); 0 = automatic.
    public var aaDpiOverride: Int = 0
    /// Global (`opencfmoto_remote_pad/remote_pad_on`): Bluetooth HID remote pad enabled.
    public var remotePad: Bool = true
    public init(resolutionMode: AndroidAutoResolutionMode = .auto, aaDpiOverride: Int = 0, remotePad: Bool = true) {
        self.resolutionMode = resolutionMode
        self.aaDpiOverride = aaDpiOverride
        self.remotePad = remotePad
    }
}

/// Typed, thread-safe settings persistence (`NSLock`). `bikeId` is the selected garage bike's scope
/// id (`GarageBike.id`), or nil when no bike is selected (global keys are used then).
public final class SettingsStore: @unchecked Sendable {
    public let store: KeyValueStore
    /// Default handlebar map when nothing is stored (iOS default, input-controls.md §9.1).
    public let defaultButtonMap: [ButtonGesture: ButtonAction]

    private let lock = NSLock()
    private let subscribersLock = NSLock()
    private var subscribers: [UUID: @Sendable () -> Void] = [:]

    public init(store: KeyValueStore, defaultButtonMap: [ButtonGesture: ButtonAction] = HandlebarPresets.iosDefaultMapping) {
        self.store = store
        self.defaultButtonMap = HandlebarPresets.completed(defaultButtonMap, fallback: HandlebarPresets.androidDefaults)
    }

    // MARK: - Observation

    /// Called (on the writing thread) after every write.
    @discardableResult
    public func subscribe(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        subscribersLock.lock(); subscribers[id] = handler; subscribersLock.unlock()
        return id
    }

    public func unsubscribe(_ id: UUID) {
        subscribersLock.lock(); subscribers[id] = nil; subscribersLock.unlock()
    }

    private func notify() {
        subscribersLock.lock()
        let subs = Array(subscribers.values)
        subscribersLock.unlock()
        for s in subs { s() }
    }

    /// Runs `body` under the store lock, then notifies subscribers.
    private func write<R>(_ body: () -> R) -> R {
        lock.lock()
        let r = body()
        lock.unlock()
        notify()
        return r
    }

    // MARK: - Scoped primitives (lock held)

    private func key(_ base: String, _ bike: String?) -> String { BikeScope.scopedKey(base, bikeId: bike) }

    private func scopedString(_ base: String, _ bike: String?) -> String? {
        if let bike, !bike.isEmpty, let v = store.string(forKey: base + "#" + bike) { return v }
        return store.string(forKey: base)
    }

    private func scopedBool(_ base: String, _ bike: String?) -> Bool? {
        if let bike, !bike.isEmpty, let v = store.bool(forKey: base + "#" + bike) { return v }
        return store.bool(forKey: base)
    }

    private func scopedInt(_ base: String, _ bike: String?) -> Int? {
        if let bike, !bike.isEmpty, let v = store.int(forKey: base + "#" + bike) { return v }
        return store.int(forKey: base)
    }

    // MARK: - Reading

    /// The effective settings for a bike (scoped → global → default for per-bike values; global keys
    /// for the rest).
    public func settings(forBike bikeId: String?) -> BikeSettings {
        lock.lock(); defer { lock.unlock() }
        return readLocked(bikeId)
    }

    /// Convenience for the selected garage bike.
    public func settings(for bike: GarageBike?) -> BikeSettings { settings(forBike: bike?.id) }

    private func readLocked(_ b: String?) -> BikeSettings {
        typealias K = SettingsKeys
        var s = BikeSettings()
        // per bike
        s.videoQuality = scopedString(K.videoQuality, b).flatMap(VideoQuality.init(rawValue:)) ?? .balanced
        s.screenFit = scopedString(K.screenFit, b).flatMap(ScreenFit.init(rawValue:)) ?? .fill
        s.mirrorOrientation = scopedString(K.mirrorOrientation, b).flatMap(MirrorOrientation.init(rawValue:)) ?? .matchDash
        s.powerMode = scopedString(K.powerMode, b).flatMap(PowerMode.init(rawValue:)) ?? .balanced
        s.profileOverride = scopedString(K.profileOverride, b).flatMap(BikeProfileID.init(rawValue:))
        s.handlebarControl = scopedBool(K.controlAa, b) ?? true
        s.buttonMap = Dictionary(uniqueKeysWithValues: ButtonGesture.allCases.map { g in
            (g, scopedString(K.buttonMap(g), b).flatMap(ButtonAction.init(rawValue:)) ?? defaultButtonMap[g]!)
        })
        s.clusterPreset = scopedString(K.clusterPreset, b).flatMap(ButtonClusterPreset.init(rawValue:))
        // global
        s.forceNonTouch = store.bool(forKey: K.forceNonTouch) ?? false
        s.forceTouch = store.bool(forKey: K.forceTouch) ?? false
        s.wifiTransport = store.string(forKey: K.wifiTransport).flatMap(WifiTransport.init(rawValue:)) ?? .auto
        s.screenMargins = readMarginsLocked()
        var timing = ButtonTiming()
        timing.doubleTapMs = ButtonTiming.normalizedDoubleTapMs(store.int(forKey: K.doubleTapMs))
        timing.holdMs = ButtonTiming.normalizedHoldMs(store.int(forKey: K.longPressMs))
        timing.holdsEnabled = store.bool(forKey: K.holdsEnabled) ?? true
        s.buttonTiming = timing
        s.map = readMapLocked()
        s.autoConnect = store.bool(forKey: K.autoConnect) ?? true
        s.autoRecovery = store.bool(forKey: K.autoRecovery) ?? true
        s.logTrips = store.bool(forKey: K.logTrips) ?? true
        s.includeSecretsInLogs = store.bool(forKey: K.includeSecretsInLogs) ?? false
        // iOS
        s.keepScreenOn = store.bool(forKey: K.iosKeepScreenOn) ?? true
        s.tileURLTemplate = store.string(forKey: K.iosTileURLTemplate) ?? BikeSettings().tileURLTemplate
        s.orsApiKey = AppJvmText.trim(store.string(forKey: K.orsApiKey) ?? "")
        return s
    }

    private func readMarginsLocked() -> ScreenMargins {
        typealias K = SettingsKeys
        let edgeKeys = [K.marginsTop, K.marginsBottom, K.marginsLeft, K.marginsRight]
        let hasEdgeKeys = edgeKeys.contains { store.int(forKey: $0) != nil }
        // Legacy files without the flag are customised iff any edge key exists (ScreenMargins.kt:36-51).
        let customised = store.bool(forKey: K.marginsCustomised) ?? hasEdgeKeys
        return ScreenMargins(customised: customised,
                             top: store.int(forKey: K.marginsTop) ?? 0,
                             bottom: store.int(forKey: K.marginsBottom) ?? 0,
                             left: store.int(forKey: K.marginsLeft) ?? 0,
                             right: store.int(forKey: K.marginsRight) ?? 0)
    }

    private func readMapLocked() -> MapPreferences {
        typealias K = SettingsKeys
        var m = MapPreferences()
        m.units = store.string(forKey: K.units).flatMap(MapUnits.init(rawValue:)) ?? .metric
        m.theme = store.string(forKey: K.mapTheme).flatMap(MapTheme.init(rawValue:)) ?? .auto
        m.chrome = store.string(forKey: K.chrome).flatMap(MapChrome.init(rawValue:)) ?? .dark
        m.voiceOn = store.bool(forKey: K.voicePrompts) ?? true
        m.showNextStop = store.bool(forKey: K.showNextStop) ?? true
        m.autoFinish = store.bool(forKey: K.autoFinishArrive) ?? true
        m.routeMode = store.string(forKey: K.routeMode).flatMap(RouteMode.init(rawValue:)) ?? .fast
        m.avoidTolls = store.bool(forKey: K.avoidTolls) ?? false
        m.avoidHighways = store.bool(forKey: K.avoidHighways) ?? false
        m.circuitKm = min(150, max(20, store.int(forKey: K.funCircuitKm) ?? 60))
        return m
    }

    /// Android-only round-trip values for a bike.
    public func androidOnlySettings(forBike b: String?) -> AndroidOnlySettings {
        lock.lock(); defer { lock.unlock() }
        return AndroidOnlySettings(
            resolutionMode: scopedString(SettingsKeys.resolutionMode, b).flatMap(AndroidAutoResolutionMode.init(rawValue:)) ?? .auto,
            aaDpiOverride: max(0, scopedInt(SettingsKeys.aaDpiOverride, b) ?? 0),
            remotePad: store.bool(forKey: SettingsKeys.remotePad) ?? true)
    }

    /// Handlebar source presence for a bike (`button_presence`, per bike).
    public func presence(forBike b: String?) -> HandlebarPresence {
        lock.lock(); defer { lock.unlock() }
        return HandlebarPresence(
            volumeRocker: scopedString(SettingsKeys.volumeRocker, b).flatMap(ButtonPresence.init(rawValue:)) ?? .unknown,
            trackKeys: scopedString(SettingsKeys.trackKeys, b).flatMap(ButtonPresence.init(rawValue:)) ?? .unknown)
    }

    /// Fire singles immediately (no UI on Android; default on).
    public var snappySingles: Bool {
        lock.lock(); defer { lock.unlock() }
        return store.bool(forKey: SettingsKeys.snappySingles) ?? true
    }

    /// Saved place slot 0…2 (global).
    public func savedPlace(_ slot: Int) -> SavedPlaceSlot {
        lock.lock(); defer { lock.unlock() }
        return SavedPlaceSlot(name: store.string(forKey: SettingsKeys.savedPlaceName(slot)) ?? "",
                              query: store.string(forKey: SettingsKeys.savedPlaceQuery(slot)) ?? "")
    }

    /// The three saved places.
    public var savedPlaces: [SavedPlaceSlot] { (0 ..< 3).map(savedPlace) }

    /// True when every gesture of the bike's map equals the default map.
    public func isButtonMapDefault(forBike b: String?) -> Bool {
        settings(forBike: b).buttonMap == defaultButtonMap
    }

    // MARK: - Writing (diff-based)

    /// Applies `body` to the current settings of `bikeId` and writes back ONLY the fields that changed
    /// (so untouched per-bike values keep inheriting the global value). Android couplings apply:
    /// `forceNonTouch = true` also clears `forceTouch` and vice versa (forceNonTouch is applied first,
    /// so setting both true leaves forceTouch); `profileOverride = nil` removes the scoped key;
    /// `screenMargins.customised == false` only resets the flag (edge values stay on disk);
    /// customised margins are clamped to 0…200; `circuitKm` is clamped to 20…150. `body` runs outside
    /// the lock and must not call back into this store. Returns the resolved settings after the write.
    /// Because only differences are written, re-selecting the inherited value does not pin it to the
    /// bike — use the individual setters (`setVideoQuality(_:forBike:)` …) for explicit user choices.
    @discardableResult
    public func update(forBike b: String?, _ body: (inout BikeSettings) -> Void) -> BikeSettings {
        let old = settings(forBike: b)
        var new = old
        body(&new)
        return write { () -> BikeSettings in
            writeDiffLocked(old: old, new: new, bike: b)
            return readLocked(b)
        }
    }

    private func writeDiffLocked(old: BikeSettings, new: BikeSettings, bike b: String?) {
        typealias K = SettingsKeys
        if new.videoQuality != old.videoQuality { store.set(new.videoQuality.rawValue, forKey: key(K.videoQuality, b)) }
        if new.screenFit != old.screenFit { store.set(new.screenFit.rawValue, forKey: key(K.screenFit, b)) }
        if new.mirrorOrientation != old.mirrorOrientation { store.set(new.mirrorOrientation.rawValue, forKey: key(K.mirrorOrientation, b)) }
        if new.powerMode != old.powerMode { store.set(new.powerMode.rawValue, forKey: key(K.powerMode, b)) }
        if new.profileOverride != old.profileOverride { setProfileOverrideLocked(new.profileOverride, b) }
        if new.handlebarControl != old.handlebarControl { store.set(new.handlebarControl, forKey: key(K.controlAa, b)) }
        let newMap = HandlebarPresets.completed(new.buttonMap, fallback: defaultButtonMap)
        let oldMap = HandlebarPresets.completed(old.buttonMap, fallback: defaultButtonMap)
        for g in ButtonGesture.allCases where newMap[g] != oldMap[g] {
            store.set(newMap[g]!.rawValue, forKey: key(K.buttonMap(g), b))
        }
        if new.clusterPreset != old.clusterPreset {
            if let p = new.clusterPreset { store.set(p.rawValue, forKey: key(K.clusterPreset, b)) }
            else { store.removeValue(forKey: key(K.clusterPreset, b)) }
        }
        if new.forceNonTouch != old.forceNonTouch { setForceNonTouchLocked(new.forceNonTouch) }
        if new.forceTouch != old.forceTouch { setForceTouchLocked(new.forceTouch) }
        if new.wifiTransport != old.wifiTransport { store.set(new.wifiTransport.rawValue, forKey: K.wifiTransport) }
        if new.screenMargins != old.screenMargins {
            let m = new.screenMargins
            if m.customised { setMarginsLocked(top: m.top, bottom: m.bottom, left: m.left, right: m.right) }
            else { store.set(false, forKey: K.marginsCustomised) }
        }
        if new.buttonTiming != old.buttonTiming {
            if new.buttonTiming.doubleTapMs != old.buttonTiming.doubleTapMs { store.set(new.buttonTiming.doubleTapMs, forKey: K.doubleTapMs) }
            if new.buttonTiming.holdMs != old.buttonTiming.holdMs { store.set(new.buttonTiming.holdMs, forKey: K.longPressMs) }
            if new.buttonTiming.holdsEnabled != old.buttonTiming.holdsEnabled { store.set(new.buttonTiming.holdsEnabled, forKey: K.holdsEnabled) }
        }
        if new.map != old.map { writeMapDiffLocked(old: old.map, new: new.map) }
        if new.autoConnect != old.autoConnect { store.set(new.autoConnect, forKey: K.autoConnect) }
        if new.autoRecovery != old.autoRecovery { store.set(new.autoRecovery, forKey: K.autoRecovery) }
        if new.logTrips != old.logTrips { store.set(new.logTrips, forKey: K.logTrips) }
        if new.includeSecretsInLogs != old.includeSecretsInLogs { store.set(new.includeSecretsInLogs, forKey: K.includeSecretsInLogs) }
        if new.keepScreenOn != old.keepScreenOn { store.set(new.keepScreenOn, forKey: K.iosKeepScreenOn) }
        if new.tileURLTemplate != old.tileURLTemplate { store.set(new.tileURLTemplate, forKey: K.iosTileURLTemplate) }
        if new.orsApiKey != old.orsApiKey { store.set(AppJvmText.trim(new.orsApiKey), forKey: K.orsApiKey) }
    }

    private func writeMapDiffLocked(old: MapPreferences, new: MapPreferences) {
        typealias K = SettingsKeys
        if new.units != old.units { store.set(new.units.rawValue, forKey: K.units) }
        if new.theme != old.theme { store.set(new.theme.rawValue, forKey: K.mapTheme) }
        if new.chrome != old.chrome { store.set(new.chrome.rawValue, forKey: K.chrome) }
        if new.voiceOn != old.voiceOn { store.set(new.voiceOn, forKey: K.voicePrompts) }
        if new.showNextStop != old.showNextStop { store.set(new.showNextStop, forKey: K.showNextStop) }
        if new.autoFinish != old.autoFinish { store.set(new.autoFinish, forKey: K.autoFinishArrive) }
        if new.routeMode != old.routeMode { store.set(new.routeMode.rawValue, forKey: K.routeMode) }
        if new.avoidTolls != old.avoidTolls { store.set(new.avoidTolls, forKey: K.avoidTolls) }
        if new.avoidHighways != old.avoidHighways { store.set(new.avoidHighways, forKey: K.avoidHighways) }
        if new.circuitKm != old.circuitKm { store.set(min(150, max(20, new.circuitKm)), forKey: K.funCircuitKm) }
    }

    private func setProfileOverrideLocked(_ p: BikeProfileID?, _ b: String?) {
        // Android: choosing AUTO removes the (scoped) key instead of storing "auto".
        if let p { store.set(p.rawValue, forKey: key(SettingsKeys.profileOverride, b)) }
        else { store.removeValue(forKey: key(SettingsKeys.profileOverride, b)) }
    }

    private func setForceNonTouchLocked(_ on: Bool) {
        store.set(on, forKey: SettingsKeys.forceNonTouch)
        if on { store.set(false, forKey: SettingsKeys.forceTouch) }
    }

    private func setForceTouchLocked(_ on: Bool) {
        store.set(on, forKey: SettingsKeys.forceTouch)
        if on { store.set(false, forKey: SettingsKeys.forceNonTouch) }
    }

    private func setMarginsLocked(top: Int, bottom: Int, left: Int, right: Int) {
        func c(_ v: Int) -> Int { min(200, max(0, v)) }
        store.set(true, forKey: SettingsKeys.marginsCustomised)
        store.set(c(top), forKey: SettingsKeys.marginsTop)
        store.set(c(bottom), forKey: SettingsKeys.marginsBottom)
        store.set(c(left), forKey: SettingsKeys.marginsLeft)
        store.set(c(right), forKey: SettingsKeys.marginsRight)
    }

    // MARK: - Individual setters (Android setter semantics)

    public func setVideoQuality(_ v: VideoQuality, forBike b: String?) {
        write { store.set(v.rawValue, forKey: key(SettingsKeys.videoQuality, b)) }
    }

    public func setScreenFit(_ v: ScreenFit, forBike b: String?) {
        write { store.set(v.rawValue, forKey: key(SettingsKeys.screenFit, b)) }
    }

    /// True when a valid Screen fit is stored for the bike (scoped or global key) — chosen by the rider
    /// or set by a settings pack. iOS mirror mode uses FIT when nothing is stored (media-video.md §15.7:
    /// iOS cannot rotate other apps, FILL shows only a slice); the read / exported default stays FILL
    /// for Android settings-pack compatibility.
    public func hasStoredScreenFit(forBike b: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return scopedString(SettingsKeys.screenFit, b).flatMap(ScreenFit.init(rawValue:)) != nil
    }

    public func setMirrorOrientation(_ v: MirrorOrientation, forBike b: String?) {
        write { store.set(v.rawValue, forKey: key(SettingsKeys.mirrorOrientation, b)) }
    }

    public func setPowerMode(_ v: PowerMode, forBike b: String?) {
        write { store.set(v.rawValue, forKey: key(SettingsKeys.powerMode, b)) }
    }

    /// nil = automatic: removes the bike's override (falls back to a global override, if any).
    public func setProfileOverride(_ p: BikeProfileID?, forBike b: String?) {
        write { setProfileOverrideLocked(p, b) }
    }

    /// Handlebar buttons drive the dash UI (`controlAa`).
    public func setHandlebarControl(_ on: Bool, forBike b: String?) {
        write { store.set(on, forKey: key(SettingsKeys.controlAa, b)) }
    }

    public func setButtonAction(_ action: ButtonAction, for gesture: ButtonGesture, forBike b: String?) {
        write { store.set(action.rawValue, forKey: key(SettingsKeys.buttonMap(gesture), b)) }
    }

    /// Resets the bike's map (removes its scoped gesture keys → global/default apply).
    public func resetButtonMap(forBike b: String?) {
        write { resetButtonMapLocked(b) }
    }

    private func resetButtonMapLocked(_ b: String?) {
        for g in ButtonGesture.allCases { store.removeValue(forKey: key(SettingsKeys.buttonMap(g), b)) }
    }

    /// `ButtonClusterPreset.apply`: reset the bike's map, write all nine gestures (`mapping`, default
    /// = the iOS mapping of the preset), remember the preset and force handlebar control on. The
    /// touchscreen flags are never changed.
    public func applyClusterPreset(_ preset: ButtonClusterPreset, forBike b: String?,
                                   mapping: [ButtonGesture: ButtonAction]? = nil) {
        let m = HandlebarPresets.completed(mapping ?? HandlebarPresets.iosMapping(for: preset),
                                           fallback: HandlebarPresets.iosMapping(for: preset))
        write {
            resetButtonMapLocked(b)
            for g in ButtonGesture.allCases { store.set(m[g]!.rawValue, forKey: key(SettingsKeys.buttonMap(g), b)) }
            store.set(preset.rawValue, forKey: key(SettingsKeys.clusterPreset, b))
            if !(scopedBool(SettingsKeys.controlAa, b) ?? true) { store.set(true, forKey: key(SettingsKeys.controlAa, b)) }
        }
    }

    /// `ButtonClusterPreset.clear`: reset the bike's map and forget the active preset.
    public func clearClusterPreset(forBike b: String?) {
        write {
            resetButtonMapLocked(b)
            store.removeValue(forKey: key(SettingsKeys.clusterPreset, b))
        }
    }

    /// Writing true also writes `forceTouch = false` (mutually exclusive overrides).
    public func setForceNonTouch(_ on: Bool) { write { setForceNonTouchLocked(on) } }

    /// Writing true also writes `forceNonTouch = false`.
    public func setForceTouch(_ on: Bool) { write { setForceTouchLocked(on) } }

    public func setWifiTransport(_ t: WifiTransport) {
        write { store.set(t.rawValue, forKey: SettingsKeys.wifiTransport) }
    }

    /// Custom margins (each clamped 0…200, `customised = true`).
    public func setScreenMargins(top: Int, bottom: Int, left: Int, right: Int) {
        write { setMarginsLocked(top: top, bottom: bottom, left: left, right: right) }
    }

    /// Back to the profile default (`customised = false`, stored edge values kept).
    public func resetScreenMargins() {
        write { store.set(false, forKey: SettingsKeys.marginsCustomised) }
    }

    public func setAndroidOnlySettings(_ s: AndroidOnlySettings, forBike b: String?) {
        write {
            store.set(s.resolutionMode.rawValue, forKey: key(SettingsKeys.resolutionMode, b))
            store.set(max(0, s.aaDpiOverride), forKey: key(SettingsKeys.aaDpiOverride, b))
            store.set(s.remotePad, forKey: SettingsKeys.remotePad)
        }
    }

    public func setResolutionMode(_ m: AndroidAutoResolutionMode, forBike b: String?) {
        write { store.set(m.rawValue, forKey: key(SettingsKeys.resolutionMode, b)) }
    }

    /// Android `setDpiOverride`: values ≤ 0 store 0 (automatic).
    public func setAaDpiOverride(_ dpi: Int, forBike b: String?) {
        write { store.set(dpi > 0 ? dpi : 0, forKey: key(SettingsKeys.aaDpiOverride, b)) }
    }

    public func setRemotePad(_ on: Bool) {
        write { store.set(on, forKey: SettingsKeys.remotePad) }
    }

    public func setVolumeRockerPresence(_ p: ButtonPresence, forBike b: String?) {
        write { store.set(p.rawValue, forKey: key(SettingsKeys.volumeRocker, b)) }
    }

    public func setTrackKeysPresence(_ p: ButtonPresence, forBike b: String?) {
        write { store.set(p.rawValue, forKey: key(SettingsKeys.trackKeys, b)) }
    }

    /// "Reset to untested": both sources back to UNKNOWN.
    public func resetPresence(forBike b: String?) {
        write {
            store.set(ButtonPresence.unknown.rawValue, forKey: key(SettingsKeys.volumeRocker, b))
            store.set(ButtonPresence.unknown.rawValue, forKey: key(SettingsKeys.trackKeys, b))
        }
    }

    public func setSnappySingles(_ on: Bool) {
        write { store.set(on, forKey: SettingsKeys.snappySingles) }
    }

    /// Saves slot 0…2 (name and query Kotlin-trimmed, like Android).
    public func setSavedPlace(_ slot: Int, name: String, query: String) {
        write {
            store.set(AppJvmText.trim(name), forKey: SettingsKeys.savedPlaceName(slot))
            store.set(AppJvmText.trim(query), forKey: SettingsKeys.savedPlaceQuery(slot))
        }
    }

    /// Removes every scoped value of a bike (all `*#<bikeId>` keys).
    public func removeAllScopedValues(forBike bikeId: String) {
        write {
            for k in store.allKeys() where BikeScope.isKey(k, scopedTo: bikeId) { store.removeValue(forKey: k) }
        }
    }
}
