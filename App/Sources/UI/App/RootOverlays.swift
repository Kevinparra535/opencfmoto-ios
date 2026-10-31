// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) MainActivity.kt: toasts (→ banner) and the error dialogs of
// app-features §7.5.8 / §9.13 (official app holding the ports, Wi-Fi off, …) adapted to iOS.

import SwiftUI
import OpenCfMotoAppModel

// MARK: - Banner (Android toasts)

/// The app-wide one-line message (`AppModel.banner`). Tap to dismiss; also auto-dismissed here
/// after a few seconds in case the model keeps it.
struct RootBannerOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack(alignment: .top) {
            if let text = model.banner, !text.isEmpty {
                Text(verbatim: text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: 520)
                    .background(Theme.surfaceHigh, in: Capsule(style: .continuous))
                    .overlay(Capsule(style: .continuous).strokeBorder(Theme.outline, lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                    .padding(.horizontal, Theme.padding)
                    .padding(.top, 6)
                    .contentShape(Capsule(style: .continuous))
                    .onTapGesture { model.dismissBanner() }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(Text("Double-tap to dismiss"))
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: text) { @MainActor in
                        try? await Task.sleep(for: .seconds(4))
                        guard !Task.isCancelled, model.banner == text else { return }
                        model.dismissBanner()
                    }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.banner)
    }
}

// MARK: - Connection issue alerts (§7.5.8)

extension View {
    /// Shows `ConnectionModel.issue` as an alert. Attach it to exactly one active presentation level.
    func connectionIssueAlert(isActive: Bool) -> some View {
        modifier(ConnectionIssueAlertModifier(isActive: isActive))
    }
}

private struct ConnectionIssueAlertModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    var isActive: Bool

    func body(content: Content) -> some View {
        let issue = presentedIssue
        content.alert(
            Self.title(for: issue),
            isPresented: Binding(get: { issue != nil }, set: { _ in /* every action clears the issue */ }),
            presenting: issue
        ) { issue in
            actions(for: issue)
        } message: { issue in
            Self.message(for: issue)
        }
    }

    /// `.noBikePaired` is not an alert: RootView opens the scanner instead.
    private var presentedIssue: ConnectionIssue? {
        guard isActive, let issue = model.connection.issue, issue != .noBikePaired else { return nil }
        return issue
    }

    @ViewBuilder
    private func actions(for issue: ConnectionIssue) -> some View {
        switch issue {
        case .portsInUse, .wifiJoinFailed, .dashNotFound:
            Button("Retry") { retry() }
            Button("Dismiss", role: .cancel) { model.connection.dismissIssue() }
        case .lostLink:
            Button("Reconnect") { retry() }
            Button("Dismiss", role: .cancel) { model.connection.dismissIssue() }
        case .localNetworkDenied:
            Button("Open Settings") {
                model.connection.dismissIssue()
                model.permissions.openAppSettings()
            }
            Button("Dismiss", role: .cancel) { model.connection.dismissIssue() }
        case .wifiUnavailable, .noBikePaired, .other:
            Button("OK", role: .cancel) { model.connection.dismissIssue() }
        }
    }

    /// Android "Close & retry": the rider closed the other app / fixed the dash; try again in the
    /// same mode (own dash UI or mirror).
    private func retry() {
        let connection = model.connection
        connection.dismissIssue()
        if connection.mode == .mirror {
            connection.startMirror()
        } else {
            connection.connect()
        }
    }

    private static func title(for issue: ConnectionIssue?) -> Text {
        guard let issue else { return Text(verbatim: "") }
        switch issue {
        case .noBikePaired: return Text(verbatim: "")
        case .portsInUse: return Text("Official CFMoto app is in the way")
        case .localNetworkDenied: return Text("Local Network access is off")
        case .wifiUnavailable: return Text("Turn on Wi-Fi")
        case .wifiJoinFailed: return Text("Couldn't join the bike Wi-Fi")
        case .dashNotFound: return Text("Dash not found")
        case .lostLink: return Text("Lost the bike link")
        case .other: return Text("Connection problem")
        }
    }

    private static func message(for issue: ConnectionIssue) -> Text {
        switch issue {
        case .portsInUse:
            return Text("Another CFMoto / EasyConnect app is using the bike's link ports (10920-10922), so the dash stays blank. Close it from the app switcher, then reconnect.")
        case .localNetworkDenied:
            return Text("OpenCfMoto needs Local Network access to talk to the dash over the bike Wi-Fi. Turn it on in Settings ▸ OpenCfMoto ▸ Local Network, then tap Connect again.")
        case .wifiUnavailable:
            return Text("OpenCfMoto joins the bike over Wi-Fi, but your phone's Wi-Fi is off.\n\nTurn it on in Control Center, then tap Connect again.")
        case .wifiJoinFailed(let message):
            return Text(verbatim: message)
        case .dashNotFound:
            return Text("Bike Wi-Fi is up but EasyConn is offline — keep the pairing QR open on the dash, then tap Connect again.")
        case .lostLink:
            return Text("The dash stopped answering after 20 reconnect attempts. Check that the bike is on and the dash shows MotoPlay, then tap Connect.")
        case .other(let message):
            return Text(verbatim: message)
        case .noBikePaired:
            return Text(verbatim: "")
        }
    }
}
