// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: the refuel log of one Garage bike (`fuel_log_v1#<bikeId>`). Every entry carries the app's own
// km counter (FuelOdometer) at the moment of the real refuel; insertion order is chronological (no
// back-dating). Numbers are metric and currency-free.

import Foundation

public enum RefuelKind: String, Sendable, Codable {
    case full, partial
    /// «Corregir nivel»: the rider reads the gauge (reserve ¼ ½ ¾) WITHOUT refuelling. Not a refuel: no litres, no
    /// price, no trip meter; an anchor for the estimate; ignored by FuelStats.
    case level
}

public enum TankLevel: String, Sendable, Codable, CaseIterable {
    /// The bike's reserve light: the tank stands at the profile's reserve (RangeEstimator: `reserve` at 0 km).
    case reserve
    case quarter, half, threeQuarters

    /// The share of the tank: the profile's reserve % for `.reserve`, else ¼ ½ ¾.
    public func fraction(reservePct: Int) -> Double {
        switch self {
        case .reserve: return Double(reservePct) / 100
        case .quarter: return 0.25
        case .half: return 0.5
        case .threeQuarters: return 0.75
        }
    }
}

public struct RefuelEntry: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    /// Wall clock when logged (epoch ms).
    public var atMs: Int64
    public var kind: RefuelKind
    /// Litres put in (> 0); always nil for `.level`.
    public var litres: Double?
    /// partial (optional) / level (required): how full the tank is now.
    public var levelAfter: TankLevel?
    /// Currency-free, ≥ 0.
    public var pricePerLitre: Double?
    /// Currency-free, ≥ 0 (wins over the per-litre price for the cost).
    public var totalPrice: Double?
    /// The bike's trip meter for THIS tank, read before resetting it (km since the previous refuel).
    public var tripMeterKm: Double?
    /// «Cargaste hace rato»: km ridden since the real refuel (audit; already subtracted from `odometerKm`).
    public var lateKm: Double?
    /// FuelOdometer total at the real refuel (counter − lateKm), ≥ the previous entry's.
    public var odometerKm: Double
    /// Stamped at log time: the odometer recorded a gap or a noGps spell after the previous entry (or one is
    /// still open). nil = false. FuelStats reads THIS, not the odometer's capped lists.
    public var unseenSincePrev: Bool?

    public init(id: String, atMs: Int64, kind: RefuelKind, litres: Double? = nil, levelAfter: TankLevel? = nil,
                pricePerLitre: Double? = nil, totalPrice: Double? = nil, tripMeterKm: Double? = nil,
                lateKm: Double? = nil, odometerKm: Double, unseenSincePrev: Bool? = nil) {
        self.id = id
        self.atMs = atMs
        self.kind = kind
        self.litres = litres
        self.levelAfter = levelAfter
        self.pricePerLitre = pricePerLitre
        self.totalPrice = totalPrice
        self.tripMeterKm = tripMeterKm
        self.lateKm = lateKm
        self.odometerKm = odometerKm
        self.unseenSincePrev = unseenSincePrev
    }

    /// The money spent, when computable: totalPrice ?? (litres × pricePerLitre).
    public var cost: Double? {
        if let totalPrice { return totalPrice }
        if let litres, let pricePerLitre { return litres * pricePerLitre }
        return nil
    }

    /// True when this entry fixes an absolute fuel level (full, partial with a level, level).
    public var isAnchor: Bool {
        switch kind {
        case .full, .level: return true
        case .partial: return levelAfter != nil
        }
    }

    var isUnseen: Bool { unseenSincePrev == true }
}

/// What the phone sheet hands over (metric; the UI converts with FuelFormat).
public struct RefuelInput: Sendable, Equatable {
    public var kind: RefuelKind
    public var litres: Double?
    public var levelAfter: TankLevel?
    public var pricePerLitre: Double?
    public var totalPrice: Double?
    public var tripMeterKm: Double?
    public var lateKm: Double?

    public init(kind: RefuelKind = .full, litres: Double? = nil, levelAfter: TankLevel? = nil, pricePerLitre: Double? = nil,
                totalPrice: Double? = nil, tripMeterKm: Double? = nil, lateKm: Double? = nil) {
        self.kind = kind
        self.litres = litres
        self.levelAfter = levelAfter
        self.pricePerLitre = pricePerLitre
        self.totalPrice = totalPrice
        self.tripMeterKm = tripMeterKm
        self.lateKm = lateKm
    }

    public enum Field: String, Sendable { case litres, price, tripMeter, lateKm, level }

