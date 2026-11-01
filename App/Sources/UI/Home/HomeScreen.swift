// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) MainActivity.kt + res/layout/activity_main.xml
// (app-features §7.1–§7.3, §7.5): header, status card, Connect ⇄ Stop, Dash view | Controls,
// Scan | Map | Mirror tiles, Setup · Garage / Trips · Logs, destination search and the tips card.
// iOS: no Android Auto phases; a Ride Mode button while projecting; a demo badge; link
// diagnostics while live. Portrait = one column, landscape (compact height) = two columns.

import SwiftUI
import OpenCfMotoAppModel

struct HomeScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        ScrollView {
            Group {
                if verticalSizeClass == .compact {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 14) { primaryColumn }
                        VStack(spacing: 14) { secondaryColumn }
                    }
                } else {
                    VStack(spacing: 14) {
                        primaryColumn
                        secondaryColumn
                    }
                }
            }
            .padding(Theme.padding)
            .frame(maxWidth: 960)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(Text(verbatim: "OpenCfMoto"))
        .toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    private var primaryColumn: some View {
        HomeHeader()
        HomeStatusCard()
        HomeConnectButton()
        if model.ride.isProjecting {
            HomeRideModeButton()
        }
    }

    @ViewBuilder
    private var secondaryColumn: some View {
        HomeQuickRow()
        HomeTiles()
        HomeFooter()
        HomeSearchField()
        HomeTipsCard()
    }
}

// MARK: - Header (§7.1 item 1)

private struct HomeHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            NavigationLink(value: MainRoute.about) {
                HStack(spacing: 10) {
                    MainRideGlyph()
                        .frame(width: 28, height: 28)
                        .foregroundStyle(Theme.brand)
                    Text(verbatim: "OpenCfMoto")
                        .font(.title3.bold())
                        .foregroundStyle(Theme.text)
                    Text(verbatim: "v\(model.appVersion)")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("OpenCfMoto, version \(model.appVersion)"))
            .accessibilityHint(Text("Shows About & credits"))
            .accessibilityAddTraits(.isButton)

            Spacer(minLength: 8)

            if AppPlatform.shared.isDemoMode {
                Text("Demo mode")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.background)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Theme.busy, in: Capsule())
                    .accessibilityHint(Text("Running on simulated services: no bike, no real GPS"))
            }
        }
    }
}

// MARK: - Status card (§7.1 item 2, §7.3)

private struct HomeStatusCard: View {
    @Environment(AppModel.self) private var model
    @ScaledMetric(relativeTo: .title2) private var circleSize: CGFloat = 64

    var body: some View {
        let connection = model.connection
        let phase = connection.phase
        let tint = Theme.tint(for: phase)
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().fill(tint.opacity(0.16))
                Circle().strokeBorder(tint.opacity(0.55), lineWidth: 2)
                Image(systemName: MainStrings.phaseSymbol(phase))
                    .font(.system(size: circleSize * 0.4, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: circleSize, height: circleSize)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(MainStrings.phaseLabel(phase))
                    .font(.title2.bold())
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                MainStrings.statusDetail(detail: connection.detail, bikeName: model.garage.selected?.name)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if phase.isLive, let line = MainStrings.diagnosticsLine(connection.diagnostics) {
                    Text(verbatim: line)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.live)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if phase.isBusy {
                ProgressView()
                    .tint(Theme.brand)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(highlighted: phase.isLive)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Connect ⇄ Stop (§7.1 item 3, §7.3)

private struct HomeConnectButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let connection = model.connection
        let phase = connection.phase
        // Stop follows the session, not only the phase: after a dash-not-found / lost-link / Local
        // Network failure the phase is .error while the session keeps re-arming the link every 20 s
        // (GPS, keep-awake, bike Wi-Fi and handlebar capture stay on) — Connect would start a second
        // session instead of ending it (review finding CL-1). `toggle()` stops in that case too.
        let showsStop = connection.isSessionActive || phase.showsStop
        VStack(spacing: 10) {
            Button {
                connection.toggle()
            } label: {
                Group {
                    if showsStop {
                        Label("Stop", systemImage: "stop.fill")
                    } else if let name = model.garage.selected?.name {
                        Label {
                            Text("Connect to \(name)")
                        } icon: {
                            Image(systemName: "power")
                        }
                    } else {
                        Label("Connect", systemImage: "power")
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 12)
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityHint(showsStop
                               ? Text("Stops the dash link and everything it projects")
                               : Text("Joins the bike Wi-Fi and shows the OpenCfMoto map on the dash"))

            if phase == .error && connection.isSessionActive {
                Button {
                    retryNow()
                } label: {
                    Label("Retry now", systemImage: "arrow.clockwise")
                }
                .buttonStyle(TonalButtonStyle())
                .accessibilityHint(Text("Tries the bike again right away instead of waiting for the automatic retry"))
            }
        }
    }

    /// The issue alert's Retry: a fresh attempt in the session's mode (own dash UI or mirror).
    private func retryNow() {
        let connection = model.connection
        connection.dismissIssue()
        if connection.mode == .mirror {
            connection.startMirror()
        } else {
            connection.connect()
        }
    }
}

private struct HomeRideModeButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            MainRideMode.enter(model.ride)
        } label: {
            Label("Ride Mode", systemImage: "moon.zzz.fill")
        }
        .buttonStyle(TonalButtonStyle())
        .accessibilityHint(Text("Black screen that keeps the dash streaming. Long-press to exit."))
    }
}

// MARK: - Dash view | Controls (§7.1 item 4)

private struct HomeQuickRow: View {
    var body: some View {
        HStack(spacing: 12) {
            NavigationLink(value: MainRoute.dashPreview) {
                Label("Dash view", systemImage: "rectangle.inset.filled")
            }
            NavigationLink(value: MainRoute.controls) {
                Label("Controls", systemImage: "gamecontroller")
            }
        }
        .buttonStyle(TonalButtonStyle())
    }
}

// MARK: - Scan | Map | Mirror tiles (§7.1 item 5, enablement §7.3)

private struct HomeTiles: View {
    @Environment(AppModel.self) private var model
    @Environment(\.mainRouter) private var router

