// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: «¿Cuál es tu moto?». The pairing QR identifies the dash FAMILY, not the model, so the rider
// picks the model ONCE per Garage bike from a short list (BikeCandidates: QR modelId, learned canvas,
// CLIENT_INFO). A row is preselected only when exactly one candidate remains: a silently wrong tank is
// worse than one tap. Also «Copiar de {bike}» (a replaced dash is a new Garage bike), «Otra moto» (the
// catalog search, exact model tokens) and «Ingresar a mano». Every row pushes the editable summary
// (FuelProfileEditor); nothing is saved in this sheet. «Luego» only when opened from the Home prompt.
// While the bike moves the rows are disabled (the rider never types while riding).

import SwiftUI
import OpenCfMotoCore
import OpenCfMotoAppModel

/// What a picker row pushes.
enum FuelPickerRoute: Hashable {
    case search
    case catalog(String)
    case copy(String)
    case manual
}

struct FuelPickerSheet: View {
    let bikeId: String
    let fromPrompt: Bool

    @Environment(AppModel.self) private var model
    @State private var showsAll = false
    @State private var path: [FuelPickerRoute] = []

    var body: some View {
        let fuel = model.fuel
        let canLog = fuel.canLogNow
        let list = fuel.candidates(for: bikeId)
        let entries = fuel.catalogEntries(list.ids)
        let copies = fuel.copySources(excluding: bikeId)
        let limit = BikeCandidates.visibleBeforeMore
        let visible = showsAll || entries.count <= limit + 1 ? entries : Array(entries.prefix(limit))
        NavigationStack(path: $path) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        if entries.isEmpty {
                            Text("We couldn't tell the model from the dash. Search for it or enter it by hand.")
                        } else if entries.count == 1 {
                            Text("Your bike's dash matches this model. Check it and save.")
                        } else {
                            Text("Your bike's dash fits these models. Pick yours: the tank changes between models.")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowBackground(Color.clear)
                    if !canLog {
                        FuelMovingLine("Stop to choose your bike")
                            .listRowBackground(Color.clear)
                    }
                }

                if !entries.isEmpty {
                    Section {
                        ForEach(visible) { entry in
                            NavigationLink(value: FuelPickerRoute.catalog(entry.id)) {
                                FuelCatalogRow(entry: entry, isPreselected: entry.id == list.preselectedId)
                            }
                            .disabled(!canLog)
                        }
                        if visible.count < entries.count {
                            Button {
                                withAnimation { showsAll = true }
                            } label: {
                                Label("Show more", systemImage: "chevron.down")
                            }
                        }
                    }
                    .featureRowBackground()
                }

                if !copies.isEmpty {
                    Section {
                        ForEach(copies) { source in
                            NavigationLink(value: FuelPickerRoute.copy(source.bikeId)) {
                                FuelCopyRow(source: source)
                            }
                            .disabled(!canLog)
                        }
                    }
                    .featureRowBackground()
                }

                Section {
                    NavigationLink(value: FuelPickerRoute.search) {
                        Label("Other bike", systemImage: "magnifyingglass")
                    }
                    .disabled(!canLog)
                    NavigationLink(value: FuelPickerRoute.manual) {
                        Label("Enter by hand", systemImage: "square.and.pencil")
                    }
                    .disabled(!canLog)
                }
                .featureRowBackground()
            }
            .navigationTitle("Which bike is it?")
            .navigationBarTitleDisplayMode(.inline)
            .featureScreenChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if fromPrompt {
                        Button("Later") {
                            fuel.deferSetup(for: bikeId)
                            fuel.dismissSheet()
                        }
                    } else {
                        Button("Cancel") { fuel.dismissSheet() }
                    }
                }
            }
            .navigationDestination(for: FuelPickerRoute.self) { route in
                destination(route, brand: list.brand)
            }
        }
    }

    @ViewBuilder
    private func destination(_ route: FuelPickerRoute, brand: FuelBrand?) -> some View {
        let fuel = model.fuel
        switch route {
        case .search:
            FuelCatalogSearchView(bikeId: bikeId, brand: brand)
        case let .catalog(id):
            if let entry = FuelCatalog.entry(id: id) {
                FuelProfileEditor(bikeId: bikeId, draft: fuel.draft(from: entry), volumeUnit: fuel.volumeUnit,
                                  units: fuel.units)
            }
        case let .copy(source):
            if let draft = fuel.draftCopy(from: source) {
                FuelProfileEditor(bikeId: bikeId, draft: draft, volumeUnit: fuel.volumeUnit, units: fuel.units)
            }
        case .manual:
            FuelProfileEditor(bikeId: bikeId, draft: fuel.draftManual(), volumeUnit: fuel.volumeUnit, units: fuel.units)
        }
    }
}

