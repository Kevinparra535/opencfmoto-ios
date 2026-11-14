// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP «Combustible»: the phone side of the fuel range estimate.
//
// - Per Garage bike (id = `GarageBike.id`): the fuel profile, the refuel log, the GPS km counter and the alert
//   latch, stored by FuelStore under scoped keys only (removing the bike deletes them).
// - The km counter is fed with every fix of RideModel (`onLocationFix`), counted only while the Connect /
//   Mirror session is COUNTABLE (ConnectionModel.isFuelCountable: not parked, not waiting for the bike, no
//   error) and attributed to the session's bike; it does not depend on trip logging. Bikes without
//   «Combustible» set up (no profile and no refuel) count nothing and store nothing.
// - «¿Cuál es tu moto?»: `setupPrompt` once the dash answered CLIENT_INFO (`profileHint`), no profile and no
//   «Luego» for that bike — a Home card, never a sheet by itself (`sheet` is set only by `present`).
// - The rider never types while riding: every sheet and every typed write is refused while moving
//   (`canLogNow`); single taps (reserve, «Usar el rendimiento medido», «Deshacer», delete, «Luego») stay.
// - The dash alert: once per crossing into low and once at the reserve (FuelAlertPolicy), from `ingest` only;
//   RideModel defers and delivers it (toast + voice).
// Logs never carry positions, litres, prices, costs or trip-meter values (LogRedactor has no rule for them).

import Foundation
import Observation
import OpenCfMotoCore

@MainActor
@Observable
public final class FuelModel {
    @ObservationIgnored let core: AppCore
    @ObservationIgnored let garage: GarageModel
    @ObservationIgnored let settings: SettingsModel
    @ObservationIgnored let navigation: NavigationModel
    @ObservationIgnored let store: FuelStore

    // MARK: Observable

    /// The bike the Home card follows: the session's bike while a session runs, else the selected one.
    public private(set) var currentBikeId: String?
    public private(set) var current: FuelBikeState?
    /// The fuel sheet RootView presents. Set ONLY by `present` (a rider tap), cleared by `dismissSheet` / the
    /// binding. FuelModel never sets it by itself (non-modal by construction).
    public var sheet: FuelSheet?
    /// «Carga registrada · Deshacer», for `undoWindow` seconds after a refuel was logged.
    public private(set) var undoOffer: FuelUndoOffer?
    /// Bumped whenever a bike's cached fuel data changes (keeps `setupPrompt` observable).
    private var revision: UInt64 = 0
    /// The pump's unit the rider chose (nil = never chosen: the default applies).
    private var chosenVolumeUnit: FuelVolumeUnit?

    /// Distance / economy units (Settings ▸ Map units).
    public var units: MapUnits { settings.current.map.units }

    /// The pump's volume unit (tank, litres, price per volume): a global preference, independent of km / mi.
    public var volumeUnit: FuelVolumeUnit {
        get { chosenVolumeUnit ?? FuelVolumeUnit.defaultFor(units: units, regionCode: regionCodeProvider()) }
        set {
            chosenVolumeUnit = newValue
            store.setVolumeUnit(newValue)
        }
    }

    /// Non-nil → Home shows the «¿Cuál es tu moto?» card.
    public var setupPrompt: FuelSetupPrompt? {
        _ = revision
        guard let id = currentBikeId, let bike = garage.bikes.first(where: { $0.id == id }), bike.profileHint != nil else {
            return nil
        }
        let c = cache(id)
        guard c.profile == nil, !c.deferred else { return nil }
        return FuelSetupPrompt(bikeId: id, bikeName: bike.name)
    }

    /// Phone entry allowed: stopped (≤ 5 km/h, or no fix fresher than 10 s). Gates every sheet and every typed
    /// write (the rider never types while riding).
    public var canLogNow: Bool {
        let fix = lastFixProvider.map { $0() } ?? core.services.location.lastFix
        return LinkLossAlarmPolicy.isStopped(lastFix: fix, now: core.services.now())
    }

