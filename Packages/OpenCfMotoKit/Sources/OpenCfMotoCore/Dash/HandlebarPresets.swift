// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) ButtonMap.kt, ButtonClusterPreset.kt, ButtonPresencePrefs.kt,
// ButtonTimingPrefs.kt, SavedPlaces.kt
//
// Handlebar mapping data (docs/spec/input-controls.md §7.3–§7.12, §9): verbatim English labels,
// Android cluster presets, the iOS default mapping, presence model and the action → DashInput map.

import Foundation

// MARK: - Presence

/// Whether a handlebar source was observed on this bike (`ButtonPresence`, persisted by name).
public enum ButtonPresence: String, Sendable, Codable, CaseIterable {
    case unknown = "UNKNOWN", present = "PRESENT", absent = "ABSENT"

    /// Android summary word: `untested` / `works` / `absent`.
    public var summaryLabel: String {
        switch self {
        case .unknown: return "untested"
        case .present: return "works"
        case .absent: return "absent"
        }
    }
}

/// Per-bike presence of the two handlebar sources (`button_presence`).
public struct HandlebarPresence: Sendable, Equatable, Codable {
    /// ▲/▼ AVRCP absolute volume (observable on iOS only through the experimental volume path).
    public var volumeRocker: ButtonPresence
    /// ◀/▶/★ track and play/pause keys (MPRemoteCommandCenter).
    public var trackKeys: ButtonPresence

    public init(volumeRocker: ButtonPresence = .unknown, trackKeys: ButtonPresence = .unknown) {
        self.volumeRocker = volumeRocker
        self.trackKeys = trackKeys
    }

    /// `"▲/▼ <untested|works|absent> · ◀/▶ <untested|works|absent>"` (shown as "Handlebar sources: …").
    public var summary: String {
        "\u{25B2}/\u{25BC} \(volumeRocker.summaryLabel) \u{00B7} \u{25C0}/\u{25B6} \(trackKeys.summaryLabel)"
    }

    /// Android `shouldPinVolume`: the volume path is only used while the rocker is not ABSENT.
    public var shouldUseVolumePath: Bool { volumeRocker != .absent }
}

// MARK: - Presets

public enum HandlebarPresets {
    /// Android shipped defaults (`ButtonGesture.default`, = the `five_way` preset on Android).
    public static let androidDefaults: [ButtonGesture: ButtonAction] =
        Dictionary(uniqueKeysWithValues: ButtonGesture.allCases.map { ($0, $0.defaultAction) })

    /// iOS default mapping (input-controls.md §9.1 cluster C): singles as Android (◀ / ▶ = knob ∓1,
    /// ★ = select), `selectLong` → `none` (★ hold is never observable on iOS: play/pause commands carry no
    /// press duration) and — P0 (D02) — every double → `none`. With snappy singles a double always fired its
    /// single first (★★ = activate, then Back; ▶▶ = move, then the menu; ◀◀ = −2), and a double pressed a bit
    /// slowly became two singles: a mistimed double meant something else. Now a quick second press is
    /// swallowed (the double's action is `none`) and a slow one is a second single — never a different action.
    /// The double-tap window stays 300 ms. What only a double reached stays reachable with singles: BACK
    /// (close a sheet, dismiss the arrival card, cancel a preview) through each one's own close / Done /
    /// Cancel control; HOME (the menu) through the map's Menu FAB; ◀◀'s D-pad left is ◀ again.
    public static let iosDefaultMapping: [ButtonGesture: ButtonAction] = {
        var m = androidDefaults
        m[.selectDouble] = ButtonAction.none
        m[.navFwdDouble] = ButtonAction.none
        m[.navBackDouble] = ButtonAction.none
        m[.selectLong] = ButtonAction.none
        return m
    }()

    /// The iOS default mapping of builds before P0: ▶▶ Home, ◀◀ D-pad left, ★★ Back, ★ hold none.
    public static let iosDefaultMappingBeforeP0: [ButtonGesture: ButtonAction] = {
        var m = androidDefaults
        m[.navFwdDouble] = .home
        m[.selectLong] = ButtonAction.none
        return m
    }()

    /// P0 (D02) migration, applied when a map is read: a map stored exactly as the pre-P0 iOS default
    /// (what applying the 5-way or MODE / ENT preset wrote on earlier builds) reads as today's
    /// `iosDefaultMapping`, so the unmapped doubles reach those riders too. Any other map — one gesture
    /// changed by the rider, an Android import, BACK / SET, the single-button option — is returned as is.
    public static func migratingLegacyDefault(_ map: [ButtonGesture: ButtonAction]) -> [ButtonGesture: ButtonAction] {
        completed(map, fallback: iosDefaultMapping) == iosDefaultMappingBeforeP0 ? iosDefaultMapping : map
    }

