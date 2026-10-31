// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) TripActivity.kt, TripsListActivity.kt, TripRouteThumb.kt
//
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
//   `isManualRecording`). `discardRecording()` = Android "Reset" (`tripRecorder.discard()`):
//   the current leg is thrown away, never saved.
// - `sections`: `core.tripStore.list()` grouped by local day (TripDays), newest day first, titles
//   via `Trip.dateText(locale:timeZone:)` style formatting; refresh on `onTripSaved` and `reload()`.
// - `exportGPX(_:)`: `TripGpx.toXML` → `files.exportsDirectory/<TripGpx.suggestedFileName>`
//   (typeIdentifier "com.topografix.gpx").
// - `thumbnail(for:size:)`: `TripThumbnail.geometry` for list rows (normalised points).
//
// Implementation notes:
// - This model installs `tripRecorder.onStats` / `onTripSaved` (chaining any handler installed
//   before it). Other models that need recorder events should chain the same way.
// - `TripStore.list()` parses every trip file: it runs off the main actor (`reload()` returns
//   immediately; `sections` updates when the listing is done). A saved trip is inserted directly.
// - Day sections use calendar days of `timeZone` (no Android 24 h DST bug); the title is
//   `EEE d MMM yyyy` in `locale`, the summary `N ride(s) · X.X km` (decimal separator of `locale`).

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

    // Formatting context (the user's; tests pin them, then call `reload()`).
    @ObservationIgnored var locale: Locale = .current
    @ObservationIgnored var timeZone: TimeZone = .current
    @ObservationIgnored var language: NavLanguage

    /// The listing in flight (tests await it).
    var pendingReload: Task<Void, Never>? { lifetime.task(in: Self.reloadSlot) }

    @ObservationIgnored private var trips: [Trip] = []
    @ObservationIgnored private var listGeneration: UInt64 = 0
    @ObservationIgnored private var isListing = false
    @ObservationIgnored private var thumbnailCache: [String: [DashPoint]] = [:]
    @ObservationIgnored private let lifetime = LogicData.Lifetime()
    @ObservationIgnored private let statsLatch = LogicData.Latch()

    public init(core: AppCore) {
        self.core = core
        language = core.language
        live = core.tripRecorder.snapshot()
        hookRecorder()
        reload()
    }

    public func reload() {
        listGeneration &+= 1
        let generation = listGeneration
        let store = core.tripStore
        isListing = true
        let task = Task { [weak self] in
            // Blocking file I/O: on a GCD worker, not on a cooperative-pool thread.
            let listed: [Trip] = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { continuation.resume(returning: store.list()) }
            }
            guard !Task.isCancelled, let self, self.listGeneration == generation else { return }
            self.isListing = false
            self.trips = listed
            self.thumbnailCache.removeAll()
            self.rebuildSections()
        }
        lifetime.replace(Self.reloadSlot, with: task)
    }

    public func startRecording() {
        let wasRecording = core.tripRecorder.isRecording
        core.tripRecorder.start()
        isManualRecording = true
        lastError = nil
        Log.i(Self.tag, wasRecording ? "manual recording (keeps the current leg)" : "manual recording started")
        refreshLive()
    }

    public func stopRecording() {
        isManualRecording = false
        guard core.tripRecorder.isRecording else {
            refreshLive()
            return
        }
        let saved = core.tripRecorder.stopAndSave()
        Log.i(Self.tag, saved == nil ? "recording stopped (leg too short \u{2014} not saved)" : "recording stopped and saved")
        if let saved { insert(saved) }
        refreshLive()
    }

    /// Trip computer "Discard" (Android "Reset", `TripRecorder.discard()`): stops the current
    /// recording — manual or automatic — and throws the leg away. Nothing is ever saved. While the
    /// automatic log applies (Log trips on, dash streaming), RideModel's next 5 s check starts a
    /// fresh leg, like Android's Reset of a running log.
    public func discardRecording() {
        let wasRecording = core.tripRecorder.isRecording
        isManualRecording = false
        core.tripRecorder.discard()
        Log.i(Self.tag, wasRecording ? "recording discarded (nothing saved)" : "trip computer reset")
        refreshLive()
    }

    public func delete(_ trip: Trip) {
        core.tripStore.delete(id: trip.id)
        trips.removeAll { $0.id == trip.id }
        thumbnailCache = thumbnailCache.filter { !$0.key.hasPrefix(trip.id + "|") }
        Log.i(Self.tag, "deleted trip \(trip.id)")
        rebuildSections()
        // A listing that started before the delete may still contain the file: list again.
        if isListing { reload() }
    }

    public func trip(id: String) -> Trip? { core.tripStore.trip(id: id) }

    public func exportGPX(_ trip: Trip) throws -> ExportedFile {
        let strings = LogicData.Strings(language)
        guard !trip.points.isEmpty else {
            lastError = strings.tripHasNoPoints
            throw LogicData.UserError(strings.tripHasNoPoints)
        }
        let xml = TripGpx.toXML(trip, locale: locale, timeZone: timeZone)
        let fileName = TripGpx.suggestedFileName(trip, timeZone: timeZone)
        do {
            let file = try LogicData.writeExport(xml, fileName: fileName, typeIdentifier: "com.topografix.gpx",
                                                 in: core.services.files.exportsDirectory)
            lastError = nil
            Log.i(Self.tag, "\u{2192} Trip GPX exported: \(fileName)")
            return file
        } catch {
            let message = strings.exportFailed(LogicData.detail(of: error))
            lastError = message
            Log.w(Self.tag, "GPX export failed: \(LogicData.detail(of: error))")
            throw LogicData.UserError(message)
        }
    }

    /// Polyline normalised into `width × height` points for a list thumbnail.
    public func thumbnail(for trip: Trip, width: Double, height: Double) -> [DashPoint] {
        guard width.isFinite, height.isFinite, width >= 1, height >= 1, width <= 100_000, height <= 100_000,
              trip.points.count >= 2 else { return [] }
        let key = "\(trip.id)|\(trip.points.count)|\(trip.end)|\(width)x\(height)"
        if let hit = thumbnailCache[key] { return hit }
        // Android draws into an integer bitmap: integral sizes give Android's exact geometry; other
        // sizes are computed on a 4× grid and scaled back (the mapping is linear in the size).
        let integral = width.rounded() == width && height.rounded() == height
        let k = integral ? 1.0 : 4.0
        let geometry = TripThumbnail.geometry(points: trip.points, widthPx: Int((width * k).rounded()),
                                              heightPx: Int((height * k).rounded()))
        let points = integral
            ? geometry.polyline
            : geometry.normalizedPolyline.map { DashPoint($0.x * width, $0.y * height) }
        if thumbnailCache.count >= 256 { thumbnailCache.removeAll() }
        thumbnailCache[key] = points
        return points
    }

    // MARK: Model-to-model (internal)

    /// RideModel calls this after the auto-log policy started/stopped a recording.
    func recorderStateChanged() {
        refreshLive()
        reload()
    }

    // MARK: Private

    private static let tag = "trip"
    private static let reloadSlot = "reload"

    private func hookRecorder() {
        let recorder = core.tripRecorder
        let previousStats = recorder.onStats
        let previousSaved = recorder.onTripSaved
        let latch = statsLatch
        recorder.onStats = { [weak self] stats in
            previousStats?(stats)
            guard latch.arm() else { return }
            let model = self
            LogicData.onMain {
                latch.disarm()
                model?.refreshLive()
            }
        }
        recorder.onTripSaved = { [weak self] trip in
            previousSaved?(trip)
            let model = self
            LogicData.onMain { model?.insert(trip) }
        }
    }

    /// Mirrors the recorder's newest stats (the callbacks may arrive out of order).
    private func refreshLive() {
        let stats = core.tripRecorder.snapshot()
        if stats != live { live = stats }
        if !stats.recording && isManualRecording { isManualRecording = false }
    }

    /// Adds (or replaces) a saved trip without re-reading the store.
    private func insert(_ trip: Trip) {
        trips.removeAll { $0.id == trip.id }
        trips.append(trip)
        trips.sort { $0.start != $1.start ? $0.start > $1.start : $0.id > $1.id }
        rebuildSections()
        if isListing { reload() }
    }

    private func rebuildSections() {
        let fresh = Self.sections(for: trips, locale: locale, timeZone: timeZone, language: language)
        if fresh != sections { sections = fresh }
    }

    /// Groups trips by local calendar day (newest day first, newest trip first).
    static func sections(for trips: [Trip], locale: Locale, timeZone: TimeZone, language: NavLanguage) -> [TripDaySection] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var byDay: [Int64: [Trip]] = [:]
        for trip in trips {
            byDay[TripDays.startOfDay(trip.start, calendar: calendar), default: []].append(trip)
        }
        let strings = LogicData.Strings(language)
        let separator: Character = locale.decimalSeparator?.first ?? "."
        return byDay.keys.sorted(by: >).map { day in
            let dayTrips = (byDay[day] ?? []).sorted { $0.start != $1.start ? $0.start > $1.start : $0.id > $1.id }
            let summary = TripDays.summary(dayTrips)
            let km = NavNumberFormat.fixed(summary.distanceKm, decimals: 1, decimalSeparator: separator)
            return TripDaySection(
                id: LogicData.posixStamp(Date(timeIntervalSince1970: Double(day) / 1000), format: "yyyy-MM-dd", timeZone: timeZone),
                title: TripFormat.dateText(epochMs: day, locale: locale, timeZone: timeZone),
                summary: strings.tripDaySummary(count: summary.count, distance: km),
                trips: dayTrips)
        }
    }
}
