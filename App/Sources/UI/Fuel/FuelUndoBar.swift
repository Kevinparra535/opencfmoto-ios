// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: «Carga registrada · Deshacer», shown on Home and in the Garage section while
// `FuelModel.undoOffer` is for this bike (10 s after a refuel was logged; the model clears it).
// VoiceOver hears «Carga registrada. Puedes deshacerla.» («Nivel ajustado. Puedes deshacerlo.» after «Corregir
// nivel») when it appears. «Deshacer» is a single tap,
// allowed while moving (no typing).

import SwiftUI
import UIKit
import OpenCfMotoAppModel

struct FuelUndoBar: View {
    let bikeId: String

    @Environment(AppModel.self) private var model

    var body: some View {
        if let offer = model.fuel.undoOffer, offer.bikeId == bikeId {
            let isLevel = model.fuel.state(for: bikeId).log.last(where: { $0.id == offer.entryId })?.kind == .level
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.live)
                    .accessibilityHidden(true)
                Group {
                    if isLevel {
                        Text("Level correction")
                    } else {
                        Text("Refuel logged")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    model.fuel.undoLastRefuel()
                } label: {
                    Text("Undo")
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderless)
                .tint(Theme.brand)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onAppear {
                UIAccessibility.post(notification: .announcement,
                                     argument: isLevel ? String(localized: "Level corrected. You can undo it.")
                                         : String(localized: "Refuel logged. You can undo it."))
            }
            .id(offer.entryId)
        }
    }
}
