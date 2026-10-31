// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) GpxNav.kt (companion formatting helpers), OverpassClient.kt
//
// Display formatting for the HUD, preview chips and status line (docs/spec/navigation-dash.md §4.6,
// §5.1, §8). Rounding is Java `String.format` HALF_UP (see `NavNumberFormat`). The decimal
// separator is explicit: "." reproduces the Android strings (English locale); pass "," for a
// Spanish display. Wire formats (URLs, JSON, GPX) never use this type.

import Foundation

/// UI language of the strings produced by the navigation core (HUD words, voice phrases, status).
public enum NavLanguage: String, Sendable, Codable, CaseIterable {
    case en
    case es

    /// `.es` when the first preferred language is Spanish, `.en` otherwise.
    public static var preferred: NavLanguage { from(languages: Locale.preferredLanguages) }

    /// First entry decides ("es", "es-CO", "es_419" → `.es`).
    public static func from(languages: [String]) -> NavLanguage {
        guard let first = languages.first?.lowercased() else { return .en }
        return first.hasPrefix("es") ? .es : .en
    }

    /// Decimal separator a native reader expects ("," for Spanish). Used for spoken numbers;
    /// display text uses whatever separator the caller configures (default ".").
    public var conventionalDecimalSeparator: Character { self == .es ? "," : "." }
}

/// Stateless formatting helpers (Android `GpxNav` companion functions).
public enum NavFormat {
    /// Bike follow zoom when speed-zoom is off (`GpxDashUi.kt:2390`).
    public static let fixedFollowZoomBike = 17.2
    /// Phone follow zoom when speed-zoom is off.
    public static let fixedFollowZoomPhone = 16.0
    /// ETA floor speed (50 km/h) used below 1.5 m/s.
    public static let assumedCruiseMps = 50.0 / 3.6

    // MARK: Distance

    /// `formatDistance(m, units)`: METRIC `"%.1f km"` (≥ 1000 m) else `"%.0f m"`; IMPERIAL
    /// `"%.1f mi"` (≥ 0.1 mi) else `"%.0f ft"`.
    public static func formatDistance(_ metres: Double, units: MapUnits, decimalSeparator: Character = ".") -> String {
        switch units {
        case .metric:
            if metres >= 1000 {
                return NavNumberFormat.fixed(metres / 1000.0, decimals: 1, decimalSeparator: decimalSeparator) + " km"
            }
            return NavNumberFormat.fixed(metres, decimals: 0, decimalSeparator: decimalSeparator) + " m"
        case .imperial:
            let miles = metres / 1609.344
            if miles >= 0.1 {
                return NavNumberFormat.fixed(miles, decimals: 1, decimalSeparator: decimalSeparator) + " mi"
            }
            return NavNumberFormat.fixed(metres * 3.28084, decimals: 0, decimalSeparator: decimalSeparator) + " ft"
        }
    }

    /// `formatKm(m)` = metric `formatDistance`.
    public static func formatKm(_ metres: Double, decimalSeparator: Character = ".") -> String {
        formatDistance(metres, units: .metric, decimalSeparator: decimalSeparator)
    }

    // MARK: Time

    /// `formatEta(sec)`: nil → "—"; < 60 min → "<m>m"; else "%dh%02dm".
    public static func formatEta(_ sec: Int?) -> String {
        guard let sec else { return "—" }
        let m = sec / 60
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h" + NavNumberFormat.padded(m % 60, width: 2) + "m"
    }

