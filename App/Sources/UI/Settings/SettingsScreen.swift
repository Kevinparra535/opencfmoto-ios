// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) SetupActivity.kt, res/layout/activity_setup.xml, GpxActivity.kt
// (map settings, routing key, map data backup)
//
// Setup & settings (docs/spec/app-features.md §2, §3.5, §8.1 adapted to iOS — no Android Auto,
// Bluetooth trigger, clock lab, update checker or telemetry). Sections in Android order:
// Screen & display (video quality, screen fit, mirror orientation, screen margins, touch
// overrides) · Battery & power · Bike profile · Map & navigation (+ Apple Music on the dash, dash
// tiles, routing key) · Startup & recovery · Privacy & logs · Permissions · Share settings / map
// data (ShareLink of a freshly exported pack; Import… via the Files picker with a confirmation, then
// the model's result message) · links to Garage, Controls, About and "Show onboarding again".
// Every control writes through SettingsModel (scoped per bike where Android scopes it).

import SwiftUI
import OpenCfMotoCore
import OpenCfMotoAppModel

@MainActor
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var tileDraft = ""
    @State private var orsDraft = ""
    @State private var draftsLoaded = false
    @State private var importTarget = SettingsImportTarget.settings
    @State private var showImporter = false
    @State private var alert: SettingsAlert?
    @State private var shareErrors = FeatureShareErrors()
    /// `-uiSettingsAnchor <name>` (CI screenshots, review fix F10): the section to scroll to once.
    private let scrollAnchor: String?
    @State private var anchorApplied = false
    /// The row the launch anchor scrolls to, set once the first layout pass is done.
    @State private var scrollTarget: String?

    init(scrollAnchor: String? = nil) {
        self.scrollAnchor = scrollAnchor
    }

    var body: some View {
        ScrollViewReader { proxy in
            settingsForm
                .task { await armLaunchAnchor() }
                .onChange(of: scrollTarget) { _, row in
                    guard let row else { return }
                    proxy.scrollTo(row, anchor: .center)
                }
        }
    }

    private var settingsForm: some View {
        Form {
            Group {
                scopeSection
                displaySection
                powerSection
                profileSection
                mapSection
                SettingsMusicSection()
                tilesSection
            }
            Group {
                routingSection
                startupSection
                compatibilitySection
                privacySection
                permissionsSection
                backupSection
                linksSection
            }
        }
        .navigationTitle("Setup & settings")
        .featureScreenChrome()
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: FeatureFileTypes.backupImport,
                      allowsMultipleSelection: false) { result in
            handleImportPick(result, target: importTarget)
        }
        .alert(alert?.title ?? Text(verbatim: ""),
               isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } }),
               presenting: alert) { state in
            alertActions(state)
        } message: { state in
            state.message
        }
        .onAppear(perform: loadDrafts)
        .onChange(of: model.settings.current.tileURLTemplate) { _, value in tileDraft = value }
        .onChange(of: model.settings.current.orsApiKey) { _, value in orsDraft = value }
        .onChange(of: shareErrors.message) { _, message in
            guard let message else { return }
            shareErrors.message = nil
            present(.exportFailed(message))
        }
        .task { await model.permissions.refresh() }
    }

    // MARK: Launch anchor (CI screenshots)

    /// `-uiSettingsAnchor` names → the row each one scrolls to.
    private static var anchorRows: [String: String] { ["music": SettingsMusicSection.anchorID] }

    /// Scrolls the section into view after the first layout pass, so the screenshot shows it
    /// (tools/ci/e2e/screenshots.sh: `settings_music`, `es_settings_music`).
    private func armLaunchAnchor() async {
        guard let name = scrollAnchor, !anchorApplied else { return }
        anchorApplied = true
        guard let row = Self.anchorRows[name] else {
            Log.w("UI", "-uiSettingsAnchor \(name): unknown section (music)")
            return
        }
        try? await Task.sleep(for: .milliseconds(500))
        scrollTarget = row
        Log.i("UI", "-uiSettingsAnchor \(name)")
    }

    // MARK: Bindings

    private var current: BikeSettings { model.settings.current }

    private func mapBinding<Value>(_ keyPath: WritableKeyPath<MapPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings.current.map[keyPath: keyPath] },
            set: { newValue in
                var prefs = model.settings.current.map
                prefs[keyPath: keyPath] = newValue
                model.settings.setMapPreferences(prefs)
            })
    }

    // MARK: Sections

    private var scopeSection: some View {
        Section {
            if let bike = model.garage.selected {
                Label {
                    Text("Per-bike settings are saved for \(bike.name).")
                        .foregroundStyle(Theme.text)
                } icon: {
                    Image(systemName: "bicycle")
                        .foregroundStyle(Theme.brand)
                }
            } else {
                Label {
                    Text("No bike paired yet — these settings apply to every bike you add.")
                        .foregroundStyle(Theme.text)
                } icon: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Theme.brand)
                }
            }
        } footer: {
            FeatureNote("Video quality, fit, power, bike profile and button mapping are kept per bike; everything else is shared by all bikes.")
        }
        .featureRowBackground()
    }

    private var displaySection: some View {
        Section {
            FeatureChoiceRow(title: "Video quality",
                             options: VideoQuality.allCases,
                             selection: Binding(get: { model.settings.current.videoQuality },
                                                set: { model.settings.setVideoQuality($0) }),
                             label: { Text(SettingsLabels.short($0)) },
                             detail: { Text(SettingsLabels.long($0)) })
            FeatureChoiceRow(title: "Screen fit",
                             options: ScreenFit.allCases,
                             selection: Binding(get: { model.settings.current.screenFit },
                                                set: { model.settings.setScreenFit($0) }),
                             label: { Text(SettingsLabels.short($0)) },
                             detail: { _ in Text("Mirror mode only: the dash map is always drawn at the dash's exact size.") })
            FeatureChoiceRow(title: "Mirror orientation",
                             options: MirrorOrientation.allCases,
                             selection: Binding(get: { model.settings.current.mirrorOrientation },
                                                set: { model.settings.setMirrorOrientation($0) }),
                             label: { Text(SettingsLabels.long($0)) },
                             detail: { _ in Text("While mirroring, hold the phone this way so the dash fills. Match dash follows the dash's shape (wide screen → landscape). iOS can't rotate the phone for you.") },
                             segmented: false)
            NavigationLink {
                SettingsMarginsScreen()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Screen margins…")
                        .foregroundStyle(Theme.text)
                    SettingsLabels.marginsSummary(effectiveMargins, profileDefault: !current.screenMargins.customised)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            FeatureToggleRow(title: "Disable touchscreen",
                             detail: current.forceNonTouch
                                 ? Text("On — focus/knob UI so handlebar buttons work")
                                 : Text("Off — use the bike profile (touch dashes stay touch)"),
                             isOn: Binding(get: { model.settings.current.forceNonTouch },
                                           set: { model.settings.setForceNonTouch($0) }))
            FeatureToggleRow(title: "Force touchscreen",
                             detail: current.forceTouch
                                 ? Text("On — touch UI (tap the dash)")
                                 : Text("Off — use the bike profile (1000 MT-X stays focus/knob)"),
                             isOn: Binding(get: { model.settings.current.forceTouch },
                                           set: { model.settings.setForceTouch($0) }))
        } header: {
            Text("Screen & display")
        } footer: {
            FeatureNote("Turn on Disable touchscreen if handlebar buttons do nothing: the dash UI then runs in focus/knob mode. Force touchscreen is for a touch panel on a focus/knob profile (e.g. 1000 MT-X; unlock the bike's own touch lock if needed). Video, fit and touch settings apply on the next connect — Stop first if you're already projecting.")
        }
        .featureRowBackground()
    }

    private var effectiveMargins: ScreenMargins {
        let stored = current.screenMargins
        return stored.customised ? stored : model.settings.defaultMargins(for: current.profileOverride)
    }

    private var powerSection: some View {
        Section {
            FeatureChoiceRow(title: "Power mode",
                             options: PowerMode.allCases,
                             selection: Binding(get: { model.settings.current.powerMode },
                                                set: { model.settings.setPowerMode($0) }),
                             label: { Text(SettingsLabels.short($0)) },
                             detail: { Text(SettingsLabels.long($0)) })
        } header: {
            Text("Battery & power")
        } footer: {
            FeatureNote("This app renders and encodes live video — it always draws power and warms the phone. Keep it on the bike's USB charger and use Pocket mode while riding (the dash stays live). Auto lowers the frame rate when the phone gets hot.")
        }
        .featureRowBackground()
    }

    private var profileSection: some View {
        let settings = model.settings
        return Section {
            Picker(selection: Binding(get: { model.settings.current.profileOverride },
                                      set: { model.settings.setProfileOverride($0) })) {
                ForEach(settings.profileChoices, id: \.self) { id in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: settings.profileName(id))
                        Text(SettingsLabels.profileDetail(id))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .tag(id)
                }
            } label: {
                Text("Bike profile")
                    .foregroundStyle(Theme.text)
            }
            .pickerStyle(.navigationLink)
            FeatureNote(SettingsLabels.profileDetail(current.profileOverride))
        } header: {
            Text("Bike profile")
        } footer: {
            FeatureNote("Use Legacy for CFDL16 / 450SR-style non-touch dashes if Auto picks the wrong bike. 800NK Adv = CFDL26 touch 720×712. Applies on the next connect (Stop first if projecting).")
        }
        .featureRowBackground()
    }

    private var mapSection: some View {
        Section {
            FeatureChoiceRow(title: "Units", options: MapUnits.allCases, selection: mapBinding(\.units),
                             label: { Text(SettingsLabels.short($0)) })
            FeatureChoiceRow(title: "Map theme", options: MapTheme.allCases, selection: mapBinding(\.theme),
                             label: { Text(SettingsLabels.short($0)) },
                             detail: { Text(SettingsLabels.long($0)) })
            FeatureToggleRow(title: "Voice prompts", isOn: mapBinding(\.voiceOn))
            FeatureChoiceRow(title: "Route mode", options: RouteMode.allCases, selection: mapBinding(\.routeMode),
                             label: { Text(SettingsLabels.short($0)) },
                             detail: { _ in Text("Fast = quickest roads. Fun = twistier. Circuit = go to a place and return home.") })
            FeatureToggleRow(title: "Avoid tolls", isOn: mapBinding(\.avoidTolls))
            FeatureToggleRow(title: "Avoid highways", isOn: mapBinding(\.avoidHighways))
            FeatureToggleRow(title: "Next stop details", isOn: mapBinding(\.showNextStop))
            FeatureToggleRow(title: "Auto-finish on arrive", isOn: mapBinding(\.autoFinish))
            FeatureChoiceRow(title: "Dash chrome", options: MapChrome.allCases, selection: mapBinding(\.chrome),
                             label: { Text(SettingsLabels.short($0)) })
        } header: {
            Text("Map & navigation")
        } footer: {
            FeatureNote("Auto switches the dash map to dark at night and light by day. Map settings apply instantly, also while projecting.")
        }
        .featureRowBackground()
    }

    private var tilesSection: some View {
        let defaultTemplate = BikeSettings().tileURLTemplate
        let trimmed = tileDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let valid = SettingsScreen.isValidTileTemplate(trimmed)
        return Section {
            TextField("Tile URL template", text: $tileDraft)
                .font(.footnote.monospaced())
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(saveTiles)
            if !valid {
                Label("The template needs {z}, {x} and {y} and must start with https://", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.error)
            }
            HStack {
                Button("Save", action: saveTiles)
                    .buttonStyle(.borderless)
                    .disabled(!valid || trimmed == current.tileURLTemplate)
                Spacer()
                Button("Reset to OpenStreetMap") {
                    tileDraft = defaultTemplate
                    saveTiles()
                }
                .buttonStyle(.borderless)
                .disabled(current.tileURLTemplate == defaultTemplate)
            }
        } header: {
            Text("Dash map tiles")
        } footer: {
            FeatureNote("Map data © OpenStreetMap contributors (ODbL). tile.openstreetmap.org is a free community server with a strict usage policy (no bulk downloads) — use your own tile server for heavy use. The phone map uses Apple Maps.")
        }
        .featureRowBackground()
    }

    private var routingSection: some View {
        let trimmed = orsDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return Section {
            SecureField("OpenRouteService API key", text: $orsDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(saveOrs)
            Button("Save routing key", action: saveOrs)
                .disabled(trimmed == current.orsApiKey)
        } header: {
            Text("Routing")
        } footer: {
            FeatureNote("Advanced (optional). Personal OpenRouteService key if you want one. It is never included in exported files.")
        }
        .featureRowBackground()
    }

    private var startupSection: some View {
        Section {
            FeatureToggleRow(title: "Auto-connect on launch",
                             detail: Text("When the app opens, connect to the active bike automatically. iOS can't scan for Wi-Fi, so it simply tries once."),
                             isOn: Binding(get: { model.settings.current.autoConnect },
                                           set: { model.settings.setAutoConnect($0) }))
            FeatureToggleRow(title: "Auto-recovery watchdog",
                             detail: Text("If the dash drops or projection stalls, reconnect automatically — no Stop/Start."),
                             isOn: Binding(get: { model.settings.current.autoRecovery },
                                           set: { model.settings.setAutoRecovery($0) }))
            FeatureToggleRow(title: "Log trips automatically",
                             detail: Text("Record each ride's route and stats from GPS while the dash shows the map. View them under Trips."),
                             isOn: Binding(get: { model.settings.current.logTrips },
                                           set: { model.settings.setLogTrips($0) }))
            FeatureToggleRow(title: "Keep screen on while projecting",
                             detail: Text("Stops the iPhone from auto-locking while the dash is linked, so the map keeps streaming at full quality."),
                             isOn: Binding(get: { model.settings.current.keepScreenOn },
                                           set: { model.settings.setKeepScreenOn($0) }))
        } header: {
            Text("Startup & recovery")
        }
        .featureRowBackground()
    }

    private var compatibilitySection: some View {
        Section {
            FeatureToggleRow(title: "Identify as an Android phone",
                             detail: Text("Sends an Android phone's brand and model to the dash instead of \"Apple / iPhone\". Everything else is already identical to the Android app. Turn on only if your dash refuses to connect or keeps dropping the link. Applies on the next connect."),
                             isOn: Binding(get: { model.settings.identifyAsAndroidPhone },
                                           set: { model.settings.setIdentifyAsAndroidPhone($0) }))
        } header: {
            Text("Compatibility")
        }
        .featureRowBackground()
    }

    private var privacySection: some View {
        Section {
            FeatureToggleRow(title: "Include secrets in shared logs",
                             detail: current.includeSecretsInLogs
                                 ? Text("On — passwords/serials stay in shared logs")
                                 : Text("Off — passwords and serials are redacted (recommended)"),
                             isOn: Binding(get: { model.settings.current.includeSecretsInLogs },
                                           set: { on in
                                               if on {
                                                   alert = .confirmSecrets
                                               } else {
                                                   model.settings.setIncludeSecretsInLogs(false)
                                               }
                                           }))
            if current.includeSecretsInLogs {
                Label("Shared logs will include secrets — turn off before posting publicly",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.busy)
            }
            NavigationLink {
                LogsScreen()
            } label: {
                Label("Logs", systemImage: "doc.text.magnifyingglass")
            }
        } header: {
            Text("Privacy & logs")
        } footer: {
            FeatureNote("OpenCfMoto has no account and sends nothing by itself: rides, logs and settings stay on this iPhone until you share them.")
        }
        .featureRowBackground()
    }

    private var permissionsSection: some View {
        let permissions = model.permissions
        return Section {
            LabeledContent {
                Text(SettingsLabels.location(permissions.location))
                    .foregroundStyle(permissions.location.isAuthorized ? Theme.live : Theme.busy)
            } label: {
                Label("Location", systemImage: "location")
            }
            if permissions.location.isAuthorized && !permissions.isPreciseLocation {
                FeatureNote("Precise Location is off — turn it on for turn-by-turn guidance.")
            }
            LabeledContent {
                Text(SettingsLabels.localNetwork(permissions.localNetwork))
                    .foregroundStyle(permissions.localNetwork == .granted ? Theme.live : Theme.busy)
            } label: {
                Label("Local Network", systemImage: "network")
            }
            LabeledContent {
                Text(SettingsLabels.appleMusic(model.music.authorization))
                    .foregroundStyle(model.music.authorization == .authorized ? Theme.live : Theme.busy)
            } label: {
                Label("Apple Music", systemImage: "music.note")
            }
            Button {
                permissions.openAppSettings()
            } label: {
                Label("Open Settings", systemImage: "gear")
            }
        } header: {
            Text("Permissions")
        } footer: {
            FeatureNote("Local Network lets OpenCfMoto reach the dash over its Wi-Fi. Location draws the map, guides you and logs your rides.")
        }
        .featureRowBackground()
    }

    private var backupSection: some View {
        let settings = model.settings
        let settingsFile = FeatureLazyFile<FeatureJSONKind>(make: shareErrors.guarded { try settings.exportSettings() })
        let mapFile = FeatureLazyFile<FeatureJSONKind>(make: shareErrors.guarded { try settings.exportMapData() })
        return Group {
            Section {
                ShareLink(item: settingsFile, preview: SharePreview("OpenCfMoto bike tuning")) {
                    Label("Share JSON", systemImage: "square.and.arrow.up")
                }
                Button {
                    importTarget = .settings
                    showImporter = true
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Share settings")
            } footer: {
                FeatureNote("Export bike tuning only — profile, fit, margins, buttons (no passwords, no personal prefs). Share it so others can import it; packs from the Android app import too.")
            }
            .featureRowBackground()

            Section {
                ShareLink(item: mapFile, preview: SharePreview("OpenCfMoto map data")) {
                    Label("Export map data…", systemImage: "square.and.arrow.up")
                }
                Button {
                    importTarget = .mapData
                    showImporter = true
                } label: {
                    Label("Import map data…", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Map data")
            } footer: {
                FeatureNote("Favorites, markers, history, home, parked spot and map preferences, in the same format as the Android app. The routing key is never exported.")
            }
            .featureRowBackground()
        }
    }

    private var linksSection: some View {
        Section {
            NavigationLink {
                GarageScreen()
            } label: {
                Label("Garage", systemImage: "bicycle")
            }
            NavigationLink {
                ControlsScreen()
            } label: {
                Label("Controls", systemImage: "dpad")
            }
            NavigationLink {
                AboutScreen()
            } label: {
                Label("About", systemImage: "info.circle")
            }
            Button {
                model.permissions.resetOnboarding()
                dismiss()
            } label: {
                Label("Show onboarding again", systemImage: "arrow.counterclockwise.circle")
            }
        }
        .featureRowBackground()
    }

    // MARK: Actions

    private func loadDrafts() {
        guard !draftsLoaded else { return }
        tileDraft = current.tileURLTemplate
        orsDraft = current.orsApiKey
        draftsLoaded = true
    }

    private func saveTiles() {
        let trimmed = tileDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SettingsScreen.isValidTileTemplate(trimmed), trimmed != current.tileURLTemplate else { return }
        model.settings.setTileURLTemplate(trimmed)
    }

    private func saveOrs() {
        let trimmed = orsDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != current.orsApiKey else { return }
        model.settings.setOrsApiKey(trimmed)
    }

    /// `https://…{z}…{x}…{y}…` (iOS App Transport Security blocks plain http tile servers).
    static func isValidTileTemplate(_ template: String) -> Bool {
        template.lowercased().hasPrefix("https://")
            && template.contains("{z}") && template.contains("{x}") && template.contains("{y}")
            && !template.contains(" ")
    }

    private func handleImportPick(_ result: Result<[URL], any Error>, target: SettingsImportTarget) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { @MainActor in
                do {
                    let text = try await FeatureFileReader.readText(url, maxBytes: 4 * 1024 * 1024)
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        present(.failure(String(localized: "Empty file")))
                    } else {
                        present(.confirmImport(target, text))
                    }
                } catch {
                    present(.failure(FeatureErrorText.describe(error)))
                }
            }
        case .failure(let error):
            present(.failure(FeatureErrorText.describe(error)))
        }
    }

    /// Shows an alert once the picker / the previous alert finished dismissing.
    private func present(_ next: SettingsAlert) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            alert = next
        }
    }

    @ViewBuilder
    private func alertActions(_ state: SettingsAlert) -> some View {
        switch state {
        case .confirmImport(let target, let text):
            Button("Import") {
                let outcome = target == .settings
                    ? model.settings.importSettings(text)
                    : model.settings.importMapData(text)
                present(.result(ok: outcome.ok, message: outcome.message))
            }
            Button("Cancel", role: .cancel) {}
        case .confirmSecrets:
            Button("Include secrets", role: .destructive) {
                model.settings.setIncludeSecretsInLogs(true)
            }
            Button("Cancel", role: .cancel) {}
        case .result, .failure, .exportFailed:
            Button("Close", role: .cancel) {}
        }
    }
}

