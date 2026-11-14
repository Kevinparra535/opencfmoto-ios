// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: «Cargué gasolina». «Lleno» (default) | «Parcial»; the pump's unit «L | gal» (remembered,
// independent of km / mi: Colombia sells by the gallon with km); litres, price and the bike's trip meter
// are optional; a partial fill may say how full the tank is now (reserve ¼ ½ ¾ / «No sé»). «¿Cargaste hace
// rato?» takes the km ridden since the real refuel (open from «¿Cargaste gasolina?»). Every value is metric when
// handed to `FuelModel.logRefuel` (FuelFormat converts); prices are currency-free and grouping-aware
// (es-CO «15.900» = 15 900: the price field offers «.» and «,» and says what it will save). A partial larger than
// the tank is refused with «Más de lo que cabe en el tanque (…). ¿Litros o galones?»; in gallons the field
// echoes the litres. Refused while moving (the rider never types while riding); after a refuel is logged the
// sheet closes and Home / Garage offer «Deshacer» for 10 s.
//
// «Corregir nivel» (FuelLevelSheet, below): the rider did NOT refuel but reads the gauge (reserve ¼ ½ ¾); not a
// refuel, it does not count toward the measured economy.

import SwiftUI
import UIKit
import OpenCfMotoCore
import OpenCfMotoAppModel

/// How the rider typed the price: per litre, per US gallon, or the total paid.
enum FuelPriceMode: Hashable {
    case perLitre, perGallon, total
}

struct RefuelSheet: View {
    let bikeId: String
    let late: Bool

    @Environment(AppModel.self) private var model
    @State private var kind: RefuelKind = .full
    @State private var litresText = ""
    @State private var level: TankLevel? = nil
    @State private var priceMode: FuelPriceMode
    @State private var priceText = ""
    @State private var tripText = ""
    @State private var lateExpanded: Bool
    @State private var lateText = ""
    @State private var invalid: RefuelInput.Field? = nil
    /// The litres are more than the tank holds (a missed comma, gallons typed as litres).
    @State private var overTank = false
    @FocusState private var focus: RefuelInput.Field?

    init(bikeId: String, late: Bool, volumeUnit: FuelVolumeUnit) {
        self.bikeId = bikeId
        self.late = late
        _lateExpanded = State(initialValue: late)
        _priceMode = State(initialValue: volumeUnit == .usGallon ? .perGallon : .perLitre)
    }

