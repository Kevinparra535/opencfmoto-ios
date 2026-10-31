// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) AboutActivity.kt + res/layout/activity_about.xml (app-features
// §8.2, strings §9.11) for the iOS port: version, tagline, the AGPL notice with links to the
// complete corresponding source of THIS app and of the upstream Android project (AGPL §13),
// credits to the original author and the community lineage, map data attribution, disclaimer.

import SwiftUI
import OpenCfMotoAppModel

struct AboutScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                sourceCode
                license
                credits
                disclaimer
                Text("© 2026 the OpenCfMoto for iOS contributors · OpenCfMoto © 2026 Alexandru")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .padding(Theme.padding)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                MainRideGlyph()
                    .frame(width: 44, height: 44)
                    .foregroundStyle(Theme.brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "OpenCfMoto")
                        .font(.title.bold())
                        .foregroundStyle(Theme.text)
                    Text("Version \(model.appVersion)  ·  build \(model.buildNumber)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Text("Your own map and turn-by-turn guidance on Carbit / EasyConnect dashes (CFMoto MotoPlay and siblings).")
                .font(.subheadline)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var sourceCode: some View {
        AboutCard(title: "Source code") {
            Text("OpenCfMoto is free software: the complete source of this app is public, and so is the Android app it was ported from.")
                .aboutBody()
            AboutLink(title: "OpenCfMoto for iOS (this app)", systemImage: "chevron.left.forwardslash.chevron.right",
                      url: AboutLinks.iosSource)
            AboutLink(title: "OpenCfMoto for Android (original project)", systemImage: "chevron.left.forwardslash.chevron.right",
                      url: AboutLinks.upstreamSource)
        }
    }

    private var license: some View {
        AboutCard(title: "License") {
            Text("GNU Affero General Public License v3 or later")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.text)
            Text("You may use, study, share, and modify this app under the AGPL. If you redistribute a modified version (including as a network service), you must offer the complete corresponding source under the same license.")
                .aboutBody()
            AboutLink(title: "View LICENSE & NOTICE", systemImage: "doc.text", url: AboutLinks.notice)
        }
    }

    private var credits: some View {
        AboutCard(title: "Credits") {
            Text("OpenCfMoto for iOS is a port of OpenCfMoto for Android by Alexandru Popa (zanderp). The dash protocol, bike profiles, navigation, trip logging and settings formats come from that project and its community.")
                .aboutBody()
            AboutLink(title: "Alexandru (zanderp) — alexandru.rocks", systemImage: "person.crop.circle",
                      url: AboutLinks.upstreamAuthor)
            Text("Built on the open-cfmoto community lineage:\n\n• dcoletto / coletz — original QR & EasyConn work\n• BojanJ — Android Auto receiver integration\n• richardbizik — 1000 MT-X support\n• ionutradu252 / open-cflink — handlebar controls, margins, reconnect & polish\n• eugen0309 — Wi-Fi Direct / CL-C450 path\n• Martin Escudero (martinescudero) — Android Auto 17.4+ head unit server path\n• Glifaus — Wi-Fi Direct keep-alive\n• sashop2001 — AA DPI, Bluetooth trigger, Bulgarian\n• Authoritt — vehicle telemetry field notes\n• headunit-revived — Android Auto projection stack (AGPL)\n\nAnd everyone who tested bikes, shared logs, and filed issues.")
                .aboutBody()
            Text("Map data © OpenStreetMap contributors (ODbL). Routing and search use public OpenStreetMap-based services.")
                .aboutBody()
            AboutLink(title: "OpenStreetMap copyright", systemImage: "map", url: AboutLinks.osmCopyright)
        }
    }

    private var disclaimer: some View {
        AboutCard(title: "Disclaimer") {
            Text("OpenCfMoto is an independent community project. It is not affiliated with, endorsed by, or sponsored by CFMOTO, Carbit, Apple, Google or any motorcycle brand that licenses EasyConnect-style dashes. CFMOTO, MotoPlay, EasyConn, Carbit and related marks are trademarks of their respective owners.")
                .aboutBody()
            Label {
                Text("Use at your own risk. Set your route before you ride and never interact with the phone or the dash while riding.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.busy)
        }
    }
}

// MARK: - Pieces

private enum AboutLinks {
    static let iosSource = URL(string: "https://github.com/Kevinparra535/opencfmoto-ios")
    static let upstreamSource = URL(string: "https://github.com/zanderp/open-cfmoto")
    static let notice = URL(string: "https://github.com/Kevinparra535/opencfmoto-ios/blob/main/NOTICE")
    static let upstreamAuthor = URL(string: "https://alexandru.rocks")
    static let osmCopyright = URL(string: "https://www.openstreetmap.org/copyright")
}

private struct AboutCard<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MainSectionCaption(text: title)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

private struct AboutLink: View {
    let title: LocalizedStringKey
    let systemImage: String
    let url: URL?

    var body: some View {
        if let url {
            Link(destination: url) {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.brand)
            }
            .accessibilityHint(Text(verbatim: url.absoluteString))
        }
    }
}

private extension Text {
    func aboutBody() -> some View {
        self.font(.subheadline)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview {
    NavigationStack {
        AboutScreen()
    }
    .environment(AppModel.preview())
    .preferredColorScheme(.dark)
}