enum SettingsImportTarget: Equatable {
    case settings
    case mapData
}

/// The one alert of the Settings screen.
enum SettingsAlert {
    case confirmImport(SettingsImportTarget, String)
    case result(ok: Bool, message: String)
    case failure(String)
    case exportFailed(String)
    case confirmSecrets

    var title: Text {
        switch self {
        case .confirmImport(let target, _):
            return target == .settings ? Text("Import settings?") : Text("Import map data?")
        case .result(let ok, _):
            return ok ? Text("Import finished") : Text("Import failed")
        case .failure:
            return Text("Import failed")
        case .exportFailed:
            return Text("Export failed")
        case .confirmSecrets:
            return Text("Include secrets in shared logs?")
        }
    }

    var message: Text {
        switch self {
        case .confirmImport(let target, _):
            if target == .settings {
                return Text("Replace the bike tuning of the active bike — profile, video quality, fit, power, margins, handlebar buttons and touch settings?\n\nPersonal prefs (map theme, saved places, auto-connect…) are left alone. Wi-Fi passwords are never imported.")
            }
            return Text("Replace your favorites, markers, history, home and parked spot, and apply the map preferences in the file?")
        case .result(_, let message):
            return Text(verbatim: message)
        case .failure(let message), .exportFailed(let message):
            return Text(verbatim: message)
        case .confirmSecrets:
            return Text("Wi-Fi passwords and serial numbers will appear in shared logs and problem reports. Only turn this on for a private debugging session.")
        }
    }
}

#Preview("Settings") {
    NavigationStack {
        SettingsScreen()
    }
    .environment(AppModel.preview())
}
