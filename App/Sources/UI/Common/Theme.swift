// SPDX-License-Identifier: AGPL-3.0-or-later
// Shared look of the phone app: the dark "cockpit" theme of the Android app (docs/spec/app-features.md
// §7.1 palette). Every screen uses it; screen-specific helpers live in their own folders.
//
// UI/UX P0: text and icons on the orange, green and red fills are dark (`onAccent`, 6.2–8.5:1 —
// white was 2.2–3.1:1, under WCAG AA, and those buttons are read outdoors at the bike), and the
// session's Stop is a neutral button with red words (`StopButtonStyle`), never the orange of Connect.

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
    /// Text and icons on the orange (`brand`), green (`live`), red (`error`) and amber (`busy`) fills:
    /// 6.6:1 on orange, 8.5:1 on green, 6.2:1 on red (white was 2.9, 2.2 and 3.1:1).
    static let onAccent = Color(hex: 0x0E1116)

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

/// Full-width primary action (brand orange, or `tint`), dark text on the fill.
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.brand
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(tint.opacity(configuration.isPressed ? 0.75 : 1),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Stop of a running session (UI/UX P0, UX-11): as big as Connect, so it is never hunted for, but
/// neutral with red words and an outline, so it never looks like the orange Connect it replaces.
/// Red text on the raised surface: 5.1:1.
struct StopButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Theme.error)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Theme.surfaceHigh.opacity(configuration.isPressed ? 0.7 : 1),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.error.opacity(0.6), lineWidth: 1.5))
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
