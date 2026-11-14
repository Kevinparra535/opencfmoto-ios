// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: the «Combustible» section of the Garage bike detail. Without a profile: «Elegir moto». With
// one: model, tank, the seed km/L with its source vs «Medido ~N km/L de tus cargas», «Usar el rendimiento
// medido», the reserve (a stepper that saves at once), the cost per km when prices were logged, the range
// (the same words as Home), «Editar», «Cambiar moto», «Cargué gasolina», «Corregir nivel», and the refuel
// history newest first with swipe-to-delete (confirmed). Everything stays on this iPhone and is deleted
// with the bike. The buttons that open a sheet are disabled while the bike moves («Detente para editar»);
// the single taps (reserve, measured economy, delete) stay.

import SwiftUI
import OpenCfMotoCore
import OpenCfMotoAppModel

struct GarageFuelSection: View {
    let bikeID: String

    /// The row the Garage detail scrolls to for `-uiScreen fuel`.
    static let anchorID = "fuel"

    @Environment(AppModel.self) private var model

    var body: some View {
        let fuel = model.fuel
        let state = Self.state(fuel, bikeID)
        let canLog = fuel.canLogNow
        let units = fuel.units
        Section {
            if let profile = state.profile {
                profileRows(state, profile: profile, units: units, canLog: canLog)
            } else {
                Button {
                    fuel.present(.picker(bikeId: bikeID, fromPrompt: false))
                } label: {
                    Label("Choose the model", systemImage: "fuelpump")
                }
                .disabled(!canLog)
                .id(Self.anchorID)
                if !canLog {
                    FuelMovingLine("Stop to choose your bike")
                }
            }
        } header: {
            Text("Fuel & range")
        } footer: {
            if state.profile == nil {
                Text("Tell us which bike it is to estimate its range.")
            } else {
                Text("Your bike's fuel gauge has the final word. The range is a calculation from the km the app measures while it is connected to the bike.")
            }
        }
        .listRowBackground(Theme.surface)

        if state.profile != nil || !state.log.isEmpty {
            Section {
                if state.log.isEmpty {
                    Text("No refuels yet")
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    let entries = Array(state.log.enumerated()).reversed()
                    ForEach(entries, id: \.element.id) { index, entry in
                        FuelHistoryRow(bikeID: bikeID, entry: entry,
                                       previous: index > 0 ? state.log[index - 1] : nil, units: units)
                    }
                }
            } header: {
                Text("Refuel history")
            }
            .listRowBackground(Theme.surface)
        }
    }

    /// The Home card's state when this is the bike it follows (updated with every counted km), else the
    /// stored one.
    static func state(_ fuel: FuelModel, _ bikeID: String) -> FuelBikeState {
        if let current = fuel.current, current.bikeId == bikeID { return current }
        return fuel.state(for: bikeID)
    }

    @ViewBuilder
    private func profileRows(_ state: FuelBikeState, profile: FuelProfile, units: MapUnits, canLog: Bool) -> some View {
        figureRows(state, profile: profile, units: units)
        rangeRows(state, units: units, canLog: canLog)
    }

