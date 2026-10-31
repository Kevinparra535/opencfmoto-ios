// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) HudViewActivity.kt ("Dash view": watch and drive the live dash
// from the phone — touch, pad, fullscreen) for the iOS own-UI path: the picture is the very display
// list the dash encoder draws (or a phone-only preview on a chosen canvas when no dash is linked),
// taps / drags / long-presses are dash touches in canvas pixels, the keypad sends handlebar keys,
// and GPS runs while the view is open so the map moves. "Type on phone" from the dash search shows
// a search field here when this screen is the visible one.

import SwiftUI
import UIKit
import OpenCfMotoAppModel
import OpenCfMotoApple
import OpenCfMotoCore

struct DashPreviewScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale

    @State private var feed = DashPreviewFeed()
    @State private var isVisible = false
    @State private var showsDashSearch = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        GeometryReader { geo in
            if geo.size.width > geo.size.height * 1.15 {
                // Landscape: picture left, controls right.
                HStack(alignment: .top, spacing: 14) {
                    surface
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    ScrollView {
                        controls
                    }
                    .frame(width: min(320, geo.size.width * 0.38))
                }
                .padding(.horizontal, Theme.padding)
                .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        surface
                        controls
                    }
                    .padding(Theme.padding)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Dash view")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    MainRideMode.enter(model.ride)
                } label: {
                    Label("Ride Mode", systemImage: "moon.zzz.fill")
                }
            }
        }
        .task(id: scenePhase == .active) { @MainActor in
            guard scenePhase == .active else { return }
            await feed.run(ride: model.ride, renderer: AppPlatform.shared.dashRenderer)
        }
        .onAppear {
            isVisible = true
            model.ride.startLocationPreview()
            if model.navigation.typeOnPhoneRequested { openDashSearch() }
        }
        .onDisappear {
            isVisible = false
            model.ride.stopLocationPreview()
        }
        .onChange(of: model.navigation.typeOnPhoneRequested) { _, requested in
            if requested { openDashSearch() }
        }
    }

    // MARK: - Picture

    private var surface: some View {
        DashPreviewSurface(
            frame: feed.frame,
            fallbackCanvas: model.ride.canvasSize,
            onTouch: { action, point in
                let touch = DashTouch(action: action, pointerId: 0, x: point.x, y: point.y,
                                      time: AppPlatform.shared.now())
                model.ride.sendPreviewInput(.touch(touch))
            },
            onSizeChange: { size in
                let canvasWidth = max(model.ride.canvasSize.width, 1)
                feed.renderScale = Double(size.width * displayScale) / canvasWidth
            }
        )
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        @Bindable var ride = model.ride
        VStack(alignment: .leading, spacing: 14) {
            if showsDashSearch {
                dashSearchField
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(ride.isProjecting ? Theme.live : Theme.idle)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    if ride.isProjecting {
                        Text("Live — this is what the dash shows")
                    } else {
                        Text("Preview — no dash connected")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.text)
                Text(verbatim: MainStrings.canvasText(ride.canvasSize))
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityLabel(Text("Canvas \(MainStrings.canvasText(ride.canvasSize))"))
                if !ride.gpsStatus.isEmpty {
                    Label {
                        Text(verbatim: ride.gpsStatus)
                    } icon: {
                        Image(systemName: "location")
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                }
            }

            if !ride.isProjecting {
                HStack {
                    Text("Preview canvas")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 8)
                    Picker(selection: $ride.previewCanvas) {
                        ForEach(DashPreviewCanvas.allCases) { canvas in
                            Text(MainStrings.previewCanvasLabel(canvas)).tag(canvas)
                        }
                    } label: {
                        Text("Preview canvas")
                    }
                    .pickerStyle(.menu)
                }
            }

            HStack {
                Spacer(minLength: 0)
                DashKeypad { key in
                    model.ride.sendPreviewInput(.key(key))
                }
                Spacer(minLength: 0)
            }

            Text("Tap, drag and long-press the picture like the dash touchscreen. The keypad works like the handlebar buttons.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - "Type on phone" (input-controls.md §6.7)

    private var dashSearchField: some View {
        @Bindable var navigation = model.navigation
        return VStack(alignment: .leading, spacing: 8) {
            MainSectionCaption(text: "Bike dash search")
            HStack(spacing: 8) {
                TextField(text: $navigation.query, prompt: Text("Bike dash search — type here")) {
                    Text("Bike dash search — type here")
                }
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { model.navigation.searchNow() }
                .autocorrectionDisabled()
                .padding(10)
                .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Button("Done") {
                    searchFocused = false
                    showsDashSearch = false
                }
                .font(.headline)
            }
            Text("Results appear on the dash.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.brand, lineWidth: 2))
    }

    private func openDashSearch() {
        guard isVisible, scenePhase == .active else { return }
        model.navigation.acknowledgeTypeOnPhone()
        showsDashSearch = true
        searchFocused = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

#Preview {
    NavigationStack {
        DashPreviewScreen()
    }
    .environment(AppModel.preview())
    .preferredColorScheme(.dark)
}
