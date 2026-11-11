// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) GpxActivity.kt (Map hub), MainActivity.kt (home search,
// "type on phone" hand-off)
//
// Map hub (docs/spec/navigation-dash.md §7–§9, §11.8, §14; app-features.md §7.5.7). One MapKit map
// shows what the ONE navigation session publishes, so a preview or route started here appears on
// the dash and vice-versa:
// - search field bound to NavigationModel.query (debounced 350 ms in the model, ≥ 2 characters),
//   keyboard Search = searchNow(); POI chips → searchNearby; idle list when the query is empty;
// - route preview card (route chips → selectRoute, Go, Cancel/Done, Circuit, ★ Save, Home, Marker),
//   active navigation card (cue + metrics, End, Recalc), arrival card, free-ride bar (Free ride,
//   Park here, Go Home, Set Home here, parked bike, GPX import);
// - GPX import (.fileImporter → security-scoped read off the main actor → previewGpx): like a file
//   opened from another app, the track is first shown as a preview with «Seguir este track» /
//   «Cancelar» (UI/UX P0, UX-17) and replaces nothing until followed;
// - the dash's "type on the phone" request focuses the search field (highlight + haptic) and is
//   acknowledged — only while this screen is the visible one (not under the Dash view it pushed,
//   pocket mode or the lock screen: MainTypeOnPhone.swift); toasts / last error are shown as banners
//   (VoiceOver announces toasts);
// - "Show dash" opens the phone preview of the dash picture.

import SwiftUI
import MapKit
import UIKit
import OpenCfMotoCore
import OpenCfMotoAppModel

@MainActor
struct NavigateScreen: View {
    @Environment(AppModel.self) private var model
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selectedPlace: Place?
    @State private var showingNearby = false
    @State private var panelDismissed = false
    @State private var dashSearchHint = false
    @State private var showGpxImporter = false
    @State private var importError: String?
    @State private var hapticTrigger = 0
    /// On screen (false while the Dash view it pushed covers it).
    @State private var isVisible = false
    @FocusState private var searchFocused: Bool

    private var lease: FeatureLocationLease { .mapHub }

    var body: some View {
        let navigation = model.navigation
        let snapshot = navigation.snapshot
        NavigateMapLayer(snapshot: snapshot,
                         results: panelVisible || selectedPlace != nil ? navigation.results : [],
                         saved: [navigation.home, navigation.parked].compactMap { $0 },
                         gpxPreview: navigation.pendingGpx,
                         camera: $camera,
                         selection: $selectedPlace)
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .safeAreaInset(edge: .bottom, spacing: 0) { footer(snapshot) }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .featureScreenChrome()
            .fileImporter(isPresented: $showGpxImporter,
                          allowedContentTypes: FeatureFileTypes.gpxImport,
                          allowsMultipleSelection: false) { result in
                handleGpxPick(result)
            }
            .sensoryFeedback(.impact(weight: .light), trigger: hapticTrigger)
            .animation(.easeInOut(duration: 0.2), value: navigation.toast)
            .onAppear {
                isVisible = true
                // The opened track's card is the question on screen (review PH-1: only then does it hold
                // the «Modo bolsillo» offer back).
                navigation.isGpxPreviewOnScreen = navigation.pendingGpx != nil
                lease.acquire(model)
                if navigation.pendingGpx != nil {
                    fitGpxPreview()
                } else if snapshot.preview != nil {
                    fitPreview()
                } else if snapshot.mode.isNavigating {
                    followRider()
                }
            }
            .onDisappear {
                isVisible = false
                model.navigation.isGpxPreviewOnScreen = false
                lease.release(model)
            }
            .mainTypeOnPhone(isVisible: isVisible) {
                openDashSearch()
            }
            .onChange(of: NavigatePreviewFraming(snapshot.preview)) { _, framing in
                if framing != nil { fitPreview() }
            }
            .onChange(of: navigation.pendingGpx?.id) { _, id in
                model.navigation.isGpxPreviewOnScreen = id != nil && isVisible
                if id != nil {
                    // An opened track is the question on screen: its card replaces the search list.
                    searchFocused = false
                    showingNearby = false
                    selectedPlace = nil
                    panelDismissed = true
                    fitGpxPreview()
                }
            }
            .onChange(of: snapshot.mode.isNavigating) { _, navigating in
                guard navigating && snapshot.preview == nil else { return }
                // An opened track's preview keeps its framing over a route that starts meanwhile (review PH-4).
                if model.navigation.pendingGpx != nil { fitGpxPreview() } else { followRider() }
            }
            .onChange(of: navigation.query) { _, _ in
                panelDismissed = false
            }
            .onChange(of: searchFocused) { _, focused in
                if focused { panelDismissed = false }
            }
            .onChange(of: selectedPlace) { _, place in
                guard let place else { return }
                // The previewed place already has its card.
                if let previewed = model.navigation.snapshot.preview?.place, place == previewed {
                    selectedPlace = nil
                    return
                }
                // A marker was tapped while the list was open: show its card instead of the list.
                searchFocused = false
                panelDismissed = true
            }
            .onChange(of: navigation.toast) { _, toast in
                if let toast, !toast.isEmpty {
                    UIAccessibility.post(notification: .announcement, argument: toast)
                }
            }
    }