    public static let litresRange = 0.0 ... 100.0       // exclusive at 0
    public static let priceRange = 0.0 ... 10_000_000.0
    public static let tripMeterRange = 0.0 ... 5000.0   // exclusive at 0
    public static let lateKmRange = 0.0 ... 2000.0

    /// The first out-of-range field (litres 0 < x ≤ 100; prices 0 ≤ x ≤ 10 000 000; trip meter 0 < x ≤ 5000;
    /// late km 0 ≤ x ≤ 2000; non-finite → invalid), nil when valid. A `.level` input needs `levelAfter`
    /// (else `.level`) and takes no litres, price or trip meter (any of them → that field).
    public func invalidField() -> Field? {
        if kind == .level {
            if litres != nil { return .litres }
            if pricePerLitre != nil || totalPrice != nil { return .price }
            if tripMeterKm != nil { return .tripMeter }
        }
        if let l = litres, !(l.isFinite && l > 0 && l <= Self.litresRange.upperBound) { return .litres }
        for p in [pricePerLitre, totalPrice].compactMap({ $0 }) where !(p.isFinite && Self.priceRange.contains(p)) {
            return .price
        }
        if let t = tripMeterKm, !(t.isFinite && t > 0 && t <= Self.tripMeterRange.upperBound) { return .tripMeter }
        if let k = lateKm, !(k.isFinite && Self.lateKmRange.contains(k)) { return .lateKm }
        if kind == .level, levelAfter == nil { return .level }
        return nil
    }
}

public struct RefuelLog: Sendable, Equatable, Codable {
    public static let version = 1
    /// The oldest entries are dropped beyond it.
    public static let maxEntries = 1000

    public var v: Int
    /// Insertion order = chronological (no back-dating).
    public var entries: [RefuelEntry]

    public init(entries: [RefuelEntry] = []) {
        v = Self.version
        self.entries = entries
    }

    /// Appends an entry built from `input` at `nowMs` and the current odometer:
    /// `odometerKm = max(lastEntry.odometerKm, odometerKm − (lateKm ?? 0))` (≥ 0; FuelModel first raises the
    /// counter when `lateKm` exceeds what it counted since the last entry, so the rider's km are kept); `levelAfter` is dropped for a
    /// full entry, litres / prices / trip meter for a level entry; `unseenSincePrev = unseen ? true : nil`.
    /// Returns the entry. The input must be valid (`invalidField() == nil`).
    @discardableResult
    public mutating func add(_ input: RefuelInput, nowMs: Int64, odometerKm: Double, unseen: Bool,
                             id: String = UUID().uuidString) -> RefuelEntry {
        let floor = entries.last?.odometerKm ?? 0
        let real = odometerKm - (input.lateKm ?? 0)
        var e = RefuelEntry(id: id, atMs: nowMs, kind: input.kind, litres: input.litres, levelAfter: input.levelAfter,
                            pricePerLitre: input.pricePerLitre, totalPrice: input.totalPrice, tripMeterKm: input.tripMeterKm,
                            lateKm: input.lateKm, odometerKm: max(floor, real.isFinite ? real : floor),
                            unseenSincePrev: unseen ? true : nil)
        switch input.kind {
        case .full:
            e.levelAfter = nil
        case .level:
            e.litres = nil
            e.pricePerLitre = nil
            e.totalPrice = nil
            e.tripMeterKm = nil
        case .partial:
            break
        }
        entries.append(e)
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
        return e
    }

    /// Removes the newest entry; returns it.
    @discardableResult
    public mutating func undoLast() -> RefuelEntry? {
        entries.popLast()
    }

    /// Removes an entry. Its `unseenSincePrev` is OR-ed into the entry after it (whose "since the previous
    /// entry" now spans both), so a deleted entry never lets a gap interval back into learning.
    @discardableResult
    public mutating func delete(id: String) -> RefuelEntry? {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = entries.remove(at: i)
        if removed.isUnseen, i < entries.count { entries[i].unseenSincePrev = true }
        return removed
    }

    /// Index of the newest anchor entry (full, partial with a level, level).
    public var lastAnchorIndex: Int? { entries.lastIndex(where: \.isAnchor) }

    // MARK: Codable (v1 only)

    enum CodingKeys: String, CodingKey { case v, entries }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        guard v == Self.version else {
            throw DecodingError.dataCorruptedError(forKey: .v, in: c, debugDescription: "unsupported refuel log version \(v)")
        }
        entries = try c.decode([RefuelEntry].self, forKey: .entries)
    }
}
