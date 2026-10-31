// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) GpxActivity.kt (hub search + rows), GpxDashUi.kt (search sheet,
// idle list, POI chips)
//
// Search results / idle suggestions of the Map hub (docs/spec/navigation-dash.md §7.3–§7.6, §14):
// POI chips ("near me" via Overpass), live results of the debounced query (NavigationModel),
// and when the query is empty the idle list: home, parked, favorites, markers, history (history
// without free-ride "mode" rows, parking rows and (0,0)). Row tap = route preview; the row menu /
// swipe actions offer Preview · Navigate · ★ Save · ＋ Marker · Set as home · Delete.

import SwiftUI
import OpenCfMotoCore
import OpenCfMotoAppModel

@MainActor
struct NavigateSearchPanel: View {
    @Environment(AppModel.self) private var model
    /// A POI chip search is showing (results without a typed query).
    let showingNearby: Bool
    /// A row was chosen (preview / navigate): the screen closes the panel.
    let onChosen: () -> Void
    let onChip: (PlaceSearch.PoiChip) -> Void

    var body: some View {
        let navigation = model.navigation
        let query = navigation.query.trimmingCharacters(in: .whitespacesAndNewlines)
        List {
            Section {
                NavigatePoiChips(chips: navigation.poiChips, onTap: onChip)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if let error = navigation.lastError, !error.isEmpty, !navigation.isSearching {
                Section {
                    Label {
                        Text(verbatim: error)
                            .font(.subheadline)
                            .foregroundStyle(Theme.text)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.error)
                    }
                    .listRowBackground(Color.clear)
                }
            }

            if !query.isEmpty || showingNearby {
                resultSection(query: query)
            } else {
                idleSections
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .environment(\.defaultMinListRowHeight, 44)
        .frame(maxHeight: 400)
        .background(Theme.surface.opacity(0.98), in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
            .strokeBorder(Theme.outline, lineWidth: 1))
    }

    @ViewBuilder
    private func resultSection(query: String) -> some View {
        let navigation = model.navigation
        if navigation.results.isEmpty {
            Section {
                if navigation.isSearching {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Searching…")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .listRowBackground(Color.clear)
                } else if showingNearby || query.count >= 2 {
                    Text("No results")
                        .foregroundStyle(Theme.textSecondary)
                        .listRowBackground(Color.clear)
                } else {
                    Text("Type a place name")
                        .foregroundStyle(Theme.textSecondary)
                        .listRowBackground(Color.clear)
                }
            }
        } else {
            Section {
                ForEach(navigation.results, id: \.self) { place in
                    NavigatePlaceRow(place: place, onChosen: onChosen)
                }
            } header: {
                Text("\(String(navigation.results.count)) places")
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var idleSections: some View {
        let navigation = model.navigation
        let saved = [navigation.home, navigation.parked].compactMap { $0 }
        let history = navigation.history.filter {
            $0.category != "mode" && $0.category != "parking" && !($0.lat == 0 && $0.lon == 0)
        }
        if saved.isEmpty && navigation.favorites.isEmpty && navigation.markers.isEmpty && history.isEmpty {
            Section {
                Text("Search for a place or tap a category")
                    .foregroundStyle(Theme.textSecondary)
                    .listRowBackground(Color.clear)
            }
        }
        if !saved.isEmpty {
            Section("Home & parking") {
                ForEach(saved, id: \.self) { place in
                    NavigatePlaceRow(place: place, onChosen: onChosen)
                }
            }
        }
        if !navigation.favorites.isEmpty {
            Section("Favorites") {
                ForEach(navigation.favorites, id: \.self) { place in
                    NavigatePlaceRow(place: place, onChosen: onChosen)
                }
            }
        }
        if !navigation.markers.isEmpty {
            Section("Markers") {
                ForEach(navigation.markers, id: \.self) { place in
                    NavigatePlaceRow(place: place, onChosen: onChosen)
                }
            }
        }
        if !history.isEmpty {
            Section("History") {
                ForEach(history, id: \.self) { place in
                    NavigatePlaceRow(place: place, onChosen: onChosen)
                }
            }
        }
    }
}

/// One place in the result / suggestion list.
@MainActor
struct NavigatePlaceRow: View {
    @Environment(AppModel.self) private var model
    let place: Place
    let onChosen: () -> Void

    var body: some View {
        let navigation = model.navigation
        let isSaved = NavigatePlaceStatus.isSaved(place, in: navigation)
        HStack(spacing: 8) {
            Button {
                navigation.preview(place)
                onChosen()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: NavigateIcons.place(place.category))
                        .font(.body)
                        .foregroundStyle(Theme.brand)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: place.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(2)
                        if !place.subtitle.isEmpty {
                            Text(verbatim: place.subtitle)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 4)
                    if let distance = distanceText {
                        Text(verbatim: distance)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityHint(Text("Shows the route preview"))

            Menu {
                Button {
                    navigation.preview(place)
                    onChosen()
                } label: {
                    Label("Preview", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
                Button {
                    navigation.navigate(to: place)
                    onChosen()
                } label: {
                    Label("Navigate", systemImage: "location.fill")
                }
                Button("★ Save") { navigation.saveFavorite(place) }
                Button("＋ Marker") { navigation.addMarker(place) }
                Button {
                    navigation.setHome(place)
                } label: {
                    Label("Set as home", systemImage: "house")
                }
                if isSaved {
                    Button(role: .destructive) {
                        navigation.delete(place)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Place actions"))
        }
        .listRowBackground(Color.clear)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                navigation.navigate(to: place)
                onChosen()
            } label: {
                Label("Navigate", systemImage: "location.fill")
            }
            .tint(Theme.brand)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if isSaved {
                Button(role: .destructive) {
                    navigation.delete(place)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            Button {
                navigation.saveFavorite(place)
            } label: {
                Label("★ Save", systemImage: "star.fill")
            }
            .tint(Theme.busy)
        }
    }

    /// Straight-line distance from the rider, except for POI results whose subtitle already has it.
    private var distanceText: String? {
        let navigation = model.navigation
        if navigation.poiChips.contains(where: { $0.label == place.category }) { return nil }
        let origin = navigation.snapshot.puck ?? model.ride.lastFix?.point
        guard let meters = NavigateGeometry.distance(from: origin, to: place) else { return nil }
        return NavigateGeometry.distanceText(meters, units: model.settings.current.map.units)
    }
}

/// "Near me" category chips (Fuel, Cafe, Food, Parking, Hotel, ATM, Hospital, Viewpoint).
struct NavigatePoiChips: View {
    let chips: [PlaceSearch.PoiChip]
    let onTap: (PlaceSearch.PoiChip) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips, id: \.self) { chip in
                    Button {
                        onTap(chip)
                    } label: {
                        Label {
                            Text(LocalizedStringKey(chip.label))
                        } icon: {
                            Image(systemName: NavigateIcons.chip(chip))
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.surfaceHigh, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.outline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Finds places of this kind near you"))
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }
}
