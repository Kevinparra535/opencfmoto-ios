// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) GpxActivity.kt (map hub search / places / GPX import),
// MainActivity.kt (debounced live suggestions, "type on phone")
//
// WAVE-2 SKELETON — owner: logic-data. The PUBLIC SURFACE below is the contract the SwiftUI layer
// codes against: implement the bodies, add private helpers / new files freely, add new public
// members only if needed (report them), never rename or remove existing public members.
//
// Phone-side navigation (Map hub, docs/spec/navigation-dash.md §7–§11, app-features §7.5.7).
// There is ONE `NavigationSession` (core.navigation): the phone screens and the dash both reflect
// its snapshots, so a preview opened on the phone appears on the dash and vice-versa.
//
// Behaviour to implement:
// - `snapshot` mirrors `core.navigation` snapshots (subscribe once; hop to the main actor; keep
//   only the newest). `NavEffect.toast` → `toast` (auto-clear after ~2.5 s); `.placesChanged` →
//   refresh `favorites/markers/history/home/parked`. `.speak` is handled by RideModel, not here.
// - `query` setter: debounce 350 ms, ≥ 2 characters → `core.navigation.searchPlaces` → `results`
//   (`isSearching` while in flight; cancel stale requests). Empty query → clear results.
// - `searchNearby(chip)` → `core.navigation.searchNearby`.
// - `loadGpx(data:fileName:)` → `core.navigation.loadGpx(data:fileName:)`; errors → `lastError`.
// - `typeOnPhoneRequested` is set by RideModel when the dash asks the rider to type on the phone
//   (DashIntent.typeOnPhone / openSearch); the Navigate screen focuses its search field and calls
//   `acknowledgeTypeOnPhone()`.
//
// Implementation notes:
// - Snapshots / effects come from the session's multi-subscriber streams (`snapshots()` /
//   `effects()`), so this model never takes the single handler slots other models may use.
// - Places lists also follow every PlacesStore write (map-data import, phone list actions,
//   dash actions) through a PlacesStore change listener, coalesced and delivered asynchronously
//   on the main actor (never inside the session's state lock).
// - One search at a time: a new query / chip / Go cancels the previous request, and results of a
//   stale request are dropped (generation token). Queries shorter than 2 characters clear the
//   results (Android shows the idle list then).
// - GPX files up to 1 MiB are parsed synchronously (`lastError` is set when `loadGpx` returns);
//   bigger files are parsed and loaded off the main actor.
// - The phone's arrive card runs the session's own arrive actions (`dismissArrival`,
//   `arrivalParkHere`), so Done / Park here / Find parking behave exactly like on the dash.

import Foundation
import Observation
import OpenCfMotoCore

@MainActor
@Observable
public final class NavigationModel {
    @ObservationIgnored let core: AppCore

    /// Latest navigation snapshot (mode, destination, route, progress, cue, preview, arrival…).
    public private(set) var snapshot: NavSnapshot
    /// Search text (setting it runs the debounced search).
    public var query: String = "" {
        didSet { queryChanged() }
    }
    public private(set) var results: [Place] = []
    public private(set) var isSearching = false
    /// POI quick searches (Fuel, Cafe, Food, Parking, …).
    public let poiChips: [PlaceSearch.PoiChip] = PlaceSearch.poiChips
    public private(set) var favorites: [Place] = []
    public private(set) var markers: [Place] = []
    public private(set) var history: [Place] = []
    public private(set) var home: Place?
    public private(set) var parked: Place?
    /// Transient status line (NavEffect.toast), auto-cleared.
    public private(set) var toast: String?
    /// Last user-facing error (search failed, GPX unreadable…).
    public private(set) var lastError: String?
    /// The dash asked to type the search on the phone.
    public private(set) var typeOnPhoneRequested = false

    // Tunables (tests shorten them).
    /// Live-suggestion debounce (Android 350 ms).
    @ObservationIgnored var searchDebounce: TimeInterval = 0.35
    /// How long a toast stays (Android ~2.5 s).
    @ObservationIgnored var toastDuration: TimeInterval = 2.5
    /// GPX files above this size are parsed off the main actor.
    @ObservationIgnored var synchronousGpxLimit = 1 << 20

    @ObservationIgnored private let lifetime = LogicData.Lifetime()
    @ObservationIgnored private let placesLatch = LogicData.Latch()
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration: UInt64 = 0
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var gpxGeneration: UInt64 = 0

    public init(core: AppCore) {
        self.core = core
        snapshot = core.navigation.snapshot
        reloadPlaces()
        subscribe()
    }