// MARK: - Rows

/// One catalog model: name, market note, «Tanque 17,5 L · ~20,5 km/L» and the source badges.
struct FuelCatalogRow: View {
    let entry: FuelCatalogEntry
    var isPreselected = false

    @Environment(AppModel.self) private var model

    var body: some View {
        let fuel = model.fuel
        let tank = FuelUIText.volume(entry.tankL, fuel.volumeUnit)
        let economy = FuelUIText.economy(entry.seedKmPerL, fuel.units)
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: entry.displayName)
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if !entry.marketNote.isEmpty {
                    Text(verbatim: entry.marketNote)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Tank \(tank) · ~\(economy)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text("Tank \(tank), about \(economy)"))
                if entry.tankKind == .official || entry.consumptionKind == .estimate {
                    // Side by side when they fit, stacked at large text sizes (never past the chevron).
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { badges }
                        VStack(alignment: .leading, spacing: 4) { badges }
                    }
                }
            }
            Spacer(minLength: 4)
            if isPreselected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.brand)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isPreselected ? .isSelected : [])
    }

    @ViewBuilder
    private var badges: some View {
        if entry.tankKind == .official {
            FuelBadge(text: Text("Official tank"), tint: Theme.live)
        }
        if entry.consumptionKind == .estimate {
            FuelBadge(text: Text("Estimated economy"), tint: Theme.idle)
        }
    }
}

/// «Copiar de {bike}»: another bike of the garage with its tank and km/L.
private struct FuelCopyRow: View {
    let source: FuelCopySource

    @Environment(AppModel.self) private var model

    var body: some View {
        let fuel = model.fuel
        let profile = source.profile
        let entry = profile.catalogId.flatMap(FuelCatalog.entry(id:))
        let tank = FuelUIText.volume(profile.tankL, fuel.volumeUnit)
        let economy = FuelUIText.economy(profile.seedKmPerL, fuel.units)
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text("Copy from \(source.bikeName)")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "doc.on.doc")
            }
            .font(.headline)
            .foregroundStyle(Theme.text)
            FuelUIText.modelName(profile, entry: entry)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Text("Tank \(tank) · ~\(economy)")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .accessibilityLabel(Text("Tank \(tank), about \(economy)"))
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - «Otra moto»

/// The catalog search: exact model tokens ("450", "800 MT", "Ibex 450"); a brand the rider types replaces
/// the dash's brand prefilter. An empty query lists every bundled model, the dash's brand first. The field is
/// disabled (and loses the keyboard) while the bike moves.
struct FuelCatalogSearchView: View {
    let bikeId: String
    let brand: FuelBrand?

    @Environment(AppModel.self) private var model
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let fuel = model.fuel
        let canLog = fuel.canLogNow
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let results = trimmed.isEmpty ? Self.allRows(brandFirst: brand) : fuel.search(trimmed, brand: brand)
        List {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityHidden(true)
                    TextField("Search model", text: $query)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.search)
                        .focused($searchFocused)
                }
                .disabled(!canLog)
                if !canLog {
                    FuelMovingLine("Stop to choose your bike")
                }
            }
            .featureRowBackground()
            if results.isEmpty {
                Section {
                    Text("No models match. Try only the number, like 450.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .featureRowBackground()
            } else {
                Section {
                    ForEach(results) { entry in
                        NavigationLink(value: FuelPickerRoute.catalog(entry.id)) {
                            FuelCatalogRow(entry: entry)
                        }
                        .disabled(!canLog)
                    }
                }
                .featureRowBackground()
            }
            Section {
                NavigationLink(value: FuelPickerRoute.manual) {
                    Label("Enter by hand", systemImage: "square.and.pencil")
                }
                .disabled(!canLog)
            }
            .featureRowBackground()
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Other bike")
        .navigationBarTitleDisplayMode(.inline)
        .featureScreenChrome()
        .onChange(of: canLog) { _, can in
            if !can { searchFocused = false }
        }
    }

    /// Every bundled row in catalog order, the given brand's rows first.
    private static func allRows(brandFirst brand: FuelBrand?) -> [FuelCatalogEntry] {
        guard let brand else { return FuelCatalog.all }
        return FuelCatalog.all.filter { $0.brand == brand } + FuelCatalog.all.filter { $0.brand != brand }
    }
}