    /// The verdict for the route preview's selected route; nil without a preview / route, for a straight-line
    /// fallback (`isDirectFallback`) or without a profile.
    public var previewVerdict: FuelVerdict? {
        guard let route = navigation.snapshot.preview?.selectedRoute, current?.profile != nil else { return nil }
        return verdict(for: route)
    }

    // MARK: Model-to-model (internal; wired by AppModel, overridable by tests)

    @ObservationIgnored var sessionBikeProvider: (() -> String?)?
    @ObservationIgnored var isCountableProvider: (() -> Bool)?
    @ObservationIgnored var liveDashInfoProvider: (() -> DashInfo?)?
    @ObservationIgnored var lastFixProvider: (() -> LocationFix?)?
    @ObservationIgnored var onDashAlert: ((FuelDashAlert) -> Void)?
    @ObservationIgnored var onDashAlertCancel: (() -> Void)?
    @ObservationIgnored var regionCodeProvider: () -> String? = { Locale.current.region?.identifier }
    @ObservationIgnored var undoWindow: TimeInterval = 10
    @ObservationIgnored var blindAfter: TimeInterval = 120

    // MARK: Private state

    struct BikeCache {
        var profile: FuelProfile?
        var log: RefuelLog
        var odometer: FuelOdometer
        var alert: FuelAlertLevel?
        var deferred: Bool
        var stats: FuelStats
        /// Fix time of the last odometer write.
        var lastPersistFixMs: Int64?
        /// The counter changed since the last write.
        var odometerDirty = false
        /// The stored odometer document is unreadable / newer: left in place until a rider action writes it.
        var odometerLocked = false

        var isSetUp: Bool { profile != nil || !log.entries.isEmpty }
    }

    @ObservationIgnored private var caches: [String: BikeCache] = [:]
    /// The bike the last counted fix was attributed to (the session id is gone when "ended" fires).
    @ObservationIgnored private(set) var streamBikeId: String?
    /// The latch to restore when the offered refuel is undone.
    @ObservationIgnored private var undoLatch: FuelAlertLevel?
    @ObservationIgnored private var undoTask: Task<Void, Never>?
    @ObservationIgnored private var blindTask: Task<Void, Never>?
    /// The last announced alert and the latch it replaced (restored when RideModel drops the alert).
    @ObservationIgnored private var announced: (bikeId: String, level: FuelAlertLevel, previous: FuelAlertLevel?)?
    /// The estimate kind last logged per bike (transitions only).
    @ObservationIgnored private var loggedEstimate: [String: String] = [:]
    @ObservationIgnored private var loggedCandidates: [String: String] = [:]

    public init(core: AppCore, garage: GarageModel, settings: SettingsModel, navigation: NavigationModel) {
        self.core = core
        self.garage = garage
        self.settings = settings
        self.navigation = navigation
        store = FuelStore(store: core.services.keyValueStore)
        chosenVolumeUnit = store.volumeUnit()
        garage.observeSelection { [weak self] _ in self?.refreshCurrentBike() }
        refreshCurrentBike()
    }

    private var nowMs: Int64 { Int64((core.services.now().timeIntervalSince1970 * 1000).rounded()) }

    // MARK: - Read any bike

    /// Any bike's fuel state. Observable for SwiftUI (reads `revision`, bumped on every change of a bike's
    /// data), so the Garage section of a bike that is not `current` refreshes too.
    public func state(for bikeId: String) -> FuelBikeState {
        _ = revision
        let c = cache(bikeId)
        return FuelBikeState(bikeId: bikeId, profile: c.profile, entry: c.profile?.catalogId.flatMap(FuelCatalog.entry(id:)),
                             log: c.log.entries, stats: c.stats, estimate: estimate(c), odometerKm: c.odometer.state.totalKm,
                             isSetupDeferred: c.deferred)
    }

