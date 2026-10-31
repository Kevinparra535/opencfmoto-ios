// SPDX-License-Identifier: AGPL-3.0-or-later
// CONTRACT FILE (wave 2, UI) — shared look of the phone app. Both UI agents use it; do not edit,
// add your own helpers in your own folders instead.
//
// Dark "cockpit" theme of the Android app (docs/spec/app-features.md §7.1 palette).

import SwiftUI
import OpenCfMotoAppModel

enum Theme {
    static let brand = Color(hex: 0xFF6A2C)
    static let brandDark = Color(hex: 0xE85A1E)
    static let background = Color(hex: 0x0E1116)
    static let surface = Color(hex: 0x171B22)
    static let surfaceHigh = Color(hex: 0x1F242E)
    static let outline = Color(hex: 0x2C333F)
    static let text = Color(hex: 0xF2F5FA)
    static let textSecondary = Color(hex: 0x9AA4B2)
    static let live = Color(hex: 0x34C759)
    static let busy = Color(hex: 0xFFB020)
    static let error = Color(hex: 0xFF5A52)
    static let idle = Color(hex: 0x8A93A3)
    /// Monospaced log text.
    static let logText = Color(hex: 0x9CDCFE)

    static let cornerRadius: CGFloat = 16
    static let padding: CGFloat = 16

    /// Status tint for a connection phase (§7.3): live green, error red, busy amber, else idle.
    static func tint(for phase: ConnectionPhase) -> Color {
        if phase.isLive { return live }
        if phase == .error { return error }
        if phase.isBusy { return busy }
        return idle
    }
}

extension Color {
    /// 0xRRGGBB.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// Rounded surface card used across screens.
struct CardStyle: ViewModifier {
    var highlighted = false
    func body(content: Content) -> some View {
        content
            .padding(Theme.padding)
            .background(highlighted ? Theme.surfaceHigh : Theme.surface,
                        in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(Theme.outline, lineWidth: 1))
    }
}

extension View {
    func cardStyle(highlighted: Bool = false) -> some View { modifier(CardStyle(highlighted: highlighted)) }
}

/// Full-width primary action (brand orange).
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.brand
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(tint.opacity(configuration.isPressed ? 0.75 : 1),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Secondary tonal action.
struct TonalButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Theme.surfaceHigh.opacity(configuration.isPressed ? 0.7 : 1),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
