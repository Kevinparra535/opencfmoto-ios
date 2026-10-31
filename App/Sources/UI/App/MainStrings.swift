// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) ConnectionState.kt (phase labels) and MainActivity.kt
// (status rendering rules, app-features §7.2–§7.3).
//
// Shared, localized wording of the ui-main screens. Everything here returns LocalizedStringKey /
// localized String so Home, Mirror and Ride Mode show the same words; translations live in
// App/Resources/Localization/ui-main.json.

import SwiftUI
import OpenCfMotoAppModel
import OpenCfMotoCore

enum MainStrings {
    /// Home status label of a phase (Android `labelRes`, §7.2).
    static func phaseLabel(_ phase: ConnectionPhase) -> LocalizedStringKey {
        switch phase {
        case .idle: return "Ready"
        case .joiningWifi: return "Connecting to bike Wi-Fi…"
        case .linking: return "Linking to dashboard…"
        case .streaming: return "Connected — projecting to dash"
        case .mirroring: return "Mirroring screen to dash"
        case .reconnecting: return "Link dropped — reconnecting…"
        case .waitingForBike: return "Bike out of range — waiting…"
        case .stopped: return "Stopped"
        case .error: return "Error — see logs"
        }
    }

    /// SF Symbol of the status circle.
    static func phaseSymbol(_ phase: ConnectionPhase) -> String {
        switch phase {
        case .idle: return "power"
        case .joiningWifi: return "wifi"
        case .linking: return "link"
        case .streaming: return "dot.radiowaves.left.and.right"
        case .mirroring: return "rectangle.on.rectangle"
        case .reconnecting: return "arrow.triangle.2.circlepath"
        case .waitingForBike: return "hourglass"
        case .stopped: return "stop.circle"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    /// Second status line (§7.3): the phase detail if any, else the paired / no-bike hint.
    static func statusDetail(detail: String, bikeName: String?) -> Text {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return Text(verbatim: trimmed) }
        if let name = bikeName { return Text("Paired: \(name) — tap Connect to reconnect") }
        return Text("No bike paired yet — tap Connect to scan the dash QR")
    }

    /// "800 × 384".
    static func canvasText(width: Int, height: Int) -> String {
        "\(width) × \(height)"
    }

    static func canvasText(_ size: DashSize) -> String {
        canvasText(width: Int(size.width.rounded()), height: Int(size.height.rounded()))
    }

    /// Canvas preset label for the Dash view picker.
    static func previewCanvasLabel(_ canvas: DashPreviewCanvas) -> LocalizedStringKey {
        switch canvas {
        case .landscape800x384: return "800 × 384 · most CFMoto dashes"
        case .portrait800x944: return "800 × 944 · portrait (1000 MT-X)"
        case .wide1280x576: return "1280 × 576 · wide (800MT)"
        }
    }

    /// SF Symbol for a maneuver (Ride Mode cue).
    static func turnSymbol(_ dir: TurnDir) -> String {
        switch dir {
        case .left, .sharpLeft: return "arrow.turn.up.left"
        case .right, .sharpRight: return "arrow.turn.up.right"
        case .slightLeft: return "arrow.up.left"
        case .slightRight: return "arrow.up.right"
        case .uturn: return "arrow.uturn.down"
        case .roundabout: return "arrow.triangle.turn.up.right.circle"
        case .mergeLeft, .mergeRight: return "arrow.merge"
        case .forkLeft, .forkRight: return "arrow.triangle.branch"
        case .arrive: return "flag.checkered"
        case .straight, .`continue`: return "arrow.up"
        }
    }

    /// One-line link summary for the status card while live: "800NK Advanced · 800 × 384 · 25 fps".
    static func diagnosticsLine(_ d: LinkDiagnostics) -> String? {
        var parts: [String] = []
        if let profile = d.profileName, !profile.isEmpty { parts.append(profile) }
        if let canvas = d.canvas { parts.append(canvasText(width: canvas.width, height: canvas.height)) }
        let fps = d.projection.framesPerSecond > 0 ? d.projection.framesPerSecond : d.stats.pullRate
        if fps > 0 { parts.append(String(format: "%.0f fps", locale: Locale(identifier: "en_US_POSIX"), fps)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