    public func candidates(for bikeId: String) -> BikeCandidateList {
        let bike = core.garage.bike(id: bikeId)
        let qr = core.garage.qr(for: bikeId)
        let override = core.settings.settings(forBike: bikeId).profileOverride != nil
        let learned = core.dashMemory.learnedSize(forSSID: bike?.ssid ?? qr?.ssid)
        let live = sessionBikeProvider?() == bikeId ? liveDashInfoProvider?() : nil
        let signals = BikeCandidates.signals(qr: qr, bike: bike, hasProfileOverride: override, learned: learned, live: live)
        let list = BikeCandidates.resolve(signals)
        var line = "candidates: "
        line += list.families.isEmpty ? "no dash family" : "family \(list.families.map(\.rawValue).joined(separator: "+")) via \(list.source.rawValue)"
        line += ", \(list.ids.count) candidate(s)"
        if let w = signals.liveWinner, list.source != .clientInfo, list.source != .canvas {
            line += " (live winner \(w.rawValue) not corroborated)"
        }
        if loggedCandidates[bikeId] != line {
            loggedCandidates[bikeId] = line
            Log.i(Self.tag, line)
        }
        return list
    }

    public func catalogEntries(_ ids: [String]) -> [FuelCatalogEntry] { ids.compactMap(FuelCatalog.entry(id:)) }

    public func search(_ query: String, brand: FuelBrand?) -> [FuelCatalogEntry] { FuelCatalog.search(query, brand: brand) }

    /// Other bikes of the garage that have a profile.
    public func copySources(excluding bikeId: String) -> [FuelCopySource] {
        garage.bikes.compactMap { b in
            guard b.id != bikeId, let p = cache(b.id).profile else { return nil }
            return FuelCopySource(bikeId: b.id, bikeName: b.name, profile: p)
        }
    }

    /// The verdict for a route against the current bike's estimate (straight-line fallbacks: nil).
    public func verdict(for route: Route) -> FuelVerdict? {
        guard let estimate = current?.estimate else { return nil }
        return FuelVerdictRule.verdict(estimate: estimate, route: route)
    }

    // MARK: - Drafts for the editor (nothing saved)

    public func draft(from entry: FuelCatalogEntry) -> FuelProfile { FuelProfile.from(entry, nowMs: nowMs) }

    public func draftManual() -> FuelProfile { FuelProfile.manual(nowMs: nowMs) }

    public func draftCopy(from sourceBikeId: String) -> FuelProfile? {
        guard core.garage.bike(id: sourceBikeId) != nil, var p = cache(sourceBikeId).profile else { return nil }
        p.seedSource = .copied
        p.updatedAtMs = nowMs
        return p
    }

    // MARK: - Writes (typed entry: refused while moving)