    /// Model, tank, seed vs measured economy, the measured toggle, reserve, cost per km.
    @ViewBuilder
    private func figureRows(_ state: FuelBikeState, profile: FuelProfile, units: MapUnits) -> some View {
        let fuel = model.fuel
        let stats = state.stats
        LabeledContent {
            FuelUIText.modelName(profile, entry: state.entry)
                .multilineTextAlignment(.trailing)
        } label: {
            Text("Model")
        }
        .id(Self.anchorID)

        LabeledContent {
            Text(verbatim: FuelUIText.volume(profile.tankL, fuel.volumeUnit))
                .monospacedDigit()
        } label: {
            Text("Tank")
        }

        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                Text(verbatim: "~" + FuelUIText.economy(profile.seedKmPerL, units))
                    .monospacedDigit()
            } label: {
                Text("Fuel economy")
            }
            sourceCaption(profile, entry: state.entry)
        }

        FuelStackedRow(title: "Measured") {
            if let learned = stats.learnedKmPerL, stats.learnedIntervalCount > 0 {
                Text("~\(FuelUIText.economy(learned, units)) from your refuels (\(stats.learnedIntervalCount))")
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
            } else {
                Text("Not measured yet: log two full tanks with litres.")
                    .foregroundStyle(Theme.textSecondary)
            }
        }

        if stats.learnedKmPerL != nil {
            Toggle(isOn: Binding(get: { profile.preferLearned },
                                 set: { fuel.setPreferLearned($0, for: bikeID) })) {
                Text("Use the measured economy")
            }
            .tint(Theme.brand)
        }

        Stepper(value: Binding(get: { profile.reservePct }, set: { fuel.setReservePct($0, for: bikeID) }),
                in: FuelProfile.reservePctRange) {
            LabeledContent {
                Text(verbatim: "\(profile.reservePct) %")
                    .monospacedDigit()
            } label: {
                Text("Reserve")
            }
        }

        if let cost = stats.costPerKm {
            LabeledContent {
                Text(verbatim: FuelFormat.costPerDistance(cost, units: units, decimalSeparator: FuelUIText.decimalSeparator))
                    .monospacedDigit()
            } label: {
                Text("Cost per \(FuelFormat.distanceUnit(units))")
            }
        }
    }

    /// The range, why it is unsure, and the actions.
    @ViewBuilder
    private func rangeRows(_ state: FuelBikeState, units: MapUnits, canLog: Bool) -> some View {
        FuelStackedRow(title: "Fuel range") {
            FuelUIText.summary(state.estimate, units: units)
                .foregroundStyle(state.estimate.aged == nil ? Theme.text : Theme.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: String(localized: "Fuel range") + ". "
            + FuelUIText.summarySpoken(state.estimate, units: units)))

        if let aged = state.estimate.aged {
            FuelUIText.agedReason(aged)
                .font(.footnote)
                .foregroundStyle(Theme.busy)
                .fixedSize(horizontal: false, vertical: true)
        }

        if !canLog {
            FuelMovingLine("Stop to edit")
        }

        actionRows(canLog: canLog, late: Self.isCheckRefuel(state.estimate))
    }

    /// «Cargué gasolina», «Corregir nivel», «Editar», «Cambiar moto», then «Deshacer» for 10 s.
    @ViewBuilder
    private func actionRows(canLog: Bool, late: Bool) -> some View {
        let fuel = model.fuel
        Button {
            fuel.present(.refuel(bikeId: bikeID, late: late))
        } label: {
            Label("I refueled", systemImage: "fuelpump.fill")
        }
        .disabled(!canLog)

        Button {
            fuel.present(.level(bikeId: bikeID))
        } label: {
            Label("Correct level", systemImage: "gauge.with.dots.needle.50percent")
        }
        .disabled(!canLog)

        Button {
            fuel.present(.editProfile(bikeId: bikeID))
        } label: {
            Label("Edit", systemImage: "slider.horizontal.3")
        }
        .disabled(!canLog)

        Button {
            fuel.present(.picker(bikeId: bikeID, fromPrompt: false))
        } label: {
            Label("Change model", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(!canLog)

        if fuel.undoOffer?.bikeId == bikeID {
            FuelUndoBar(bikeId: bikeID)
        }
    }

    @ViewBuilder
    private func sourceCaption(_ profile: FuelProfile, entry: FuelCatalogEntry?) -> some View {
        let source = FuelUIText.source(of: profile, entry: entry)
        switch source {
        case let .official(_, url), let .published(_, url):
            Link(destination: url) {
                FuelUIText.sourceText(source)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.borderless)
        default:
            FuelUIText.sourceText(source)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func isCheckRefuel(_ e: FuelEstimate) -> Bool {
        if case .checkRefuel = e.state { return true }
        return false
    }
}

/// A list row with its title above a value that may wrap (long Spanish lines stay readable).
private struct FuelStackedRow<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            content
                .font(.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - History row

/// One refuel: date, «Lleno | Parcial | Ajuste de nivel», litres, price, «+{km}» since the entry before.
/// Swipe «Eliminar» asks first («¿Eliminar esta carga?»).
private struct FuelHistoryRow: View {
    let bikeID: String
    let entry: RefuelEntry
    let previous: RefuelEntry?
    let units: MapUnits

    @Environment(AppModel.self) private var model
    @State private var confirmsDelete = false

    var body: some View {
        let volumeUnit = model.fuel.volumeUnit
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.kind == .level ? "gauge.with.dots.needle.50percent" : "fuelpump.fill")
                .foregroundStyle(entry.kind == .full ? Theme.brand : Theme.textSecondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                FuelUIText.kind(entry)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                Text(verbatim: FuelUIText.date(entry.atMs))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                if let line = detailLine(volumeUnit) {
                    Text(verbatim: line)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let previous, entry.odometerKm > previous.odometerKm {
                Text(verbatim: "+" + FuelUIText.distance(entry.odometerKm - previous.odometerKm, units))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                confirmsDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                confirmsDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .confirmationDialog("Delete this refuel?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                model.fuel.deleteRefuel(id: entry.id, for: bikeID)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// "12,0 L · 4,25 /L · 51" — litres, the price per volume unit, the money spent (currency-free).
    private func detailLine(_ volumeUnit: FuelVolumeUnit) -> String? {
        var parts: [String] = []
        if let litres = entry.litres { parts.append(FuelUIText.volume(litres, volumeUnit)) }
        if let ppl = entry.pricePerLitre {
            let shown = FuelFormat.displayPrice(pricePerLitre: ppl, unit: volumeUnit)
            parts.append(FuelUIText.amount(shown) + " /" + FuelFormat.volumeUnit(volumeUnit))
        }
        if let cost = entry.cost {
            parts.append(String(localized: "Total \(FuelUIText.amount(cost))"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }
}
