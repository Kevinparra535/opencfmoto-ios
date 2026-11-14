// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: the dash's low-range alert, once per crossing. A latch remembers the highest level already
// announced for the current tank (nil < low < reserve); a refuel or an edit that lifts the estimate re-arms
// it (`rearmed` = min(latch, level), ok → nil). Untrustworthy estimates (unknown, aged, checkRefuel) never
// fire and never re-arm.

import Foundation

public enum FuelAlertLevel: String, Sendable, Codable, Comparable {
    case low, reserve

    private var rank: Int { self == .low ? 0 : 1 }
    public static func < (a: FuelAlertLevel, b: FuelAlertLevel) -> Bool { a.rank < b.rank }
}

public enum FuelAlertPolicy {
    /// How long the dash toast stays (the default toasts last 2.5 s).
    public static let toastSeconds: TimeInterval = 6

    /// The level an estimate stands at (nil for ok), only for trustworthy estimates (else nil).
    public static func level(of e: FuelEstimate) -> FuelAlertLevel? {
        guard e.isTrustworthy else { return nil }
        switch e.state {
        case .low: return .low
        case .reserve: return .reserve
        default: return nil
        }
    }

    /// The level to announce now: trustworthy, at low or reserve, and above `alerted` (nil < low < reserve).
    public static func alertToFire(estimate: FuelEstimate, alerted: FuelAlertLevel?) -> FuelAlertLevel? {
        guard let l = level(of: estimate) else { return nil }
        if let alerted, l <= alerted { return nil }
        return l
    }

    /// Re-arm: for a trustworthy estimate `min(alerted, level)` (ok → nil); untrustworthy → unchanged.
    public static func rearmed(_ alerted: FuelAlertLevel?, estimate: FuelEstimate) -> FuelAlertLevel? {
        guard estimate.isTrustworthy, let alerted else { return alerted }
        guard let l = level(of: estimate) else { return nil }
        return min(alerted, l)
    }
}