    /// Clamps, applies the seedSource rule, recomputes the stats and re-arms the alert.
    @discardableResult
    public func saveProfile(_ draft: FuelProfile, for bikeId: String) -> FuelSaveOutcome {
        guard knows(bikeId) else { return .noSuchBike }
        guard canLogNow else { return .refusedWhileMoving }
        guard draft.isComplete else { return .incomplete }
        var p = draft.clamped()
        p.v = FuelProfile.version
        p.seedSource = seedSource(of: p, for: bikeId)
        if p.catalogId == nil, p.seedSource == .manual { p.name = p.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        p.updatedAtMs = nowMs
        var c = cache(bikeId)
        let wasSetUp = c.isSetUp
        c.profile = p
        store.setProfile(p, bikeId: bikeId)
        c.stats = Self.stats(c)
        caches[bikeId] = c
        Log.i(Self.tag, "profile saved: \(p.catalogId.map { "catalog:\($0)" } ?? "manual") (reserve \(p.reservePct) %, seedSource \(p.seedSource.rawValue))")
        if !wasSetUp, bikeId == streamBikeId, isCountableProvider?() == true {
            Log.i(Self.tag, "counting starts for \(bikeId)")
        }
        rearm(bikeId)
        changed(bikeId)
        return .saved
    }

    @discardableResult
    public func logRefuel(_ input: RefuelInput, for bikeId: String) -> FuelLogOutcome {
        guard knows(bikeId) else { return .noSuchBike }
        guard canLogNow else { return .refusedWhileMoving }
        if let field = input.invalidField() { return .invalid(field) }
        let now = nowMs
        var c = cache(bikeId)
        let state = c.odometer.state
        let unseen = (state.lastUnseenAtMs ?? .min) > (c.log.entries.last?.atMs ?? .min)
            || (state.openBlindSinceMs.map { now - $0 >= FuelOdometer.blindAfterMs } ?? false)
        let entry = c.log.add(input, nowMs: now, odometerKm: state.totalKm, unseen: unseen)
        c.odometerLocked = false
        caches[bikeId] = c
        persistLog(bikeId)
        persistOdometer(bikeId, force: true)
        recomputeStats(bikeId)
        let previous = cache(bikeId).alert
        rearm(bikeId)
        undoLatch = previous
        offerUndo(FuelUndoOffer(bikeId: bikeId, entryId: entry.id))
        Log.i(Self.tag, "refuel logged: \(entry.kind.rawValue), litres=\(Self.yesNo(entry.litres != nil)), price=\(Self.yesNo(entry.cost != nil || entry.pricePerLitre != nil)), trip=\(Self.yesNo(entry.tripMeterKm != nil)), late=\(Self.yesNo(entry.lateKm != nil)), unseen=\(Self.yesNo(unseen))")
        changed(bikeId)
        return .logged(entry)
    }

    /// «Corregir nivel»: a `.level` entry (a new anchor; ignored by the stats).
    @discardableResult
    public func logLevel(_ level: TankLevel, for bikeId: String) -> FuelLogOutcome {
        logRefuel(RefuelInput(kind: .level, levelAfter: level), for: bikeId)
    }

    // MARK: - Single taps (no typing; allowed while moving)

    public func setPreferLearned(_ on: Bool, for bikeId: String) {
        guard knows(bikeId), var p = cache(bikeId).profile, p.preferLearned != on else { return }
        p.preferLearned = on
        p.updatedAtMs = nowMs
        updateProfile(p, bikeId)
    }

    public func setReservePct(_ pct: Int, for bikeId: String) {
        guard knows(bikeId), var p = cache(bikeId).profile else { return }
        let clamped = min(max(pct, FuelProfile.reservePctRange.lowerBound), FuelProfile.reservePctRange.upperBound)
        guard clamped != p.reservePct else { return }
        p.reservePct = clamped
        p.updatedAtMs = nowMs
        updateProfile(p, bikeId)
    }

    /// «Luego»: hides «¿Cuál es tu moto?» for that bike for good (the Garage still offers «Elegir moto»).
    public func deferSetup(for bikeId: String) {
        guard knows(bikeId) else { return }
        var c = cache(bikeId)
        guard !c.deferred else { return }
        c.deferred = true
        caches[bikeId] = c
        store.setSetupDeferred(true, bikeId: bikeId)
        Log.i(Self.tag, "setup deferred («Luego») for \(bikeId)")
        changed(bikeId)
    }

    /// Acts on `undoOffer`; no-op without one.
    public func undoLastRefuel() {
        guard let offer = undoOffer else { return }
        clearUndo()
        guard knows(offer.bikeId) else { return }
        var c = cache(offer.bikeId)
        let removed: RefuelEntry?
        if c.log.entries.last?.id == offer.entryId {
            removed = c.log.undoLast()
        } else {
            removed = c.log.delete(id: offer.entryId)
        }
        guard let removed else { return }
        let restored = undoLatch
        c.alert = restored
        caches[offer.bikeId] = c
        store.setAlertLevel(restored, bikeId: offer.bikeId)
        persistLog(offer.bikeId)
        persistOdometer(offer.bikeId, force: true)
        recomputeStats(offer.bikeId)
        Log.i(Self.tag, "refuel undone: \(removed.kind.rawValue)")
        changed(offer.bikeId)
    }

    public func deleteRefuel(id: String, for bikeId: String) {
        guard knows(bikeId) else { return }
        var c = cache(bikeId)
        guard let removed = c.log.delete(id: id) else { return }
        caches[bikeId] = c
        if undoOffer?.entryId == id { clearUndo() }
        persistLog(bikeId)
        persistOdometer(bikeId, force: true)
        recomputeStats(bikeId)
        rearm(bikeId)
        Log.i(Self.tag, "refuel deleted: \(removed.kind.rawValue)")
        changed(bikeId)
    }

    // MARK: - Presentation

    /// Opens a sheet on a rider tap. Returns false (and opens nothing) for an unknown bike or while moving.
    @discardableResult
    public func present(_ sheet: FuelSheet) -> Bool {
        guard knows(sheet.bikeId), canLogNow else { return false }
        self.sheet = sheet
        return true
    }

    public func dismissSheet() { sheet = nil }

    // MARK: - Model-to-model

    /// Every fix that reached RideModel (AppModel wires `ride.onLocationFix`).
    func ingest(_ fix: LocationFix) {
        guard isCountableProvider?() == true, let bikeId = sessionBikeProvider?(), knows(bikeId) else {
            // Not countable (parked, phone-only, no session): the stream ends; the next countable fix resumes.
            if let s = streamBikeId, caches[s]?.odometer.isStreaming == true { endStream(s, reason: "not countable") }
            return
        }
        if let s = streamBikeId, s != bikeId { endStream(s, reason: "bike switched") }
        if streamBikeId != bikeId {
            streamBikeId = bikeId
            refreshCurrentBike()
        }
        var c = cache(bikeId)
        guard c.isSetUp else { return } // nothing counted or stored for a bike without «Combustible»
        let wasOpen = c.odometer.state.openBlindSinceMs != nil
        let before = c.odometer.state.totalKm
        let location = core.services.location
        if !location.permission.isAuthorized || !location.isPrecise { c.odometer.noteBlind(atMs: nowMs) }
        let step = c.odometer.ingest(fix)
        if case .rejected(.inaccurate) = step { c.odometer.noteBlind(atMs: fix.timeMs) }
        if c.odometer.state.totalKm != before { c.odometerDirty = true }
        let isOpen = c.odometer.state.openBlindSinceMs != nil
        caches[bikeId] = c
        var persistNow = false
        switch step {
        case let .gap(chord):
            persistNow = true
            Log.i(Self.tag, "gap detected: ~\(Self.kmText(chord)) unseen \u{2014} estimate marked aged")
        case let .bridged(chord):
            persistNow = true
            Log.i(Self.tag, "bridged ~\(Self.kmText(chord)) unseen")
        default:
            break
        }
        if wasOpen != isOpen {
            persistNow = true
            Log.i(Self.tag, isOpen ? "blind spell opened (\(blindCause(step)))" : "blind spell closed")
            if isOpen { scheduleBlindRefresh() }
        }
        if c.odometerDirty, c.lastPersistFixMs.map({ fix.timeMs &- $0 >= FuelOdometer.persistIntervalMs }) ?? true { persistNow = true }
        if persistNow { persistOdometer(bikeId, fixMs: fix.timeMs) }
        alertStep(bikeId)
        if bikeId == currentBikeId { rebuildCurrent() }
    }

    /// A Connect / Mirror session started (true) or ended (false).
    func sessionChanged(active: Bool) {
        if !active, let s = streamBikeId {
            endStream(s, reason: "session ended")
            streamBikeId = nil
        }
        refreshCurrentBike()
    }

    /// ConnectionModel.isFuelCountable changed (parked / waiting for the bike / error → false).
    func countableChanged(_ countable: Bool) {
        if !countable {
            if let s = streamBikeId { endStream(s, reason: "counting paused") }
            rebuildCurrent()
            return
        }
        guard let bikeId = sessionBikeProvider?(), knows(bikeId) else { return }
        if let s = streamBikeId, s != bikeId { endStream(s, reason: "bike switched") }
        streamBikeId = bikeId
        refreshCurrentBike()
        openBlindSpellIfSetUp(bikeId, cause: "not measured yet")
        rebuildCurrent()
    }

    /// RideModel could not deliver the alert on any channel: restore the latch it replaced, so the next
    /// odometer change fires it again with a fresh number.
    func fuelAlertDropped(_ alert: FuelDashAlert) {
        guard let a = announced, a.level == alert.level, knows(a.bikeId) else { return }
        announced = nil
        var c = cache(a.bikeId)
        guard c.alert == alert.level else { return }
        c.alert = a.previous
        caches[a.bikeId] = c
        store.setAlertLevel(a.previous, bikeId: a.bikeId)
        Log.i(Self.tag, "alert dropped: \(alert.level.rawValue) \u{2014} latch restored")
    }

    /// GarageModel removed a bike (its keys are gone): drop every cache and never write for it again.
    func bikeRemoved(_ bikeId: String) {
        caches[bikeId] = nil
        loggedEstimate[bikeId] = nil
        loggedCandidates[bikeId] = nil
        if streamBikeId == bikeId { streamBikeId = nil }
        if undoOffer?.bikeId == bikeId { clearUndo() }
        if sheet?.bikeId == bikeId { sheet = nil }
        if announced?.bikeId == bikeId { announced = nil }
        revision &+= 1
        refreshCurrentBike()
    }

    func scenePhaseChanged(_ phase: AppScenePhase) {
        switch phase {
        case .background:
            for id in caches.keys where caches[id]?.odometerDirty == true { persistOdometer(id, force: true) }
        case .active:
            if isCountableProvider?() == true, let bikeId = sessionBikeProvider?(), knows(bikeId) {
                let location = core.services.location
                if !location.permission.isAuthorized || !location.isPrecise {
                    openBlindSpellIfSetUp(bikeId, cause: "approximate or denied location")
                }
            }
            rebuildCurrent()
        case .inactive:
            break
        }
    }

    // MARK: - Private

    private static let tag = "fuel"

    private func knows(_ bikeId: String) -> Bool { core.garage.bike(id: bikeId) != nil }

    /// The cache of a bike, loaded lazily (counter consistency on load: never below the newest entry).
    private func cache(_ bikeId: String) -> BikeCache {
        if let c = caches[bikeId] { return c }
        let profile = store.profile(bikeId: bikeId)
        let log = store.log(bikeId: bikeId)
        var odometer = FuelOdometer(state: store.odometer(bikeId: bikeId))
        let locked = store.isUnreadable(FuelStore.Keys.odometer, bikeId: bikeId)
        var c = BikeCache(profile: profile, log: log, odometer: odometer, alert: store.alertLevel(bikeId: bikeId),
                          deferred: store.isSetupDeferred(bikeId: bikeId), stats: .empty, odometerLocked: locked)
        if let newest = log.entries.last, odometer.state.totalKm < newest.odometerKm {
            // A lost / unreadable / older counter would restart below the log and look like a full tank.
            odometer.raiseTotal(to: newest.odometerKm, gapAtMs: nowMs)
            c.odometer = odometer
            c.odometerDirty = true
            Log.w(Self.tag, "km counter behind the refuel log \u{2014} raised to it and marked aged")
        }
        c.stats = Self.stats(c)
        if knows(bikeId) { caches[bikeId] = c }
        return c
    }

    private static func stats(_ c: BikeCache) -> FuelStats {
        guard let p = c.profile else { return .empty }
        return FuelStats.compute(log: c.log.entries, seedKmPerL: p.seedKmPerL, tankL: p.tankL)
    }

    private func recomputeStats(_ bikeId: String) {
        guard var c = caches[bikeId] else { return }
        c.stats = Self.stats(c)
        caches[bikeId] = c
    }

    private func estimate(_ c: BikeCache) -> FuelEstimate {
        RangeEstimator.estimate(profile: c.profile, log: c.log.entries, odometer: c.odometer.state, stats: c.stats, nowMs: nowMs)
    }

    /// seedSource (§2.3): a copy of another bike within the tolerance → copied; a catalog row within the
    /// tolerance → catalog; a catalog row changed → edited; no catalog id → manual.
    private func seedSource(of p: FuelProfile, for bikeId: String) -> FuelSeedSource {
        let tol = FuelProfile.sameValueTolerance
        func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= tol }
        if p.seedSource == .copied {
            let match = copySources(excluding: bikeId).contains {
                $0.profile.catalogId == p.catalogId && same($0.profile.tankL, p.tankL) && same($0.profile.seedKmPerL, p.seedKmPerL)
            }
            if match { return .copied }
            return p.catalogId == nil ? .manual : .edited
        }
        guard let id = p.catalogId else { return .manual }
        guard let row = FuelCatalog.entry(id: id) else { return .edited }
        return same(row.tankL, p.tankL) && same(row.seedKmPerL, p.seedKmPerL) ? .catalog : .edited
    }

