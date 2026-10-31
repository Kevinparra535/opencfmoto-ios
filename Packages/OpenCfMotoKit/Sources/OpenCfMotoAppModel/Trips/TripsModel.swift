// SPDX-License-Identifier: AGPL-3.0-or-later
// WAVE-2 SKELETON — owner: logic-data. The PUBLIC SURFACE below is the contract the SwiftUI layer
// codes against: implement the bodies, add private helpers / new files freely, add new public
// members only if needed (report them), never rename or remove existing public members.
//
// Trips (docs/spec/app-features.md §5). `core.tripRecorder` is fed with location fixes by
// RideModel (it also applies TripAutoLogPolicy for automatic logging); this model owns the
// trip-computer view state, manual recording, the saved-trip list and GPX export.
//
// Behaviour to implement:
// - `live` mirrors `tripRecorder.onStats` (main actor). `isRecording` = live.recording.
// - `startRecording()` / `stopRecording()` = manual recording (`tripRecorder.start()` /
//   `stopAndSave()`); RideModel's auto-log must not stop a manual recording (keep a flag:
//   `isManualRecording`).
// - `sections`: `core.tripStore.list()` grouped by local day (TripDays), newest day first, titles
//   via `Trip.dateText(locale:timeZone:)` style formatting; refresh on `onTripSaved` and `reload()`.
// - `exportGPX(_:)`: `TripGpx.toXML` → `files.exportsDirectory/<TripGpx.suggestedFileName>`
//   (typeIdentifier "com.topografix.gpx").
// - `thumbnail(for:size:)`: `TripThumbnail.geometry` for list rows (normalised points).

import Foundation
import Observation
import OpenCfMotoCore

@MainActor
@Observable
public final class TripsModel {
    @ObservationIgnored let core: AppCore

    /// Live trip computer (speed, distance, moving time, max speed, fix state).
    public private(set) var live: TripRecorder.Stats = TripRecorder.Stats()
    public var isRecording: Bool { live.recording }
    /// A recording started by the rider (auto-log never stops it).
    public private(set) var isManualRecording = false
    /// Saved trips grouped by local day, newest first.
    public private(set) var sections: [TripDaySection] = []
    public private(set) var lastError: String?

    public init(core: AppCore) {
        self.core = core
        // TODO(logic-data): hook recorder callbacks, load the list.
    }

    public func reload() { /* TODO(logic-data) */ }
    public func startRecording() { /* TODO(logic-data) */ }
    public func stopRecording() { /* TODO(logic-data) */ }
    public func delete(_ trip: Trip) { /* TODO(logic-data) */ }
    public func trip(id: String) -> Trip? { core.tripStore.trip(id: id) }
    public func exportGPX(_ trip: Trip) throws -> ExportedFile {
        throw CocoaError(.featureUnsupported) // TODO(logic-data)
    }
    /// Polyline normalised into `width × height` points for a list thumbnail.
    public func thumbnail(for trip: Trip, width: Double, height: Double) -> [DashPoint] {
        [] // TODO(logic-data)
    }

    // MARK: Model-to-model (internal)

    /// RideModel calls this after the auto-log policy started/stopped a recording.
    func recorderStateChanged() { /* TODO(logic-data): refresh live + sections */ }
}
