// SPDX-License-Identifier: AGPL-3.0-or-later
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

    public init(core: AppCore) {
        self.core = core
        snapshot = core.navigation.snapshot
        // TODO(logic-data): subscribe to snapshots/effects, load places.
    }

    // MARK: Search
    public func searchNow() { /* TODO(logic-data): immediate search (keyboard Go) */ }
    public func searchNearby(_ chip: PlaceSearch.PoiChip) { /* TODO(logic-data) */ }
    public func clearSearch() { /* TODO(logic-data) */ }
    public func acknowledgeTypeOnPhone() { typeOnPhoneRequested = false }

    // MARK: Plan & go (all forward to core.navigation; the dash follows automatically)
    public func preview(_ place: Place) { /* TODO(logic-data) */ }
    public func selectRoute(_ index: Int) { /* TODO(logic-data) */ }
    public func go() { /* TODO(logic-data) */ }
    public func cancelPreview() { /* TODO(logic-data) */ }
    public func navigate(to place: Place) { /* TODO(logic-data) */ }
    public func startFreeRide() { /* TODO(logic-data) */ }
    public func startCircuit() { /* TODO(logic-data) */ }
    public func endNavigation() { /* TODO(logic-data) */ }
    public func goHome() { /* TODO(logic-data) */ }
    public func parkHere() { /* TODO(logic-data) */ }
    public func setHomeHere() { /* TODO(logic-data) */ }
    public func recalc() { /* TODO(logic-data) */ }
    /// GPX file picked in Files / opened with the app.
    public func loadGpx(data: Data, fileName: String) { /* TODO(logic-data) */ }

    // MARK: Places
    public func saveFavorite(_ place: Place) { /* TODO(logic-data) */ }
    public func addMarker(_ place: Place) { /* TODO(logic-data) */ }
    public func delete(_ place: Place) { /* TODO(logic-data) */ }
    public func setHome(_ place: Place) { /* TODO(logic-data) */ }

    // MARK: Model-to-model (internal)

    /// RideModel forwards dash intents that need the phone keyboard.
    func requestTypeOnPhone() { typeOnPhoneRequested = true }

    private func queryChanged() { /* TODO(logic-data): debounce */ }
}
