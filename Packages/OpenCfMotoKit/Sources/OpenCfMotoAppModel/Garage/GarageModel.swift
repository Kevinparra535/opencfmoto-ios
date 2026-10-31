// SPDX-License-Identifier: AGPL-3.0-or-later
// WAVE-2 SKELETON — owner: logic-data. The PUBLIC SURFACE below is the contract the SwiftUI layer
// codes against: implement the bodies, add private helpers / new files freely, add new public
// members only if needed (report them), never rename or remove existing public members.
//
// Garage (docs/spec/app-features.md §4, session-network.md §2): saved bikes keyed by SSID(+MAC),
// raw QR (contains the Wi-Fi password) only in the SecretStore via `Garage`, photos stored as
// files in `AppFileLocations.photosDirectory` (only the file name is persisted).
//
// Behaviour to implement:
// - `pair(rawQR:)`: `BikeQR.parse` (trim like Kotlin) → `garage.save(qr)` → select it → log
//   `qr.parsedLogLine` (NEVER the raw text) → `.paired(bike)`. Failure: log
//   `BikeQR.parseFailedLogLine(for:)`, return `.invalid(hint: BikeQR.iosFailureHint(for:) ?? "Invalid QR")`
//   (localize "Invalid QR" ES "QR no válido").
// - `pairManually`: `BikeQR.buildManual(ssid:password:displayName:)` then the same as pair.
// - `remove`: `garage.remove(id)`; delete its photo file; `SettingsStore.removeAllScopedValues(forBike:)`
//   is already done by Garage.remove (check) — do not double-delete.
// - Every mutation refreshes `bikes` / `selected` and notifies `observeSelection` handlers when the
//   selected bike changes (SettingsModel re-scopes; ConnectionModel uses it for "Connect to <name>").

import Foundation
import Observation
import OpenCfMotoCore

@MainActor
@Observable
public final class GarageModel {
    @ObservationIgnored let core: AppCore

    /// All saved bikes (Garage order).
    public private(set) var bikes: [GarageBike] = []
    /// The bike Connect uses; nil when the garage is empty.
    public private(set) var selected: GarageBike?

    public init(core: AppCore) {
        self.core = core
        reload()
    }

    /// Re-reads the garage from storage.
    public func reload() {
        bikes = core.garage.bikes
        selected = core.garage.selected
    }

    /// Scanned (or imported-from-photo) QR text.
    public func pair(rawQR: String) -> PairingOutcome {
        .invalid(hint: "Invalid QR") // TODO(logic-data)
    }

    /// Bikes without a QR (e.g. Benelli TRK): SSID + password typed by the rider.
    public func pairManually(ssid: String, password: String, name: String?) -> PairingOutcome {
        .invalid(hint: "Invalid QR") // TODO(logic-data)
    }

    public func select(_ id: String) {
        // TODO(logic-data)
    }

    public func rename(_ id: String, to name: String) {
        // TODO(logic-data)
    }

    /// Saves JPEG/PNG data as the bike photo (replaces the previous file).
    public func setPhoto(_ id: String, imageData: Data, fileExtension: String = "jpg") throws {
        // TODO(logic-data)
    }

    public func removePhoto(_ id: String) {
        // TODO(logic-data)
    }

    /// File URL of the bike photo, nil when none.
    public func photoURL(for id: String) -> URL? {
        nil // TODO(logic-data)
    }

    public func remove(_ id: String) {
        // TODO(logic-data)
    }

    /// The parsed QR of a saved bike (SSID, password, model…), nil if unreadable.
    public func qr(for id: String) -> BikeQR? {
        core.garage.qr(for: id)
    }

    /// Learned dash canvas for a bike's SSID (shown in the garage detail), nil if never connected.
    public func learnedCanvas(for id: String) -> VideoCanvas? {
        nil // TODO(logic-data)
    }

    // MARK: Model-to-model (internal)

    /// Called with the new selection after every change of `selected` (main actor).
    func observeSelection(_ handler: @escaping @MainActor (GarageBike?) -> Void) {
        selectionHandlers.append(handler)
    }

    @ObservationIgnored private var selectionHandlers: [@MainActor (GarageBike?) -> Void] = []
}
