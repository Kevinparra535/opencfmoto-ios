// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) AboutActivity.kt + res/layout/activity_about.xml (app-features
// §8.2, strings §9.11) for the iOS port: version, tagline, the AGPL notice with links to the
// complete corresponding source of THIS app and of the upstream Android project (AGPL §13), the
// install guide, the "no warranty" line and the licences (AGPL §5(d) "Appropriate Legal Notices",
// Apache-2.0 §4 for the AOSP ports and Material icons), credits to the original author and the
// community lineage (CREDITS.md), map data and service attribution, disclaimer.

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
            AboutLink(title: "Install guide", systemImage: "arrow.down.circle", url: AboutLinks.installGuide)
        }
    }

    private var license: some View {
        AboutCard(title: "License") {
            Text("GNU Affero General Public License v3 or later")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.text)
            Text("You may use, study, share, and modify this app under the AGPL. If you redistribute a modified version (including as a network service), you must offer the complete corresponding source under the same license.")
                .aboutBody()
            Text("This app comes with ABSOLUTELY NO WARRANTY, to the extent permitted by applicable law.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            AboutLink(title: "View LICENSE & NOTICE", systemImage: "doc.text", url: AboutLinks.notice)
            Text("Portions © The Android Open Source Project and Material Icons by Google are licensed under the Apache License 2.0.")
                .aboutBody()
            AboutLink(title: "Open-source licenses", systemImage: "doc.plaintext", url: AboutLinks.openSourceLicenses)
        }
    }

    private var credits: some View {
        AboutCard(title: "Credits") {
            Text("OpenCfMoto for iOS is a port of OpenCfMoto for Android by Alexandru Popa (zanderp). The dash protocol, bike profiles, navigation, trip logging and settings formats come from that project and its community.")
                .aboutBody()
            AboutLink(title: "Alexandru (zanderp) — alexandru.rocks", systemImage: "person.crop.circle",
                      url: AboutLinks.upstreamAuthor)
            Text("Built on the open-cfmoto community:\n\n• dcoletto / coletz — the original open-cfmoto (QR & EasyConn)\n• richardbizik — 1000 MT-X support\n• ionutradu252 / OpenCFLink — handlebar controls, margins, reconnect & polish\n• eugen0309 — CL-C450 path (and Wi-Fi Direct on Android)\n• Authoritt — Spanish translation, Wi-Fi transport memory, telemetry notes")
                .aboutBody()
            Text("Android app only, not in this app: BojanJ (Android Auto integration), Martin Escudero (Android Auto 17.4+), Glifaus (Wi-Fi Direct keep-alive), sashop2001 (AA DPI, Bluetooth trigger), headunit by Michael Reid and Open Headunit (headunit-revived) by Andre Rinas.")
                .aboutBody()
            Text("And everyone who tested bikes, shared logs and filed issues.")
                .aboutBody()
            AboutLink(title: "Full credits", systemImage: "person.3", url: AboutLinks.credits)
            Text("Map data © OpenStreetMap contributors (ODbL). Map tiles: OpenStreetMap Foundation (default server). Search: Photon by komoot and Nominatim. Places and speed limits: Overpass API. Routing: Valhalla (FOSSGIS) and OSRM; with your own key, © openrouteservice.org by HeiGIT. The phone map uses Apple Maps.")
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
    private static let repository = "https://github.com/Kevinparra535/opencfmoto-ios"
    static let iosSource = URL(string: repository)
    static let upstreamSource = URL(string: "https://github.com/zanderp/open-cfmoto")
    static let notice = URL(string: repository + "/blob/main/NOTICE")
    static let credits = URL(string: repository + "/blob/main/CREDITS.md")
    static let openSourceLicenses = URL(string: repository + "/tree/main/LICENSES")
    static let upstreamAuthor = URL(string: "https://alexandru.rocks")
    static let osmCopyright = URL(string: "https://www.openstreetmap.org/copyright")

    /// docs/INSTALAR.md holds the Spanish guide first and the English one under `#english`; open
    /// the half that matches the language the app is shown in.
    static var installGuide: URL? {
        let spanish = Bundle.main.preferredLocalizations.first?.hasPrefix("es") ?? false
        return URL(string: repository + "/blob/main/docs/INSTALAR.md" + (spanish ? "" : "#english"))
    }
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
