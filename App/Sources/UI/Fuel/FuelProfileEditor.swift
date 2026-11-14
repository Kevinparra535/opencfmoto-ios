// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: the editable summary before saving a bike's fuel profile («Revisa y guarda»): tank (in the
// pump's unit), km/L or mpg with «~» and where the figure comes from, and the reserve (5…30 %, default 12).
// Pushed by «¿Cuál es tu moto?» and opened by the Garage «Editar».
//
// Dirty fields: the editor keeps the metric draft and converts a field's text back to metric ONLY when
// the rider changed it — a field is dirty while its text differs from what it showed for the metric value, so
// retyping the shown «4,6» gal keeps the catalog's 17.5 L — and a catalog 20.5 km/L shown as «48,2 mpg» and saved
// untouched stays 20.5 and `.catalog` (FuelModel.saveProfile applies the seedSource rule with its 0.05 tolerance).
// The tank section has the pump's «L | gal» switch (the same global preference as «Cargué gasolina»).
// «Guardar» → `saveProfile` (refused while moving, like every typed write) → when the bike has no refuel
// yet, «¿Tienes el tanque lleno ahora?» [«Sí, está lleno» logs a full refuel and closes; refused while moving,
// the editor stays open and asks again once stopped | «No sé»] → the sheet closes.

import SwiftUI
import OpenCfMotoCore
import OpenCfMotoAppModel

struct FuelProfileEditor: View {
    let bikeId: String
    let draft: FuelProfile
    let units: MapUnits
    /// The root of its own sheet (Garage «Editar»): «Cancelar» in the toolbar.
    var isSheetRoot = false

    @Environment(AppModel.self) private var model
    @State private var tankText: String
    /// What the tank field showed for `tankBaseL` (in the unit shown): the field is dirty only when it differs.
    @State private var tankSeedText: String
    /// The metric litres behind `tankSeedText` (the draft's, or the rider's after a unit switch).
    @State private var tankBaseL: Double
    @State private var shownUnit: FuelVolumeUnit
    @State private var economyText: String
    @State private var economySeedText: String
    @State private var reservePct: Int
    @State private var asksFullTank = false
    /// «Sí, está lleno» was refused while moving: ask again once stopped.
    @State private var fullTankPending = false
    @FocusState private var focus: Field?

    private enum Field: Hashable { case tank, economy }

    init(bikeId: String, draft: FuelProfile, volumeUnit: FuelVolumeUnit, units: MapUnits, isSheetRoot: Bool = false) {
        self.bikeId = bikeId
        self.draft = draft
        self.units = units
        self.isSheetRoot = isSheetRoot
        let tank = FuelUIText.fieldNumber(FuelFormat.displayVolume(litres: draft.tankL, unit: volumeUnit))
        _tankText = State(initialValue: tank)
        _tankSeedText = State(initialValue: tank)
        _tankBaseL = State(initialValue: draft.tankL)
        _shownUnit = State(initialValue: volumeUnit)
        let economy = FuelUIText.fieldNumber(FuelFormat.displayEconomy(kmPerL: draft.seedKmPerL, units: units))
        _economyText = State(initialValue: economy)
        _economySeedText = State(initialValue: economy)
        _reservePct = State(initialValue: min(max(draft.reservePct, FuelProfile.reservePctRange.lowerBound),
                                              FuelProfile.reservePctRange.upperBound))
    }

    private var volumeUnit: FuelVolumeUnit { shownUnit }
    private var tankDirty: Bool { tankText != tankSeedText }
    private var economyDirty: Bool { economyText != economySeedText }

