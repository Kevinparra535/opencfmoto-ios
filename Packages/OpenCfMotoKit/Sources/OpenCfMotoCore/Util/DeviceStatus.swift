// SPDX-License-Identifier: AGPL-3.0-or-later
// Locked iPhone, Phase 0 (P0-12): the battery state the background diagnostics log (`[lock]` lines,
// `[bg-budget]` lines) and the background budget reads. The iOS app fills it from
// `UIDevice.batteryLevel` / `batteryState` (App/Sources/Services/BatteryMonitor.swift) and exposes it
// through `SystemControlling.batteryStatus` and the projection engine's `batteryProvider`.

import Foundation

public struct BatteryStatus: Sendable, Equatable, Codable {
    /// `UIDevice.BatteryState` without UIKit.
    public enum State: String, Sendable, Equatable, Codable, CaseIterable {
        case unknown
        case unplugged
        case charging
        case full
    }

    /// Charge level 0…1; nil when unknown (UIKit reports −1 then). Values outside 0…1 are clamped.
    public var level: Double?
    public var state: State

    public init(level: Double?, state: State) {
        if let l = level, l.isFinite, l >= 0 {
            self.level = min(1, l)
        } else {
            self.level = nil
        }
        self.state = state
    }

    /// The level in whole percent (rounded), nil when unknown.
    public var percent: Int? { level.map { Int(($0 * 100).rounded()) } }

    /// On external power (`charging` or `full`): the budget applies no battery cap then.
    public var isOnExternalPower: Bool { state == .charging || state == .full }

    /// The battery part of the `[lock]` and `[bg-budget]` lines, exactly `64% unplugged`,
    /// `100% full`, `?% unknown` (`?` when the level is unknown).
    public var logText: String {
        "\(percent.map { String($0) } ?? "?")% \(state.rawValue)"
    }
}