    /// Android `ButtonClusterPreset.mapping()` (all nine gestures).
    public static func androidMapping(for preset: ButtonClusterPreset) -> [ButtonGesture: ButtonAction] {
        switch preset {
        case .fiveWay, .modeEnt:
            return androidDefaults
        case .backSet:
            return backSetMapping
        }
    }

    /// The mapping `apply` writes on iOS (input-controls.md §9): `five_way` / `mode_ent` use the iOS
    /// default mapping; `back_set` is identical to Android (its ▲▲/▼▼ doubles need the experimental
    /// volume path, ★ select still works).
    public static func iosMapping(for preset: ButtonClusterPreset) -> [ButtonGesture: ButtonAction] {
        switch preset {
        case .fiveWay, .modeEnt:
            return iosDefaultMapping
        case .backSet:
            return backSetMapping
        }
    }

    private static let backSetMapping: [ButtonGesture: ButtonAction] = [
        .navBack: .knobBack,
        .navFwd: .knobFwd,
        .selectPress: .select,
        .navBackLong: ButtonAction.none,
        .navFwdLong: ButtonAction.none,
        .selectLong: ButtonAction.none,
        .selectDouble: ButtonAction.none,
        .navBackDouble: .back,
        .navFwdDouble: .home,
    ]

    /// iOS-only option for dashes where only ★ is observable (input-controls.md §9.3 option A1):
    /// ★ cycles focus, ★★ selects. Not a persisted preset id (Android has no such preset) — apply it
    /// as a custom map (cluster preset nil).
    public static let iosSingleButtonMapping: [ButtonGesture: ButtonAction] = {
        var m = iosDefaultMapping
        m[.selectPress] = .knobFwd
        m[.selectDouble] = .select
        return m
    }()

    /// Every gesture → action map is complete (all nine gestures); missing entries fall back to `fallback`.
    public static func completed(_ map: [ButtonGesture: ButtonAction],
                                 fallback: [ButtonGesture: ButtonAction] = iosDefaultMapping) -> [ButtonGesture: ButtonAction] {
        Dictionary(uniqueKeysWithValues: ButtonGesture.allCases.map { ($0, map[$0] ?? fallback[$0] ?? $0.defaultAction) })
    }
}

public extension ButtonClusterPreset {
    /// Verbatim Android title.
    var englishTitle: String {
        switch self {
        case .fiveWay: return "5-way Explore (Fn / \u{2605} / voice)"
        case .modeEnt: return "MODE / ENT cluster"
        case .backSet: return "BACK / SET diamond (limited)"
        }
    }

    /// Verbatim Android summary.
    var englishSummary: String {
        switch self {
        case .fiveWay:
            return "\u{25C0}/\u{25B6} = knob (move) \u{00B7} \u{25C0}\u{25C0}/\u{25B6}\u{25B6} = D-pad \u{2190}/\u{2192} (into apps) \u{00B7} \u{2605} = Select \u{00B7} \u{2605}\u{2605} = Back \u{00B7} \u{2605} hold = Home. Singles fire immediately (no lag waiting for \u{00D7}2)."
        case .modeEnt:
            return "Same AA navigation as 5-way: knob \u{00B7} \u{00D7}2 = D-pad \u{2190}/\u{2192} \u{00B7} \u{2605}\u{2605} = Back. Singles are snappy; a second tap in the window still fires \u{00D7}2."
        case .backSet:
            return "Snappy singles (no double-tap wait). Discrete hold / Select \u{00D7}2 usually don't exist \u{2014} but a hard \u{25B2}\u{25B2} / \u{25BC}\u{25BC} volume flick often coalesces into \u{00D7}2 \u{2192} Back / Home. On-screen pad covers anything else."
        }
    }

    /// All Android presets fire singles immediately (`instantSingles == true`).
    var instantSingles: Bool { true }
}

