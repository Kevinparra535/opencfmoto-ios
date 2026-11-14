// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: the rider's measured consumption, from full-to-full fills.
//
// A candidate interval runs from a FULL entry F_i to the next FULL entry F_j (the refuel entries between
// are partials; `.level` entries are observations, skipped for litres / km / cost but not for their
// `unseenSincePrev` stamp). It is complete when:
// 1. F_j has litres and every partial between has litres (a partial with only a level breaks it);
// 2. distance: the app's km (F_j.odometerKm − F_i.odometerKm), or the bike's trip meter when F_j and every
//    partial between carry one and Σ trip passes 0.9 × app ≤ trip ≤ max(1.5 × app, app + 50) and
//    trip ≤ tank × seed × 1.3 (a meter not reset, a typo, is ignored); an app-distance interval with an
//    `unseenSincePrev` stamp inside is invalid (km the app did not see);
// 3. litres = Σ litres over (F_i, F_j];
// 4. km ≥ 30, litres ≥ 1, km/L 8…60;
// 5. km/L within 0.6…1.4 × the seed, unless another interval passing 1–4 agrees within ±15 % (two
//    independent fills beat a seed that is simply wrong).
// Learned km/L = Σ km / Σ litres over the newest 5 valid intervals.

import Foundation

public enum FuelDistanceSource: String, Sendable, Equatable { case app, tripMeter }

public struct FuelInterval: Sendable, Equatable {
    public var fromEntryId: String
    public var toEntryId: String
    public var startMs: Int64
    public var endMs: Int64
    public var km: Double
    public var litres: Double
    public var kmPerL: Double
    /// nil unless every fill in the interval has a cost.
    public var cost: Double?
    public var distanceSource: FuelDistanceSource
}

public struct FuelStats: Sendable, Equatable {
    public static let lastN = 5
    public static let minIntervalKm = 30.0
    public static let minIntervalLitres = 1.0
    public static let plausibleKmPerL = 8.0 ... 60.0
    /// An interval's km/L must lie within these factors of the profile's seed (else an outlier).
    public static let seedBand = 0.6 ... 1.4
    /// Two intervals "agree" within this relative difference (corroborated outliers).
    public static let agreementTolerance = 0.15
    /// Trip meter accepted only within [0.9 × appKm, max(1.5 × appKm, appKm + 50)] and ≤ T × seed × 1.3.
    public static let tripMeterLowFactor = 0.9, tripMeterHighFactor = 1.5, tripMeterHighSlackKm = 50.0
    public static let tripMeterTankFactor = 1.3
    /// With a single learned interval, the effective km/L is at most seed × 1.15 (RangeEstimator).
    public static let singleIntervalCapFactor = 1.15

    /// Valid intervals, newest first.
    public var intervals: [FuelInterval]
    /// Σ km / Σ litres over the newest `lastN` intervals.
    public var learnedKmPerL: Double?
    /// How many intervals went into it (≤ lastN).
    public var learnedIntervalCount: Int
    /// The newest interval's km/L.
    public var lastKmPerL: Double?
    /// Σ cost / Σ km over the newest `lastN` intervals that have a cost.
    public var costPerKm: Double?

    public init(intervals: [FuelInterval], learnedKmPerL: Double?, learnedIntervalCount: Int, lastKmPerL: Double?,
                costPerKm: Double?) {
        self.intervals = intervals
        self.learnedKmPerL = learnedKmPerL
        self.learnedIntervalCount = learnedIntervalCount
        self.lastKmPerL = lastKmPerL
        self.costPerKm = costPerKm
    }

    public static let empty = FuelStats(intervals: [], learnedKmPerL: nil, learnedIntervalCount: 0, lastKmPerL: nil,
                                        costPerKm: nil)

    public static func compute(log: [RefuelEntry], seedKmPerL: Double, tankL: Double) -> FuelStats {
        let fulls = log.indices.filter { log[$0].kind == .full }
        guard fulls.count >= 2 else { return .empty }
        var candidates: [FuelInterval] = []
        for k in 1 ..< fulls.count {
            if let iv = interval(log, from: fulls[k - 1], to: fulls[k], seed: seedKmPerL, tank: tankL) { candidates.append(iv) }
        }
        // 5. seed band, softened by agreement.
        let valid = candidates.enumerated().filter { idx, iv in
            if inSeedBand(iv.kmPerL, seed: seedKmPerL) { return true }
            return candidates.enumerated().contains { j, other in j != idx && agree(iv.kmPerL, other.kmPerL) }
        }.map(\.element)
        let newestFirst = Array(valid.reversed())
        let used = Array(newestFirst.prefix(lastN))
        let sumKm = used.reduce(0) { $0 + $1.km }
        let sumL = used.reduce(0) { $0 + $1.litres }
        let costed = Array(newestFirst.filter { $0.cost != nil }.prefix(lastN))
        let costKm = costed.reduce(0) { $0 + $1.km }
        let cost = costed.reduce(0) { $0 + ($1.cost ?? 0) }
        return FuelStats(intervals: newestFirst,
                         learnedKmPerL: used.isEmpty || sumL <= 0 ? nil : sumKm / sumL,
                         learnedIntervalCount: used.count,
                         lastKmPerL: newestFirst.first?.kmPerL,
                         costPerKm: costed.isEmpty || costKm <= 0 ? nil : cost / costKm)
    }

    /// Rules 1–4 for the interval (log[i], log[j]], both full.
    private static func interval(_ log: [RefuelEntry], from i: Int, to j: Int, seed: Double, tank: Double) -> FuelInterval? {
        let start = log[i], end = log[j]
        let span = log[(i + 1) ... j]
        let fills = span.filter { $0.kind != .level } // the partials between + F_j
        // 1. litres everywhere
        guard fills.allSatisfy({ $0.litres != nil }) else { return nil }
        // 2. distance
        let appKm = end.odometerKm - start.odometerKm
        let unseen = span.contains { $0.isUnseen }
        var km = appKm
        var source = FuelDistanceSource.app
        let trips = fills.compactMap(\.tripMeterKm)
        if trips.count == fills.count {
            let trip = trips.reduce(0, +)
            let low = tripMeterLowFactor * appKm
            let high = max(tripMeterHighFactor * appKm, appKm + tripMeterHighSlackKm)
            if trip >= low, trip <= high, trip <= tank * seed * tripMeterTankFactor {
                km = trip
                source = .tripMeter
            }
        }
        if source == .app, unseen { return nil }
        // 3. litres
        let litres = fills.reduce(0) { $0 + ($1.litres ?? 0) }
        // 4. plausibility
        guard km.isFinite, litres.isFinite, km >= minIntervalKm, litres >= minIntervalLitres else { return nil }
        let kmPerL = km / litres
        guard plausibleKmPerL.contains(kmPerL) else { return nil }
        let costs = fills.map(\.cost)
        let cost: Double? = costs.allSatisfy({ $0 != nil }) ? costs.reduce(0) { $0 + ($1 ?? 0) } : nil
        return FuelInterval(fromEntryId: start.id, toEntryId: end.id, startMs: start.atMs, endMs: end.atMs, km: km,
                            litres: litres, kmPerL: kmPerL, cost: cost, distanceSource: source)
    }

    static func inSeedBand(_ kmPerL: Double, seed: Double) -> Bool {
        guard seed.isFinite, seed > 0 else { return true }
        return kmPerL >= seedBand.lowerBound * seed && kmPerL <= seedBand.upperBound * seed
    }

    /// Two km/L figures within ±15 % of each other (relative to the smaller one).
    static func agree(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) <= agreementTolerance * min(a, b)
    }
}
