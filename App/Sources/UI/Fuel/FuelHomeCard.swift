// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: the Home fuel card (primary column, after Connect / Pocket mode). Non-modal by construction:
// «¿Cuál es tu moto?» is a card the rider taps, never a sheet that pops up by itself during a ride.
//
// | State                         | Shows                                                        | Actions                       |
// |-------------------------------|--------------------------------------------------------------|-------------------------------|
// | setup prompt                  | «¿Cuál es tu moto?» · «Elige el modelo de {bike}…»           | «Elegir», «Luego»             |
// | no profile, no refuel         | nothing (the Garage offers it)                               | —                             |
// | unknown(noRefuel / partial…)  | «Autonomía» + why                                            | «Cargué gasolina»             |
// | ok / low / reserve            | «~250 km hasta la reserva» (amber low, red reserve, words)   | «Cargué gasolina»             |
// | checkRefuel                   | «¿Cargaste gasolina?» · «Toca para actualizar» (tappable)    | opens the late refuel sheet   |
// | aged                          | «~250 km?» in grey + the reason                              | «Cargué gasolina», «Corregir nivel» |
// Footer on number states «El indicador de la moto manda»; the undo bar replaces it for 10 s after a refuel.
// While the bike moves every button that opens a sheet is disabled and the card says «Detente para …».

import SwiftUI
import OpenCfMotoCore
import OpenCfMotoAppModel

struct FuelHomeCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let fuel = model.fuel
        if let prompt = fuel.setupPrompt {
            FuelSetupCard(prompt: prompt)
        } else if let state = fuel.current, state.isSetUp {
            FuelRangeCard(state: state)
        }
    }
}

// MARK: - «¿Cuál es tu moto?»

private struct FuelSetupCard: View {
    let prompt: FuelSetupPrompt

    @Environment(AppModel.self) private var model

