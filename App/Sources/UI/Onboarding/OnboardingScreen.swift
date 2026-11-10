// SPDX-License-Identifier: AGPL-3.0-or-later
// First run (Android: SetupActivity "Get started" + setup_seen, app-features §7.5.2) for iOS:
// welcome → location (When-In-Use) → Local Network → pair the bike (QR / manual Wi-Fi, or skip)
// → done. The steps come from `PermissionsModel.step`. Every exit from the pair-bike step
// (Continue, "Skip for now", a scanner / manual entry that paired) only `advance()`s to the "done"
// page — "You're all set", the ride-safety note and the pocket mode advice (review finding UI-3).
// Only its "Start riding" calls `completeOnboarding()`, which persists the onboarding flag; RootView
// then switches to Home (which auto-connects if enabled).

import SwiftUI
import OpenCfMotoAppModel
import OpenCfMotoCore

struct OnboardingScreen: View {
    @Environment(AppModel.self) private var model
    @State private var showsScanner = false
    @State private var showsManualEntry = false
    @State private var pairedHere = false
    @State private var isRequestingLocalNetwork = false

    var body: some View {
        let step = model.permissions.step
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                progress(step)
                switch step {
                case .welcome: welcome
                case .location: location
                case .localNetwork: localNetwork
                case .pairBike: pairBike
                case .done: done
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { @MainActor in
            await model.permissions.refresh()
        }
        .sheet(isPresented: $showsScanner, onDismiss: continueAfterPairing) {
            NavigationStack {
                ScanScreen(showsCancelButton: true) { _ in
                    pairedHere = true
                }
            }
        }
        .sheet(isPresented: $showsManualEntry, onDismiss: continueAfterPairing) {
            ManualWifiPairingSheet { _ in
                pairedHere = true
            }
        }
    }

    // MARK: - Progress

    private func progress(_ step: OnboardingStep) -> some View {
        let all = OnboardingStep.allCases
        let index = (all.firstIndex(of: step) ?? 0) + 1
        return HStack(spacing: 6) {
            ForEach(Array(all.enumerated()), id: \.offset) { offset, _ in
                Capsule()
                    .fill(offset < index ? Theme.brand : Theme.outline)
                    .frame(height: 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step \(index) of \(all.count)"))
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            MainRideGlyph()
                .frame(width: 64, height: 64)
                .foregroundStyle(Theme.brand)
            Text("Welcome to OpenCfMoto")
                .font(.largeTitle.bold())
                .foregroundStyle(Theme.text)
            Text("OpenCfMoto shows its own map and turn-by-turn guidance on your motorcycle's dash, over the bike's Wi-Fi. It works with CFMoto MotoPlay and other Carbit / EasyConnect dashes that show a pairing QR.")
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                feature("map", "Map, search, routes and GPX tracks on the dash")
                feature("bolt.horizontal.circle", "One-tap Connect and automatic reconnects")
                feature("lock.shield", "No account, no ads, no tracking — your rides stay on this iPhone")
            }
            Text("Free software under the GNU AGPL v3 or later, ported from OpenCfMoto for Android by Alexandru (zanderp).")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.flavor == .free {
                note(systemImage: "wifi.exclamationmark",
                     text: "This build can't join Wi-Fi networks by itself. When you connect, OpenCfMoto shows the bike's Wi-Fi name and password so you can join it in Settings ▸ Wi-Fi.")
            }
            Button {
                model.permissions.advance()
            } label: {
                Text("Get started")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    private var location: some View {
        let permissions = model.permissions
        return VStack(alignment: .leading, spacing: 18) {
            stepHeader(systemImage: "location.fill", title: "Location")
            Text("Your location draws the map and the turn-by-turn guidance on the dash and logs your rides on this iPhone. OpenCfMoto asks for “While Using the App”; during a ride it keeps working with the screen locked and iOS shows the location indicator.")
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            switch permissions.location {
            case .notDetermined:
                statusRow(ok: nil, text: "Not asked yet")
                Button {
                    permissions.requestLocation()
                } label: {
                    Label("Allow location access", systemImage: "location")
                }
                .buttonStyle(PrimaryButtonStyle())
                Button("Not now") { permissions.advance() }
                    .buttonStyle(TonalButtonStyle())
            case .denied, .restricted:
                statusRow(ok: false, text: "Location is off for OpenCfMoto")
                Text("Turn it on in Settings ▸ OpenCfMoto ▸ Location (While Using the App, Precise Location on).")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings") { permissions.openAppSettings() }
                    .buttonStyle(TonalButtonStyle())
                Button("Continue") { permissions.advance() }
                    .buttonStyle(PrimaryButtonStyle())
            case .whenInUse, .always:
                statusRow(ok: true, text: "Location allowed")
                if !permissions.isPreciseLocation {
                    note(systemImage: "scope",
                         text: "Precise Location is off — turn it on in Settings for accurate turn-by-turn guidance.")
                }
                Button("Continue") { permissions.advance() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var localNetwork: some View {
        let permissions = model.permissions
        return VStack(alignment: .leading, spacing: 18) {
            stepHeader(systemImage: "network", title: "Local network")
            Text("The dash talks to your iPhone over the bike's Wi-Fi, so iOS asks for Local Network access. The prompt can also appear the first time OpenCfMoto connects — tap Allow when it does.")
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            switch permissions.localNetwork {
            case .granted:
                statusRow(ok: true, text: "Local network allowed")
            case .denied:
                statusRow(ok: false, text: "Local network access is off")
                Text("Turn it on in Settings ▸ OpenCfMoto ▸ Local Network, or the dash can't be reached.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings") { permissions.openAppSettings() }
                    .buttonStyle(TonalButtonStyle())
            case .undetermined:
                statusRow(ok: nil, text: "Not asked yet")
            case .unavailable:
                statusRow(ok: nil, text: "iOS will ask when you first connect")
            }
            if permissions.localNetwork != .granted && permissions.localNetwork != .denied {
                Button {
                    requestLocalNetwork()
                } label: {
                    if isRequestingLocalNetwork {
                        ProgressView().tint(Theme.onAccent)
                    } else {
                        Label("Allow local network access", systemImage: "network")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isRequestingLocalNetwork)
            }
            if permissions.localNetwork == .granted {
                Button("Continue") { permissions.advance() }
                    .buttonStyle(PrimaryButtonStyle())
            } else {
                Button("Continue") { permissions.advance() }
                    .buttonStyle(TonalButtonStyle())
            }
        }
    }

    private var pairBike: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader(systemImage: "qrcode.viewfinder", title: "Pair your bike")
            Text("Turn the bike on and open MotoPlay / EasyConnect on the dash so it shows the pairing QR, then scan it. Bikes without a QR (e.g. Benelli TRK): enter the Wi-Fi name and password instead.")
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let bike = model.garage.selected {
                statusRow(ok: true, text: "Paired: \(bike.name)")
                Button("Continue") { model.permissions.advance() }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Scan another bike") { showsScanner = true }
                    .buttonStyle(TonalButtonStyle())
            } else {
                Button {
                    showsScanner = true
                } label: {
                    Label("Scan the dash QR", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(PrimaryButtonStyle())
                Button {
                    showsManualEntry = true
                } label: {
                    Label("Enter Wi-Fi manually", systemImage: "keyboard")
                }
                .buttonStyle(TonalButtonStyle())
                Button("Skip for now") { model.permissions.advance() }
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader(systemImage: "checkmark.seal.fill", title: "You're all set")
            Text("Turn the bike on, then tap Connect on the home screen. During a ride keep OpenCfMoto open: Pocket mode keeps the iPhone screen dark while the dash stays live. It starts by itself 5 s after Connect or Go.")
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            note(systemImage: "exclamationmark.triangle",
                 text: "Set your route before you ride and never interact with the phone or the dash while riding.")
            Button {
                model.permissions.completeOnboarding()
            } label: {
                Text("Start riding")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: - Pieces

    private func stepHeader(systemImage: String, title: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Theme.brand)
                .accessibilityHidden(true)
            Text(title)
                .font(.largeTitle.bold())
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func feature(_ systemImage: String, _ text: LocalizedStringKey) -> some View {
        Label {
            Text(text)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.brand)
        }
    }

    /// `ok`: true = granted (green), false = denied (red), nil = unknown (grey).
    private func statusRow(ok: Bool?, text: LocalizedStringKey) -> some View {
        let color: Color = ok == true ? Theme.live : (ok == false ? Theme.error : Theme.idle)
        let symbol = ok == true ? "checkmark.circle.fill" : (ok == false ? "xmark.octagon.fill" : "questionmark.circle")
        return Label {
            Text(text)
                .foregroundStyle(Theme.text)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(color)
        }
        .font(.headline)
    }

    private func note(systemImage: String, text: LocalizedStringKey) -> some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
        }
        .font(.footnote)
        .foregroundStyle(Theme.busy)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Actions

    private func requestLocalNetwork() {
        guard !isRequestingLocalNetwork else { return }
        isRequestingLocalNetwork = true
        Task { @MainActor in
            await model.permissions.requestLocalNetwork()
            isRequestingLocalNetwork = false
        }
    }

    private func continueAfterPairing() {
        guard pairedHere else { return }
        pairedHere = false
        if model.permissions.step == .pairBike {
            model.permissions.advance()
        }
    }
}

#Preview {
    NavigationStack {
        OnboardingScreen()
    }
    .environment(AppModel.preview())
    .preferredColorScheme(.dark)
}
