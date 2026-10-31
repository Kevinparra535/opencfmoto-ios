// SPDX-License-Identifier: AGPL-3.0-or-later
// CONTRACT FILE — settings value types. Raw values are the Android persisted strings so the
// "opencfmoto.settings" v1 JSON pack round-trips between platforms (docs/spec/app-features.md §2).
// Persistence (scoped per-bike keys, App Group UserDefaults) and JSON import/export live in
// Settings/SettingsStore.swift and Settings/SettingsBackup.swift.

import Foundation

public enum VideoQuality: String, Sendable, Codable, CaseIterable {
    case smooth = "SMOOTH", balanced = "BALANCED", sharp = "SHARP"
    /// Multiplier on the profile base bitrate (2.5 Mbit/s).
    public var bitrateFactor: Double {
        switch self {
        case .smooth: return 0.7
        case .balanced: return 1.0
        case .sharp: return 1.6
        }
    }
}

public enum ScreenFit: String, Sendable, Codable, CaseIterable {
    case fill = "FILL", fit = "FIT", stretch = "STRETCH"
}

public enum MirrorOrientation: String, Sendable, Codable, CaseIterable {
    case matchDash = "MATCH_DASH", follow = "FOLLOW", landscape = "LANDSCAPE", portrait = "PORTRAIT"
}

public enum PowerMode: String, Sendable, Codable, CaseIterable {
    case auto = "AUTO", smooth = "SMOOTH", balanced = "BALANCED", saver = "SAVER"
    /// Frame cap (fps). AUTO starts at 30 and adapts (AdaptivePolicy).
    public var frameCap: Int {
        switch self {
        case .auto, .smooth: return 30
        case .balanced: return 24
        case .saver: return 20
        }
    }
}

public enum WifiTransport: String, Sendable, Codable, CaseIterable {
    case auto = "auto", ap = "ap", p2p = "p2p"
}

/// Assignable handlebar actions (ButtonMap.kt:13-27), persisted by id.
public enum ButtonAction: String, Sendable, Codable, CaseIterable {
    case none = "none"
    case knobFwd = "knobFwd"
    case knobBack = "knobBack"
    case select = "select"
    case back = "back"
    case home = "home"
    case assistant = "assistant"
    case up = "up", down = "down", left = "left", right = "right"
    case nav1 = "nav1", nav2 = "nav2", nav3 = "nav3"
}

/// Handlebar gestures (ButtonMap.kt:58-74), persisted by id.
public enum ButtonGesture: String, Sendable, Codable, CaseIterable {
    case navBack = "navBack"
    case navFwd = "navFwd"
    case selectPress = "selectPress"
    case navBackLong = "navBackLong"
    case navFwdLong = "navFwdLong"
    case selectLong = "selectLong"
    case navBackDouble = "navBackDouble"
    case navFwdDouble = "navFwdDouble"
    case selectDouble = "selectDouble"

    public var defaultAction: ButtonAction {
        switch self {
        case .navBack: return .knobBack
        case .navFwd: return .knobFwd
        case .selectPress: return .select
        case .navBackLong, .navFwdLong: return .none
        case .selectLong: return .home
        case .navBackDouble: return .left
        case .navFwdDouble: return .right
        case .selectDouble: return .back
        }
    }
}

public enum ButtonClusterPreset: String, Sendable, Codable, CaseIterable {
    case fiveWay = "five_way", modeEnt = "mode_ent", backSet = "back_set"
}

/// Per-edge insets in dash pixels (0…200). `customised == false` → the profile default applies
/// (800NK Advanced: top 22, all others 0).
public struct ScreenMargins: Sendable, Equatable, Codable {
    public var customised: Bool
    public var top: Int
    public var bottom: Int
    public var left: Int
    public var right: Int
    public init(customised: Bool = false, top: Int = 0, bottom: Int = 0, left: Int = 0, right: Int = 0) {
        self.customised = customised; self.top = top; self.bottom = bottom; self.left = left; self.right = right
    }
    public static let zero = ScreenMargins()
    public func clamped() -> ScreenMargins {
        func c(_ v: Int) -> Int { min(200, max(0, v)) }
        return ScreenMargins(customised: customised, top: c(top), bottom: c(bottom), left: c(left), right: c(right))
    }
}

/// Built-in map preferences (MapPrefs.kt / NightPrefs.kt; navigation-dash.md §12.3).
public struct MapPreferences: Sendable, Equatable, Codable {
    public var units: MapUnits = .metric
    public var theme: MapTheme = .auto
    public var chrome: MapChrome = .dark
    public var voiceOn: Bool = true
    public var showNextStop: Bool = true
    public var autoFinish: Bool = true
    public var routeMode: RouteMode = .fast
    public var avoidTolls: Bool = false
    public var avoidHighways: Bool = false
    public var circuitKm: Int = 60
    public init() {}
    public var routeOptions: RouteOptions {
        RouteOptions(mode: routeMode, avoidTolls: avoidTolls, avoidHighways: avoidHighways, maxAlternatives: 4, circuitKm: circuitKm)
    }
}

/// Handlebar timing (global).
public struct ButtonTiming: Sendable, Equatable, Codable {
    /// Double-tap window ms (choices 200 / 300 / 450 / 1000).
    public var doubleTapMs: Int = 300
    public var holdsEnabled: Bool = true
    /// Hold threshold ms (choices 500 / 600 / 800).
    public var holdMs: Int = 600
    public init() {}
}

/// Effective settings for one bike (scoped values already resolved). Defaults = Android defaults.
public struct BikeSettings: Sendable, Equatable, Codable {
    // per-bike
    public var videoQuality: VideoQuality = .balanced
    public var screenFit: ScreenFit = .fill
    public var mirrorOrientation: MirrorOrientation = .matchDash
    public var powerMode: PowerMode = .balanced
    /// nil = automatic profile selection ("auto").
    public var profileOverride: BikeProfileID? = nil
    /// Handlebar buttons drive the dash UI (Android `controlAa`).
    public var handlebarControl: Bool = true
    public var buttonMap: [ButtonGesture: ButtonAction] = Dictionary(uniqueKeysWithValues: ButtonGesture.allCases.map { ($0, $0.defaultAction) })
    public var clusterPreset: ButtonClusterPreset? = nil
    // global
    public var forceNonTouch: Bool = false
    public var forceTouch: Bool = false
    public var wifiTransport: WifiTransport = .auto
    public var screenMargins: ScreenMargins = .zero
    public var buttonTiming: ButtonTiming = ButtonTiming()
    public var map: MapPreferences = MapPreferences()
    public var autoConnect: Bool = true
    public var autoRecovery: Bool = true
    public var logTrips: Bool = true
    public var includeSecretsInLogs: Bool = false
    // iOS-only
    public var keepScreenOn: Bool = true
    /// Raster tile URL template for the dash map ({z}/{x}/{y}).
    public var tileURLTemplate: String = "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
    /// OpenRouteService API key (optional; enables ORS routing).
    public var orsApiKey: String = ""

    public init() {}
}
