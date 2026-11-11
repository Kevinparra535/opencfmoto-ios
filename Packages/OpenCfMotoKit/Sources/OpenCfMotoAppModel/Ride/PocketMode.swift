// SPDX-License-Identifier: AGPL-3.0-or-later
// «Modo bolsillo» / Pocket mode (the phone's riding screen, called "Ride Mode" before the UI/UX P0)
// offered by itself (P0, UX-01): when the own dash UI goes live (Connect, auto-connect, the bike back
// after a stop) or guidance starts (Go on the phone or on the dash, a saved place, a GPX track to
// follow), the phone counts 5 s down — «Guarda el teléfono: el tablero sigue en vivo» with a labelled
// «Quedarme aquí» — and then covers itself with the pocket screen, so the iPhone is not locked (a
// locked iPhone freezes the dash picture) and stray touches in a pocket do nothing.
//
// Safe by construction:
// - the offer starts only while the dash shows the own UI (a mirror session would mirror the black
//   screen), the app is in the foreground and nothing else needs the rider: no dialog, sheet,
//   keyboard, opened file waiting for an answer or dash "type on the phone" request;
// - the same rule is checked again when the countdown runs out (it may end without pocket mode);
// - leaving the foreground, the dash link ending, the rider using the phone (any touch, the keyboard, a
//   sheet, another screen) or entering pocket mode by hand ends a running countdown; one at a time;
// - with VoiceOver or Switch Control the countdown is 3 × longer;
// - pocket mode itself changes nothing on the dash and is left with a 1.5-s hold.
// RideModel owns the countdown (`pocketCountdown`); these are its pure rules.

import Foundation
import OpenCfMotoCore

/// A running «Modo bolsillo» offer: pocket mode starts when it runs out, unless the rider stays.
public struct PocketCountdown: Sendable, Equatable {
    /// What offered pocket mode.
    public enum Trigger: String, Sendable, Equatable {
        /// The own dash UI went live on the dash (Connect, auto-connect, the bike back after a stop).
        case connected
        /// Guidance started (Go on the phone or on the dash, a saved place, a GPX track to follow).
        case guidance
    }

    public let trigger: Trigger
    /// `services.clock` time (monotonic seconds) the countdown started.
    public let startedAt: TimeInterval
    /// Seconds from the start to pocket mode.
    public let duration: TimeInterval

    public init(trigger: Trigger, startedAt: TimeInterval, duration: TimeInterval) {
        self.trigger = trigger
        self.startedAt = startedAt
        self.duration = max(0, duration.isFinite ? duration : 0)
    }

    /// When pocket mode starts (`services.clock` time).
    public var deadline: TimeInterval { startedAt + duration }

    /// Seconds left at `now`, 0…duration.
    public func remaining(at now: TimeInterval) -> TimeInterval {
        guard now.isFinite else { return duration }
        return min(duration, max(0, deadline - now))
    }

    /// The number on screen: 5, 4, 3, 2, 1 — whole seconds left, rounded up, never 0 while it runs.
    public func secondsLeft(at now: TimeInterval) -> Int {
        max(1, Int(remaining(at: now).rounded(.up)))
    }

    /// Share of the countdown already elapsed, 0…1 (the ring).
    public func progress(at now: TimeInterval) -> Double {
        guard duration > 0 else { return 1 }
        return 1 - remaining(at: now) / duration
    }
}

/// The rules of the pocket-mode offer (pure; RideModel applies them).
enum PocketModePolicy {
    /// Seconds from the offer to pocket mode (P0: 5 s).
    static let countdownSeconds: TimeInterval = 5
    /// With VoiceOver or Switch Control the countdown is 3 × longer (15 s): the card is announced, and the
    /// rider moves to «Quedarme aquí» before the cover comes (WCAG 2.2.1, timing adjustable; review PH-5).
    static let assistiveCountdownFactor: TimeInterval = 3

    /// Everything the offer depends on, at one moment.
    struct Context: Equatable {
        /// False in the E2E / screenshot launch modes: their screens must stay as launched.
        var isEnabled: Bool
        /// The own dash UI is live on the dash (`RideModel.isProjecting`).
        var isProjecting: Bool
        /// The app is in the foreground (unlocked, not covered by the app switcher or a call).
        var isSceneActive: Bool
        /// Pocket mode is already on screen.
        var isPocketModeActive: Bool
        /// Something on the phone needs the rider right now (a dialog, a sheet, the keyboard, an opened
        /// file waiting for an answer, the dash's "type on the phone" request): why, for the log; nil
        /// when nothing does.
        var busyReason: String?
    }

    /// Why no countdown may start, or a running one may not end in pocket mode, now; nil when it may.
    static func blocker(_ c: Context) -> String? {
        if !c.isEnabled { return "off in this launch mode" }
        if c.isPocketModeActive { return "pocket mode is already on" }
        if !c.isProjecting { return "the dash is not showing the map" }
        if !c.isSceneActive { return "the app is not in the foreground" }
        if let reason = c.busyReason { return reason }
        return nil
    }

    /// Guidance started between two navigation snapshots: into navigation from free ride, or onto
    /// another destination / track. A reroute, an opened preview, an arrival or an ended route is not
    /// a start.
    static func guidanceStarted(from old: NavMode, to new: NavMode) -> Bool {
        new.isNavigating && new != old
    }
}
