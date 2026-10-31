// SPDX-License-Identifier: AGPL-3.0-or-later
// iOS adaptation of the Android Wi-Fi join step (BikeWifi.kt / WifiGate.kt, session-network.md §3):
// in the free build (no Hotspot Configuration entitlement), or when iOS refuses the join, the rider
// joins the bike Wi-Fi in Settings. This sheet shows the SSID + password with copy buttons and
// waits; the model also watches the Wi-Fi path and continues by itself once the bike network
// appears.

import SwiftUI
import OpenCfMotoAppModel

struct ManualJoinPromptSheet: View {
    let prompt: ManualWifiJoinPrompt

    @Environment(AppModel.self) private var model
    @State private var copiedNote: LocalizedStringKey?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !prompt.message.isEmpty {
                        Text(verbatim: prompt.message)
                            .font(.body)
                            .foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: 12) {
                        MainCopyableValueRow(title: "Wi-Fi name (SSID)", value: prompt.ssid) {
                            copiedNote = "Wi-Fi name copied"
                        }
                        Divider().overlay(Theme.outline)
                        if let password = prompt.password, !password.isEmpty {
                            MainCopyableValueRow(title: "Password", value: password, isSecret: true) {
                                copiedNote = "Password copied — paste it in Settings"
                            }
                        } else {
                            Text("Open network — no password needed")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .cardStyle()

                    if let copiedNote {
                        Label(copiedNote, systemImage: "checkmark.circle.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.live)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        MainSectionCaption(text: "How to join")
                        Text("1. Copy the password.\n2. Open Settings, go back to the main list and tap Wi-Fi.\n3. Choose the bike's network and paste the password.\n4. Come back here — OpenCfMoto continues by itself, or tap “I've joined”.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: 12) {
                        Button {
                            model.connection.confirmManualJoin()
                        } label: {
                            Label("I've joined", systemImage: "checkmark")
                        }
                        .buttonStyle(PrimaryButtonStyle())

                        Button {
                            model.permissions.openAppSettings()
                        } label: {
                            Label("Open Settings", systemImage: "gear")
                        }
                        .buttonStyle(TonalButtonStyle())
                    }
                    .padding(.top, 4)
                }
                .padding(Theme.padding)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.background)
            .navigationTitle("Join the bike Wi-Fi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.connection.cancelManualJoin() }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }
}

#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        ManualJoinPromptSheet(prompt: ManualWifiJoinPrompt(
            ssid: "CFMOTO-f46457", password: "59a9cddc94",
            message: "Join CFMOTO-f46457 in Settings ▸ Wi-Fi, then come back."))
            .environment(AppModel.preview())
    }
    .preferredColorScheme(.dark)
}
