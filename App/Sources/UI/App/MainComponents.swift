// SPDX-License-Identifier: AGPL-3.0-or-later
// Small building blocks shared by the ui-main screens (copyable Wi-Fi values, the ride glyph,
// section headers). Names are prefixed to stay clear of the other UI module's helpers.

import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum MainPasteboard {
    /// Copies `value`. Secrets (Wi-Fi passwords) stay on this device and expire after 2 minutes.
    @MainActor
    static func copy(_ value: String, secret: Bool) {
        if secret {
            UIPasteboard.general.setItems(
                [[UTType.plainText.identifier: value]],
                options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)]
            )
        } else {
            UIPasteboard.general.string = value
        }
    }
}

/// "Wi-Fi name (SSID)  CFMOTO-f46457  [copy]" — with an optional reveal toggle for secrets.
struct MainCopyableValueRow: View {
    let title: LocalizedStringKey
    let value: String
    var isSecret = false
    var onCopied: (() -> Void)?

    @State private var revealed = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Text(verbatim: isSecret && !revealed ? String(repeating: "•", count: max(8, min(value.count, 16))) : value)
                    .font(.body.monospaced())
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .accessibilityLabel(isSecret && !revealed ? Text("Hidden") : Text(verbatim: value))
            }
            Spacer(minLength: 8)
            if isSecret {
                Button {
                    revealed.toggle()
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(revealed ? Text("Hide password") : Text("Show password"))
            }
            Button {
                MainPasteboard.copy(value, secret: isSecret)
                onCopied?()
            } label: {
                Image(systemName: "doc.on.doc")
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Copy"))
        }
        .accessibilityElement(children: .contain)
    }
}

/// The Android `ic_ride` motorcycle glyph (template image, tint with foregroundStyle).
struct MainRideGlyph: View {
    var body: some View {
        Image("RideGlyph")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .accessibilityHidden(true)
    }
}

/// Small uppercase caption above a card (Android "RIDER TIPS", "DIAGNOSTICS").
struct MainSectionCaption: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}