    // MARK: Search
    public func searchNow() {
        let q = trimmedQuery
        guard !q.isEmpty else {
            cancelSearch()
            if !results.isEmpty { results = [] }
            showToast(strings.typePlace)
            return
        }
        startSearch(debounce: 0) { session in try await session.searchPlaces(q) } completion: { [weak self] found in
            guard let self else { return }
            if found.isEmpty { self.showToast(self.navStrings.phrase(.noResults)) }
        }
    }

    public func searchNearby(_ chip: PlaceSearch.PoiChip) {
        let label = navStrings.poiChipLabel(chip.label)
        startSearch(debounce: 0) { session in try await session.searchNearby(chip) } completion: { [weak self] found in
            guard let self else { return }
            self.showToast(found.isEmpty ? self.navStrings.phrase(.noneFoundNearby(label))
                                         : self.navStrings.phrase(.foundNearby(found.count, label)))
        }
    }

    public func clearSearch() {
        cancelSearch()
        if !query.isEmpty { query = "" }   // didSet → queryChanged() clears the results
        if !results.isEmpty { results = [] }
        lastError = nil
    }

    public func acknowledgeTypeOnPhone() { typeOnPhoneRequested = false }

    /// The rider closed the error banner: forget `lastError` (a new failure sets it again).
    public func dismissError() {
        if lastError != nil { lastError = nil }
    }

    // MARK: Plan & go (all forward to core.navigation; the dash follows automatically)
    public func preview(_ place: Place) { core.navigation.previewPlace(place) }
    public func selectRoute(_ index: Int) { core.navigation.selectRoute(index) }
    public func go() { core.navigation.go() }
    public func cancelPreview() { core.navigation.cancelPreview() }
    public func navigate(to place: Place) { core.navigation.navigate(to: place) }
    /// Map hub "Free ride" (pushes the "Started free ride" history row like Android).
    public func startFreeRide() { core.navigation.startFreeRide(recordHistory: true) }
    public func startCircuit() { core.navigation.startCircuit() }
    public func endNavigation() { core.navigation.endNavigation() }
    public func goHome() { core.navigation.goHome() }
    public func parkHere() { core.navigation.parkHere() }
    public func setHomeHere() { core.navigation.setHomeHere() }
    public func recalc() { core.navigation.recalc() }

    // MARK: Arrive card (the same card and actions as the dash's, navigation-dash.md §11.8)

    /// "Done": hides the arrive card; with `announce` the status line says "Free ride" (the dash's
    /// Done). "Find parking" passes `announce: false` before running the Parking chip, like the dash.
    public func dismissArrival(announce: Bool = true) { core.navigation.dismissArrival(announce: announce) }
    /// "Park here": parked pin at the rider's fix ("Marked on arrival"), closes the card. Unlike the
    /// free-ride `parkHere()` it never toggles an existing parked pin away.
    public func arrivalParkHere() { core.navigation.arrivalParkHere() }

