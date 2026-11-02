// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) GpxDashUi.kt:1921-2136 (handlebar focus navigation) —
// docs/spec/navigation-dash.md §11.9, input-controls.md §6.6.
//
// Focus is tracked by stable widget id (Android tracks an index, which can paint the wrong
// control when the list changes; ids fix that). Lists are computed per UI state by the scene
// builder, top-most interactive layer first.

import Foundation

/// `ensureFocus(prefer)` hints.
public enum DashFocusPreference: String, Sendable, Equatable {
    /// Focus the preview "Go" button when listed.
    case go
    /// Focus the metrics "End" button when listed.
    case end
    /// Keep the current focus when still listed, else the first item.
    case `default`
    /// Focus the Music sheet's ⏯ when listed (the sheet just opened; iOS addition).
    case musicPlayPause
    /// Focus the now-playing tile when listed (the Music sheet just closed; iOS addition).
    case musicTile
}

public struct DashFocusEngine: Sendable, Equatable {
    public static let goId = "preview.go"
    public static let endId = "metrics.end"
    public static let musicPlayPauseId = "music.playPause"
    public static let musicTileId = "music.tile"

    public private(set) var focusedId: String?

    public init(focusedId: String? = nil) { self.focusedId = focusedId }

    /// `ensureFocus(prefer)`: empty list → clear; `.go` / `.end` / `.musicPlayPause` / `.musicTile`
    /// → that control when listed (otherwise behaves like `.default`); `.default` → keep the
    /// focused control when still listed, else the first item.
    public mutating func ensure(_ list: [String], prefer: DashFocusPreference = .default) {
        guard let first = list.first else { focusedId = nil; return }
        let preferred: String?
        switch prefer {
        case .go: preferred = Self.goId
        case .end: preferred = Self.endId
        case .musicPlayPause: preferred = Self.musicPlayPauseId
        case .musicTile: preferred = Self.musicTileId
        case .default: preferred = nil
        }
        if let preferred, list.contains(preferred) {
            focusedId = preferred
            return
        }
        if let f = focusedId, list.contains(f) { return }
        focusedId = first
    }

    /// `moveFocus(delta)`: next/previous with wrap-around (Kotlin `mod`, never negative);
    /// nothing focused (or focus not listed) → the first item.
    public mutating func move(_ list: [String], by delta: Int) {
        guard !list.isEmpty else { focusedId = nil; return }
        guard let f = focusedId, let i = list.firstIndex(of: f) else { focusedId = list[0]; return }
        let n = list.count
        focusedId = list[((i + delta) % n + n) % n]
    }

    /// Focus a specific control (e.g. the one the rider just touched) if it is listed.
    public mutating func focus(_ id: String, in list: [String]) {
        if list.contains(id) { focusedId = id }
    }

    public mutating func clear() { focusedId = nil }

    /// `defaultPrefer()`: "go" with a preview, "end" while navigating, else "default".
    public static func defaultPreference(inPreview: Bool, navigating: Bool) -> DashFocusPreference {
        if inPreview { return .go }
        if navigating { return .end }
        return .default
    }
}