    private func updateProfile(_ p: FuelProfile, _ bikeId: String) {
        var c = cache(bikeId)
        c.profile = p
        store.setProfile(p, bikeId: bikeId)
        c.stats = Self.stats(c)
        caches[bikeId] = c
        rearm(bikeId)
        changed(bikeId)
    }

    /// Edits never announce; a re-arm that lowers the latch cancels a pending dash alert.
    private func rearm(_ bikeId: String) {
        var c = cache(bikeId)
        let next = FuelAlertPolicy.rearmed(c.alert, estimate: estimate(c))
        guard next != c.alert else { return }
        let lowered = Self.lowers(c.alert, to: next)
        c.alert = next
        caches[bikeId] = c
        store.setAlertLevel(next, bikeId: bikeId)
        if lowered {
            if announced?.bikeId == bikeId { announced = nil }
            onDashAlertCancel?()
        }
    }

    /// The alert order per odometer change: re-arm, then fire once above the latch.
    private func alertStep(_ bikeId: String) {
        var c = cache(bikeId)
        let e = estimate(c)
        let old = c.alert
        let rearmed = FuelAlertPolicy.rearmed(old, estimate: e)
        if Self.lowers(old, to: rearmed) {
            if announced?.bikeId == bikeId { announced = nil }
            onDashAlertCancel?()
        }
        var latch = rearmed
        if let level = FuelAlertPolicy.alertToFire(estimate: e, alerted: rearmed) {
            latch = level
            announced = (bikeId, level, rearmed)
            Log.i(Self.tag, "alert: \(level.rawValue) (\(FuelFormat.range(e.kmToReserve ?? 0, units: units).text) to reserve)")
            onDashAlert?(FuelDashAlert(level: level, kmToReserve: e.kmToReserve ?? 0))
        }
        guard latch != old else { return }
        c.alert = latch
        caches[bikeId] = c
        store.setAlertLevel(latch, bikeId: bikeId)
    }

