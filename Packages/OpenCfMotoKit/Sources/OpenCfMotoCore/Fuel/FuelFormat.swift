// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: units and number formatting. Storage is always metric (km, litres, km/L, price per litre);
// distances and economy follow `MapUnits` (km / mi, km/L / US mpg), volumes and prices per volume follow the
// pump's `FuelVolumeUnit` (L / US gal), which is independent of MapUnits: Colombia, Ecuador and Peru sell
// fuel by the US gallon with distances in km. A range is rounded DOWN to 10 km (5 mi) and shown with «~».

import Foundation

/// The pump's volume unit.
public enum FuelVolumeUnit: String, Sendable, Codable, CaseIterable {
    case litre = "L"
    case usGallon = "gal"

    /// Default before the rider chooses: US gallons for imperial units or the regions that sell by the
    /// gallon with km (CO, EC, PE), else litres.
    public static func defaultFor(units: MapUnits, regionCode: String?) -> FuelVolumeUnit {
        if units == .imperial { return .usGallon }
        if let r = regionCode?.uppercased(), ["CO", "EC", "PE"].contains(r) { return .usGallon }
        return .litre
    }
}

public enum FuelFormat {
    public static let kmPerMile = 1.609344
    /// US gallon.
    public static let litresPerGallon = 3.785411784
    /// 1 km/L in US mpg (= litresPerGallon / kmPerMile).
    public static let mpgPerKmPerL = 2.352145833
    public static let rangeStepKm = 10, rangeStepMi = 5

    public struct RangeDisplay: Sendable, Equatable {
        /// Rounded DOWN to the step, in display units (0 when under a step).
        public var value: Int
        /// 10 (km) or 5 (mi).
        public var step: Int
        /// "km" | "mi".
        public var unit: String
        public var isUnderStep: Bool
        /// "250 km" | "10 km" (the step, when under it).
        public var number: String
        /// "~250 km" | "<10 km".
        public var text: String
    }

    /// A range for display: negative / NaN / ∞ → under a step.
    public static func range(_ km: Double, units: MapUnits) -> RangeDisplay {
        let step = units == .metric ? rangeStepKm : rangeStepMi
        let unit = distanceUnit(units)
        let display = displayDistance(km: km, units: units)
        let x = display.isFinite ? max(0, min(display, 1_000_000)) : 0
        let value = Int((x / Double(step) + 1e-9).rounded(.down)) * step
        let under = value == 0
        return RangeDisplay(value: value, step: step, unit: unit, isUnderStep: under,
                            number: "\(under ? step : value) \(unit)",
                            text: under ? "<\(step) \(unit)" : "~\(value) \(unit)")
    }

    public static func distanceUnit(_ u: MapUnits) -> String { u == .metric ? "km" : "mi" }
    public static func volumeUnit(_ u: FuelVolumeUnit) -> String { u.rawValue }
    public static func economyUnit(_ u: MapUnits) -> String { u == .metric ? "km/L" : "mpg" }

    /// "120 km" (nearest whole).
    public static func distance(_ km: Double, units: MapUnits) -> String {
        "\(NavNumberFormat.fixed(finite(displayDistance(km: km, units: units)), decimals: 0)) \(distanceUnit(units))"
    }

    /// "17.5 L" | "4.6 gal" (1 decimal).
    public static func volume(_ litres: Double, unit: FuelVolumeUnit, decimalSeparator: Character = ".") -> String {
        let v = finite(displayVolume(litres: litres, unit: unit))
        return "\(NavNumberFormat.fixed(v, decimals: 1, decimalSeparator: decimalSeparator)) \(volumeUnit(unit))"
    }

    /// "20.5 km/L" | "48.2 mpg" (1 decimal).
    public static func economy(_ kmPerL: Double, units: MapUnits, decimalSeparator: Character = ".") -> String {
        let v = finite(displayEconomy(kmPerL: kmPerL, units: units))
        return "\(NavNumberFormat.fixed(v, decimals: 1, decimalSeparator: decimalSeparator)) \(economyUnit(units))"
    }

    /// The cost per km or per mi, no currency: < 1 → 3 decimals, < 10 → 2, < 100 → 1, else 0.
    public static func costPerDistance(_ costPerKm: Double, units: MapUnits, decimalSeparator: Character = ".") -> String {
        let v = finite(units == .metric ? costPerKm : costPerKm * kmPerMile)
        let decimals = abs(v) < 1 ? 3 : abs(v) < 10 ? 2 : abs(v) < 100 ? 1 : 0
        return NavNumberFormat.fixed(v, decimals: decimals, decimalSeparator: decimalSeparator)
    }

    // MARK: display ↔ metric