public extension ButtonGesture {
    /// Verbatim Android label (note the two spaces before the glyphs).
    var englishLabel: String {
        switch self {
        case .navBack: return "Backward  \u{25C0} / \u{25B2}"
        case .navFwd: return "Forward  \u{25B6} / \u{25BC}"
        case .selectPress: return "Select  Enter / \u{2605}"
        case .navBackLong: return "Backward (hold)  \u{25C0}"
        case .navFwdLong: return "Forward (hold)  \u{25B6}"
        case .selectLong: return "Select (hold)  Enter / \u{2605}"
        case .navBackDouble: return "Backward \u{00D7}2"
        case .navFwdDouble: return "Forward \u{00D7}2"
        case .selectDouble: return "Select \u{00D7}2"
        }
    }

    /// Verbatim Android hint.
    var englishHint: String {
        switch self {
        case .navBack: return "\u{25C0} left, or the \u{25B2} volume press on non-touch dashes"
        case .navFwd: return "\u{25B6} right, or the \u{25BC} volume press on non-touch dashes"
        case .selectPress: return "a quick tap of the OK / \u{2605} start button"
        case .navBackLong: return "press and hold \u{25C0} (track-key dashes only)"
        case .navFwdLong: return "press and hold \u{25B6} (track-key dashes only)"
        case .selectLong: return "press and hold the OK / \u{2605} button"
        case .navBackDouble: return "double-tap backward within a short window"
        case .navFwdDouble: return "double-tap forward within a short window"
        case .selectDouble: return "double-tap the OK / \u{2605} button"
        }
    }
}

public extension ButtonAction {
    /// Verbatim Android label.
    var englishLabel: String {
        switch self {
        case .none: return "Do nothing"
        case .knobFwd: return "Knob forward (next item)"
        case .knobBack: return "Knob back (previous item)"
        case .select: return "Select / OK"
        case .back: return "Back"
        case .home: return "Home (app list)"
        case .assistant: return "Assistant (voice)"
        case .up: return "D-pad up"
        case .down: return "D-pad down"
        case .left: return "D-pad left"
        case .right: return "D-pad right"
        case .nav1: return "Navigate to saved place 1"
        case .nav2: return "Navigate to saved place 2"
        case .nav3: return "Navigate to saved place 3"
        }
    }

    /// What this action does to the iOS dash UI (`MediaButtonBridge.perform` → our own UI):
    /// knob ±1, Android keycodes 23/4/3/84/19/20/21/22 as `HandlebarKey`s, saved place 1…3.
    /// `none` → nil (the press is swallowed).
    var handlebarDashInput: DashInput? {
        switch self {
        case .none: return nil
        case .knobFwd: return .knob(1)
        case .knobBack: return .knob(-1)
        case .select: return .key(.enter)
        case .back: return .key(.back)
        case .home: return .key(.home)
        case .assistant: return .key(.assistant)
        case .up: return .key(.up)
        case .down: return .key(.down)
        case .left: return .key(.left)
        case .right: return .key(.right)
        case .nav1: return .savedPlace(1)
        case .nav2: return .savedPlace(2)
        case .nav3: return .savedPlace(3)
        }
    }
}

// MARK: - Timing choices (ButtonTimingPrefs.kt)

public extension ButtonTiming {
    /// Allowed double-tap windows (ms); any other stored value reads as 300.
    static let doubleTapChoices = [200, 300, 450, 1000]
    /// Allowed hold thresholds (ms); any other stored value reads as 600.
    static let holdChoices = [500, 600, 800]

    /// The value Android would use for a stored double-tap window.
    static func normalizedDoubleTapMs(_ ms: Int?) -> Int {
        guard let ms, doubleTapChoices.contains(ms) else { return 300 }
        return ms
    }

    /// The value Android would use for a stored hold threshold.
    static func normalizedHoldMs(_ ms: Int?) -> Int {
        guard let ms, holdChoices.contains(ms) else { return 600 }
        return ms
    }
}

// MARK: - Saved places (SavedPlaces.kt)

/// One of the three saved-place slots that `nav1…nav3` navigate to (global setting).
public struct SavedPlaceSlot: Sendable, Equatable, Codable {
    public var name: String
    /// Address, place name or `lat,lng`.
    public var query: String
    public init(name: String = "", query: String = "") { self.name = name; self.query = query }
    /// A slot is set iff its query is not blank.
    public var isSet: Bool { !AppJvmText.isBlank(query) }

    /// Android picker label for slot index `slot` (0-based): `Navigate to saved place N (not set yet)`
    /// or `Navigate: <name or query>`.
    public func actionLabel(slot: Int) -> String {
        if !isSet { return "Navigate to saved place \(slot + 1) (not set yet)" }
        return "Navigate: \(AppJvmText.isBlank(name) ? query : name)"
    }
}