    /// `formatArrival(etaSec)`: local wall-clock time `now + min(sec, 48 h)` as "HH:mm" (24 h).
    public static func formatArrival(_ etaSec: Int?, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        guard let etaSec else { return "—" }
        let seconds = min(etaSec, 48 * 3600)
        let date = now.addingTimeInterval(TimeInterval(seconds))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute], from: date)
        return NavNumberFormat.padded(c.hour ?? 0, width: 2) + ":" + NavNumberFormat.padded(c.minute ?? 0, width: 2)
    }

    /// `etaSeconds(remainM, speedMps)`: 0 when nothing remains; speed below 1.5 m/s uses the
    /// 50 km/h cruise; `round(remain / v)` (ties up), never negative. Speed is evaluated in
    /// `Float` like Android's `Location.speed`.
    public static func etaSeconds(remainM: Double, speedMps: Double) -> Int {
        if remainM <= 0 { return 0 }
        let f = Float(speedMps)
        let v = f >= 1.5 ? Double(f) : assumedCruiseMps
        return max(0, NavNumberFormat.roundHalfUp(remainM / v))
    }

    // MARK: Speed / altitude

    /// `formatSpeed(kmh)`: METRIC `"%.0f"`; IMPERIAL `"%.0f"` of `kmh·0.621371` (Float maths).
    public static func formatSpeed(kmh: Double, units: MapUnits) -> String {
        let f = Float(kmh)
        switch units {
        case .metric: return NavNumberFormat.fixed(Double(f), decimals: 0)
        case .imperial: return NavNumberFormat.fixed(Double(f * Float(0.621371)), decimals: 0)
        }
    }

    /// Speed in km/h from m/s exactly like Android (`loc.speed * 3.6f`, Float). Unknown → 0.
    public static func speedKmh(fromMps mps: Double?) -> Double {
        Double(Float(mps ?? 0) * Float(3.6))
    }

    /// "km/h" | "mph".
    public static func speedUnitLabel(_ units: MapUnits) -> String { units == .metric ? "km/h" : "mph" }

    /// Altitude unit label for the ALT column: "m" | "ft".
    public static func altitudeUnitLabel(_ units: MapUnits) -> String { units == .metric ? "m" : "ft" }

    /// `formatAltitude(m)`: rounded metres or feet, no unit.
    public static func formatAltitude(_ metres: Double, units: MapUnits) -> String {
        switch units {
        case .metric: return String(NavNumberFormat.roundHalfUp(metres))
        case .imperial: return String(NavNumberFormat.roundHalfUp(metres * 3.28084))
        }
    }

    /// `formatAscent(m)`: "↑<rounded>".
    public static func formatAscent(_ metres: Double, units: MapUnits) -> String {
        "↑" + formatAltitude(metres, units: units)
    }

    // MARK: Zoom

    /// `zoomForSpeedKmh` phone ladder: <8 17.8, <20 17.0, <35 16.2, <55 15.4, <80 14.6, <110 13.8, else 13.0.
    public static func zoomForSpeedKmh(_ kmh: Double) -> Double {
        let v = Float(kmh)
        if v < 8 { return 17.8 }
        if v < 20 { return 17.0 }
        if v < 35 { return 16.2 }
        if v < 55 { return 15.4 }
        if v < 80 { return 14.6 }
        if v < 110 { return 13.8 }
        return 13.0
    }

    /// Follow zoom: on the bike (projected) the ladder is offset `min(z + 1.1, 18.6)`.
    public static func followZoom(speedKmh: Double, projected: Bool = true) -> Double {
        let z = zoomForSpeedKmh(speedKmh)
        return projected ? min(z + 1.1, 18.6) : z
    }

    // MARK: Voice distances

    /// `roundedSpokenDistance`: METRIC ≥ 1000 → "%.1f kilometers", else the first of
    /// [50,100,150,200,300,400,500,700,800] ≥ m, else round(m/100)·100 → "<n> meters";
    /// IMPERIAL ≥ 0.2 mi → "%.1f miles", else feet steps [50,100,150,200,300,500,800,1000,1500]
    /// or round(ft/500)·500 → "<n> feet". Spanish uses metros / kilómetros / pies / millas and a
    /// decimal comma.
    public static func roundedSpokenDistance(_ metres: Double, units: MapUnits, language: NavLanguage = .en) -> String {
        let sep = language.conventionalDecimalSeparator
        switch units {
        case .imperial:
            let miles = metres / 1609.344
            if miles >= 0.2 {
                let n = NavNumberFormat.fixed(miles, decimals: 1, decimalSeparator: sep)
                return language == .es ? "\(n) millas" : "\(n) miles"
            }
            let ft = metres * 3.28084
            let steps = [50, 100, 150, 200, 300, 500, 800, 1000, 1500]
            let r = steps.first(where: { Double($0) >= ft }) ?? NavNumberFormat.roundHalfUp(ft / 500.0) * 500
            return language == .es ? "\(r) pies" : "\(r) feet"
        case .metric:
            if metres >= 1000 {
                let n = NavNumberFormat.fixed(metres / 1000.0, decimals: 1, decimalSeparator: sep)
                return language == .es ? "\(n) kilómetros" : "\(n) kilometers"
            }
            let steps = [50, 100, 150, 200, 300, 400, 500, 700, 800]
            let r = steps.first(where: { Double($0) >= metres }) ?? NavNumberFormat.roundHalfUp(metres / 100.0) * 100
            return language == .es ? "\(r) metros" : "\(r) meters"
        }
    }

    // MARK: Speed limit

    /// `formatLimit`: nil km/h → "—"; METRIC "<kmh>"; IMPERIAL "<toInt(kmh·0.621371)>".
    /// With `keepNativeUnit` (iOS fix, §8 pitfall) an OSM "NN mph" limit shows NN in imperial
    /// instead of the double-converted value.
    public static func formatLimit(_ limit: SpeedLimit, units: MapUnits, keepNativeUnit: Bool = false) -> String {
        guard let kmh = limit.kmh else { return "—" }
        switch units {
        case .metric:
            return String(kmh)
        case .imperial:
            if keepNativeUnit, let mph = SpeedLimitParsing.nativeMph(limit.label) { return String(mph) }
            return String(NavNumberFormat.truncateToInt(Double(kmh) * 0.621371))
        }
    }
}

