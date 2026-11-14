// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: «¿Llego?» under the route chips of the Map hub's route preview (NavigatePreviewCard), from
// `FuelModel.previewVerdict` against the selected route. Nothing without a preview, a route, a profile, or
// for a straight-line / offline fallback (its chord under-states the road). «Llegas» needs ≥ 25 km to
// spare on a trustworthy estimate; an aged estimate never says «Llegas». A tap on the unknown lines opens
// the refuel sheet (disabled while the bike moves).

import SwiftUI
import OpenCfMotoCore
import OpenCfMotoAppModel

struct FuelVerdictLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let fuel = model.fuel
        if let verdict = fuel.previewVerdict, let bikeId = fuel.currentBikeId, let content = line(for: verdict) {
            if let late = refuelTap(for: verdict) {
                Button {
                    fuel.present(.refuel(bikeId: bikeId, late: late))
                } label: {
                    row(content, tappable: true)
                }
                .buttonStyle(.plain)
                .disabled(!fuel.canLogNow)
            } else {
                row(content, tappable: false)
            }
        }
    }

    private struct Line {
        let text: Text
        let icon: Color
        let words: Color
        /// VoiceOver, when the visible words carry a «~» (read «Unos 60 km», never «tilde 60»).
        var spoken: Text? = nil
    }

    private func row(_ line: Line, tappable: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "fuelpump.fill")
                .foregroundStyle(line.icon)
                .accessibilityHidden(true)
            line.text
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(line.words)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if tappable {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .modifier(SpokenLabel(text: line.spoken))
    }

    private struct SpokenLabel: ViewModifier {
        let text: Text?
        @ViewBuilder
        func body(content: Content) -> some View {
            if let text { content.accessibilityLabel(text) } else { content }
        }
    }

    private func line(for verdict: FuelVerdict) -> Line? {
        let units = model.fuel.units
        switch verdict {
        case let .reaches(margin):
            let d = FuelFormat.range(margin, units: units)
            return Line(text: Text("You reach it with ~\(d.number) before the reserve"), icon: Theme.live, words: Theme.text,
                        spoken: Text("You reach it with about \(d.number) before the reserve"))
        case .tight:
            return Line(text: Text("Tight: refuel before you leave"), icon: Theme.busy, words: Theme.busy)
        case let .needsRefuel(stops):
            let text = stops <= 1 ? Text("You'll need to refuel on the way")
                : Text("You'll need about \(stops) refuels on the way")
            return Line(text: text, icon: Theme.error, words: Theme.text)
        case let .unknown(reason):
            let text: Text
            switch reason {
            case .noProfile:
                return nil
            case .noRefuel:
                text = Text("Log a refuel to know if you get there")
            case .partialWithoutAmount:
                text = Text("Fill the tank to know if you get there")
            case .checkRefuel:
                text = Text("Did you refuel? Update it to know if you get there")
            case .aged:
                text = model.fuel.current?.estimate.aged == .noGps
                    ? Text("Check your bike's gauge: the app couldn't measure the km")
                    : Text("Check your bike's gauge: you may have ridden without the app")
            }
            return Line(text: text, icon: Theme.textSecondary, words: Theme.textSecondary)
        }
    }

    /// The refuel sheet for the lines that ask for a refuel (`late` for «¿Cargaste gasolina?»), else nil.
    private func refuelTap(for verdict: FuelVerdict) -> Bool? {
        guard case let .unknown(reason) = verdict else { return nil }
        switch reason {
        case .noRefuel, .partialWithoutAmount: return false
        case .checkRefuel: return true
        case .noProfile, .aged: return nil
        }
    }
}