    var body: some View {
        let fuel = model.fuel
        let canLog = fuel.canLogNow
        let volumeUnit = fuel.volumeUnit
        let units = fuel.units
        let distanceUnit = FuelFormat.distanceUnit(units)
        NavigationStack {
            Form {
                if !canLog {
                    Section {
                        FuelMovingLine("Stop to log the refuel")
                            .listRowBackground(Color.clear)
                    }
                }

                Section {
                    Picker(selection: $kind) {
                        Text("Full").tag(RefuelKind.full)
                        Text("Partial").tag(RefuelKind.partial)
                    } label: {
                        Text("I refueled")
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                Section {
                    Picker(selection: unitBinding) {
                        Text(verbatim: FuelFormat.volumeUnit(.litre)).tag(FuelVolumeUnit.litre)
                        Text(verbatim: FuelFormat.volumeUnit(.usGallon)).tag(FuelVolumeUnit.usGallon)
                    } label: {
                        Text(verbatim: "L / gal")
                    }
                    .pickerStyle(.segmented)
                    numberField(volumeUnit == .litre ? "Liters (optional)" : "Gallons (optional)", text: $litresText,
                                unit: FuelFormat.volumeUnit(volumeUnit), field: .litres)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if invalid == .litres, overTank, let tank = fuel.state(for: bikeId).profile?.tankL {
                            Text("More than the tank holds (\(FuelUIText.volume(tank, volumeUnit))). Liters or gallons?")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Theme.error)
                        } else {
                            invalidHint(.litres)
                        }
                        // Gallons: the litres they make, so a unit slip shows before «Guardar».
                        if volumeUnit == .usGallon, case let .value(v) = Self.parse(litresText) {
                            Text(verbatim: "= " + FuelUIText.volume(FuelFormat.litres(fromDisplay: v, unit: .usGallon), .litre))
                                .monospacedDigit()
                        }
                    }
                }
                .featureRowBackground()

                if kind == .partial {
                    Section {
                        FuelLevelChoice(selection: $level, allowsNotSure: true, isEnabled: canLog)
                            .accessibilityLabel(Text("How full is it now?"))
                    } header: {
                        Text("How full is it now?")
                    } footer: {
                        if litresText.trimmingCharacters(in: .whitespaces).isEmpty, level == nil {
                            Text("Without liters or a level, the range waits for your next full tank.")
                        }
                    }
                    .featureRowBackground()
                }

                Section {
                    Picker(selection: $priceMode) {
                        Text("Per liter").tag(FuelPriceMode.perLitre)
                        Text("Per gallon").tag(FuelPriceMode.perGallon)
                        Text("Total").tag(FuelPriceMode.total)
                    } label: {
                        Text("Price (optional)")
                    }
                    .pickerStyle(.segmented)
                    // «.» and «,» both: es-CO prices group thousands with «.» (15.900), the decimal pad has only «,».
                    numberField("Price (optional)", text: $priceText, unit: nil, field: .price, keyboard: .numbersAndPunctuation)
                } header: {
                    Text("Price (optional)")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        invalidHint(.price)
                        if invalid != .price, case let .value(v) = Self.parse(priceText, price: true) {
                            priceEcho(v).monospacedDigit()
                        }
                    }
                }
                .featureRowBackground()

                Section {
                    numberField("Trip meter (optional)", text: $tripText, unit: distanceUnit, field: .tripMeter)
                } header: {
                    Text("Trip meter (optional)")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        invalidHint(.tripMeter)
                        if units == .metric {
                            Text("What the trip meter showed before you reset it: the km since your previous refuel. It makes the measured economy exact.")
                        } else {
                            Text("What the trip meter showed before you reset it: the miles since your previous refuel. It makes the measured economy exact.")
                        }
                    }
                }
                .featureRowBackground()

                Section {
                    DisclosureGroup(isExpanded: $lateExpanded) {
                        numberField(units == .metric ? "Km since you refueled" : "Miles since you refueled",
                                    text: $lateText, unit: distanceUnit, field: .lateKm)
                    } label: {
                        Text("Refueled a while ago?")
                            .foregroundStyle(Theme.text)
                    }
                } footer: {
                    invalidHint(.lateKm)
                }
                .featureRowBackground()

                Section {
                    Button {
                        save()
                    } label: {
                        Text("Save")
                    }
                    .buttonStyle(FuelPrimaryButtonStyle())
                    .disabled(!canLog)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } footer: {
                    Text("Your bike's fuel gauge has the final word")
                        .padding(.top, 8)
                }
            }
            .navigationTitle("I refueled")
            .navigationBarTitleDisplayMode(.inline)
            .featureScreenChrome()
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { fuel.dismissSheet() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(!canLog)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focus = nil }
                }
            }
            .onChange(of: canLog) { _, can in
                if !can { focus = nil }
            }
            .onChange(of: kind) { _, k in
                if k == .full { level = nil }
            }
        }
    }

    // MARK: Fields

    private var unitBinding: Binding<FuelVolumeUnit> {
        Binding(get: { model.fuel.volumeUnit }, set: { model.fuel.volumeUnit = $0 })
    }

    private func numberField(_ title: LocalizedStringKey, text: Binding<String>, unit: String?,
                             field: RefuelInput.Field, keyboard: UIKeyboardType = .decimalPad) -> some View {
        let isInvalid = invalid == field
        let canLog = model.fuel.canLogNow
        return HStack(spacing: 8) {
            TextField(title, text: Binding(get: { text.wrappedValue }, set: { value in
                text.wrappedValue = value
                if invalid == field { invalid = nil }
                if field == .litres { overTank = false }
            }))
            .keyboardType(keyboard)
            .font(.body.monospacedDigit())
            .foregroundStyle(isInvalid ? Theme.error : Theme.text)
            .focused($focus, equals: field)
            if let unit {
                Text(verbatim: unit)
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
            }
            if isInvalid {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Theme.error)
                    .accessibilityLabel(Text("Check this value"))
            }
        }
        .disabled(!canLog)
    }

    /// «Se guarda: 15.900 por galón» — what the price field will save, in the locale's format.
    private func priceEcho(_ v: Double) -> Text {
        let amount = FuelUIText.amount(v)
        switch priceMode {
        case .perLitre: return Text("Saved as \(amount) per liter")
        case .perGallon: return Text("Saved as \(amount) per gallon")
        case .total: return Text("Saved as a total of \(amount)")
        }
    }

    @ViewBuilder
    private func invalidHint(_ field: RefuelInput.Field) -> some View {
        if invalid == field {
            Text("Check this value")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.error)
        }
    }

    // MARK: Save

    private enum Parsed {
        case empty, value(Double), invalid
    }

    private static func parse(_ text: String, price: Bool = false) -> Parsed {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return .empty }
        let v = price ? FuelFormat.parsePrice(t, decimalSeparator: FuelUIText.decimalSeparator) : FuelFormat.parseDecimal(t)
        return v.map(Parsed.value) ?? .invalid
    }

    /// The metric input, or the first field that does not parse.
    private func input() -> Result<RefuelInput, FieldError> {
        let fuel = model.fuel
        var i = RefuelInput(kind: kind)
        switch Self.parse(litresText) {
        case .empty: break
        case let .value(v): i.litres = FuelFormat.litres(fromDisplay: v, unit: fuel.volumeUnit)
        case .invalid: return .failure(FieldError(field: .litres))
        }
        if kind == .partial { i.levelAfter = level }
        switch Self.parse(priceText, price: true) {
        case .empty: break
        case let .value(v):
            switch priceMode {
            case .perLitre: i.pricePerLitre = v
            case .perGallon: i.pricePerLitre = FuelFormat.pricePerLitre(fromDisplay: v, unit: .usGallon)
            case .total: i.totalPrice = v
            }
        case .invalid: return .failure(FieldError(field: .price))
        }
        switch Self.parse(tripText) {
        case .empty: break
        case let .value(v): i.tripMeterKm = FuelFormat.km(fromDisplay: v, units: fuel.units)
        case .invalid: return .failure(FieldError(field: .tripMeter))
        }
        if lateExpanded {
            switch Self.parse(lateText) {
            case .empty: break
            case let .value(v): i.lateKm = FuelFormat.km(fromDisplay: v, units: fuel.units)
            case .invalid: return .failure(FieldError(field: .lateKm))
            }
        }
        return .success(i)
    }

    private struct FieldError: Error {
        let field: RefuelInput.Field
    }

    /// A partial larger than the tank (FuelModel refuses it too: it would read as a full tank).
    private func exceedsTank(_ i: RefuelInput) -> Bool {
        guard i.kind == .partial, let l = i.litres, let t = model.fuel.state(for: bikeId).profile?.tankL else { return false }
        return l > t * FuelModel.maxFillOverTank
    }

    private func save() {
        focus = nil
        overTank = false
        switch input() {
        case let .failure(error):
            invalid = error.field
        case let .success(i):
            if let field = i.invalidField() {
                invalid = field
                return
            }
            if exceedsTank(i) {
                invalid = .litres
                overTank = true
                return
            }
            switch model.fuel.logRefuel(i, for: bikeId) {
            case .logged:
                model.fuel.dismissSheet()
            case let .invalid(field):
                invalid = field
                overTank = field == .litres && exceedsTank(i)
            case .refusedWhileMoving:
                break // the moving line already says why
            case .noSuchBike:
                model.fuel.dismissSheet()
            }
        }
    }
}