    var body: some View {
        let canLog = model.fuel.canLogNow
        let entry = draft.catalogId.flatMap(FuelCatalog.entry(id:))
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    FuelUIText.modelName(draft, entry: entry)
                        .font(.title3.bold())
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note = entry?.marketNote, !note.isEmpty {
                        Text(verbatim: note)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .listRowBackground(Color.clear)
                if !canLog {
                    FuelMovingLine("Stop to edit")
                        .listRowBackground(Color.clear)
                }
            }

            Section {
                Picker(selection: unitBinding) {
                    Text(verbatim: FuelFormat.volumeUnit(.litre)).tag(FuelVolumeUnit.litre)
                    Text(verbatim: FuelFormat.volumeUnit(.usGallon)).tag(FuelVolumeUnit.usGallon)
                } label: {
                    Text(verbatim: "L / gal")
                }
                .pickerStyle(.segmented)
                .disabled(!canLog)
                numberField(text: $tankText, unit: FuelFormat.volumeUnit(volumeUnit), field: .tank,
                            label: Text("Tank (\(FuelFormat.volumeUnit(volumeUnit)))"),
                            isInvalid: tankL == nil && !tankText.isEmpty)
            } header: {
                // No upper-casing: the unit keeps its case («L», «km/L», «mpg»).
                Text("Tank (\(FuelFormat.volumeUnit(volumeUnit)))")
                    .textCase(nil)
            } footer: {
                if tankL == nil, !tankText.isEmpty {
                    rangeHint(FuelProfile.tankRange.lowerBound, FuelProfile.tankRange.upperBound,
                              toDisplay: { FuelFormat.displayVolume(litres: $0, unit: volumeUnit) },
                              unit: FuelFormat.volumeUnit(volumeUnit))
                } else if let entry, entry.tankKind == .official, !edited(tankL, draft.tankL) {
                    Label {
                        Text("Official tank")
                    } icon: {
                        Image(systemName: "checkmark.seal.fill")
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.live)
                }
            }
            .featureRowBackground()

            Section {
                numberField(text: $economyText, unit: FuelFormat.economyUnit(units), field: .economy,
                            label: Text("Fuel economy (\(FuelFormat.economyUnit(units)))"),
                            isInvalid: kmPerL == nil && !economyText.isEmpty)
            } header: {
                Text("Fuel economy (\("~" + FuelFormat.economyUnit(units)))")
                    .textCase(nil)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if kmPerL == nil, !economyText.isEmpty {
                        rangeHint(FuelProfile.kmPerLRange.lowerBound, FuelProfile.kmPerLRange.upperBound,
                                  toDisplay: { FuelFormat.displayEconomy(kmPerL: $0, units: units) },
                                  unit: FuelFormat.economyUnit(units))
                    }
                    sourceLine(entry: entry)
                }
            }
            .featureRowBackground()

            Section {
                Stepper(value: $reservePct, in: FuelProfile.reservePctRange) {
                    HStack {
                        Text("Reserve")
                            .foregroundStyle(Theme.text)
                        Spacer(minLength: 8)
                        Text(verbatim: "\(reservePct) %")
                            .monospacedDigit()
                            .foregroundStyle(Theme.text)
                    }
                }
                .disabled(!canLog)
            } footer: {
                Text("The range counts down to this level, never to an empty tank.")
            }
            .featureRowBackground()