/// Parsing helpers for OSM `maxspeed` values (`OverpassClient.parseMaxspeedKmh`).
public enum SpeedLimitParsing {
    /// `parseMaxspeedKmh(raw)`: lower-case/trim; none|signals|variable|walk → nil; "NN mph" →
    /// toInt(NN·1.60934); otherwise the leading `[0-9.]*` as a number truncated to Int (or nil).
    public static func parseMaxspeedKmh(_ raw: String) -> Int? {
        let s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch s {
        case "none", "signals", "variable", "walk": return nil
        default: break
        }
        if s.hasSuffix("mph") {
            let num = s.dropLast(3).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let n = kotlinToDouble(num) else { return nil }
            return NavNumberFormat.truncateToInt(n * 1.60934)
        }
        let digits = String(s.prefix(while: { $0.isASCIIDigitOrDot }))
        guard let d = kotlinToDouble(digits) else { return nil }
        return NavNumberFormat.truncateToInt(d)
    }

    /// The numeric part of an "NN mph" value (for native-unit display), else nil.
    public static func nativeMph(_ raw: String) -> Int? {
        let s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasSuffix("mph") else { return nil }
        let num = s.dropLast(3).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let n = kotlinToDouble(num) else { return nil }
        return NavNumberFormat.truncateToInt(n)
    }

    /// Kotlin `String.toDoubleOrNull()` for the plain decimal forms OSM uses ("50", "50.5", ".5").
    static func kotlinToDouble(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t != "." else { return nil }
        guard t.allSatisfy({ $0.isASCIIDigitOrDot || $0 == "-" || $0 == "+" || $0 == "e" || $0 == "E" }) else { return nil }
        return Double(t)
    }
}

extension Character {
    fileprivate var isASCIIDigitOrDot: Bool { ("0" ... "9").contains(self) || self == "." }
}