    /// True when `next` is below `old` (nil is below low).
    private static func lowers(_ old: FuelAlertLevel?, to next: FuelAlertLevel?) -> Bool {
        guard let old else { return false }
        guard let next else { return true }
        return next < old
    }

    private func endStream(_ bikeId: String, reason: String) {
        guard var c = caches[bikeId] else { return }
        let wasStreaming = c.odometer.isStreaming
        let hadSpell = c.odometer.state.openBlindSinceMs != nil
        c.odometer.endStream(atMs: nowMs)
        caches[bikeId] = c
        guard c.isSetUp, wasStreaming || hadSpell else { return }
        persistOdometer(bikeId, force: true)
        Log.i(Self.tag, "stream ended for \(bikeId) (\(reason)), total persisted")
        if bikeId == currentBikeId { rebuildCurrent() }
    }

    private func openBlindSpellIfSetUp(_ bikeId: String, cause: String) {
        var c = cache(bikeId)
        guard c.isSetUp, c.odometer.state.openBlindSinceMs == nil else { return }
        c.odometer.noteBlind(atMs: nowMs)
        caches[bikeId] = c
        persistOdometer(bikeId, force: true)
        Log.i(Self.tag, "blind spell opened (\(cause))")
        scheduleBlindRefresh()
    }

