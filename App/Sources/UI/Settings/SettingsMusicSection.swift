// SPDX-License-Identifier: AGPL-3.0-or-later
// Settings ▸ "Apple Music on the dash" (iOS addition, no Android counterpart): the opt-in for the
// now-playing tile and the Music sheet on the dash (MusicModel). Turning it on is the only place the
// "Media & Apple Music" permission is asked — on the phone, parked. When access is off the row says
// so and links to the app's page in iOS Settings. Only the system Music app can be shown: iOS gives
// other apps no access to what Spotify, YouTube Music… play.
// Review fix F6: the setting can be ON while iOS never asked (Reset Location & Privacy, the app
// killed while the prompt was up) — then the feature silently stays off and iOS Settings has no
// "Media & Apple Music" switch yet. The section says so and offers the prompt ("Allow access…"),
// still an explicit phone action.

import SwiftUI
import OpenCfMotoCore
import OpenCfMotoAppModel

@MainActor
struct SettingsMusicSection: View {
    @Environment(AppModel.self) private var model

    /// Row id for `-uiSettingsAnchor music` (the CI screenshot of this section, F10).
    static let anchorID = "settings.music"

    var body: some View {
        let music = model.music
        let accessOff = music.authorization == .denied || music.authorization == .restricted
        let needsAsk = music.isAvailable && music.isEnabled && music.authorization == .notDetermined
        Section {
            FeatureToggleRow(title: "Show Apple Music on the dash",
                             detail: Text("Cover, song and controls on the dash map. Only Apple Music: iOS doesn't let apps see what other music apps play."),
                             isOn: Binding(get: { model.music.isEnabled },
                                           set: { on in Task { await model.music.setEnabled(on) } }))
                .disabled(!music.isAvailable)
                .id(Self.anchorID)
            if accessOff {
                Label("Access to Media & Apple Music is off", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.busy)
                Button {
                    model.music.openAppSettings()
                } label: {
                    Label("Open Settings", systemImage: "gear")
                }
            } else if needsAsk {
                Label("OpenCfMoto needs access to Media & Apple Music to show the song.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.busy)
                Button {
                    Task { await model.music.setEnabled(true) } // asks: the permission is undetermined
                } label: {
                    Label("Allow access to Media & Apple Music", systemImage: "music.note")
                }
            }
        } header: {
            Text("Apple Music on the dash")
        } footer: {
            FeatureNote("While Apple Music plays, the bike's ◀ ▶ ★ buttons control the music. With the phone media remote on, pause the song with ★ to give them back to the dash.")
        }
        .featureRowBackground()
        .task { model.music.refreshAuthorization() } // changed in iOS Settings meanwhile?
    }
}