    var body: some View {
        let fuel = model.fuel
        let canLog = fuel.canLogNow
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "fuelpump.fill")
                    .foregroundStyle(Theme.brand)
                    .accessibilityHidden(true)
                Text("Which bike is it?")
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Pick the model of \(prompt.bikeName) to estimate its fuel range.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !canLog {
                FuelMovingLine("Stop to choose your bike")
            }
            HStack(spacing: 10) {
                Button {
                    fuel.present(.picker(bikeId: prompt.bikeId, fromPrompt: true))
                } label: {
                    Text("Choose")
                }
                .buttonStyle(FuelPrimaryButtonStyle())
                .disabled(!canLog)

                Button {
                    fuel.deferSetup(for: prompt.bikeId)
                } label: {
                    Text("Later")
                }
                .buttonStyle(FuelTonalButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

// MARK: - Range

private struct FuelRangeCard: View {
    let state: FuelBikeState

    @Environment(AppModel.self) private var model

    var body: some View {
        let fuel = model.fuel
        let canLog = fuel.canLogNow
        let estimate = state.estimate
        let units = fuel.units
        let hasUndo = fuel.undoOffer?.bikeId == state.bikeId
        let asksRefuel = Self.isCheckRefuel(estimate)
        VStack(alignment: .leading, spacing: 12) {
            if asksRefuel {
                // The whole card asks; a tap opens the refuel sheet with «¿Cargaste hace rato?» open.
                Button {
                    fuel.present(.refuel(bikeId: state.bikeId, late: true))
                } label: {
                    info(estimate, units: units)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canLog)
                .accessibilityHint(Text("Tap to update"))
            } else {
                info(estimate, units: units)
            }

            if !canLog {
                FuelMovingLine(state.profile == nil ? "Stop to choose your bike" : "Stop to log the refuel")
            }

            actions(estimate, canLog: canLog)

            if hasUndo {
                FuelUndoBar(bikeId: state.bikeId)
            } else if Self.isNumberState(estimate) {
                Text("Your bike's fuel gauge has the final word")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .animation(.easeInOut(duration: 0.2), value: hasUndo)
    }

    // MARK: Info (one VoiceOver element)

    private func info(_ e: FuelEstimate, units: MapUnits) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header(e)
            headline(e, units: units)
            details(e, units: units)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken(e, units: units)))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func header(_ e: FuelEstimate) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "fuelpump.fill")
                .foregroundStyle(iconTint(e))
                .accessibilityHidden(true)
            Text("Fuel range")
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 8)
            if e.aged == nil {
                switch e.state {
                case .low: FuelBadge(text: Text("Low range"), tint: Theme.busy)
                case .reserve: FuelBadge(text: Text("On reserve"), tint: Theme.error)
                default: EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private func headline(_ e: FuelEstimate, units: MapUnits) -> some View {
        let aged = e.aged != nil
        switch e.state {
        case .unknown(.partialWithoutAmount):
            Text("Range not calculated: your last refuel has no litres.")
                .font(.headline)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        case .unknown(.noProfile):
            Text("Which bike is it?")
                .font(.headline)
                .foregroundStyle(Theme.text)
        case .unknown(.noRefuel):
            Text("Log a refuel to start.")
                .font(.headline)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        case let .ok(km), let .low(km):
            FuelUIText.rangeHeadline(km, units: units, aged: aged, numberFont: .title.bold())
                .font(.title3.weight(.semibold))
                .foregroundStyle(aged ? Theme.textSecondary : (isLow(e) ? Theme.busy : Theme.text))
                .fixedSize(horizontal: false, vertical: true)
        case .reserve:
            (aged ? Text("On reserve") + Text(verbatim: "?") : Text("On reserve"))
                .font(.title.bold())
                .foregroundStyle(aged ? Theme.textSecondary : Theme.error)
        case .checkRefuel:
            Text("Did you refuel?")
                .font(.title2.bold())
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func details(_ e: FuelEstimate, units: MapUnits) -> some View {
        Group {
            switch e.state {
            case .unknown(.partialWithoutAmount):
                Text("A full tank calculates it again.")
            case .unknown(.noProfile):
                Text("Tell us which bike it is to estimate its range.")
            case .unknown(.noRefuel):
                EmptyView()
            case .ok, .low:
                if let aged = e.aged {
                    FuelUIText.agedReason(aged)
                } else if let since = FuelUIText.sinceLastRefuel(e, units: units) {
                    Text("Since your last refuel: \(since)")
                        .monospacedDigit()
                }
            case .reserve:
                if let aged = e.aged {
                    FuelUIText.agedReason(aged)
                } else {
                    Text("Refuel soon")
                }
            case .checkRefuel:
                Text("Tap to update")
            }
        }
        .font(.footnote)
        .foregroundStyle(Theme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Actions

    @ViewBuilder
    private func actions(_ e: FuelEstimate, canLog: Bool) -> some View {
        let fuel = model.fuel
        let bikeId = state.bikeId
        if state.profile == nil {
            Button {
                fuel.present(.picker(bikeId: bikeId, fromPrompt: false))
            } label: {
                Text("Choose")
            }
            .buttonStyle(FuelPrimaryButtonStyle())
            .disabled(!canLog)
        } else if e.aged != nil {
            // Stacked, each full width: side by side, «Cargué gasolina» wraps in half a card.
            VStack(spacing: 10) {
                refuelButton(e, canLog: canLog)
                levelButton(canLog: canLog)
            }
        } else {
            refuelButton(e, canLog: canLog)
        }
    }

    private func refuelButton(_ e: FuelEstimate, canLog: Bool) -> some View {
        let fuel = model.fuel
        let bikeId = state.bikeId
        let late = Self.isCheckRefuel(e)
        return Button {
            fuel.present(.refuel(bikeId: bikeId, late: late))
        } label: {
            Label("I refueled", systemImage: "fuelpump.fill")
        }
        .buttonStyle(FuelPrimaryButtonStyle())
        .disabled(!canLog)
    }

    private func levelButton(canLog: Bool) -> some View {
        let fuel = model.fuel
        let bikeId = state.bikeId
        return Button {
            fuel.present(.level(bikeId: bikeId))
        } label: {
            Text("Correct level")
        }
        .buttonStyle(FuelTonalButtonStyle())
        .disabled(!canLog)
    }

    // MARK: Helpers

    private static func isCheckRefuel(_ e: FuelEstimate) -> Bool {
        if case .checkRefuel = e.state { return true }
        return false
    }

    private func isLow(_ e: FuelEstimate) -> Bool {
        if case .low = e.state { return true }
        return false
    }

    private func iconTint(_ e: FuelEstimate) -> Color {
        if e.aged != nil { return Theme.textSecondary }
        switch e.state {
        case .low: return Theme.busy
        case .reserve: return Theme.error
        case .ok: return Theme.brand
        case .unknown, .checkRefuel: return Theme.textSecondary
        }
    }

    static func isNumberState(_ e: FuelEstimate) -> Bool {
        switch e.state {
        case .ok, .low, .reserve: return true
        case .unknown, .checkRefuel: return false
        }
    }

    /// «Autonomía. Unos 250 km hasta la reserva. Desde tu última carga: 120 km.»
    private func spoken(_ e: FuelEstimate, units: MapUnits) -> String {
        var parts = [String(localized: "Fuel range")]
        switch e.state {
        case .unknown(.partialWithoutAmount):
            parts.append(String(localized: "Range not calculated: your last refuel has no litres."))
            parts.append(String(localized: "A full tank calculates it again."))
        case .unknown(.noProfile):
            parts.append(String(localized: "Tell us which bike it is to estimate its range."))
        case .unknown(.noRefuel):
            parts.append(String(localized: "Log a refuel to start."))
        case let .ok(km), let .low(km):
            if case .low = e.state, e.aged == nil { parts.append(String(localized: "Low range")) }
            parts.append(FuelUIText.rangeSpoken(km, units: units))
            if let aged = e.aged {
                parts.append(FuelUIText.agedReasonSpoken(aged))
            } else if let since = e.kmSinceLastEntry {
                parts.append(String(localized: "Since your last refuel: \(FuelUIText.distance(since, units))"))
            }
        case .reserve:
            parts.append(String(localized: "On reserve"))
            if let aged = e.aged {
                parts.append(FuelUIText.agedReasonSpoken(aged))
            } else {
                parts.append(String(localized: "Refuel soon"))
            }
        case .checkRefuel:
            parts.append(String(localized: "Did you refuel?"))
        }
        return parts.map { $0.hasSuffix(".") || $0.hasSuffix("?") ? $0 : $0 + "." }.joined(separator: " ")
    }
}
