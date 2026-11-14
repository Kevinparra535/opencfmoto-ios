// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP «Combustible»: the pure text helpers of the fuel screens — estimate state → words, units
// (`MapUnits` for distance and economy, the pump's `FuelVolumeUnit` for volumes and prices), the
// locale's decimal separator, source captions, and the shared bits every fuel view uses (the moving-lock
// line, the full-height secondary button). Numbers come from `FuelFormat` (Core): a range is always «~»,
// rounded DOWN to 10 km / 5 mi and counted to the reserve, never to an empty tank.
// Every word here is a whole localized string (App/Resources/Localization/fuel.json); VoiceOver hears
// «Unos 250 km», never «tilde 250».

import SwiftUI
import OpenCfMotoCore
import OpenCfMotoAppModel

enum FuelUIText {
    /// The locale's decimal separator ("," in Spanish locales).
    static var decimalSeparator: Character { Locale.current.decimalSeparator?.first ?? "." }

    // MARK: Numbers

    /// "120 km" | "75 mi" (nearest whole).
    static func distance(_ km: Double, _ units: MapUnits) -> String { FuelFormat.distance(km, units: units) }

    /// "17,5 L" | "4,6 gal".
    static func volume(_ litres: Double, _ unit: FuelVolumeUnit) -> String {
        FuelFormat.volume(litres, unit: unit, decimalSeparator: decimalSeparator)
    }

    /// "20,5 km/L" | "48,2 mpg".
    static func economy(_ kmPerL: Double, _ units: MapUnits) -> String {
        FuelFormat.economy(kmPerL, units: units, decimalSeparator: decimalSeparator)
    }

    /// The value an editable field starts with: 1 decimal, a trailing ",0" dropped ("17,5", "14").
    static func fieldNumber(_ v: Double) -> String {
        guard v.isFinite, v > 0 else { return "" }
        let text = NavNumberFormat.fixed(v, decimals: 1, decimalSeparator: decimalSeparator)
        let zero = "\(decimalSeparator)0"
        return text.hasSuffix(zero) ? String(text.dropLast(zero.count)) : text
    }

    /// A currency-free amount with the locale's grouping ("15.900", "4,25").
    static func amount(_ v: Double) -> String {
        guard v.isFinite else { return "" }
        return v.formatted(.number.precision(.fractionLength(0 ... 2)))
    }

    /// "¼" | "½" | "¾" (shown verbatim: not words).
    static func level(_ l: TankLevel) -> String {
        switch l {
        case .quarter: return "\u{00BC}"
        case .half: return "\u{00BD}"
        case .threeQuarters: return "\u{00BE}"
        }
    }

