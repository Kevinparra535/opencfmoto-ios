// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) ButtonMap.kt (gesture / action labels and hints),
// ButtonClusterPreset.kt (cluster titles), ButtonPresencePrefs.kt (presence words), SavedPlaces.kt
//
// Labels of the handlebar mapping editor (docs/spec/input-controls.md §7.3, §7.4, §7.10, §9;
// app-features.md §2.8, §9.8). Gesture and action labels are the verbatim Android English (note
// the two spaces before the glyphs); actions that behave differently in the iOS dash UI say so
// (HOME toggles the dash menu, ASSISTANT toggles the dash search — Siri cannot be invoked).
// Preset summaries describe the iOS mapping (HandlebarPresets.iosMapping).

import SwiftUI
import OpenCfMotoCore
import OpenCfMotoAppModel

enum ControlsLabels {
    // MARK: Gestures

    static func gesture(_ gesture: ButtonGesture) -> LocalizedStringKey {
        switch gesture {
        case .navBack: return "Backward  ◀ / ▲"
        case .navFwd: return "Forward  ▶ / ▼"
        case .selectPress: return "Select  Enter / ★"
        case .navBackLong: return "Backward (hold)  ◀"
        case .navFwdLong: return "Forward (hold)  ▶"
        case .selectLong: return "Select (hold)  Enter / ★"
        case .navBackDouble: return "Backward ×2"
        case .navFwdDouble: return "Forward ×2"
        case .selectDouble: return "Select ×2"
        }
    }

    static func hint(_ gesture: ButtonGesture) -> LocalizedStringKey {
        switch gesture {
        case .navBack: return "◀ left, or the ▲ volume press on non-touch dashes"
        case .navFwd: return "▶ right, or the ▼ volume press on non-touch dashes"
        case .selectPress: return "a quick tap of the OK / ★ start button"
        case .navBackLong: return "press and hold ◀ (track-key dashes only)"
        case .navFwdLong: return "press and hold ▶ (track-key dashes only)"
        case .selectLong: return "press and hold the OK / ★ button"
        case .navBackDouble: return "double-tap backward within a short window"
        case .navFwdDouble: return "double-tap forward within a short window"
        case .selectDouble: return "double-tap the OK / ★ button"
        }
    }

    /// What iOS can and cannot observe for a gesture (input-controls.md §8, §9.1).
    static func iosNote(_ gesture: ButtonGesture) -> LocalizedStringKey? {
        switch gesture {
        case .selectLong:
            return "iOS can't see how long ★ is held, so this gesture never fires."
        case .navBackLong, .navFwdLong:
            return "Only if the dash sends seek (hold) commands — most dashes don't."
        default:
            return nil
        }
    }

    // MARK: Actions

    static func action(_ action: ButtonAction, slots: [SavedPlaceSlot]) -> Text {
        switch action {
        case .none: return Text("Do nothing")
        case .knobFwd: return Text("Knob forward (next item)")
        case .knobBack: return Text("Knob back (previous item)")
        case .select: return Text("Select / OK")
        case .back: return Text("Back")
        case .home: return Text("Home (dash menu)")
        case .assistant: return Text("Assistant (dash search)")
        case .up: return Text("D-pad up")
        case .down: return Text("D-pad down")
        case .left: return Text("D-pad left")
        case .right: return Text("D-pad right")
        case .nav1: return savedPlace(0, slots: slots)
        case .nav2: return savedPlace(1, slots: slots)
        case .nav3: return savedPlace(2, slots: slots)
        }
    }

    /// `Navigate: <name or query>` / `Navigate to saved place N (not set yet)` (SavedPlaces.kt:34-38).
    static func savedPlace(_ index: Int, slots: [SavedPlaceSlot]) -> Text {
        let number = String(index + 1)
        guard slots.indices.contains(index), slots[index].isSet else {
            return Text("Navigate to saved place \(number) (not set yet)")
        }
        let slot = slots[index]
        let name = slot.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = name.isEmpty ? slot.query.trimmingCharacters(in: .whitespacesAndNewlines) : name
        return Text("Navigate: \(target)")
    }

    /// Slot numbers (1…3) of the saved-place actions.
    static func savedPlaceIndex(_ action: ButtonAction) -> Int? {
        switch action {
        case .nav1: return 0
        case .nav2: return 1
        case .nav3: return 2
        default: return nil
        }
    }

    // MARK: Cluster presets

    enum PresetChoice: Equatable {
        case preset(ButtonClusterPreset)
        /// iOS-only: only ★ reaches the phone (★ moves the focus, ★★ selects).
        case singleButton
    }

    static func presetTitle(_ preset: ButtonClusterPreset) -> String {
        switch preset {
        case .fiveWay: return String(localized: "5-way Explore (Fn / ★ / voice)")
        case .modeEnt: return String(localized: "MODE / ENT cluster")
        case .backSet: return String(localized: "BACK / SET diamond (limited)")
        }
    }

    static func title(_ choice: PresetChoice) -> String {
        switch choice {
        case .preset(let preset): return presetTitle(preset)
        case .singleButton: return String(localized: "★ only (one-button dashes)")
        }
    }

    static func summary(_ choice: PresetChoice) -> String {
        switch choice {
        case .preset(.fiveWay):
            return String(localized: "◀/▶ = move the focus · ★ = Select. Singles fire at once; a quick second press is ignored, so a double never does something else. The menu is the ⋮ button on the map.")
        case .preset(.modeEnt):
            return String(localized: "Same as 5-way: ◀/▶ move · ★ (ENT) selects. A quick second press is ignored: a double never does something else.")
        case .preset(.backSet):
            return String(localized: "Snappy singles. Discrete hold / Select ×2 usually don't exist; ▲/▼ only work with Volume buttons on (a hard ▲▲ / ▼▼ flick = Back / menu). Dash touch and the phone cover the rest.")
        case .singleButton:
            return String(localized: "★ moves the focus and ★★ selects. For dashes where only ★ reaches the phone; works best with a long double-tap delay.")
        }
    }

    // MARK: Presence ("Teach my handlebar")

    /// Choices of each source, in Android's dialog order (`▲/▼ works`, `▲/▼ absent`, untested).
    static let teachChoices: [ButtonPresence] = [.present, .absent, .unknown]

    static func teachChoice(_ value: ButtonPresence) -> Text {
        switch value {
        case .present: return Text("Present")
        case .absent: return Text("Absent")
        case .unknown: return Text("Unknown")
        }
    }
}