    var body: some View {
        let phase = model.connection.phase
        // Android: Scan iff !busy; Map and Mirror iff (!busy || live) so the rider can switch
        // what the dash shows while live.
        let canScan = !phase.isBusy
        let canSwitch = !phase.isBusy || phase.isLive
        HStack(spacing: 12) {
            Button {
                router?.scan(then: .connect)
            } label: {
                HomeTileLabel(title: "Scan", systemImage: "qrcode.viewfinder")
            }
            .disabled(!canScan)
            .accessibilityHint(Text("Scan the pairing QR on the dash, then connect"))

            NavigationLink(value: MainRoute.navigate) {
                HomeTileLabel(title: "Map", systemImage: "map")
            }
            .disabled(!canSwitch)
            .accessibilityHint(Text("Search places, plan a route or load a GPX track"))

            NavigationLink(value: MainRoute.mirror) {
                HomeTileLabel(title: "Mirror", systemImage: "rectangle.on.rectangle")
            }
            .disabled(!canSwitch)
            .accessibilityHint(Text("Show the whole iPhone screen on the dash"))
        }
        .buttonStyle(HomeTileButtonStyle())
    }
}

private struct HomeTileLabel: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(Theme.brand)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 76)
    }
}

/// Surface tile; disabled tiles are dimmed to 40 % like Android.
private struct HomeTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HomeTileBody(configuration: configuration)
    }

    private struct HomeTileBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .padding(.vertical, 6)
                .background(Theme.surface.opacity(configuration.isPressed ? 0.6 : 1),
                            in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.outline, lineWidth: 1))
                .opacity(isEnabled ? 1 : 0.4)
        }
    }
}

// MARK: - Footer: Setup · Garage / Trips · Logs (§7.1 item 6)

private struct HomeFooter: View {
    var body: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                NavigationLink(value: MainRoute.settings) {
                    Label("Setup", systemImage: "gearshape")
                }
                NavigationLink(value: MainRoute.garage) {
                    Label {
                        Text("Garage")
                    } icon: {
                        MainRideGlyph().frame(width: 20, height: 20)
                    }
                }
            }
            GridRow {
                NavigationLink(value: MainRoute.trips) {
                    Label("Trips", systemImage: "clock.arrow.circlepath")
                }
                NavigationLink(value: MainRoute.logs) {
                    Label("Logs", systemImage: "doc.plaintext")
                }
            }
        }
        .buttonStyle(TonalButtonStyle())
    }
}

// MARK: - Tips card (§7.1 item 8, rewritten for iOS)

private struct HomeTipsCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MainSectionCaption(text: "Rider tips")
            Text("• Connect — joins the bike Wi-Fi and shows the OpenCfMoto map on the dash (becomes Stop while linked).\n• Map — search places, plan routes and load GPX tracks; the dash follows.\n• Mirror — shows the whole iPhone screen on the dash (no touch back).\n• Dash view & Controls — the live dash picture on the phone and the handlebar pad.\n• Ride Mode — a black screen that keeps the dash streaming with the iPhone unlocked.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            NavigationLink(value: MainRoute.about) {
                Label("About & credits", systemImage: "info.circle")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

#Preview {
    NavigationStack {
        HomeScreen()
    }
    .environment(AppModel.preview())
    .preferredColorScheme(.dark)
}
