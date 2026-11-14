// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP test helpers: refuel entries and profiles in one line.
import Foundation
@testable import OpenCfMotoCore

enum FuelT {
    static let dayMs = RangeEstimator.msPerDay
    static let now: Int64 = 1_793_000_000_000

    static func full(_ id: String, odo: Double, litres: Double? = nil, trip: Double? = nil, at: Int64 = now,
                     per: Double? = nil, total: Double? = nil, unseen: Bool = false) -> RefuelEntry {
        RefuelEntry(id: id, atMs: at, kind: .full, litres: litres, pricePerLitre: per, totalPrice: total, tripMeterKm: trip,
                    odometerKm: odo, unseenSincePrev: unseen ? true : nil)
    }

    static func partial(_ id: String, odo: Double, litres: Double? = nil, level: TankLevel? = nil, trip: Double? = nil,
                        at: Int64 = now, per: Double? = nil, total: Double? = nil, unseen: Bool = false) -> RefuelEntry {
        RefuelEntry(id: id, atMs: at, kind: .partial, litres: litres, levelAfter: level, pricePerLitre: per, totalPrice: total,
                    tripMeterKm: trip, odometerKm: odo, unseenSincePrev: unseen ? true : nil)
    }

    static func level(_ id: String, odo: Double, _ l: TankLevel, at: Int64 = now, unseen: Bool = false) -> RefuelEntry {
        RefuelEntry(id: id, atMs: at, kind: .level, levelAfter: l, odometerKm: odo, unseenSincePrev: unseen ? true : nil)
    }

    /// The 450MT reference profile: 17.5 L, 20.5 km/L, 12 %.
    static func mt450(reserve: Int = 12, preferLearned: Bool = true) -> FuelProfile {
        FuelProfile(catalogId: "cfmoto-450mt", name: "CFMOTO 450MT", tankL: 17.5, seedKmPerL: 20.5, seedSource: .catalog,
                    reservePct: reserve, preferLearned: preferLearned, updatedAtMs: 0)
    }

    static func odometer(_ km: Double) -> FuelOdometerState {
        var s = FuelOdometerState()
        s.totalKm = km
        return s
    }
}
