// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) res/values/strings.xml (setup_*, pref_*, gpx_*, controls_*),
// VideoPrefs.kt, NightPrefs.kt, MapPrefs.kt, ProfileOverride.kt
//
// Localized labels of the setting values (docs/spec/app-features.md §2.3, §9.4). Short labels are
// the segment titles, long labels the description line under a selector (Android shows the
// current choice's label there). Spanish lives in App/Resources/Localization/ui-features.json.

import SwiftUI
import OpenCfMotoCore
import OpenCfMotoAppModel

enum SettingsLabels {
    // MARK: Video quality (pref_vq_*)

    static func short(_ value: VideoQuality) -> LocalizedStringKey {
        switch value {
        case .smooth: return "Smoother"
        case .balanced: return "Balanced"
        case .sharp: return "Sharper"
        }
    }

    static func long(_ value: VideoQuality) -> LocalizedStringKey {
        switch value {
        case .smooth: return "Smoother — less data/latency"
        case .balanced: return "Balanced (recommended)"
        case .sharp: return "Sharper — more data"
        }
    }

    // MARK: Screen fit (pref_fit_*)

    static func short(_ value: ScreenFit) -> LocalizedStringKey {
        switch value {
        case .fill: return "Fill"
        case .fit: return "Fit"
        case .stretch: return "Stretch"
        }
    }

    static func long(_ value: ScreenFit) -> LocalizedStringKey {
        switch value {
        case .fill: return "Fill — edge to edge (crops a little)"
        case .fit: return "Fit — no cropping (black bars)"
        case .stretch: return "Stretch — fills, slight distortion"
        }
    }

    // MARK: Mirror orientation (pref_mirror_orient_*)

    static func long(_ value: MirrorOrientation) -> LocalizedStringKey {
        switch value {
        case .matchDash: return "Match dash (recommended)"
        case .follow: return "Follow phone"
        case .landscape: return "Landscape"
        case .portrait: return "Portrait"
        }
    }

    // MARK: Battery & power (pref_power_*)

    static func short(_ value: PowerMode) -> LocalizedStringKey {
        switch value {
        case .auto: return "Auto"
        case .smooth: return "Smooth"
        case .balanced: return "Balanced"
        case .saver: return "Saver"
        }
    }

    static func long(_ value: PowerMode) -> LocalizedStringKey {
        switch value {
        case .auto: return "Auto — adapts to heat & signal"
        case .smooth: return "Smooth — 30 fps (most battery)"
        case .balanced: return "Balanced — 24 fps (recommended)"
        case .saver: return "Battery saver — 20 fps (coolest)"
        }
    }

    // MARK: Map (gpx_*, controls_*, pref_map_theme_*)

    static func short(_ value: MapUnits) -> LocalizedStringKey {
        switch value {
        case .metric: return "Metric"
        case .imperial: return "Imperial"
        }
    }

    static func short(_ value: MapTheme) -> LocalizedStringKey {
        switch value {
        case .auto: return "Auto"
        case .day: return "Day"
        case .night: return "Night"
        }
    }

    static func long(_ value: MapTheme) -> LocalizedStringKey {
        switch value {
        case .auto: return "Auto (day / night)"
        case .day: return "Day (light)"
        case .night: return "Night (dark)"
        }
    }

    static func short(_ value: RouteMode) -> LocalizedStringKey {
        switch value {
        case .fast: return "Fast"
        case .fun: return "Fun"
        }
    }

    static func short(_ value: MapChrome) -> LocalizedStringKey {
        switch value {
        case .dark: return "Dark"
        case .black: return "Black"
        case .slate: return "Slate"
        case .forest: return "Forest"
        }
    }

    // MARK: Handlebar timing (pref_dbltap_*, pref_hold_*)

    static func doubleTap(_ ms: Int) -> LocalizedStringKey {
        switch ms {
        case 200: return "200 ms — snappier singles"
        case 450: return "450 ms — forgiving doubles"
        case 1000: return "1000 ms — slow doubles (long physical press)"
        default: return "300 ms — balanced (recommended)"
        }
    }

    static func hold(_ ms: Int) -> LocalizedStringKey {
        switch ms {
        case 500: return "500 ms — quicker hold"
        case 800: return "800 ms — deliberate hold"
        default: return "600 ms — balanced (recommended)"
        }
    }

    // MARK: Bike profiles (pref_profile_*)

    /// What a profile is for (shown under its name in the picker).
    static func profileDetail(_ id: BikeProfileID?) -> LocalizedStringKey {
        guard let id else { return "Detect from the bike (recommended)" }
        switch id {
        case .legacy: return "CFDL16 / 450SR-style non-touch"
        case .nk800: return "CRCP / sdk 0.9.23.x non-touch"
        case .nkAdvanced: return "CFDL26 touch 720×712"
        case .cfdl26Landscape: return "CFDL26 landscape touch"
        case .cfdl26Portrait: return "CFDL26 portrait (handlebar-primary)"
        case .clc450: return "544×512 near-square"
        case .morini: return "Moto Morini SoftAP (experimental)"
        case .motoplayLandscape: return "CFDL16 MotoPlay landscape (800×400)"
        }
    }

    // MARK: Permissions

    static func location(_ value: LocationPermission) -> LocalizedStringKey {
        switch value {
        case .notDetermined: return "Not asked yet"
        case .restricted: return "Restricted"
        case .denied: return "Denied"
        case .whenInUse: return "While using the app"
        case .always: return "Always"
        }
    }

    static func localNetwork(_ value: LocalNetworkAccessState) -> LocalizedStringKey {
        switch value {
        case .granted: return "Allowed"
        case .denied: return "Denied"
        case .undetermined: return "Not asked yet"
        case .unavailable: return "Unknown"
        }
    }

    /// "Media & Apple Music" (Apple Music on the dash, iOS addition).
    static func appleMusic(_ value: MusicAuthorizationState) -> LocalizedStringKey {
        switch value {
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .notDetermined: return "Not asked yet"
        case .restricted: return "Restricted"
        case .unavailable: return "Not available"
        }
    }

    // MARK: Margins (margins_summary_*)

    static func marginsSummary(_ margins: ScreenMargins, profileDefault: Bool) -> Text {
        if margins.top == 0 && margins.bottom == 0 && margins.left == 0 && margins.right == 0 {
            return Text("None — the dash UI uses the whole screen")
        }
        let top = String(margins.top), bottom = String(margins.bottom)
        let left = String(margins.left), right = String(margins.right)
        if profileDefault {
            return Text("Top \(top) · bottom \(bottom) · left \(left) · right \(right) px (profile default)")
        }
        return Text("Top \(top) · bottom \(bottom) · left \(left) · right \(right) px")
    }
}
