// SPDX-License-Identifier: AGPL-3.0-or-later
// «No link-lost alarm while stopped» (UI/UX P0; proposal principle: "a link drop while stopped — an
// ignition cycle — is not an alarm"). Switching the bike off at a fuel stop or a café takes the dash
// and its Wi-Fi away; the session waits and reconnects by itself (Wi-Fi supervision, the 180-s park).
// While the bike is stopped (≤ 5 km/h, or no fresh GPS speed) a link that drops in a session that
// already reached the dash is therefore shown in calm words — «Moto apagada · se reconecta sola» —
// with a neutral colour and no dialog, never as an error or an alarm. While moving, today's
// "reconnecting" presentation stays (the pocket-screen banner, haptic and tone come with the Modo
// bolsillo redesign, P1).
//
// Covered: the status label and colour (Home card, pocket screen) through
// `ConnectionModel.linkLossNotice`, and the "Lost the bike link" / "Dash not found" dialogs of an
// auto-recovery-off session (`allowsLinkLossDialog`). A session that never reached the dash is
// connecting, not "lost": nothing here changes it.

import Foundation
import OpenCfMotoCore

/// How the phone presents a dash link that dropped in a session that already reached the dash.
public enum LinkLossNotice: String, Sendable, Equatable {
    /// Stopped, and the bike Wi-Fi is gone (the ignition is off at a stop): «Moto apagada · se
    /// reconecta sola». Calm: neutral colour, no dialog.
    case bikeOffWhileStopped
    /// Stopped, the bike Wi-Fi is up but the dash does not answer yet (it is starting up after the
    /// ignition, or its pairing screen is closed): «Esperando el tablero…». Calm: neutral colour, no
    /// dialog; the status detail keeps its hint.
    case dashAwayWhileStopped
    /// Moving: the link dropped mid-ride. Today's "reconnecting" / error presentation stays.
    case droppedWhileMoving

    /// True for the calm, no-alarm notices.
    public var isQuiet: Bool { self != .droppedWhileMoving }
}

/// The pure rules behind `LinkLossNotice`.
enum LinkLossAlarmPolicy {
    /// At or below this speed the bike counts as stopped.
    static let stoppedAtOrBelowKmh = 5.0
    /// A fix older (or further in the future) than this proves nothing about moving.
    static let maxFixAge: TimeInterval = 10

    /// Stopped: no fix, a stale fix, an unknown / invalid speed, or ≤ 5 km/h. Not knowing counts as
    /// stopped: the rule only ever removes alarms, it never adds one.
    static func isStopped(speedMps: Double?, fixAgeSeconds: Double?) -> Bool {
        guard let speed = speedMps, speed.isFinite, speed >= 0,
              let age = fixAgeSeconds, age.isFinite, abs(age) <= maxFixAge else { return true }
        return speed * 3.6 <= stoppedAtOrBelowKmh
    }

    /// `isStopped` from the last fix (`LocationFix.timeMs` is wall-clock milliseconds) at `now`.
    static func isStopped(lastFix: LocationFix?, now: Date) -> Bool {
        guard let fix = lastFix else { return true }
        let age = now.timeIntervalSince1970 - Double(fix.timeMs) / 1000
        return isStopped(speedMps: fix.speedMps, fixAgeSeconds: age)
    }

    /// The phases in which the dash link of an established session is down: reconnecting (link or
    /// bike Wi-Fi), parked waiting for the bike, or an error the link re-arms from.
    static func isLinkDown(_ phase: ConnectionPhase) -> Bool {
        phase == .reconnecting || phase == .waitingForBike || phase == .error
    }

    /// The notice for a session that already reached the dash (`hasReachedDash`); nil while the link
    /// is fine, or for a session that is still connecting.
    static func notice(phase: ConnectionPhase, hasReachedDash: Bool, bikeWifiLost: Bool,
                       stopped: Bool) -> LinkLossNotice? {
        guard hasReachedDash, isLinkDown(phase) else { return nil }
        guard stopped else { return .droppedWhileMoving }
        return bikeWifiLost || phase == .waitingForBike ? .bikeOffWhileStopped : .dashAwayWhileStopped
    }

    /// A "Lost the bike link" / "Dash not found" dialog may be raised: never for a session that already
    /// reached the dash while the bike is stopped (an ignition cycle at a stop).
    static func allowsLinkLossDialog(hasReachedDash: Bool, stopped: Bool) -> Bool {
        !(hasReachedDash && stopped)
    }
}