    // MARK: Panel state

    /// The result / suggestion list is open (typing, a chip search, or the dash asked to type).
    private var panelVisible: Bool {
        if searchFocused { return true }
        if panelDismissed { return false }
        return !model.navigation.query.isEmpty || showingNearby
    }

    // MARK: Header (search + chips + results)

    @ViewBuilder
    private var header: some View {
        let navigation = model.navigation
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                searchField
                if panelVisible {
                    Button("Cancel") { closePanel(clearQuery: true) }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.brand)
                }
            }
            if dashSearchHint && navigation.query.isEmpty {
                NavigateBanner(text: String(localized: "Bike search open — type here. Results appear on the dash."),
                               kind: .info)
            }
            if panelVisible {
                NavigateSearchPanel(showingNearby: showingNearby,
                                    onChosen: { closePanel(clearQuery: false) },
                                    onChip: { searchChip($0) },
                                    maxHeight: searchFocused ? 260 : 400)
            } else {
                NavigatePoiChips(chips: navigation.poiChips, onTap: { searchChip($0) })
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Theme.background.opacity(0.9))
    }

    private var searchField: some View {
        let navigation = model.navigation
        let query = Binding(get: { model.navigation.query }, set: { model.navigation.query = $0 })
        let prompt = dashSearchHint ? Text("Bike dash search — type here") : Text("Search a place or address…")
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
            TextField(text: query, prompt: prompt) {
                Text("Search")
            }
            .focused($searchFocused)
            .submitLabel(.search)
            .onSubmit { model.navigation.searchNow() }
            .autocorrectionDisabled()
            .foregroundStyle(Theme.text)
            if navigation.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Searching…"))
            }
            if !navigation.query.isEmpty {
                Button {
                    model.navigation.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textSecondary)
                        .frame(minWidth: 32, minHeight: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
        .background(Theme.surfaceHigh, in: Capsule())
        .overlay(Capsule().strokeBorder(dashSearchHint ? Theme.brand : Theme.outline,
                                        lineWidth: dashSearchHint ? 2 : 1))
    }

    // MARK: Footer (banners + the card of the current state)

    @ViewBuilder
    private func footer(_ snapshot: NavSnapshot) -> some View {
        let navigation = model.navigation
        VStack(spacing: 8) {
            if let toast = navigation.toast, !toast.isEmpty {
                NavigateBanner(text: toast, kind: .info)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let error = visibleError {
                NavigateBanner(text: error, kind: .error, onDismiss: { dismissError() })
            }
            if locationDenied {
                NavigateBanner(text: String(localized: "Location access is off. Turn it on to see your position, search nearby and build routes."),
                               kind: .error,
                               actionTitle: "Open Settings",
                               action: { model.permissions.openAppSettings() })
            }
            if !panelVisible {
                if let gpx = navigation.pendingGpx {
                    // UX-17: an opened / picked GPX track waits here; nothing replaced until followed.
                    NavigateGpxPreviewCard(preview: gpx)
                } else if let place = selectedPlace {
                    NavigatePlaceCard(place: place, onClose: { selectedPlace = nil })
                } else if let preview = snapshot.preview {
                    NavigatePreviewCard(preview: preview)
                } else if let arrival = snapshot.arrival {
                    NavigateArrivalCard(arrival: arrival, onFindParking: { findParking() })
                } else if snapshot.mode.isNavigating {
                    NavigateRouteCard(snapshot: snapshot)
                } else {
                    NavigateIdleBar(onChooseGpx: { showGpxImporter = true })
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .padding(.top, 4)
    }

    private var visibleError: String? {
        if let importError { return importError }
        guard let error = model.navigation.lastError, !error.isEmpty else { return nil }
        return error
    }

    private var locationDenied: Bool {
        let permission = model.permissions.location
        return permission == .denied || permission == .restricted
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showGpxImporter = true
            } label: {
                Label("Choose GPX file…", systemImage: "doc.badge.plus")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            // A root route (not a nested destination): the stack knows the Dash view is on top, so an opened
            // GPX track pops back to this hub's card instead of staying hidden under it (review PH-1).
            NavigationLink(value: MainRoute.dashPreview) {
                Label("Show dash", systemImage: "rectangle.inset.filled")
            }
        }
    }

    // MARK: Actions

    private func closePanel(clearQuery: Bool) {
        searchFocused = false
        showingNearby = false
        dashSearchHint = false
        panelDismissed = true
        if clearQuery { model.navigation.clearSearch() }
    }

    private func searchChip(_ chip: PlaceSearch.PoiChip) {
        selectedPlace = nil
        if !model.navigation.query.isEmpty { model.navigation.clearSearch() }
        searchFocused = false
        showingNearby = true
        panelDismissed = false
        model.navigation.searchNearby(chip)
    }

    /// Arrive card "Find parking" (the dash's): hide the card without an announcement, then run the
    /// Parking chip.
    private func findParking() {
        let navigation = model.navigation
        if navigation.snapshot.arrival != nil { navigation.dismissArrival(announce: false) }
        let chips = navigation.poiChips
        if let chip = chips.first(where: { $0.label == "Parking" }) ?? chips.first(where: { $0.query == "amenity=parking" }) {
            searchChip(chip)
        }
    }

    /// The dash asked the rider to type the search on the phone (DashIntent.typeOnPhone / openSearch).
    private func openDashSearch() {
        selectedPlace = nil
        showingNearby = false
        panelDismissed = false
        dashSearchHint = true
        hapticTrigger &+= 1
        model.navigation.acknowledgeTypeOnPhone()
        // Focus once the field is on screen (the request may arrive while this screen is pushed).
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            searchFocused = true
        }
    }

    /// The banner shows the file-picker error first, then the model's last error.
    private func dismissError() {
        if importError != nil {
            importError = nil
        } else {
            model.navigation.dismissError()
        }
    }

    private func handleGpxPick(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let navigation = model.navigation
            Task { @MainActor in
                do {
                    let data = try await FeatureFileReader.read(url, maxBytes: 64 * 1024 * 1024)
                    importError = nil
                    navigation.previewGpx(data: data, fileName: url.lastPathComponent)
                } catch {
                    importError = FeatureErrorText.describe(error)
                }
            }
        case .failure(let error):
            importError = FeatureErrorText.describe(error)
        }
    }

    // MARK: Camera

    /// Frames the preview: every candidate route plus the rider and the place.
    private func fitPreview() {
        let snapshot = model.navigation.snapshot
        guard let preview = snapshot.preview else { return }
        let rider = snapshot.puck ?? model.ride.lastFix?.point
        guard let rect = NavigateGeometry.previewRect(preview, rider: rider) else { return }
        withAnimation(.easeInOut(duration: 0.4)) {
            camera = .rect(rect)
        }
    }

    /// Frames an opened GPX track waiting as a preview (UX-17).
    private func fitGpxPreview() {
        guard let gpx = model.navigation.pendingGpx,
              let rect = NavigateGeometry.framingRect(NavigateGeometry.coordinates(gpx.outline, maxPoints: 300)) else { return }
        withAnimation(.easeInOut(duration: 0.4)) {
            camera = .rect(rect)
        }
    }

    /// Navigation started: follow the rider (falls back to the whole route without a fix).
    private func followRider() {
        let snapshot = model.navigation.snapshot
        var fallback: MapCameraPosition = .automatic
        if let route = snapshot.route,
           let rect = NavigateGeometry.framingRect(NavigateGeometry.coordinates(route.points, maxPoints: 300)) {
            fallback = .rect(rect)
        }
        withAnimation(.easeInOut(duration: 0.4)) {
            camera = .userLocation(followsHeading: false, fallback: fallback)
        }
    }
}

#Preview("Map hub") {
    NavigationStack {
        NavigateScreen()
    }
    .environment(AppModel.preview())
}