            Section {
                Button {
                    save()
                } label: {
                    Text("Save")
                }
                .buttonStyle(FuelPrimaryButtonStyle())
                .disabled(!canLog || profile == nil)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } footer: {
                Text("Your bike's fuel gauge has the final word")
                    .padding(.top, 8)
            }
        }
        .navigationTitle("Check and save")
        .navigationBarTitleDisplayMode(.inline)
        .featureScreenChrome()
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            if isSheetRoot {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.fuel.dismissSheet() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .fontWeight(.semibold)
                    .disabled(!canLog || profile == nil)
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focus = nil }
            }
        }
        .onChange(of: canLog) { _, can in
            if !can { focus = nil }
            // «Sí, está lleno» was refused while moving: ask again once stopped (no anchor was logged).
            if can, fullTankPending, model.fuel.state(for: bikeId).log.isEmpty {
                fullTankPending = false
                asksFullTank = true
            }
        }
        .onChange(of: model.fuel.volumeUnit) { _, unit in
            switchTankUnit(to: unit)
        }
        .confirmationDialog("Is the tank full now?", isPresented: $asksFullTank, titleVisibility: .visible) {
            Button("Yes, it's full") {
                if case .logged = model.fuel.logRefuel(RefuelInput(kind: .full), for: bikeId) {
                    model.fuel.dismissSheet()
                } else {
                    fullTankPending = true // the editor stays open («Detente para editar»)
                }
            }
            Button("Not sure", role: .cancel) {
                model.fuel.dismissSheet()
            }
        }
    }

    // MARK: Fields

    private var unitBinding: Binding<FuelVolumeUnit> {
        Binding(get: { model.fuel.volumeUnit }, set: { model.fuel.volumeUnit = $0 })
    }

    /// The pump's unit changed: the tank field shows the same litres in the new unit. Untouched, it stays the
    /// draft's exact value; typed, the typed value carries over.
    private func switchTankUnit(to unit: FuelVolumeUnit) {
        guard unit != shownUnit else { return }
        let litres = tankL ?? tankBaseL
        if tankDirty, tankL != nil { tankBaseL = litres }
        shownUnit = unit
        let text = FuelUIText.fieldNumber(FuelFormat.displayVolume(litres: tankBaseL, unit: unit))
        tankSeedText = text
        tankText = text
    }

    private func numberField(text: Binding<String>, unit: String, field: Field, label: Text, isInvalid: Bool) -> some View {
        let canLog = model.fuel.canLogNow
        return HStack(spacing: 8) {
            // The label is what VoiceOver says («Tanque (L)», «Rendimiento (km/L)»), not the bare unit.
            TextField(text: text, prompt: Text(verbatim: "0")) {
                label
            }
            .keyboardType(.decimalPad)
            .font(.title3.weight(.semibold).monospacedDigit())
            .foregroundStyle(isInvalid ? Theme.error : Theme.text)
            .focused($focus, equals: field)
            Text(verbatim: unit)
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
        }
        .disabled(!canLog)
    }

    /// «Entre 3 y 60 L» under an out-of-range value.
    private func rangeHint(_ low: Double, _ high: Double, toDisplay: (Double) -> Double, unit: String) -> some View {
        let lo = FuelUIText.fieldNumber(toDisplay(low))
        let hi = FuelUIText.fieldNumber(toDisplay(high))
        return Text("Between \(lo) and \(hi + " " + unit)")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.error)
    }

    @ViewBuilder
    private func sourceLine(entry: FuelCatalogEntry?) -> some View {
        let changed = edited(tankL, draft.tankL) || (economyDirty && edited(kmPerL, draft.seedKmPerL))
        let source: FuelUIText.Source = {
            if changed {
                return draft.catalogId == nil && draft.seedSource != .copied ? .manual : .edited
            }
            return FuelUIText.source(of: draft, entry: entry, economyEdited: economyDirty)
        }()
        switch source {
        case let .official(_, url), let .published(_, url):
            Link(destination: url) {
                FuelUIText.sourceText(source)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
        default:
            FuelUIText.sourceText(source)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Values (metric)

    /// Litres: the draft's when untouched, else the parsed field; nil when the field does not parse or is
    /// outside the tank range.
    private var tankL: Double? {
        let litres: Double
        if tankDirty {
            guard let v = FuelFormat.parseDecimal(tankText) else { return nil }
            litres = FuelFormat.litres(fromDisplay: v, unit: volumeUnit)
        } else {
            litres = tankBaseL
        }
        return FuelProfile.tankRange.contains(litres) ? litres : nil
    }

    private var kmPerL: Double? {
        let value: Double
        if economyDirty {
            guard let v = FuelFormat.parseDecimal(economyText) else { return nil }
            value = FuelFormat.kmPerL(fromDisplay: v, units: units)
        } else {
            value = draft.seedKmPerL
        }
        return FuelProfile.kmPerLRange.contains(value) ? value : nil
    }

    /// The profile to save, nil while incomplete.
    private var profile: FuelProfile? {
        guard let t = tankL, let k = kmPerL else { return nil }
        var p = draft
        p.tankL = t
        p.seedKmPerL = k
        p.reservePct = reservePct
        return p.isComplete ? p : nil
    }

    private func edited(_ value: Double?, _ original: Double) -> Bool {
        guard let value else { return true }
        return abs(value - original) > FuelProfile.sameValueTolerance
    }

    private func save() {
        guard let p = profile else { return }
        focus = nil
        switch model.fuel.saveProfile(p, for: bikeId) {
        case .saved:
            if model.fuel.state(for: bikeId).log.isEmpty {
                asksFullTank = true
            } else {
                model.fuel.dismissSheet()
            }
        case .refusedWhileMoving, .incomplete:
            break // the moving line / the disabled «Guardar» already say why
        case .noSuchBike:
            model.fuel.dismissSheet()
        }
    }
}

/// The Garage «Editar» sheet: the editor with the bike's saved profile.
struct FuelEditProfileSheet: View {
    let bikeId: String

    @Environment(AppModel.self) private var model

    var body: some View {
        let fuel = model.fuel
        NavigationStack {
            if let profile = fuel.state(for: bikeId).profile {
                FuelProfileEditor(bikeId: bikeId, draft: profile, volumeUnit: fuel.volumeUnit, units: fuel.units,
                                  isSheetRoot: true)
            } else {
                FuelPickerRootFallback(bikeId: bikeId)
            }
        }
    }
}

/// No profile to edit (removed meanwhile): the picker's own entry points.
private struct FuelPickerRootFallback: View {
    let bikeId: String

    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                Text("Tell us which bike it is to estimate its range.")
                    .foregroundStyle(Theme.textSecondary)
            }
            .featureRowBackground()
        }
        .navigationTitle("Fuel & range")
        .navigationBarTitleDisplayMode(.inline)
        .featureScreenChrome()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { model.fuel.dismissSheet() }
            }
        }
    }
}
