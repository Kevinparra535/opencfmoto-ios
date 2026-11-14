// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: the editable summary before saving a bike's fuel profile («Revisa y guarda»): tank (in the
// pump's unit), km/L or mpg with «~» and where the figure comes from, and the reserve (5…30 %, default 12).
// Pushed by «¿Cuál es tu moto?» and opened by the Garage «Editar».
//
// Dirty fields: the editor keeps the metric draft and converts a field's text back to metric ONLY when
// the rider edited it, so a catalog 20.5 km/L shown as «48,2 mpg» and saved untouched stays 20.5 and
// `.catalog` (FuelModel.saveProfile applies the seedSource rule with its 0.05 tolerance).
// «Guardar» → `saveProfile` (refused while moving, like every typed write) → when the bike has no refuel
// yet, «¿Tienes el tanque lleno ahora?» [«Sí, está lleno» logs a full refuel | «No sé»] → the sheet closes.

import SwiftUI
import OpenCfMotoCore
import OpenCfMotoAppModel

struct FuelProfileEditor: View {
    let bikeId: String
    let draft: FuelProfile
    let volumeUnit: FuelVolumeUnit
    let units: MapUnits
    /// The root of its own sheet (Garage «Editar»): «Cancelar» in the toolbar.
    var isSheetRoot = false

    @Environment(AppModel.self) private var model
    @State private var tankText: String
    @State private var economyText: String
    @State private var tankDirty = false
    @State private var economyDirty = false
    @State private var reservePct: Int
    @State private var asksFullTank = false
    @FocusState private var focus: Field?

    private enum Field: Hashable { case tank, economy }

    init(bikeId: String, draft: FuelProfile, volumeUnit: FuelVolumeUnit, units: MapUnits, isSheetRoot: Bool = false) {
        self.bikeId = bikeId
        self.draft = draft
        self.volumeUnit = volumeUnit
        self.units = units
        self.isSheetRoot = isSheetRoot
        _tankText = State(initialValue: FuelUIText.fieldNumber(FuelFormat.displayVolume(litres: draft.tankL, unit: volumeUnit)))
        _economyText = State(initialValue: FuelUIText.fieldNumber(FuelFormat.displayEconomy(kmPerL: draft.seedKmPerL, units: units)))
        _reservePct = State(initialValue: min(max(draft.reservePct, FuelProfile.reservePctRange.lowerBound),
                                              FuelProfile.reservePctRange.upperBound))
    }

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
                numberField(text: tankBinding, unit: FuelFormat.volumeUnit(volumeUnit), field: .tank,
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
                } else if let entry, entry.tankKind == .official, !(tankDirty && edited(tankL, draft.tankL)) {
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
                numberField(text: economyBinding, unit: FuelFormat.economyUnit(units), field: .economy,
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
        }
        .confirmationDialog("Is the tank full now?", isPresented: $asksFullTank, titleVisibility: .visible) {
            Button("Yes, it's full") {
                model.fuel.logRefuel(RefuelInput(kind: .full), for: bikeId)
                model.fuel.dismissSheet()
            }
            Button("Not sure", role: .cancel) {
                model.fuel.dismissSheet()
            }
        }
    }

    // MARK: Fields

    private var tankBinding: Binding<String> {
        Binding(get: { tankText }, set: { tankText = $0; tankDirty = true })
    }

    private var economyBinding: Binding<String> {
        Binding(get: { economyText }, set: { economyText = $0; economyDirty = true })
    }

    private func numberField(text: Binding<String>, unit: String, field: Field, isInvalid: Bool) -> some View {
        let canLog = model.fuel.canLogNow
        return HStack(spacing: 8) {
            TextField(text: text, prompt: Text(verbatim: "0")) {
                Text(verbatim: unit)
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
        let changed = (tankDirty && edited(tankL, draft.tankL)) || (economyDirty && edited(kmPerL, draft.seedKmPerL))
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
            litres = draft.tankL
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
