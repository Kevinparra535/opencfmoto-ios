// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: a bike's fuel profile (stored per Garage bike under `fuel_profile_v1#<bikeId>`, never
// globally). The learned km/L is NOT stored here: FuelStats derives it from the refuel log on every load or
// change, so deleting an entry updates it and a copied profile starts unlearned.

import Foundation

/// Where the profile's seed figures come from.
public enum FuelSeedSource: String, Sendable, Codable {
    /// A catalog row, tank and km/L as the row has them (within `FuelProfile.sameValueTolerance`).
    case catalog
    /// A catalog row whose tank or km/L the rider changed.
    case edited
    /// Entered by hand (no catalog row).
    case manual
    /// Copied from another bike of the garage (a replaced dash is a new Garage bike).
    case copied
}

public struct FuelProfile: Sendable, Equatable, Codable {
    public static let version = 1
    public static let defaultReservePct = 12
    public static let reservePctRange = 5 ... 30
    public static let tankRange = 3.0 ... 60.0
    public static let kmPerLRange = 5.0 ... 60.0
    /// Absorbs unit round trips only (|Δ| ≤ 0.05 L and ≤ 0.05 km/L still counts as the catalog value).
    public static let sameValueTolerance = 0.05
    /// Pre-filled km/L of a hand-entered bike (the "unknown engine" class default; shown as an estimate).
    public static let manualDefaultKmPerL = 15.5

    public var v: Int
    /// nil = entered by hand.
    public var catalogId: String?
    /// Snapshot of the display name ("CFMOTO 450MT"); "" for a manual profile.
    public var name: String
    public var tankL: Double
    public var seedKmPerL: Double
    public var seedSource: FuelSeedSource
    /// The range counts down to this share of the tank, never to empty.
    public var reservePct: Int
    /// The learned km/L replaces the seed when it exists.
    public var preferLearned: Bool
    public var updatedAtMs: Int64

    public init(catalogId: String?, name: String, tankL: Double, seedKmPerL: Double, seedSource: FuelSeedSource,
                reservePct: Int = FuelProfile.defaultReservePct, preferLearned: Bool = true, updatedAtMs: Int64) {
        v = Self.version
        self.catalogId = catalogId
        self.name = name
        self.tankL = tankL
        self.seedKmPerL = seedKmPerL
        self.seedSource = seedSource
        self.reservePct = reservePct
        self.preferLearned = preferLearned
        self.updatedAtMs = updatedAtMs
    }

    /// A profile straight from a catalog row (`seedSource` .catalog).
    public static func from(_ entry: FuelCatalogEntry, nowMs: Int64) -> FuelProfile {
        FuelProfile(catalogId: entry.id, name: entry.displayName, tankL: entry.tankL, seedKmPerL: entry.seedKmPerL,
                    seedSource: .catalog, updatedAtMs: nowMs)
    }

    /// An empty hand-entered profile: no tank yet (not complete), km/L pre-filled with the class default.
    public static func manual(nowMs: Int64) -> FuelProfile {
        FuelProfile(catalogId: nil, name: "", tankL: 0, seedKmPerL: manualDefaultKmPerL, seedSource: .manual,
                    updatedAtMs: nowMs)
    }

    /// Values clamped to the ranges (reserve into 5…30); a non-finite value becomes the range minimum.
    public func clamped() -> FuelProfile {
        var p = self
        p.tankL = Self.clamp(tankL, Self.tankRange)
        p.seedKmPerL = Self.clamp(seedKmPerL, Self.kmPerLRange)
        p.reservePct = min(max(reservePct, Self.reservePctRange.lowerBound), Self.reservePctRange.upperBound)
        return p
    }

    /// Tank and km/L inside their ranges (the editor enables «Guardar» on it).
    public var isComplete: Bool {
        tankL.isFinite && Self.tankRange.contains(tankL) && seedKmPerL.isFinite && Self.kmPerLRange.contains(seedKmPerL)
    }

    private static func clamp(_ x: Double, _ r: ClosedRange<Double>) -> Double {
        guard x.isFinite else { return r.lowerBound }
        return min(max(x, r.lowerBound), r.upperBound)
    }

    // MARK: Codable (v1 only: a newer or broken document reads as absent)

    enum CodingKeys: String, CodingKey {
        case v, catalogId, name, tankL, seedKmPerL, seedSource, reservePct, preferLearned, updatedAtMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        guard v == Self.version else {
            throw DecodingError.dataCorruptedError(forKey: .v, in: c, debugDescription: "unsupported fuel profile version \(v)")
        }
        catalogId = try c.decodeIfPresent(String.self, forKey: .catalogId)
        name = try c.decode(String.self, forKey: .name)
        tankL = try c.decode(Double.self, forKey: .tankL)
        seedKmPerL = try c.decode(Double.self, forKey: .seedKmPerL)
        seedSource = try c.decode(FuelSeedSource.self, forKey: .seedSource)
        reservePct = try c.decode(Int.self, forKey: .reservePct)
        preferLearned = try c.decodeIfPresent(Bool.self, forKey: .preferLearned) ?? true
        updatedAtMs = try c.decode(Int64.self, forKey: .updatedAtMs)
    }
}