// MARK: - «Corregir nivel»

struct FuelLevelSheet: View {
    let bikeId: String

    @Environment(AppModel.self) private var model
    @State private var level: TankLevel? = nil

    var body: some View {
        let fuel = model.fuel
        let canLog = fuel.canLogNow
        NavigationStack {
            Form {
                if !canLog {
                    Section {
                        FuelMovingLine("Stop to edit")
                            .listRowBackground(Color.clear)
                    }
                }
                Section {
                    FuelLevelChoice(selection: $level, allowsNotSure: false, isEnabled: canLog)
                        .accessibilityLabel(Text("What does the gauge show?"))
                } header: {
                    Text("What does the gauge show?")
                } footer: {
                    Text("It isn't a refuel: it doesn't count toward the measured economy.")
                }
                .featureRowBackground()

                Section {
                    Button {
                        save()
                    } label: {
                        Text("Save")
                    }
                    .buttonStyle(FuelPrimaryButtonStyle())
                    .disabled(!canLog || level == nil)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } footer: {
                    Text("Your bike's fuel gauge has the final word")
                        .padding(.top, 8)
                }
            }
            .navigationTitle("Correct level")
            .navigationBarTitleDisplayMode(.inline)
            .featureScreenChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { fuel.dismissSheet() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(!canLog || level == nil)
                }
            }
        }
    }

    private func save() {
        guard let level else { return }
        switch model.fuel.logLevel(level, for: bikeId) {
        case .logged, .noSuchBike:
            model.fuel.dismissSheet()
        case .refusedWhileMoving, .invalid:
            break
        }
    }
}

// MARK: - Level choice

/// The tank-level choices as one row of segment-like buttons («Reserva» 1/4 1/2 3/4 [«No sé»]). Each speaks
/// words («Un cuarto de tanque», «En reserva»), never «1/4», and carries the selected trait: a segmented Picker
/// turns its content into plain segment titles and drops a per-segment accessibility label.
struct FuelLevelChoice: View {
    @Binding var selection: TankLevel?
    let allowsNotSure: Bool
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TankLevel.allCases, id: \.self) { l in
                segment(FuelUIText.levelSegment(l), spoken: FuelUIText.levelSpoken(l), selected: selection == l) {
                    selection = l
                }
            }
            if allowsNotSure {
                segment(Text("Not sure"), spoken: Text("Not sure"), selected: selection == nil) { selection = nil }
            }
        }
        .padding(2)
        .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityElement(children: .contain)
    }

    private func segment(_ title: Text, spoken: Text, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            title
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(selected ? Theme.onAccent : Theme.text)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(selected ? Theme.brand : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Sheet switch (RootView)

/// The fuel sheet RootView presents for `FuelModel.sheet` (set only by a rider tap: `FuelModel.present`).
struct FuelSheetView: View {
    let sheet: FuelSheet

    @Environment(AppModel.self) private var model

    var body: some View {
        switch sheet {
        case let .picker(bikeId, fromPrompt):
            FuelPickerSheet(bikeId: bikeId, fromPrompt: fromPrompt)
        case let .editProfile(bikeId):
            FuelEditProfileSheet(bikeId: bikeId)
        case let .refuel(bikeId, late):
            RefuelSheet(bikeId: bikeId, late: late, volumeUnit: model.fuel.volumeUnit)
        case let .level(bikeId):
            FuelLevelSheet(bikeId: bikeId)
        }
    }
}