    private func blindCause(_ step: FuelOdometerStep) -> String {
        if case .rejected(.inaccurate) = step { return "inaccurate fix" }
        let location = core.services.location
        if !location.permission.isAuthorized { return "location denied" }
        if !location.isPrecise { return "approximate location" }
        return "no usable fix"
    }

    /// The live `noGps` age needs a refresh once a spell may have aged (no fix may arrive to trigger one).
    private func scheduleBlindRefresh() {
        blindTask?.cancel()
        let delay = blindAfter
        blindTask = Task { [weak self] in
            await sleepSeconds(delay)
            guard !Task.isCancelled, let self else { return }
            self.rebuildCurrent()
        }
    }

    private func persistLog(_ bikeId: String) {
        guard knows(bikeId), let c = caches[bikeId] else { return }
        store.setLog(c.log, bikeId: bikeId)
    }

    /// Writes the counter of a set-up bike (never for an unknown bike, never over an unreadable document
    /// before a rider action).
    private func persistOdometer(_ bikeId: String, fixMs: Int64? = nil, force: Bool = false) {
        guard knows(bikeId), var c = caches[bikeId], c.isSetUp, !c.odometerLocked else { return }
        guard force || c.odometerDirty || fixMs != nil else { return }
        store.setOdometer(c.odometer.state, bikeId: bikeId)
        c.odometerDirty = false
        if let fixMs { c.lastPersistFixMs = fixMs }
        caches[bikeId] = c
    }

