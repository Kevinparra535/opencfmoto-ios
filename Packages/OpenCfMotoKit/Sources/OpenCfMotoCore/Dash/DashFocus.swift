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
    /// Focus the now-playing tile when listed (the Music sheet just closed; iOS addition); when it
    /// is not (no room for it, preview / arrival, the song went away meanwhile) → like `.musicGone`.
    case musicTile
    /// A Music control vanished under the focus (iOS addition, music fix F2): the song went away for
    /// a moment (a paused song while another app plays, a stale reading right after a pause, no item
    /// between songs). Never the default item: while navigating that is End, where the rider's next ★,
    /// meant for the tile, ⏯ or the menu's "Music", would end navigation without confirmation. →
    /// the first listed of `musicGoneIds` (harmless neighbours), else like `.default`.
    case musicGone
    /// Focus the menu's "Music" when listed (iOS addition, R3-FOCUS-3): the menu opened by HOME from the Music
    /// sheet. Never its first item: while navigating that is End, and on the iOS default map HOME is ▶▶ —
    /// two quick ▶ are also the rider's way from ⏯ to ✕, so the ★ meant for ✕ would end navigation without
    /// confirmation. When "Music" is not listed (the song went away in the same frame) → like `.musicGone`.
    case menuMusic
}

public struct DashFocusEngine: Sendable, Equatable {
    public static let goId = "preview.go"
    public static let endId = "metrics.end"
    public static let musicPlayPauseId = "music.playPause"
    public static let musicTileId = "music.tile"
    public static let menuMusicId = "menu.music"
    /// Where the focus goes when a Music control vanishes (F2, R2-DASH-1): the map's Recenter FAB (★ only
    /// recenters and the focus stays on the map, so repeated ★ meant for the tile or ⏯ are harmless), in the
    /// menu its "Circuit" (★ without a previewed place only shows a hint). Neither ends anything.
    public static let musicGoneIds = ["fab.recenter", "menu.circuit"]

    public private(set) var focusedId: String?

    public init(focusedId: String? = nil) { self.focusedId = focusedId }

    /// A control of the Apple Music feature: the tile, the sheet's controls, the menu's "Music".
    public static func isMusicControl(_ id: String) -> Bool { id.hasPrefix("music.") || id == menuMusicId }

    private static func musicGoneTarget(in list: [String]) -> String? { musicGoneIds.first { list.contains($0) } }

    /// `ensureFocus(prefer)`: empty list → clear; `.go` / `.end` / `.musicPlayPause` → that control
    /// when listed (otherwise behaves like `.default`); `.musicTile` / `.menuMusic` → the tile / the
    /// menu's "Music" when listed, else like `.musicGone`; `.musicGone` → the first listed of
    /// `musicGoneIds`, else like `.default`; `.default` → keep the focused control when still listed,
    /// else the first item.
    public mutating func ensure(_ list: [String], prefer: DashFocusPreference = .default) {
        guard let first = list.first else { focusedId = nil; return }
        let preferred: String?
        switch prefer {
        case .go: preferred = Self.goId
        case .end: preferred = Self.endId
        case .musicPlayPause: preferred = Self.musicPlayPauseId
        // F2: the sheet closed but the tile is not listed (no room for it, or the song went away in
        // the same frame): a harmless neighbour, never the first item (End while navigating).
        case .musicTile: preferred = list.contains(Self.musicTileId) ? Self.musicTileId : Self.musicGoneTarget(in: list)
        case .menuMusic: preferred = list.contains(Self.menuMusicId) ? Self.menuMusicId : Self.musicGoneTarget(in: list)
        case .musicGone: preferred = Self.musicGoneTarget(in: list)
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
