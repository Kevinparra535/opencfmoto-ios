// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) ControlsActivity.kt, ButtonMappingActivity.kt, SetupActivity.kt
// (Handlebar timing section)
//
// Handlebar controls (docs/spec/input-controls.md §7–§9; app-features.md §2.8, §9.8):
// - the master switch "Handlebar buttons drive the dash" (per bike, Android `controlAa`);
// - the OPT-IN phone media remote (MPRemoteCommandCenter + silent audio session — it pauses other
//   music, it is experimental and not every dash sends media keys) and the experimental ▲/▼
//   volume path; nothing is enabled without the rider confirming;
// - a live button tester (last raw event / last decoded command);
// - left-cluster presets (Apply preset… with confirmation, Clear preset; plus the iOS-only
//   "★ only" mapping), the 9-gesture mapping editor (+ Reset to defaults), timing (double-tap
//   200/300/450/1000 ms, hold detection, hold delay 500/600/800 ms), saved places 1–3 and
//   "Teach my handlebar" (Present / Absent / Unknown per source, Reset to untested; the engine
//   also learns them by itself).

import SwiftUI
import OpenCfMotoCore
import OpenCfMotoAppModel

@MainActor
struct ControlsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRemote = false
    @State private var pendingPreset: ControlsLabels.PresetChoice?
    @State private var slotNames = ["", "", ""]
    @State private var slotQueries = ["", "", ""]

    var body: some View {
        Form {
            handlebarSection
            remoteSection
            testerSection
            clusterSection
            mappingSection
            timingSection
            savedPlacesSection
            presenceSection
        }
        .navigationTitle("Controls")
        .featureScreenChrome()
        .onAppear(perform: loadSlots)
        .onDisappear(perform: commitDirtySlots)
        .onChange(of: model.settings.savedPlaces) { old, new in refreshSlots(old: old, new: new) }
        .alert("Use the phone media remote?", isPresented: $confirmRemote) {
            Button("Turn on") { model.controls.setRemoteEnabled(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("OpenCfMoto will play silent audio to become the iPhone's Now Playing app, so the bike's ◀ ▶ ★ buttons reach the dash. Music from other apps pauses while this is on. Experimental: not every dash sends these buttons.")
        }
        .confirmationDialog(Text(verbatim: pendingPreset.map(ControlsLabels.title) ?? ""),
                            isPresented: Binding(get: { pendingPreset != nil },
                                                 set: { if !$0 { pendingPreset = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingPreset) { choice in
            Button("Apply preset") { apply(choice) }
            Button("Cancel", role: .cancel) {}
        } message: { choice in
            Text(verbatim: ControlsLabels.summary(choice))
                + Text(verbatim: "\n\n")
                + Text("Replace the current mapping for this bike? Saved places are kept.")
        }
    }

    private var current: BikeSettings { model.settings.current }

    // MARK: Sections

    private var handlebarSection: some View {
        Section {
            FeatureToggleRow(title: "Handlebar buttons drive the dash",
                             detail: Text("While on, the bike's ◀ ▶ ★ buttons move the focus, select and open the menu of the dash UI. Turn it off if you want them to control your music again."),
                             isOn: Binding(get: { model.settings.current.handlebarControl },
                                           set: { model.settings.setHandlebarControl($0) }))
        } header: {
            Text("Handlebar buttons")
        } footer: {
            FeatureNote("Touch dashes (800NK Advanced, 800MT): just tap the dash. Handlebar control is meant for non-touch dashes such as the 450SR.")
        }
        .featureRowBackground()
    }

    private var remoteSection: some View {
        let controls = model.controls
        return Section {
            FeatureToggleRow(title: "Use the phone media remote",
                             detail: Text("Experimental. OpenCfMoto becomes the iPhone's Now Playing app with a silent audio session so the ◀ ▶ ★ buttons the bike sends over Bluetooth reach the dash UI."),
                             isOn: Binding(get: { model.controls.isRemoteEnabled },
                                           set: { on in
                                               if on {
                                                   confirmRemote = true
                                               } else {
                                                   model.controls.setRemoteEnabled(false)
                                               }
                                           }))
                .disabled(!controls.isRemoteAvailable)
            if !controls.isRemoteAvailable {
                FeatureNote("Not available on this device.")
            }
            FeatureToggleRow(title: "Volume buttons ▲/▼ (experimental)",
                             detail: Text("Also read the dash's ▲/▼ by watching the phone volume. Each press really changes the volume and shows the volume indicator."),
                             isOn: Binding(get: { model.controls.volumeButtonsEnabled },
                                           set: { model.controls.setVolumeButtonsEnabled($0) }))
                .disabled(!controls.isRemoteEnabled)
        } header: {
            Text("Phone media remote")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                FeatureNote("iOS gives these buttons to one app at a time: while this is on, music from other apps pauses (press ★ in the music app, or turn this off, to get it back). Pair the phone with the bike over Bluetooth first. Off in mirror mode. May not be accepted in App Store builds.")
                FeatureNote("Starting Apple Music from the dash gives these buttons to the music until you pause it.")
            }
        }
        .featureRowBackground()
    }

    private var testerSection: some View {
        let controls = model.controls
        return Section {
            LabeledContent {
                Text(verbatim: controls.lastRawEvent ?? "—")
                    .font(.body.monospaced())
                    .foregroundStyle(Theme.text)
            } label: {
                Text("Last button")
            }
            .accessibilityAddTraits(.updatesFrequently)
            LabeledContent {
                Text(verbatim: controls.lastCommand ?? "—")
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.trailing)
            } label: {
                Text("Last command")
            }
            .accessibilityAddTraits(.updatesFrequently)
        } header: {
            Text("Button tester")
        } footer: {
            FeatureNote(controls.isRemoteEnabled
                        ? Text("Press a handlebar button: the raw event and the command it triggers show up here.")
                        : Text("Turn on the phone media remote to test the buttons."))
        }
        .featureRowBackground()
    }

    private var clusterSection: some View {
        Section {
            FeatureNote("CFMOTO ships a few different left pods. Pick the one that matches your bars — doubles and long-press do not work the same on every cluster.")
            if let preset = current.clusterPreset {
                Text("Active: \(ControlsLabels.presetTitle(preset))")
                    .foregroundStyle(Theme.text)
            } else {
                Text("No preset — shipped defaults / your custom map")
                    .foregroundStyle(Theme.textSecondary)
            }
            Menu {
                ForEach(ButtonClusterPreset.allCases, id: \.self) { preset in
                    Button {
                        pendingPreset = .preset(preset)
                    } label: {
                        Text(verbatim: ControlsLabels.presetTitle(preset))
                    }
                }
                Button {
                    pendingPreset = .singleButton
                } label: {
                    Text(verbatim: ControlsLabels.title(.singleButton))
                }
            } label: {
                Label("Apply preset…", systemImage: "slider.horizontal.3")
            }
            Button("Clear preset") { model.settings.clearClusterPreset() }
                .disabled(current.clusterPreset == nil)
        } header: {
            Text("Your left switch cluster")
        }
        .featureRowBackground()
    }

    private var mappingSection: some View {
        let slots = model.settings.savedPlaces
        let unsetSlotMapped = ButtonGesture.allCases.contains { gesture in
            guard let index = ControlsLabels.savedPlaceIndex(action(for: gesture)) else { return false }
            return !(slots.indices.contains(index) && slots[index].isSet)
        }
        return Section {
            ForEach(ButtonGesture.allCases, id: \.self) { gesture in
                Picker(selection: Binding(get: { action(for: gesture) },
                                          set: { model.settings.setButtonAction($0, for: gesture) })) {
                    ForEach(ButtonAction.allCases, id: \.self) { action in
                        ControlsLabels.action(action, slots: slots)
                            .tag(action)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ControlsLabels.gesture(gesture))
                            .foregroundStyle(Theme.text)
                        Text(ControlsLabels.hint(gesture))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        if let note = ControlsLabels.iosNote(gesture) {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(Theme.busy)
                        }
                        ControlsLabels.action(action(for: gesture), slots: slots)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.brand)
                    }
                }
                .pickerStyle(.navigationLink)
            }
            if unsetSlotMapped {
                Label("A gesture navigates to a saved place that is not set yet — add its address below.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.busy)
            }
            Button("Reset to defaults") { model.settings.resetButtonMap() }
                .disabled(isDefaultMapping)
        } header: {
            Text("Button mapping")
        } footer: {
            FeatureNote("Choose what each handlebar gesture does on the dash. Changes apply on the next press — no reconnect needed. ▲/▼ only work with Volume buttons on.")
        }
        .featureRowBackground()
    }

    private var timingSection: some View {
        let timing = current.buttonTiming
        return Section {
            Picker(selection: Binding(get: { ButtonTiming.normalizedDoubleTapMs(model.settings.current.buttonTiming.doubleTapMs) },
                                      set: { value in
                                          var updated = model.settings.current.buttonTiming
                                          updated.doubleTapMs = value
                                          model.settings.setButtonTiming(updated)
                                      })) {
                ForEach(ButtonTiming.doubleTapChoices, id: \.self) { ms in
                    Text(SettingsLabels.doubleTap(ms)).tag(ms)
                }
            } label: {
                Text("Double-tap delay")
                    .foregroundStyle(Theme.text)
            }
            .pickerStyle(.navigationLink)

            FeatureToggleRow(title: "Hold detection",
                             detail: timing.holdsEnabled
                                 ? Text("On — press-and-hold can fire hold gestures")
                                 : Text("Off — every release is a tap / ×2 (use with a long double-tap delay)"),
                             isOn: Binding(get: { model.settings.current.buttonTiming.holdsEnabled },
                                           set: { on in
                                               var updated = model.settings.current.buttonTiming
                                               updated.holdsEnabled = on
                                               model.settings.setButtonTiming(updated)
                                           }))

            Picker(selection: Binding(get: { ButtonTiming.normalizedHoldMs(model.settings.current.buttonTiming.holdMs) },
                                      set: { value in
                                          var updated = model.settings.current.buttonTiming
                                          updated.holdMs = value
                                          model.settings.setButtonTiming(updated)
                                      })) {
                ForEach(ButtonTiming.holdChoices, id: \.self) { ms in
                    Text(SettingsLabels.hold(ms)).tag(ms)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hold delay")
                        .foregroundStyle(Theme.text)
                    if !timing.holdsEnabled {
                        Text("Ignored while Hold detection is Off")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .pickerStyle(.navigationLink)
            .disabled(!timing.holdsEnabled)
        } header: {
            Text("Handlebar timing")
        } footer: {
            FeatureNote("Timing is shared by all bikes and applies on the next press.")
        }
        .featureRowBackground()
    }

    private var savedPlacesSection: some View {
        Section {
            ForEach(0 ..< 3, id: \.self) { slot in
                slotEditor(slot)
            }
        } header: {
            Text("Saved places")
        } footer: {
            FeatureNote("Map a gesture to Navigate to saved place 1–3 and one press starts turn-by-turn there — hands-free.")
        }
        .featureRowBackground()
    }

    private func slotEditor(_ slot: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved place \(String(slot + 1))")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
            TextField("Name (e.g. Home)", text: $slotNames[slot])
                .textInputAutocapitalization(.words)
                .submitLabel(.next)
            TextField("Address or place", text: $slotQueries[slot])
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { commitSlot(slot) }
            HStack {
                ControlsLabels.savedPlace(slot, slots: model.settings.savedPlaces)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                Spacer()
                Button("Save") { commitSlot(slot) }
                    .buttonStyle(.borderless)
                    .disabled(!isDirty(slot))
            }
        }
        .padding(.vertical, 4)
    }

    /// Android "Teach my handlebar…": the rider tells which sources this bike sends (Present /
    /// Absent / Unknown per source) or resets both to untested; the live engine follows.
    private var presenceSection: some View {
        let presence = model.settings.presence
        return Section {
            FeatureNote("Which buttons does this bike actually send? Mark a source Absent if it never reaches the phone, or leave it Unknown and OpenCfMoto finds out by itself.")
            FeatureChoiceRow(title: "▲/▼ volume rocker",
                             options: ControlsLabels.teachChoices,
                             selection: Binding(get: { model.settings.presence.volumeRocker },
                                                set: { model.settings.setVolumeRockerPresence($0) }),
                             label: { ControlsLabels.teachChoice($0) })
            FeatureChoiceRow(title: "◀/▶/★ track keys",
                             options: ControlsLabels.teachChoices,
                             selection: Binding(get: { model.settings.presence.trackKeys },
                                                set: { model.settings.setTrackKeysPresence($0) }),
                             label: { ControlsLabels.teachChoice($0) })
            Button("Reset to untested") { model.settings.resetHandlebarPresence() }
                .disabled(presence.volumeRocker == .unknown && presence.trackKeys == .unknown)
        } header: {
            Text("Teach my handlebar")
        } footer: {
            FeatureNote("OpenCfMoto learns which buttons this bike sends: ◀/▶/★ track keys and, with Volume buttons on, ▲/▼. After about 90 s of streaming with no ▲/▼ the rocker is marked absent automatically.")
        }
        .featureRowBackground()
    }

    // MARK: Mapping helpers

    private func action(for gesture: ButtonGesture) -> ButtonAction {
        model.settings.current.buttonMap[gesture]
            ?? HandlebarPresets.iosDefaultMapping[gesture]
            ?? gesture.defaultAction
    }

    private var isDefaultMapping: Bool {
        ButtonGesture.allCases.allSatisfy { gesture in
            action(for: gesture) == (HandlebarPresets.iosDefaultMapping[gesture] ?? gesture.defaultAction)
        }
    }

    private func apply(_ choice: ControlsLabels.PresetChoice) {
        let settings = model.settings
        switch choice {
        case .preset(let preset):
            settings.applyClusterPreset(preset)
        case .singleButton:
            settings.clearClusterPreset()
            for gesture in ButtonGesture.allCases {
                let target = HandlebarPresets.iosSingleButtonMapping[gesture] ?? gesture.defaultAction
                if action(for: gesture) != target {
                    settings.setButtonAction(target, for: gesture)
                }
            }
            if !settings.current.handlebarControl {
                settings.setHandlebarControl(true)
            }
        }
        pendingPreset = nil
    }

    // MARK: Saved places

    private func storedSlot(_ index: Int) -> SavedPlaceSlot {
        let slots = model.settings.savedPlaces
        return slots.indices.contains(index) ? slots[index] : SavedPlaceSlot()
    }

    private func loadSlots() {
        for index in 0 ..< 3 {
            let slot = storedSlot(index)
            slotNames[index] = slot.name
            slotQueries[index] = slot.query
        }
    }

    /// The stored slots changed (a save, an import): take the new values for every slot the rider
    /// is not editing, keep the drafts of the others.
    private func refreshSlots(old: [SavedPlaceSlot], new: [SavedPlaceSlot]) {
        for index in 0 ..< 3 {
            let before = old.indices.contains(index) ? old[index] : SavedPlaceSlot()
            let after = new.indices.contains(index) ? new[index] : SavedPlaceSlot()
            let name = slotNames[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let query = slotQueries[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let untouched = name == before.name && query == before.query
            let saved = name == after.name && query == after.query
            if untouched || saved {
                slotNames[index] = after.name
                slotQueries[index] = after.query
            }
        }
    }

    private func isDirty(_ index: Int) -> Bool {
        let slot = storedSlot(index)
        return slotNames[index].trimmingCharacters(in: .whitespacesAndNewlines) != slot.name
            || slotQueries[index].trimmingCharacters(in: .whitespacesAndNewlines) != slot.query
    }

    private func commitSlot(_ index: Int) {
        guard isDirty(index) else { return }
        model.settings.setSavedPlace(index,
                                     name: slotNames[index].trimmingCharacters(in: .whitespacesAndNewlines),
                                     query: slotQueries[index].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Android saves the slots when the screen pauses.
    private func commitDirtySlots() {
        for index in 0 ..< 3 { commitSlot(index) }
    }
}

#Preview("Controls") {
    NavigationStack {
        ControlsScreen()
    }
    .environment(AppModel.preview())
}