    /// GPX file picked in Files / opened with the app.
    public func loadGpx(data: Data, fileName: String) {
        gpxGeneration &+= 1
        let generation = gpxGeneration
        lastError = nil
        let session = core.navigation
        if data.count <= synchronousGpxLimit {
            do {
                try session.loadGpx(data: data, fileName: fileName)
            } catch {
                reportGpxFailure(error, fileName: fileName)
            }
            return
        }
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let track = try GpxParser.importTrack(data, fileName: fileName)
                let stillWanted = await self?.isCurrentGpx(generation) ?? false
                guard stillWanted, !Task.isCancelled else { return }
                session.loadGpx(track, displayName: track.name)
            } catch {
                await self?.gpxFailed(error, fileName: fileName, generation: generation)
            }
        }
        lifetime.replace("gpx", with: task)
    }

    // MARK: Places
    public func saveFavorite(_ place: Place) {
        core.places.addFavorite(place)
        reloadPlaces()
        showToast(navStrings.phrase(.savedToFavorites(place.name)))
    }

    public func addMarker(_ place: Place) {
        core.places.addMarker(place)
        reloadPlaces()
        showToast(navStrings.phrase(.markerAdded))
    }

    public func delete(_ place: Place) {
        core.places.deletePlace(place)
        reloadPlaces()
    }

    public func setHome(_ place: Place) {
        let str = navStrings
        core.places.setHome(place, defaultName: str.homeName, subtitle: str.homeName)
        reloadPlaces()
        showToast(str.phrase(.homeSet))
    }

    // MARK: Model-to-model (internal)

    /// RideModel forwards dash intents that need the phone keyboard.
    func requestTypeOnPhone() {
        typeOnPhoneRequested = true
        // Android: highlight the field, vibrate 40 ms and toast the hint (MainActivity.kt:591-612).
        // The 40 ms buzz (and the voice prompt) belong to RideModel, which knows whether the request
        // came from the dash (buzz) or from the phone's own dash preview (no buzz).
        showToast(strings.bikeSearchOpen)
    }

    private func queryChanged() {
        let q = trimmedQuery
        guard q.count >= 2 else {
            // Empty / 1 character: no request; Android shows the idle list (recent & favorites).
            cancelSearch()
            if !results.isEmpty { results = [] }
            if q.isEmpty { lastError = nil }
            return
        }
        startSearch(debounce: searchDebounce) { session in try await session.searchPlaces(q) } completion: { _ in }
    }

    // MARK: Private — search

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration &+= 1
        if isSearching { isSearching = false }
    }

    /// Runs one search after `debounce` seconds, replacing any pending / running one.
    private func startSearch(debounce: TimeInterval,
                             _ request: @escaping @Sendable (NavigationSession) async throws -> [Place],
                             completion: @escaping @MainActor @Sendable ([Place]) -> Void) {
        cancelSearch()
        let generation = searchGeneration
        let session = core.navigation
        searchTask = Task { [weak self] in
            if debounce > 0 {
                try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
            }
            guard !Task.isCancelled, let self, self.searchGeneration == generation else { return }
            self.isSearching = true
            self.lastError = nil
            do {
                let found = try await request(session)
                guard !Task.isCancelled, self.searchGeneration == generation else { return }
                self.results = found
                self.isSearching = false
                completion(found)
            } catch {
                guard !Task.isCancelled, self.searchGeneration == generation, !(error is CancellationError) else { return }
                self.isSearching = false
                let message = self.strings.serviceError(error, fallback: self.strings.searchFailed)
                self.lastError = message
                Log.w("NAV", "[search] failed: \(NavServiceError.message(for: error, fallback: "error"))")
            }
        }
    }

    // MARK: Private — snapshots, effects, places

    private var strings: LogicData.Strings { LogicData.Strings(core.language) }
    private var navStrings: NavStrings {
        NavStrings(language: core.language, decimalSeparator: core.language.conventionalDecimalSeparator)
    }

    private func subscribe() {
        let snapshots = core.navigation.snapshots()
        lifetime.add(Task { [weak self] in
            for await snap in snapshots {
                guard let self else { return }
                self.apply(snap)
            }
        })
        let effects = core.navigation.effects()
        lifetime.add(Task { [weak self] in
            for await effect in effects {
                guard let self else { return }
                self.handle(effect)
            }
        })
        let latch = placesLatch
        let listener = core.places.addChangeListener { [weak self] _ in
            // Called on the writer's thread, possibly while the session holds its state lock: never
            // re-enter synchronously (an observer reacting to the lists could call the session) —
            // always hop asynchronously. This model's own place actions reload immediately anyway.
            guard latch.arm() else { return }
            let model = self
            Task { @MainActor in
                latch.disarm()
                model?.reloadPlaces()
            }
        }
        let places = core.places
        lifetime.onDeinit { places.removeChangeListener(listener) }
    }

    private func apply(_ snap: NavSnapshot) {
        // Deliveries are ordered; never step back to an older revision (the initial read may be newer).
        guard snap.revision >= snapshot.revision, snap != snapshot else { return }
        snapshot = snap
    }

    private func handle(_ effect: NavEffect) {
        switch effect {
        case let .toast(text): showToast(text)
        case .placesChanged: reloadPlaces()
        case .speak: break   // RideModel speaks
        }
    }

    private func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        let duration = toastDuration
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, duration) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.toast = nil
        }
    }

    private func reloadPlaces() {
        let p = core.places
        let fav = p.favorites(), mark = p.markers(), hist = p.history(), h = p.home(), park = p.parked()
        if fav != favorites { favorites = fav }
        if mark != markers { markers = mark }
        if hist != history { history = hist }
        if h != home { home = h }
        if park != parked { parked = park }
    }

    // MARK: Private — GPX

    private func isCurrentGpx(_ generation: UInt64) -> Bool { generation == gpxGeneration }

    private func gpxFailed(_ error: Error, fileName: String, generation: UInt64) {
        guard generation == gpxGeneration else { return }
        reportGpxFailure(error, fileName: fileName)
    }

    private func reportGpxFailure(_ error: Error, fileName: String) {
        if error is GpxParser.ImportError {
            lastError = strings.gpxEmpty
        } else {
            lastError = strings.gpxUnreadable(LogicData.detail(of: error))
        }
        Log.w("NAV", "[GPX] import failed for \(fileName): \(LogicData.detail(of: error))")
    }
}
