// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: «Cargué gasolina». «Lleno» (default) | «Parcial»; the pump's unit «L | gal» (remembered,
// independent of km / mi: Colombia sells by the gallon with km); litres, price and the bike's trip meter
// are optional; a partial fill may say how full the tank is now (¼ ½ ¾ / «No sé»). «¿Cargaste hace rato?»
// takes the km ridden since the real refuel (open from «¿Cargaste gasolina?»). Every value is metric when
// handed to `FuelModel.logRefuel` (FuelFormat converts); prices are currency-free and grouping-aware
// (es-CO «15.900» = 15 900). Refused while moving (the rider never types while riding); after a refuel is
// logged the sheet closes and Home / Garage offer «Deshacer» for 10 s.
//
// «Corregir nivel» (FuelLevelSheet, below): the rider did NOT refuel but reads the gauge (¼ ½ ¾); not a refuel,
// it does not count toward the measured economy.

import SwiftUI
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
                    numberField(volumeUnit == .litre ? "Litres (optional)" : "Gallons (optional)", text: $litresText,
                                unit: FuelFormat.volumeUnit(volumeUnit), field: .litres)
                } footer: {
                    invalidHint(.litres)
                }
                .featureRowBackground()

                if kind == .partial {
                    Section {
                        Picker(selection: $level) {
                            ForEach(TankLevel.allCases, id: \.self) { l in
                                Text(verbatim: FuelUIText.levelSegment(l))
                                    .accessibilityLabel(Text(verbatim: FuelUIText.level(l)))
                                    .tag(TankLevel?.some(l))
                            }
                            Text("Not sure").tag(TankLevel?.none)
                        } label: {
                            Text("How full is it now?")
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("How full is it now?")
                    } footer: {
                        if litresText.trimmingCharacters(in: .whitespaces).isEmpty, level == nil {
                            Text("Without litres or a level, the range waits for your next full tank.")
                        }
                    }
                    .featureRowBackground()
                }

                Section {
                    Picker(selection: $priceMode) {
                        Text("Per litre").tag(FuelPriceMode.perLitre)
                        Text("Per gallon").tag(FuelPriceMode.perGallon)
                        Text("Total").tag(FuelPriceMode.total)
                    } label: {
                        Text("Price (optional)")
                    }
                    .pickerStyle(.segmented)
                    numberField("Price (optional)", text: $priceText, unit: nil, field: .price)
                } header: {
                    Text("Price (optional)")
                } footer: {
                    invalidHint(.price)
                }
                .featureRowBackground()

                Section {
                    numberField("Trip meter (optional)", text: $tripText, unit: distanceUnit, field: .tripMeter)
                } header: {
                    Text("Trip meter (optional)")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        invalidHint(.tripMeter)
                        Text("What the trip meter showed before you reset it: the \(distanceUnit) since your previous refuel. It makes the measured economy exact.")
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
                             field: RefuelInput.Field) -> some View {
        let isInvalid = invalid == field
        let canLog = model.fuel.canLogNow
        return HStack(spacing: 8) {
            TextField(title, text: Binding(get: { text.wrappedValue }, set: { value in
                text.wrappedValue = value
                if invalid == field { invalid = nil }
            }))
            .keyboardType(.decimalPad)
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

    private func save() {
        focus = nil
        switch input() {
        case let .failure(error):
            invalid = error.field
        case let .success(i):
            if let field = i.invalidField() {
                invalid = field
                return
            }
            switch model.fuel.logRefuel(i, for: bikeId) {
            case .logged:
                model.fuel.dismissSheet()
            case let .invalid(field):
                invalid = field
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
                    Picker(selection: $level) {
                        ForEach(TankLevel.allCases, id: \.self) { l in
                            Text(verbatim: FuelUIText.levelSegment(l))
                                .accessibilityLabel(Text(verbatim: FuelUIText.level(l)))
                                .tag(TankLevel?.some(l))
                        }
                    } label: {
                        Text("What does the gauge show?")
                    }
                    .pickerStyle(.segmented)
                    .disabled(!canLog)
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