    private func offerUndo(_ offer: FuelUndoOffer) {
        undoTask?.cancel()
        undoOffer = offer
        let window = undoWindow
        undoTask = Task { [weak self] in
            await sleepSeconds(window)
            guard !Task.isCancelled, let self, self.undoOffer == offer else { return }
            self.undoOffer = nil
        }
    }

    private func clearUndo() {
        undoTask?.cancel()
        undoTask = nil
        undoOffer = nil
    }

    /// A bike's data changed: observers and the Home card.
    private func changed(_ bikeId: String) {
        revision &+= 1
        if bikeId == currentBikeId { rebuildCurrent() }
    }

    private func refreshCurrentBike() {
        let candidates = [streamBikeId, sessionBikeProvider?(), core.garage.selected?.id]
        let known = candidates.compactMap { $0 }.first(where: knows)
        if known != currentBikeId { currentBikeId = known }
        rebuildCurrent()
    }

    private func rebuildCurrent() {
        guard let id = currentBikeId, knows(id) else {
            if current != nil { current = nil }
            return
        }
        let s = state(for: id)
        logEstimateTransition(id, s.estimate)
        if s != current { current = s }
    }

    /// Logs estimate state transitions (kind + aged), with the rounded display value only.
    private func logEstimateTransition(_ bikeId: String, _ e: FuelEstimate) {
        var key: String
        var shown = ""
        switch e.state {
        case let .unknown(r): key = "unknown(\(r.rawValue))"
        case let .ok(km):
            key = "ok"
            shown = " (\(FuelFormat.range(km, units: units).text) to reserve)"
        case let .low(km):
            key = "low"
            shown = " (\(FuelFormat.range(km, units: units).text) to reserve)"
        case .reserve: key = "reserve"
        case .checkRefuel: key = "checkRefuel"
        }
        if let aged = e.aged { key += " aged \(Self.agedLabel(aged))" }
        let previous = loggedEstimate[bikeId]
        guard previous != key else { return }
        loggedEstimate[bikeId] = key
        Log.i(Self.tag, "estimate: \(previous ?? "none") \u{2192} \(key)\(shown)")
    }

    private static func agedLabel(_ a: FuelAgedReason) -> String {
        switch a {
        case .old: return "old"
        case .noGps: return "noGps"
        case .gap: return "gap"
        }
    }

    private static func yesNo(_ b: Bool) -> String { b ? "yes" : "no" }

    /// "3 km" / "800 m" (rounded; for gap / bridge lines only, never a position).
    private static func kmText(_ metres: Double) -> String {
        metres >= 1000 ? "\(Int((metres / 1000).rounded())) km" : "\(Int((metres / 100).rounded()) * 100) m"
    }
}
