// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: the range ESTIMATE. The dash link carries no fuel data, so the range is the bike's fuel
// profile and the km the app measured since the last refuel the rider logged — always shown with «~»,
// rounded down, counted to the reserve (never to empty), and with the standing hint that the bike's own
// fuel gauge has the final word.
//
// Maths (T = tank L, k = effective km/L, r = reserve %/100, odo = the app's km counter):
// 1. no profile → unknown(noProfile); no anchor entry (full, partial with a level, level) → unknown(noRefuel);
// 2. A = the newest anchor: fuel = T (full) or level × T; prev = A.odometerKm;
// 3. each partial after A: no litres → unknown(partialWithoutAmount); else
//    fuel = min(T, max(0, fuel − (E.odometerKm − prev) / k) + E.litres), prev = E.odometerKm;
// 4. kmSinceLast = max(0, odo − prev); kmToEmpty = fuel × k − kmSinceLast;
//    kmToReserve = (fuel − r × T) × k − kmSinceLast; nominalFull = T × k;
// 5. first match: kmToEmpty < −10 % of nominalFull → checkRefuel (for a full anchor exactly "km since the
//    last full > full nominal range × 1.1"; never auto-reset); kmToReserve ≤ 0 → reserve; ≤ 80 km → low;
//    else ok;
// 6. aged: the newest entry is > 30 days old → old(days); an open blind spell ≥ 2 min or a closed noGps mark
//    after A → noGps; a gap mark after A → gap.
// Comparisons are plain IEEE on the raw values (no epsilon).

import Foundation

public enum FuelUnknownReason: String, Sendable, Equatable { case noProfile, noRefuel, partialWithoutAmount }

public enum FuelAgedReason: Sendable, Equatable {
    /// The newest entry is more than 30 days old.
    case old(days: Int)
    /// The app could not measure: approximate / denied location, or no usable fix.
    case noGps
    /// The bike moved while the app did not see it.
    case gap
}

public enum FuelKmPerLSource: Sendable, Equatable { case seed, learned(intervals: Int), learnedCapped }

public enum FuelRangeState: Sendable, Equatable {
    case unknown(FuelUnknownReason)
    /// > lowThresholdKm to the reserve.
    case ok(kmToReserve: Double)
    /// 0 < km ≤ lowThresholdKm.
    case low(kmToReserve: Double)
    /// ≤ 0 km to the reserve (but not past the check cap).
    case reserve
    /// Far past the tank's nominal range: «¿Cargaste gasolina? Toca para actualizar».
    case checkRefuel(kmSinceAnchor: Double)
}

public struct FuelEstimate: Sendable, Equatable {
    public var state: FuelRangeState
    /// Only set when the state is ok / low / reserve / checkRefuel.
    public var aged: FuelAgedReason?
    /// Effective km/L.
    public var kmPerL: Double?
    public var kmPerLSource: FuelKmPerLSource?
    /// tank × (1 − r) × kmPerL.
    public var fullRangeToReserveKm: Double?
    public var kmSinceLastEntry: Double?
    public var kmSinceAnchor: Double?
    /// The newest entry.
    public var lastRefuelAtMs: Int64?
    public var anchorAtMs: Int64?

    public init(state: FuelRangeState, aged: FuelAgedReason? = nil, kmPerL: Double? = nil,
                kmPerLSource: FuelKmPerLSource? = nil, fullRangeToReserveKm: Double? = nil, kmSinceLastEntry: Double? = nil,
                kmSinceAnchor: Double? = nil, lastRefuelAtMs: Int64? = nil, anchorAtMs: Int64? = nil) {
        self.state = state
        self.aged = aged
        self.kmPerL = kmPerL
        self.kmPerLSource = kmPerLSource
        self.fullRangeToReserveKm = fullRangeToReserveKm
        self.kmSinceLastEntry = kmSinceLastEntry
        self.kmSinceAnchor = kmSinceAnchor
        self.lastRefuelAtMs = lastRefuelAtMs
        self.anchorAtMs = anchorAtMs
    }

    /// ok / low / reserve, and not aged: the only estimates that may alert or say «Llegas».
    public var isTrustworthy: Bool {
        guard aged == nil else { return false }
        switch state {
        case .ok, .low, .reserve: return true
        case .unknown, .checkRefuel: return false
        }
    }

