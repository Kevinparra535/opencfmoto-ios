// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) MainActivity.kt:580-631 (home search row, app-features §7.5.7):
// "Search a place or address…" + Go. Go hands the text to the shared `NavigationModel` and opens
// the Map hub (one navigation session: a place previewed there shows on the dash too). Empty →
// "Type a place to search on the map". "Type on phone" from the dash search highlights this field
// for 2.5 s with the hint "Bike dash search — type here", a light haptic and a banner; while the
// rider types for the dash, every edit goes to `NavigationModel.query` (its 350 ms / ≥ 2 characters
// debounce feeds the dash suggestions) and Go stays on Home ("Searching "<q>" on the dash").
// The request is taken only while Home is the visible screen (MainTypeOnPhone.swift): also when
// it arrived while the phone was locked, under Ride Mode or behind a sheet — once that ends.

import SwiftUI
import UIKit
import OpenCfMotoAppModel

struct HomeSearchField: View {
    @Environment(AppModel.self) private var model
    @Environment(\.mainRouter) private var router
    @FocusState private var focused: Bool
    @State private var text = ""
    /// The dash asked to type here: live suggestions, Go keeps the rider on Home.
    @State private var typingForDash = false
    @State private var highlighted = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(highlighted ? Theme.brand : Theme.textSecondary)
                .accessibilityHidden(true)
            TextField(text: $text,
                      prompt: typingForDash ? Text("Bike dash search — type here") : Text("Search a place or address…")) {
                Text("Search a place or address…")
            }
            .focused($focused)
            .submitLabel(.go)
            .onSubmit(go)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.words)
            .foregroundStyle(Theme.text)

            Button(action: go) {
                Text("Go")
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.brand, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Searches the map for this place"))
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
            .strokeBorder(highlighted ? Theme.brand : Theme.outline, lineWidth: highlighted ? 2 : 1))
        .onChange(of: text) { _, newValue in
            if typingForDash, model.navigation.query != newValue { model.navigation.query = newValue }
        }
        // Home is the root of the stack: it is the visible screen exactly when nothing is pushed.
        .mainTypeOnPhone(isVisible: router?.path.isEmpty == true) {
            handleTypeOnPhone()
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { typingForDash = false }
        }
        .task(id: highlighted) { @MainActor in
            guard highlighted else { return }
            try? await Task.sleep(for: .milliseconds(2500))
            if !Task.isCancelled { highlighted = false }
        }
    }

    private func go() {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            model.showBanner(String(localized: "Type a place to search on the map"))
            return
        }
        model.navigation.query = query
        model.navigation.searchNow()
        focused = false
        if typingForDash {
            typingForDash = false
            model.showBanner(String(localized: "Searching \"\(query)\" on the dash"))
        } else {
            router?.open(.navigate)
        }
    }

    /// Home is visible, active and uncovered (the Map hub / Dash view handle it when they are on top).
    private func handleTypeOnPhone() {
        model.navigation.acknowledgeTypeOnPhone()
        typingForDash = true
        highlighted = true
        text = model.navigation.query
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        model.showBanner(String(localized: "Bike search open — type here. Results appear on the dash."))
        focused = true
        // Home may only just be coming back (unlock, Ride Mode exit, a pop from another screen) and
        // SwiftUI drops a focus asked before the field is on screen: ask once more shortly after.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard highlighted, !focused else { return }
            typingForDash = true
            focused = true
        }
    }
}