    /// "example.com" of a source URL (no "www."), nil when it is not an http(s) URL.
    static func host(_ source: String) -> String? {
        guard let url = URL(string: source), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              var host = url.host, !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    // MARK: Estimate → words

    /// The headline of a number state: «~250 km hasta la reserva» with the number large, «Menos de 10 km
    /// hasta la reserva» under one step, or «~250 km?» when aged (secondary colour, set by the caller).
    static func rangeHeadline(_ km: Double, units: MapUnits, aged: Bool, numberFont: Font) -> Text {
        let d = FuelFormat.range(km, units: units)
        if aged {
            return Text(verbatim: d.text + "?").font(numberFont).monospacedDigit()
        }
        let number = Text(verbatim: d.number).font(numberFont).monospacedDigit()
        if d.isUnderStep {
            return Text("Under \(number) to reserve")
        }
        return Text("~\(number) to reserve")
    }

    /// VoiceOver: «Unos 250 km hasta la reserva» / «Menos de 10 km hasta la reserva».
    static func rangeSpoken(_ km: Double, units: MapUnits) -> String {
        let d = FuelFormat.range(km, units: units)
        return d.isUnderStep ? String(localized: "Under \(d.number) to reserve")
            : String(localized: "About \(d.number) to reserve")
    }

    /// The reason line of an aged estimate.
    static func agedReason(_ aged: FuelAgedReason) -> Text {
        switch aged {
        case .gap: return Text("You may have ridden without the app. Check your bike's gauge.")
        case .noGps: return Text("The app couldn't measure the km (no precise GPS). Check your bike's gauge.")
        case let .old(days): return Text("Your last refuel was \(days) days ago. Check your bike's gauge.")
        }
    }

    static func agedReasonSpoken(_ aged: FuelAgedReason) -> String {
        switch aged {
        case .gap: return String(localized: "You may have ridden without the app. Check your bike's gauge.")
        case .noGps: return String(localized: "The app couldn't measure the km (no precise GPS). Check your bike's gauge.")
        case let .old(days): return String(localized: "Your last refuel was \(days) days ago. Check your bike's gauge.")
        }
    }

    /// «Desde tu última carga: 120 km · ~20,5 km/L» (nil without the km since the last entry).
    static func sinceLastRefuel(_ e: FuelEstimate, units: MapUnits) -> String? {
        guard let km = e.kmSinceLastEntry else { return nil }
        var detail = distance(km, units)
        if let k = e.kmPerL { detail += " \u{00B7} ~" + economy(k, units) }
        return detail
    }

    /// One line for the «Autonomía» row of the Garage section (the same words as the Home card).
    static func summary(_ e: FuelEstimate, units: MapUnits) -> Text {
        switch e.state {
        case .unknown(.noProfile):
            return Text("Tell us which bike it is to estimate its range.")
        case .unknown(.noRefuel):
            return Text("Log a refuel to start.")
        case .unknown(.partialWithoutAmount):
            return Text("Range not calculated: your last refuel has no litres.")
        case .checkRefuel:
            return Text("Did you refuel?")
        case .reserve:
            return e.aged == nil ? Text("On reserve") : Text("On reserve") + Text(verbatim: "?")
        case let .ok(km), let .low(km):
            return rangeHeadline(km, units: units, aged: e.aged != nil, numberFont: .body.weight(.semibold))
        }
    }

    /// VoiceOver for the summary.
    static func summarySpoken(_ e: FuelEstimate, units: MapUnits) -> String {
        switch e.state {
        case .unknown(.noProfile): return String(localized: "Tell us which bike it is to estimate its range.")
        case .unknown(.noRefuel): return String(localized: "Log a refuel to start.")
        case .unknown(.partialWithoutAmount): return String(localized: "Range not calculated: your last refuel has no litres.")
        case .checkRefuel: return String(localized: "Did you refuel?")
        case .reserve: return String(localized: "On reserve")
        case let .ok(km), let .low(km): return rangeSpoken(km, units: units)
        }
    }

    // MARK: Profile

    /// The model name of a profile: its catalog name, or «Ingresado a mano».
    static func modelName(_ p: FuelProfile, entry: FuelCatalogEntry?) -> Text {
        if let entry { return Text(verbatim: entry.displayName) }
        let name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? Text("Entered by hand") : Text(verbatim: name)
    }

    /// Where the seed km/L comes from.
    enum Source: Equatable {
        case official(host: String, url: URL)
        case published(host: String, url: URL)
        case estimate
        case manual
        case edited
        case copied
    }

    /// The source of a profile's km/L: a catalog row's kind (official / published with its host, or an
    /// estimate), else what the rider did. A hand-entered km/L that is still the class default is an estimate.
    static func source(of p: FuelProfile, entry: FuelCatalogEntry?, economyEdited: Bool = false) -> Source {
        switch p.seedSource {
        case .catalog:
            guard let entry else { return .edited }
            switch entry.consumptionKind {
            case .official, .published:
                guard let name = Self.host(entry.consumptionSource), let url = URL(string: entry.consumptionSource) else {
                    return .estimate
                }
                return entry.consumptionKind == .official ? .official(host: name, url: url) : .published(host: name, url: url)
            case .estimate:
                return .estimate
            }
        case .edited: return .edited
        case .copied: return .copied
        case .manual:
            return !economyEdited && abs(p.seedKmPerL - FuelProfile.manualDefaultKmPerL) <= FuelProfile.sameValueTolerance
                ? .estimate : .manual
        }
    }

    /// The caption of a source (official / published carry their host).
    static func sourceText(_ s: Source) -> Text {
        switch s {
        case let .official(host, _): return Text("Official figure · \(host)")
        case let .published(host, _): return Text("Published figure · \(host)")
        case .estimate: return Text("Estimate: it adjusts with your refuels")
        case .manual: return Text("Entered by hand")
        case .edited: return Text("Edited by you")
        case .copied: return Text("Copied from another bike")
        }
    }

    // MARK: History

    /// «Lleno» | «Parcial» | «Ajuste de nivel · ½» (a partial with a level adds it too).
    static func kind(_ e: RefuelEntry) -> Text {
        switch e.kind {
        case .full:
            return Text("Full")
        case .partial:
            if let l = e.levelAfter { return Text("Partial") + Text(verbatim: " \u{00B7} " + level(l)) }
            return Text("Partial")
        case .level:
            if let l = e.levelAfter { return Text("Level correction · \(level(l))") }
            return Text("Level correction")
        }
    }

    /// "14 nov 2026, 9:41" in the rider's locale.
    static func date(_ ms: Int64) -> String {
        Date(timeIntervalSince1970: Double(ms) / 1000).formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Shared views

/// «Detente para …»: why a fuel button is disabled while the bike moves (the rider never types while riding).
struct FuelMovingLine: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "hand.raised.fill")
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(Theme.busy)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The tonal (neutral) action at the height of `PrimaryButtonStyle`, so the two sit side by side.
struct FuelTonalButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FuelTonalButtonBody(configuration: configuration)
    }

    struct FuelTonalButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.headline)
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Theme.surfaceHigh.opacity(configuration.isPressed ? 0.7 : 1),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .opacity(isEnabled ? 1 : 0.45)
        }
    }
}

/// `PrimaryButtonStyle` (orange, dark text) that dims when disabled.
struct FuelPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FuelPrimaryButtonBody(configuration: configuration)
    }

    struct FuelPrimaryButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.headline)
                .foregroundStyle(Theme.onAccent)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Theme.brand.opacity(configuration.isPressed ? 0.75 : 1),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .opacity(isEnabled ? 1 : 0.45)
        }
    }
}

/// A small filled badge with dark words (amber «Autonomía baja», red «En reserva», «Tanque oficial»).
struct FuelBadge: View {
    let text: Text
    let tint: Color

    var body: some View {
        text
            .font(.caption.weight(.bold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint, in: Capsule())
            .fixedSize()
    }
}