    /// km to the reserve, ≥ 0 (0 for reserve / checkRefuel); nil when unknown.
    public var kmToReserve: Double? {
        switch state {
        case .unknown: return nil
        case let .ok(km), let .low(km): return max(0, km)
        case .reserve, .checkRefuel: return 0
        }
    }

    public static func unknown(_ r: FuelUnknownReason) -> FuelEstimate { FuelEstimate(state: .unknown(r)) }
}

public enum RangeEstimator {
    /// «Autonomía baja» at or below this many km to the reserve.
    public static let lowThresholdKm = 80.0
    public static let checkRefuelFactor = 1.1
    public static let agedAfterDays = 30
    public static let msPerDay: Int64 = 86_400_000

    /// The learned km/L when it exists and is preferred (capped at seed × 1.15 while only one interval exists),
    /// else the seed.
    public static func effectiveKmPerL(profile: FuelProfile, stats: FuelStats) -> (Double, FuelKmPerLSource) {
        guard profile.preferLearned, let learned = stats.learnedKmPerL, stats.learnedIntervalCount >= 1 else {
            return (profile.seedKmPerL, .seed)
        }
        if stats.learnedIntervalCount == 1 {
            let cap = profile.seedKmPerL * FuelStats.singleIntervalCapFactor
            return learned > cap ? (cap, .learnedCapped) : (learned, .learned(intervals: 1))
        }
        return (learned, .learned(intervals: stats.learnedIntervalCount))
    }

    public static func estimate(profile: FuelProfile?, log: [RefuelEntry], odometer: FuelOdometerState,
                                stats: FuelStats, nowMs: Int64) -> FuelEstimate {
        guard let profile else { return .unknown(.noProfile) }
        guard let ai = log.lastIndex(where: \.isAnchor) else { return .unknown(.noRefuel) }
        let anchor = log[ai]
        let t = profile.tankL
        let (k, source) = effectiveKmPerL(profile: profile, stats: stats)
        guard t.isFinite, t > 0, k.isFinite, k > 0 else { return .unknown(.noProfile) }
        let r = Double(profile.reservePct) / 100
        var fuel = anchor.kind == .full ? t : (anchor.levelAfter?.fraction ?? 1) * t
        var prev = anchor.odometerKm
        for e in log[(ai + 1)...] {
            guard let litres = e.litres else {
                var u = FuelEstimate.unknown(.partialWithoutAmount)
                u.lastRefuelAtMs = log.last?.atMs
                u.anchorAtMs = anchor.atMs
                return u
            }
            fuel = min(t, max(0, fuel - (e.odometerKm - prev) / k) + litres)
            prev = e.odometerKm
        }
        let odo = odometer.totalKm
        let kmSinceLast = max(0, odo - prev)
        let kmSinceAnchor = max(0, odo - anchor.odometerKm)
        let kmToEmpty = fuel * k - kmSinceLast
        let kmToReserve = (fuel - r * t) * k - kmSinceLast
        let nominalFull = t * k
        let state: FuelRangeState
        if kmToEmpty < -(checkRefuelFactor - 1) * nominalFull {
            state = .checkRefuel(kmSinceAnchor: kmSinceAnchor)
        } else if kmToReserve <= 0 {
            state = .reserve
        } else if kmToReserve <= lowThresholdKm {
            state = .low(kmToReserve: kmToReserve)
        } else {
            state = .ok(kmToReserve: kmToReserve)
        }
        let newest = log[log.count - 1]
        return FuelEstimate(state: state, aged: aged(newest: newest, anchor: anchor, odometer: odometer, nowMs: nowMs),
                            kmPerL: k, kmPerLSource: source, fullRangeToReserveKm: t * (1 - r) * k,
                            kmSinceLastEntry: kmSinceLast, kmSinceAnchor: kmSinceAnchor, lastRefuelAtMs: newest.atMs,
                            anchorAtMs: anchor.atMs)
    }

    private static func aged(newest: RefuelEntry, anchor: RefuelEntry, odometer: FuelOdometerState,
                             nowMs: Int64) -> FuelAgedReason? {
        let age = nowMs - newest.atMs
        if age > Int64(agedAfterDays) * msPerDay { return .old(days: Int(age / msPerDay)) }
        if let open = odometer.openBlindSinceMs, nowMs - open >= FuelOdometer.blindAfterMs { return .noGps }
        if let mark = odometer.lastNoGpsAtMs, mark > anchor.atMs { return .noGps }
        if let mark = odometer.lastGapAtMs, mark > anchor.atMs { return .gap }
        return nil
    }
}