    public static func litres(fromDisplay v: Double, unit: FuelVolumeUnit) -> Double {
        unit == .litre ? v : v * litresPerGallon
    }

    public static func displayVolume(litres: Double, unit: FuelVolumeUnit) -> Double {
        unit == .litre ? litres : litres / litresPerGallon
    }

    public static func km(fromDisplay v: Double, units: MapUnits) -> Double {
        units == .metric ? v : v * kmPerMile
    }

    public static func displayDistance(km: Double, units: MapUnits) -> Double {
        units == .metric ? km : km / kmPerMile
    }

    public static func kmPerL(fromDisplay v: Double, units: MapUnits) -> Double {
        units == .metric ? v : v / mpgPerKmPerL
    }

    public static func displayEconomy(kmPerL: Double, units: MapUnits) -> Double {
        units == .metric ? kmPerL : kmPerL * mpgPerKmPerL
    }

    /// Price per gallon → per litre.
    public static func pricePerLitre(fromDisplay v: Double, unit: FuelVolumeUnit) -> Double {
        unit == .litre ? v : v / litresPerGallon
    }

    public static func displayPrice(pricePerLitre: Double, unit: FuelVolumeUnit) -> Double {
        unit == .litre ? pricePerLitre : pricePerLitre * litresPerGallon
    }

    private static func finite(_ v: Double) -> Double { v.isFinite ? v : 0 }

    // MARK: Parsing

    /// A rider-typed decimal (litres, km, km/L, tank): trimmed, "," or "." as the separator (at most one),
    /// no grouping ("1.234,5" → nil); empty, non-finite and negative values → nil.
    public static func parseDecimal(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        var digits = 0
        var separators = 0
        var normalized = ""
        for ch in t {
            if ch.isASCII, ch.isNumber {
                digits += 1
                normalized.append(ch)
            } else if ch == "," || ch == "." {
                separators += 1
                normalized.append(".")
            } else {
                return nil
            }
        }
        guard digits > 0, separators <= 1, let v = Double(normalized.hasPrefix(".") ? "0" + normalized : normalized),
              v.isFinite, v >= 0 else { return nil }
        return v
    }

    /// A rider-typed PRICE, grouping-aware for the locale (es-CO "15.900" = fifteen thousand nine hundred):
    /// `decimalSeparator` is the locale's, the grouping separator is the other of "," / ".".
    /// Both present → the last one is the decimal separator and every earlier group after the first has
    /// exactly 3 digits; one kind only → grouping when EVERY occurrence is followed by exactly 3 digits and it
    /// is not the locale's decimal separator, else the decimal separator (at most one occurrence).
    /// Anything else, empty, negative or non-finite → nil.
    public static func parsePrice(_ text: String, decimalSeparator: Character) -> Double? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "," || $0 == "." }) else { return nil }
        let localeDecimal: Character = decimalSeparator == "," ? "," : "."
        let chars = Array(t)
        let hasComma = chars.contains(","), hasDot = chars.contains(".")
        var intDigits = ""
        var fraction = ""
        if hasComma, hasDot {
            guard let lastIndex = chars.lastIndex(where: { $0 == "," || $0 == "." }) else { return nil }
            let dec = chars[lastIndex]
            let head = String(chars[..<lastIndex])
            fraction = String(chars[(lastIndex + 1)...])
            guard !head.contains(dec) else { return nil }
            guard let grouped = ungroup(head, by: dec == "," ? "." : ",") else { return nil }
            intDigits = grouped
        } else if hasComma || hasDot {
            let sep: Character = hasComma ? "," : "."
            let parts = t.split(separator: sep, omittingEmptySubsequences: false).map(String.init)
            let grouping = sep != localeDecimal && parts.count >= 2 && !parts[0].isEmpty
                && parts.dropFirst().allSatisfy { $0.count == 3 }
            if grouping {
                intDigits = parts.joined()
            } else {
                guard parts.count == 2 else { return nil }
                intDigits = parts[0]
                fraction = parts[1]
            }
        } else {
            intDigits = t
        }
        guard !(intDigits.isEmpty && fraction.isEmpty) else { return nil }
        guard let v = Double((intDigits.isEmpty ? "0" : intDigits) + (fraction.isEmpty ? "" : "." + fraction)),
              v.isFinite, v >= 0 else { return nil }
        return v
    }

    /// "1.500.000" (by ".") → "1500000": the first group 1+ digits, every later group exactly 3; nil otherwise.
    private static func ungroup(_ s: String, by sep: Character) -> String? {
        let parts = s.split(separator: sep, omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first, !first.isEmpty, parts.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
        return parts.joined()
    }
}
