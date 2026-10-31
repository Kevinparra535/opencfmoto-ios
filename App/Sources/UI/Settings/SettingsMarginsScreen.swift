// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) ScreenMarginsActivity.kt, ScreenMargins.kt
//
// Screen margins editor (docs/spec/app-features.md §2.6): four insets 0…200 dash pixels
// (top / bottom / left / right). Any change stores all four with customised = true; "Reset to
// profile default" clears the customisation so the profile default applies again (800NK Advanced:
// top 22, all others 0). On iOS the margins are the safe area of our dash UI and the insets of the
// mirrored screen; they apply live.

import SwiftUI
import OpenCfMotoCore
import OpenCfMotoAppModel

@MainActor
struct SettingsMarginsScreen: View {
    @Environment(AppModel.self) private var model
    /// Values being dragged (committed when the slider is released).
    @State private var draft: ScreenMargins?

    var body: some View {
        let settings = model.settings
        let stored = settings.current.screenMargins
        let profileDefault = settings.defaultMargins(for: settings.current.profileOverride)
        let effective = draft ?? (stored.customised ? stored : profileDefault)
        Form {
            Section {
                FeatureNote("Inset the dash UI (and the mirrored screen) from each edge of the dash, in dash pixels. On the 800NK Advanced, a top margin keeps MotoPlay's pull-down handle from stealing swipes.")
                SettingsLabels.marginsSummary(effective, profileDefault: !stored.customised && draft == nil)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
            }
            .featureRowBackground()

            Section {
                edgeRow("Top", \.top, effective: effective)
                edgeRow("Bottom", \.bottom, effective: effective)
                edgeRow("Left", \.left, effective: effective)
                edgeRow("Right", \.right, effective: effective)
            }
            .featureRowBackground()

            Section {
                Button {
                    draft = nil
                    settings.resetScreenMargins()
                } label: {
                    Label("Reset to profile default", systemImage: "arrow.counterclockwise")
                }
                .disabled(!stored.customised && draft == nil)
                LabeledContent {
                    SettingsLabels.marginsSummary(profileDefault, profileDefault: true)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.trailing)
                } label: {
                    Text("Profile default")
                }
            } footer: {
                FeatureNote("Margins apply right away. The profile default follows Settings ▸ Bike profile (Auto uses the dash it detects).")
            }
            .featureRowBackground()
        }
        .navigationTitle("Screen margins")
        .navigationBarTitleDisplayMode(.inline)
        .featureScreenChrome()
    }

    private func edgeRow(_ title: LocalizedStringKey, _ edge: WritableKeyPath<ScreenMargins, Int>,
                         effective: ScreenMargins) -> some View {
        let value = effective[keyPath: edge]
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(verbatim: "\(value) px")
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                Stepper(value: Binding(get: { value },
                                       set: { commit(edge, $0, from: effective) }),
                        in: 0 ... 200) {
                    Text(title)
                }
                .labelsHidden()
            }
            Slider(value: Binding(get: { Double(value) },
                                  set: { newValue in
                                      var margins = effective
                                      margins[keyPath: edge] = Int(newValue.rounded())
                                      margins.customised = true
                                      draft = margins.clamped()
                                  }),
                   in: 0 ... 200,
                   step: 1,
                   onEditingChanged: { editing in
                       if !editing, let pending = draft {
                           model.settings.setScreenMargins(pending)
                           draft = nil
                       }
                   })
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(verbatim: "\(value) px"))
        }
        .padding(.vertical, 4)
    }

    private func commit(_ edge: WritableKeyPath<ScreenMargins, Int>, _ value: Int, from base: ScreenMargins) {
        var margins = base
        margins[keyPath: edge] = value
        margins.customised = true
        draft = nil
        model.settings.setScreenMargins(margins.clamped())
    }
}

#Preview("Margins") {
    NavigationStack {
        SettingsMarginsScreen()
    }
    .environment(AppModel.preview())
}
