// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) GpxDashUi.handleMapKey + MapInputBridge (ButtonMap actions →
// map focus engine) — docs/spec/navigation-dash.md §11.9, input-controls.md §6.6, §7.4.

import Foundation

public extension DashInput {
    /// The dash input for a handlebar `ButtonAction` (after the gesture engine and ButtonMap):
    /// knobFwd/knobBack → focus ±1, select → ENTER, back/home/assistant → keys, D-pad → keys,
    /// nav1…nav3 → saved-place slots 1…3. `none` → nil.
    init?(buttonAction: ButtonAction) {
        switch buttonAction {
        case .none: return nil
        case .knobFwd: self = .knob(1)
        case .knobBack: self = .knob(-1)
        case .select: self = .key(.enter)
        case .back: self = .key(.back)
        case .home: self = .key(.home)
        case .assistant: self = .key(.assistant)
        case .up: self = .key(.up)
        case .down: self = .key(.down)
        case .left: self = .key(.left)
        case .right: self = .key(.right)
        case .nav1: self = .savedPlace(1)
        case .nav2: self = .savedPlace(2)
        case .nav3: self = .savedPlace(3)
        }
    }
}
