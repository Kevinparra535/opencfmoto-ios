// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: «¿Llego?» for a route preview. remaining = the estimate's km to the reserve (raw, not rounded),
// margin = remaining − route km: ≥ 25 km and a trustworthy estimate → reaches; 0…25 → tight («Justo: carga
// antes de salir», aged or not); < 0 → needs ceil((route − remaining) / full range to the reserve) refuels.
// An aged estimate never says «Llegas»; a straight-line fallback route gets no verdict (the chord
// under-states the road distance).

import Foundation

public enum FuelVerdictUnknownReason: String, Sendable, Equatable {
    case noProfile, noRefuel, partialWithoutAmount, aged, checkRefuel
}

public enum FuelVerdict: Sendable, Equatable {
    /// margin ≥ 25 km and a trustworthy estimate.
    case reaches(marginKm: Double)
    /// 0 ≤ margin < 25 km.
    case tight(marginKm: Double)
    /// margin < 0; stops ≥ 1.
    case needsRefuel(stops: Int)
    case unknown(FuelVerdictUnknownReason)
}

public enum FuelVerdictRule {
    public static let marginKm = 25.0

    /// nil when the distance is not finite or ≤ 0, or the route is a straight-line fallback.
    public static func verdict(estimate: FuelEstimate, routeDistanceM: Double, isStraightLine: Bool = false) -> FuelVerdict? {
        guard routeDistanceM.isFinite, routeDistanceM > 0, !isStraightLine else { return nil }
        switch estimate.state {
        case let .unknown(reason):
            switch reason {
            case .noProfile: return .unknown(.noProfile)
            case .noRefuel: return .unknown(.noRefuel)
            case .partialWithoutAmount: return .unknown(.partialWithoutAmount)
            }
        case .checkRefuel:
            return .unknown(.checkRefuel)
        case .ok, .low, .reserve:
            break
        }
        let remaining = estimate.kmToReserve ?? 0
        let d = routeDistanceM / 1000
        let margin = remaining - d
        if margin >= marginKm { return estimate.aged != nil ? .unknown(.aged) : .reaches(marginKm: margin) }
        if margin >= 0 { return .tight(marginKm: margin) }
        guard let full = estimate.fullRangeToReserveKm, full.isFinite, full > 0 else { return .needsRefuel(stops: 1) }
        let stops = ((d - remaining) / full).rounded(.up)
        return .needsRefuel(stops: max(1, stops.isFinite ? Int(min(stops, 1_000)) : 1))
    }

    /// The route form FuelModel uses: straight line = `route.isDirectFallback` (label "Direct" OR any step
    /// flagged "offline": a beeline with a forced label), never `route.isStraightLine`.
    public static func verdict(estimate: FuelEstimate, route: Route) -> FuelVerdict? {
        verdict(estimate: estimate, routeDistanceM: route.distanceM, isStraightLine: route.isDirectFallback)
    }
}
