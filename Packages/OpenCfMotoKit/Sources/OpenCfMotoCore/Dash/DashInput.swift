// SPDX-License-Identifier: AGPL-3.0-or-later
// CONTRACT FILE — inputs that drive the dash UI (docs/spec/input-controls.md).

import Foundation

/// Abstract handlebar / pad keys after gesture mapping (Android keycodes in comments).
public enum HandlebarKey: String, Sendable, Codable, CaseIterable {
    case up        // 19
    case down      // 20
    case left      // 21
    case right     // 22
    case enter     // 23 — click focused control
    case back      // 4  — close card / preview / sheet
    case home      // 3  — toggle menu
    case assistant // 84 — toggle search (no Siri on iOS)
}

public enum DashInput: Sendable, Equatable {
    /// Filtered dash touch (or a phone "Dash view" touch mapped to canvas pixels).
    case touch(DashTouch)
    case key(HandlebarKey)
    /// Rotary knob / knobFwd / knobBack: +1 next, −1 previous focus.
    case knob(Int)
    /// Navigate to saved place slot 1…3 (ButtonAction nav1…nav3).
    case savedPlace(Int)
}

/// Raw handlebar events as observable on iOS (MPRemoteCommandCenter / outputVolume KVO),
/// before tap / double / hold detection (docs/spec/input-controls.md §7-§9).
public enum HandlebarRawEvent: String, Sendable, Codable, CaseIterable {
    /// ★ / Enter: play, pause or togglePlayPause.
    case select
    /// ▶ / ▼: nextTrack (or skipForward).
    case forward
    /// ◀ / ▲: previousTrack (or skipBackward).
    case backward
    /// seekForward / seekBackward begin/end (only if the dash sends FAST_FORWARD / REWIND holds).
    case forwardHoldBegan, forwardHoldEnded, backwardHoldBegan, backwardHoldEnded
    /// Experimental: AVRCP absolute-volume steps observed via outputVolume KVO.
    case volumeUp, volumeDown
}
