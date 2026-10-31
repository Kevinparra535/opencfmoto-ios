// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) HudViewActivity.kt / activity_hud_view.xml (on-screen pad of the
// Dash view, input-controls.md §7.14): ▲ ▼ ◀ ▶ OK, Back and Menu drive the dash UI exactly like the
// handlebar keys (focus navigation, click, close, menu).

import SwiftUI
import OpenCfMotoCore

struct DashKeypad: View {
    var send: (HandlebarKey) -> Void
    @ScaledMetric(relativeTo: .title3) private var keySize: CGFloat = 56

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                key(.back, symbol: "arrow.uturn.backward", label: "Back")
                key(.up, symbol: "chevron.up", label: "Up")
                key(.home, symbol: "line.3.horizontal", label: "Menu")
            }
            GridRow {
                key(.left, symbol: "chevron.left", label: "Left")
                key(.enter, symbol: nil, label: "OK")
                key(.right, symbol: "chevron.right", label: "Right")
            }
            GridRow {
                Color.clear.frame(width: keySize, height: keySize)
                key(.down, symbol: "chevron.down", label: "Down")
                Color.clear.frame(width: keySize, height: keySize)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Handlebar keypad"))
    }

    private func key(_ key: HandlebarKey, symbol: String?, label: LocalizedStringKey) -> some View {
        Button {
            send(key)
        } label: {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.title3.weight(.semibold))
                } else {
                    Text(label)
                        .font(.headline)
                }
            }
            .foregroundStyle(key == .enter ? Color.white : Theme.text)
            .frame(width: keySize, height: keySize)
            .background(key == .enter ? Theme.brand : Theme.surfaceHigh,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.outline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}
