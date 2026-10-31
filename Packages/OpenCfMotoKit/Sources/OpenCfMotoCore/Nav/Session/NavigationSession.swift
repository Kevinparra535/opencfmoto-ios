// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) GpxDashUi.kt (navigation state machine: bind, applyProgress,
// onLocationChanged, requestOsrm, finishToFreeRideUi, canDeclareArrival, compass tick),
// GpxSession.kt (modes)
//
// The navigation engine of the dash map (docs/spec/navigation-dash.md §1.3, §4.7–§4.10, §11.6–§11.8):
// owns the mode (free ride / GPX / navigate-to), destination, route preview, active route and
// follower, and publishes a `NavSnapshot` (HUD strings pre-formatted as on Android) plus
// `NavEffect`s (speech, toasts, places changed) after every change.
//
// iOS fixes over Android (disabled by `Configuration.parityMode` where they change observable
// behaviour, see the spec references):
//  - arrival: the start distance is captured on the first progress after Go (§4.8 intent), so real
//    arrivals declare "Destination reached" instead of silently finishing;
//  - stale async results (preview, reroute, delayed finish) are dropped with request tokens;
//  - a route request in flight is never duplicated by the next fix;
//  - a preview opened without GPS requests its routes when the first fix arrives;
//  - turn + waypoint phrases of one fix are spoken as one utterance (QUEUE_FLUSH would cut one);
//  - Cancel restores heading-up after a preview (§11.8 note, fix (h));
//  - the voice planner is reset when a new route is applied (turn indices change meaning).

import Foundation

/// Thread-safe navigation engine. All state is guarded by an `NSLock`; handlers / streams are
/// invoked outside it, snapshots in strictly increasing `revision` order.
///
/// Typical wiring (app layer):
/// ```swift
/// let http = ThrottledHTTPClient(base: cellularAwareClient)
/// let nav = NavigationSession(http: http, places: PlacesStore(store: kv), preferences: settings.map)
/// nav.setSnapshotHandler { snap in dashController.update(nav: snap) }   // or `for await` nav.snapshots()
/// nav.setEffectHandler { effect in … speak / toast / reload places … }
/// locationService.onFix = { nav.updateLocation($0) }                     // every CLLocation
/// locationService.onHeading = { nav.updateHeading($0) }                  // raw CLHeading.trueHeading
/// ```
/// Dash intents map to the actions in `NavigationSession+Actions.swift` (`previewPlace`,
/// `selectRoute`, `go`, `cancelPreview`, `startCircuit`, `dropPin`, `saveFavoriteFromPreview`,
/// `setHomeFromPreview`, `addMarkerFromPreview`, `arrivalParkHere`, `dismissArrival`,
/// `endNavigation`, `parkHere`, `goHome`, `setHomeHere`, `recalc`, `toggleLapTimer`,
/// `navigateToSavedPlace`, …).
///
/// Snapshot conventions: `cue` is never nil while navigating (seeded "GPS" / "To …");
/// `speedLimit` is display-ready (`label` = number in the current units) and nil when the sign
/// must be hidden; during a preview the previewed place (`preview.place`) is the pin to draw and a
/// dashed rider → place line may be drawn while `preview.loading`; `pins` never contain the
/// destination (drawn separately) nor places at (0,0).
public final class NavigationSession: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// Language of HUD words, voice phrases and status texts.
        public var language: NavLanguage
        /// Decimal separator of displayed distances ("." = Android parity, "," for Spanish).
        public var decimalSeparator: Character
        /// Android-exact behaviour (follower without the step fixes, lazy arrival bug, separate
        /// utterances). For golden-vector tests.
        public var parityMode: Bool
        /// Time zone of the "ARRIVE" clock.
        public var timeZone: TimeZone
        /// Show an OSM "NN mph" limit as NN in imperial (iOS fix) instead of the double conversion.
        public var keepNativeSpeedLimitUnit: Bool

        public init(language: NavLanguage = .preferred, decimalSeparator: Character = ".", parityMode: Bool = false,
                    timeZone: TimeZone = .current, keepNativeSpeedLimitUnit: Bool = true) {
            self.language = language
            self.decimalSeparator = decimalSeparator
            self.parityMode = parityMode
            self.timeZone = timeZone
            self.keepNativeSpeedLimitUnit = keepNativeSpeedLimitUnit
        }
    }

    // MARK: Dependencies

    public let places: PlacesStore
    public let router: RouteOrchestrator
    public let search: PlaceSearch
    public let speedLimits: SpeedLimitService
    public let savedSlots: SavedPlaceSlots?
    let clock: MonotonicClock
    let wallClock: @Sendable () -> Date
    let scheduler: NavScheduler
    let parityMode: Bool
    let timeZone: TimeZone
    let keepNativeLimitUnit: Bool

    // MARK: State

    enum RouteReason { case start, recalc }

    struct State {
        var prefs: MapPreferences
        var language: NavLanguage
        var decimalSeparator: Character
        var mode: NavMode = .freeRide
        var trackName = "Free ride"
        var destination: Place?
        var overlays: [Place] = []
        var gpxTrack: GpxTrack?
        var gpxOriented = true
        var follower: RouteFollower?
        var route: Route?
        var progress: RouteProgress?
        var lastFix: LocationFix?
        var rideStats = RideStats()
        var lapTimer = LapTimer()
        var voice = VoicePlanner()
        var heading = HeadingSmoother()
        var lastHeadingProcessAt: TimeInterval?
        var headingUp = true
        var headingUpBeforePreview: Bool?
        var lastMapBearing = 0.0
        var routeRequested = false
        var routeToken: UInt64 = 0
        var navGeneration: UInt64 = 0
        var offRouteSince: TimeInterval?
        var lastAutoReroute: TimeInterval?
        var destArrivedSpoken = false
        var navStartDist: Double?
        var navEngagedAt: TimeInterval?
        var preview: RoutePreview?
        var previewOrigin: LocationFix?
        var previewToken: UInt64 = 0
        var previewWaitingForFix = false
        var arrival: ArrivalCard?
        var cue: HudCue?
        var metrics = HudMetrics()
        var puck: GeoPoint?
        var puckBearing = 0.0
        var rawSpeedLimit: SpeedLimit?
        var pins: [Place] = []
        var pinsRevision: UInt64?
        var revision: UInt64 = 0
        // Outbox, flushed after each locked section.
        var outEffects: [NavEffect] = []
        var outCamera: [NavCameraHint] = []
        var dirty = false
    }

    let lock = NSLock()
    var s: State

    // Delivery (outside the state lock, ordered).
    private let deliveryLock = NSRecursiveLock()
    private var lastDeliveredRevision: UInt64 = 0
    private var snapshotHandler: (@Sendable (NavSnapshot) -> Void)?
    private var effectHandler: (@Sendable (NavEffect) -> Void)?
    private var cameraHandler: (@Sendable (NavCameraHint) -> Void)?
    private var snapshotStreams: [UUID: AsyncStream<NavSnapshot>.Continuation] = [:]
    private var effectStreams: [UUID: AsyncStream<NavEffect>.Continuation] = [:]

    // Background work.
    private let taskLock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    var previewTask: Task<Void, Never>?

    /// - Parameters:
    ///   - http: transport for routing / search / Overpass (wrap it in `ThrottledHTTPClient`).
    ///   - places: saved places (pins, history, home, parked).
    ///   - preferences: map preferences (units, voice, auto-finish, route options…).
    ///   - orsApiKey: optional OpenRouteService key.
    ///   - clock: monotonic time for timers (arrival, reroute, compass throttle).
    ///   - wallClock: wall-clock time for the ARRIVE column and the lap timer.
    ///   - scheduler: delayed actions (auto-finish).
    ///   - router / search / speedLimits: override the default services (tests).
    ///   - savedSlots: handlebar saved-place slots (nav1…nav3).
    public init(http: HTTPClient,
                places: PlacesStore,
                preferences: MapPreferences = MapPreferences(),
                orsApiKey: String = "",
                configuration: Configuration = Configuration(),
                clock: MonotonicClock = SystemMonotonicClock(),
                wallClock: @escaping @Sendable () -> Date = { Date() },
                scheduler: NavScheduler = TaskNavScheduler(),
                router: RouteOrchestrator? = nil,
                search: PlaceSearch? = nil,
                speedLimits: SpeedLimitService? = nil,
                savedSlots: SavedPlaceSlots? = nil) {
        self.places = places
        self.router = router ?? RouteOrchestrator(http: http, orsApiKey: orsApiKey)
        if router != nil && !orsApiKey.isEmpty { self.router.orsApiKey = orsApiKey }
        self.search = search ?? PlaceSearch(http: http)
        self.speedLimits = speedLimits ?? SpeedLimitService(http: http, clock: clock)
        self.savedSlots = savedSlots
        self.clock = clock
        self.wallClock = wallClock
        self.scheduler = scheduler
        parityMode = configuration.parityMode
        timeZone = configuration.timeZone
        keepNativeLimitUnit = configuration.keepNativeSpeedLimitUnit
        s = State(prefs: preferences, language: configuration.language, decimalSeparator: configuration.decimalSeparator)
        let strings = NavStrings(language: configuration.language, decimalSeparator: configuration.decimalSeparator)
        s.voice = VoicePlanner(strings: strings)
        s.trackName = strings.phrase(.freeRide)
        s.metrics = HudMetrics(altUnit: NavFormat.altitudeUnitLabel(preferences.units), status: strings.phrase(.gpsFreeRide))
        s.revision = 1
    }

    // MARK: - Output

    /// The latest snapshot.
    public var snapshot: NavSnapshot {
        lock.lock(); defer { lock.unlock() }
        return buildSnapshotLocked()
    }

    /// Called with every new snapshot (revision strictly increasing), outside internal locks.
    public func setSnapshotHandler(_ handler: (@Sendable (NavSnapshot) -> Void)?) {
        deliveryLock.lock(); snapshotHandler = handler; deliveryLock.unlock()
    }

    /// Called for every effect (speak / toast / placesChanged) in emission order.
    public func setEffectHandler(_ handler: (@Sendable (NavEffect) -> Void)?) {
        deliveryLock.lock(); effectHandler = handler; deliveryLock.unlock()
    }

    /// Optional camera hints for the dash UI.
    public func setCameraHintHandler(_ handler: (@Sendable (NavCameraHint) -> Void)?) {
        deliveryLock.lock(); cameraHandler = handler; deliveryLock.unlock()
    }

    /// Snapshot stream: yields the current snapshot immediately, then every change (latest only
    /// when the consumer is slow).
    public func snapshots() -> AsyncStream<NavSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont in
            // Register and yield the current snapshot atomically w.r.t. deliveries.
            deliveryLock.lock()
            snapshotStreams[id] = cont
            cont.yield(snapshot)
            deliveryLock.unlock()
            cont.onTermination = { [weak self] _ in
                guard let self else { return }
                self.deliveryLock.lock(); self.snapshotStreams[id] = nil; self.deliveryLock.unlock()
            }
        }
    }

    /// Effect stream (unbounded buffer).
    public func effects() -> AsyncStream<NavEffect> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { cont in
            deliveryLock.lock()
            effectStreams[id] = cont
            deliveryLock.unlock()
            cont.onTermination = { [weak self] _ in
                guard let self else { return }
                self.deliveryLock.lock(); self.effectStreams[id] = nil; self.deliveryLock.unlock()
            }
        }
    }

    /// Waits until every background request started so far (routing, search, speed limit) has
    /// finished. For tests and orderly shutdown.
    public func waitUntilIdle() async {
        while true {
            let pending = pendingTasks()
            if pending.isEmpty { return }
            for t in pending { await t.value }
        }
    }

    /// Cancels all background work (call when the dash session ends).
    public func cancelBackgroundWork() {
        for t in pendingTasks() { t.cancel() }
    }

    private func pendingTasks() -> [Task<Void, Never>] {
        taskLock.lock(); defer { taskLock.unlock() }
        return Array(tasks.values)
    }

    private func removeTask(_ id: UUID) {
        taskLock.lock(); defer { taskLock.unlock() }
        tasks[id] = nil
    }

    // MARK: - Locked helpers

    var strings: NavStrings { NavStrings(language: s.language, decimalSeparator: s.decimalSeparator) }
    var units: MapUnits { s.prefs.units }
    var nowMs: Int64 { Int64((clock.now() * 1000).rounded()) }
    var wallMs: Int64 { Int64((wallClock().timeIntervalSince1970 * 1000).rounded()) }

    /// Runs `body` under the state lock, then publishes (snapshot if dirty, effects, camera hints).
    @discardableResult
    func mutate<T>(_ body: () -> T) -> T {
        lock.lock()
        let result = body()
        let effects = s.outEffects
        let camera = s.outCamera
        s.outEffects = []
        s.outCamera = []
        var snap: NavSnapshot?
        if s.dirty || !effects.isEmpty {
            s.dirty = false
            s.revision &+= 1
            snap = buildSnapshotLocked()
        }
        lock.unlock()
        deliver(snapshot: snap, effects: effects, camera: camera)
        return result
    }

    private func deliver(snapshot snap: NavSnapshot?, effects: [NavEffect], camera: [NavCameraHint]) {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        for e in effects {
            effectHandler?(e)
            for c in effectStreams.values { c.yield(e) }
        }
        for h in camera { cameraHandler?(h) }
        if let snap, snap.revision > lastDeliveredRevision {
            lastDeliveredRevision = snap.revision
            snapshotHandler?(snap)
            for c in snapshotStreams.values { c.yield(snap) }
        }
    }

    func markDirty() { s.dirty = true }

    func speakLocked(_ text: String) {
        guard s.prefs.voiceOn, !text.isEmpty else { return }
        s.outEffects.append(.speak(text))
    }

    func speakLocked(_ phrase: NavPhrase) { speakLocked(strings.phrase(phrase)) }

    /// Status-line message (Android `statusView.text = …`) + transient toast (iOS fix (g)).
    func statusLocked(_ text: String, toast: Bool = true) {
        s.metrics.status = text
        s.metrics.statusWarning = false
        if toast { s.outEffects.append(.toast(text)) }
        s.dirty = true
    }

    func statusLocked(_ phrase: NavPhrase, toast: Bool = true) { statusLocked(strings.phrase(phrase), toast: toast) }

    func placesChangedLocked() {
        s.outEffects.append(.placesChanged)
        s.pinsRevision = nil
        s.dirty = true
    }

    func cameraLocked(_ hint: NavCameraHint) { s.outCamera.append(hint) }

    /// Starts tracked background work.
    func spawn(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        taskLock.lock()
        let task = Task { [weak self] in
            await operation()
            self?.removeTask(id)
        }
        tasks[id] = task
        taskLock.unlock()
        return task
    }

    var isNavTo: Bool { if case .navTo = s.mode { return true } else { return false } }
    var isGpx: Bool { if case .gpx = s.mode { return true } else { return false } }

    // MARK: - Snapshot

    func buildSnapshotLocked() -> NavSnapshot {
        refreshPinsIfNeededLocked()
        let navigating = s.mode.isNavigating
        var cue: HudCue? = nil
        if navigating { cue = s.cue ?? seedCueLocked() }
        var limit: SpeedLimit?
        if let raw = s.rawSpeedLimit {
            let d = SpeedLimitService.displayLimit(raw, units: units, keepNativeUnit: keepNativeLimitUnit)
            limit = SpeedLimitService.isVisible(d) ? d : nil
        }
        return NavSnapshot(mode: s.mode, destination: s.destination, route: s.route, progress: s.progress, cue: cue,
                           metrics: s.metrics, preview: s.preview, arrival: s.arrival,
                           showStraightLineToDestination: isNavTo && s.follower == nil && s.lastFix != nil,
                           puck: s.puck, puckBearingDeg: s.puckBearing, speedLimit: limit, pins: s.pins,
                           revision: s.revision)
    }

    /// Seeded maneuver row while navigating without content yet: arrive icon, "GPS", "To <name>".
    func seedCueLocked() -> HudCue {
        HudCue(dir: .arrive, distanceText: strings.gpsPlaceholder,
               text: strings.toDestination(s.destination?.name ?? s.trackName))
    }

    /// `collectPins`: home, parked, markers, favorites, GPX waypoints, session overlays (minus
    /// home / pin / "Parked"), lap gate "S/F"; distinct by "%.5f,%.5f|name"; (0,0) never drawn.
    func refreshPinsIfNeededLocked() {
        let rev = places.revision
        if s.pinsRevision == rev { return }
        s.pinsRevision = rev
        var out: [Place] = []
        if let h = places.home() { out.append(h) }
        if let p = places.parked() { out.append(p) }
        out += places.markers()
        out += places.favorites()
        let str = strings
        for w in s.gpxTrack?.waypoints ?? [] {
            out.append(Place(name: w.name ?? str.waypointName, lat: w.lat, lon: w.lon, category: "wpt"))
        }
        for p in s.overlays {
            if p.category == "home" || p.category == "pin" { continue }
            if p.name == "Parked" || p.name == str.parkedName || p.subtitle.range(of: "Parked", options: .caseInsensitive) != nil { continue }
            out.append(p)
        }
        if let g = s.lapTimer.gate { out.append(Place(name: "S/F", lat: g.lat, lon: g.lon, category: "lap")) }
        var seen = Set<String>()
        s.pins = out.filter { p in
            if p.lat == 0 && p.lon == 0 { return false }
            let key = NavNumberFormat.fixed(p.lat, decimals: 5) + "," + NavNumberFormat.fixed(p.lon, decimals: 5) + "|" + p.name
            return seen.insert(key).inserted
        }
    }

    // MARK: - Inputs

    /// Feeds one GPS fix through the Android per-fix pipeline (§4.10).
    public func updateLocation(_ fix: LocationFix) {
        mutate {
            processFixLocked(fix)
            s.dirty = true
        }
        _ = pendingSpeedLimitLookup()
    }

    /// Feeds a raw compass heading (degrees, e.g. `CLHeading.trueHeading`). The session applies the
    /// α = 0.15 unit-vector filter and processes at most one tick per 120 ms: off-route join arrows
    /// follow the phone while standing still, and when stopped in heading-up the puck / map bearing
    /// follows the compass.
    public func updateHeading(_ rawDeg: Double) {
        mutate {
            let az = s.heading.add(rawDeg)
            let now = clock.now()
            if let last = s.lastHeadingProcessAt, now - last < 0.12 { return }
            s.lastHeadingProcessAt = now
            guard let fix = s.lastFix else { return }
            if s.preview == nil {
                // Join-route arrow refresh (onHeadingTick).
                var prog: RouteProgress?
                if s.follower != nil {
                    prog = s.follower!.progress(lat: fix.lat, lon: fix.lon, speedMps: fix.speedMps ?? 0,
                                                gpsAltitudeM: fix.altitudeM, units: units)
                }
                let needGuide = (prog.map { $0.offTrackM > RouteFollower.offRouteGuideM } ?? false)
                    || (prog == nil && s.destination != nil && isNavTo)
                if needGuide {
                    s.progress = prog
                    applyProgressLocked(prog, fix: fix)
                    s.dirty = true
                }
            }
            if fix.isMoving { return }
            if s.headingUp {
                s.lastMapBearing = az
                s.puckBearing = az
                s.dirty = true
            }
        }
    }

    /// Heading-up (true) / north-up map. The puck bearing follows the compass only in heading-up.
    public func setHeadingUp(_ on: Bool) {
        mutate {
            s.headingUp = on
            if !on { s.lastMapBearing = 0 } else { s.lastMapBearing = bestBearingLocked() }
            statusLocked(on ? .headingUp : .northUp)
        }
    }

    public var headingUp: Bool {
        lock.lock(); defer { lock.unlock() }
        return s.headingUp
    }

    /// Applies new map preferences (units, voice, next stop, auto-finish, routing options). A
    /// change of route mode / avoids re-runs a pending route preview (Android segment taps).
    public func updatePreferences(_ prefs: MapPreferences) {
        mutate {
            let old = s.prefs
            s.prefs = prefs
            s.metrics.altUnit = NavFormat.altitudeUnitLabel(prefs.units)
            s.dirty = true
            let routingChanged = old.routeMode != prefs.routeMode || old.avoidTolls != prefs.avoidTolls
                || old.avoidHighways != prefs.avoidHighways
            if routingChanged, let p = s.preview, !p.pinMode {
                if p.isCircuit { startCircuitLocked() } else { previewPlaceLocked(p.place) }
            }
            if old.units != prefs.units, let fix = s.lastFix { refreshNavigationLocked(fix: fix) }
        }
    }

    public var preferences: MapPreferences {
        lock.lock(); defer { lock.unlock() }
        return s.prefs
    }

    /// Changes the language / display decimal separator of all produced text.
    public func setLanguage(_ language: NavLanguage, decimalSeparator: Character? = nil) {
        mutate {
            s.language = language
            if let decimalSeparator { s.decimalSeparator = decimalSeparator }
            let str = strings
            s.voice.strings = str
            s.follower?.strings = str
            if case .freeRide = s.mode { s.trackName = str.phrase(.freeRide) }
            s.pinsRevision = nil
            if let fix = s.lastFix { refreshNavigationLocked(fix: fix) }
            s.dirty = true
        }
    }

    /// Updates the OpenRouteService key used for future requests.
    public func setOrsApiKey(_ key: String) { router.orsApiKey = key }

    /// Session-only overlay places (e.g. corridor POIs) drawn as pins.
    public func setOverlayPlaces(_ overlays: [Place]) {
        mutate {
            s.overlays = overlays
            s.pinsRevision = nil
            s.dirty = true
        }
    }

    // MARK: - Per-fix pipeline

    private var speedLookupPending: (lat: Double, lon: Double)?

    private func pendingSpeedLimitLookup() -> Task<Void, Never>? {
        lock.lock()
        let pos = speedLookupPending
        speedLookupPending = nil
        lock.unlock()
        guard let pos else { return nil }
        let service = speedLimits
        return spawn { [weak self] in
            let v = await service.lookup(lat: pos.lat, lon: pos.lon)
            guard let self else { return }
            self.mutate {
                self.s.rawSpeedLimit = v
                self.s.dirty = true
            }
        }
    }

    func processFixLocked(_ fix: LocationFix) {
        // 1. lastLoc + places sync (pins refresh lazily on the next snapshot).
        s.lastFix = fix
        let speed = fix.speedMps ?? 0
        // 3. Ride stats and lap timer.
        s.rideStats.onLocation(lat: fix.lat, lon: fix.lon, speedMps: speed, nowMs: nowMs)
        let lapNow = fix.timeMs > 0 ? fix.timeMs : wallMs
        if s.lapTimer.onFix(lat: fix.lat, lon: fix.lon, nowMs: lapNow) {
            let h = s.lapTimer.hud(nowMs: wallMs)
            let last = h.lastMs.map(LapTimer.formatMs) ?? ""
            statusLocked(.lapFinished(h.finished, last))
            speakLocked(.lap(h.finished))
            Log.i("NAV", "[LAP] finished #\(h.finished) \(last)")
        }
        // 4. GPX one-time orientation.
        if isGpx && !s.gpxOriented, let track = s.gpxTrack {
            s.gpxOriented = true
            let heading: Double? = (fix.courseDeg != nil && Float(speed) > 1.0) ? fix.courseDeg : nil
            let (oriented, flipped) = track.orientedForRider(lat: fix.lat, lon: fix.lon, headingDeg: heading)
            if flipped {
                s.gpxTrack = oriented
                let f = RouteFollower(track: oriented, parityMode: parityMode, strings: strings)
                s.follower = f
                s.route = f.asRoute(label: "GPX")
                s.voice.reset()
                Log.i("NAV", "[GPX] reversed track to match rider heading")
                speakLocked(.followingTrackReversed)
            }
        }
        // 5. NAV_TO without a route → request one.
        if isNavTo, s.destination != nil, s.follower == nil, !s.routeRequested {
            s.routeRequested = true
            requestRouteLocked(from: fix, reason: .start)
        }
        // A preview opened without GPS routes as soon as a fix exists (iOS improvement).
        if s.previewWaitingForFix, let p = s.preview, !p.pinMode {
            s.previewWaitingForFix = false
            if p.isCircuit { startCircuitLocked() } else { previewPlaceLocked(p.place) }
        }
        // 6. Speed-limit lookup every > 12 s.
        if speedLimits.shouldRefresh() { speedLookupPending = (fix.lat, fix.lon) }
        // 7–10.
        refreshNavigationLocked(fix: fix)
    }

    /// Steps 7–10 of the per-fix pipeline: progress, status line, HUD, auto-reroute, puck.
    func refreshNavigationLocked(fix: LocationFix) {
        let speed = fix.speedMps ?? 0
        let speedKmh = NavFormat.speedKmh(fromMps: fix.speedMps)
        var prog: RouteProgress?
        if s.follower != nil {
            prog = s.follower!.progress(lat: fix.lat, lon: fix.lon, speedMps: speed, gpsAltitudeM: fix.altitudeM, units: units)
        }
        s.progress = prog
        let str = strings
        let avg = s.rideStats.avgKmh()
        if let f = s.follower {
            s.metrics.status = str.hudStatus(avgKmh: avg, progress: prog, totalM: f.totalM, units: units,
                                             showNextStop: s.prefs.showNextStop)
        } else if let dest = s.destination {
            let dM = GeoMath.haversineM(fix.lat, fix.lon, dest.lat, dest.lon)
            s.metrics.status = str.toDestinationStatus(speedKmh: speedKmh, distanceM: dM, name: dest.name, avgKmh: avg, units: units)
        } else {
            s.metrics.status = str.freeRideStatus(speedKmh: speedKmh, avgKmh: avg, units: units)
        }
        applyProgressLocked(prog, fix: fix)
        // 9. Auto-reroute (NAV_TO only).
        if isNavTo, s.destination != nil, let p = prog {
            if p.offTrackM > 80 {
                let now = clock.now()
                if s.offRouteSince == nil { s.offRouteSince = now }
                let offFor = now - (s.offRouteSince ?? now)
                let cooledDown = s.lastAutoReroute.map { now - $0 > 15 } ?? true
                if offFor > 8, cooledDown, let acc = fix.accuracyM, acc < 60 {
                    s.lastAutoReroute = now
                    s.offRouteSince = nil
                    Log.i("NAV", "[GPX] auto-reroute (off \(Int(p.offTrackM))m for \(Int(offFor))s)")
                    speakLocked(.rerouting)
                    requestRouteLocked(from: fix, reason: .recalc)
                }
            } else {
                s.offRouteSince = nil
            }
        }
        // 10. Bearing / puck.
        let moving = fix.isMoving
        let brng: Double
        if let course = fix.courseDeg, moving {
            brng = course
        } else if s.headingUp, let h = s.heading.heading {
            brng = h
        } else if let p = prog {
            brng = p.trackBearingDeg
        } else if let dest = s.destination, isNavTo {
            brng = GeoMath.bearingDeg(fix.lat, fix.lon, dest.lat, dest.lon)
        } else {
            brng = 0
        }
        if let p = prog, p.offTrackM < 40 {
            s.puck = GeoPoint(lat: p.snapLat, lon: p.snapLon)
        } else {
            s.puck = fix.point
        }
        s.puckBearing = brng
        if s.preview == nil { s.lastMapBearing = s.headingUp ? brng : 0 }
        s.dirty = true
    }

    /// GPS course while moving, else the smoothed compass, else the last map bearing.
    func bestBearingLocked() -> Double {
        if let fix = s.lastFix, fix.isMoving, let c = fix.courseDeg { return c }
        if let h = s.heading.heading { return h }
        return s.lastMapBearing
    }

    func altitudeTextLocked(_ progAlt: Double?, _ fix: LocationFix) -> String {
        if let a = progAlt { return NavFormat.formatAltitude(a, units: units) }
        if let a = fix.altitudeM { return NavFormat.formatAltitude(a, units: units) }
        return "—"
    }

    /// `applyProgress` (§11.7): metrics, maneuver row, voice and arrival.
    func applyProgressLocked(_ prog: RouteProgress?, fix: LocationFix) {
        let str = strings
        let speed = fix.speedMps ?? 0
        let now = wallClock()
        if !parityMode && isNavTo {
            // Start distance on the first progress after Go; "Already nearby" ends silently before
            // anything is shown or spoken.
            if let p = prog, s.follower != nil {
                noteNavProgressLocked(p.remainM)
            } else if let dest = s.destination {
                noteNavProgressLocked(GeoMath.haversineM(fix.lat, fix.lon, dest.lat, dest.lon))
            }
            if !isNavTo {
                s.metrics.alt = altitudeTextLocked(nil, fix)
                return
            }
        }
        if let p = prog, s.follower != nil {
            s.metrics.time = NavFormat.formatEta(p.etaSec)
            s.metrics.arrive = NavFormat.formatArrival(p.etaSec, now: now, timeZone: timeZone)
            s.metrics.left = str.distance(p.remainM, units)
            s.metrics.alt = altitudeTextLocked(p.altitudeM, fix)
            s.metrics.statusWarning = p.offTrackM > 80
            if p.offTrackM > RouteFollower.offRouteGuideM {
                let toSnap = GeoMath.bearingDeg(fix.lat, fix.lon, p.snapLat, p.snapLon)
                let dir = RouteFollower.dirToFace(headingDeg: bestBearingLocked(), targetBearingDeg: Double(Float(toSnap)))
                s.cue = HudCue(dir: dir, distanceText: str.distance(p.offTrackM, units), text: str.joinRouteWord(dir))
                if s.prefs.voiceOn, let phrase = s.voice.onJoinRoute(dir: dir, offTrackM: p.offTrackM, units: units, nowMs: nowMs) {
                    speakLocked(phrase)
                }
            } else if let turn = p.upcomingTurn {
                s.cue = HudCue(dir: turn.dir, distanceText: str.distance(turn.distanceFromRiderM, units),
                               text: turn.roadName ?? str.maneuverWord(turn.dir), lanes: turn.laneLabel)
                if s.prefs.voiceOn { speakPhrasesLocked(s.voice.onProgress(p, units: units, speedMps: speed)) }
            } else {
                s.cue = HudCue(dir: .arrive, distanceText: str.distance(p.remainM, units),
                               text: str.toDestination(s.destination?.name ?? s.trackName))
                if s.prefs.voiceOn { speakPhrasesLocked(s.voice.onProgress(p, units: units, speedMps: speed)) }
            }
            if isNavTo {
                if p.remainM < 40 && !s.destArrivedSpoken && canDeclareArrivalLocked(p.remainM) {
                    declareArrivalLocked(spoken: .destinationReached, delay: 2.0)
                }
            }
        } else if let dest = s.destination, isNavTo {
            let dM = GeoMath.haversineM(fix.lat, fix.lon, dest.lat, dest.lon)
            let eta = NavFormat.etaSeconds(remainM: dM, speedMps: speed)
            s.metrics.time = NavFormat.formatEta(eta)
            s.metrics.arrive = NavFormat.formatArrival(eta, now: now, timeZone: timeZone)
            s.metrics.left = str.distance(dM, units)
            s.metrics.alt = altitudeTextLocked(nil, fix)
            s.metrics.statusWarning = false
            let toDest = GeoMath.bearingDegF(fix.lat, fix.lon, dest.lat, dest.lon)
            let dir = RouteFollower.dirToFace(headingDeg: bestBearingLocked(), targetBearingDeg: Double(toDest))
            let text = (dir == .straight || dir == .continue) ? str.goAhead : str.joinRouteWord(dir)
            s.cue = HudCue(dir: dir, distanceText: str.distance(dM, units), text: text)
            if s.prefs.voiceOn && dM > RouteFollower.offRouteGuideM,
               let phrase = s.voice.onJoinRoute(dir: dir, offTrackM: dM, units: units, nowMs: nowMs) {
                speakLocked(phrase)
            }
            if dM < 80 && !s.destArrivedSpoken && canDeclareArrivalLocked(dM) {
                declareArrivalLocked(spoken: .arrivingAt(dest.name), delay: 2.5)
            }
        } else {
            s.metrics.time = "—"
            s.metrics.left = "—"
            s.metrics.arrive = "—"
            s.metrics.alt = altitudeTextLocked(nil, fix)
            s.metrics.statusWarning = false
            s.cue = nil
        }
    }

    /// Several phrases from one update: parity speaks them one by one (QUEUE_FLUSH — the last one
    /// wins), iOS joins them into one utterance.
    private func speakPhrasesLocked(_ phrases: [String]) {
        guard !phrases.isEmpty else { return }
        if parityMode || phrases.count == 1 {
            for p in phrases { speakLocked(p) }
        } else {
            speakLocked(phrases.joined(separator: ". "))
        }
    }

    // MARK: - Arrival (§4.8)

    /// iOS fix: capture the start distance on the first progress after Go; < 200 m → silent
    /// "Already nearby" finish (an app reopened near the destination never flashes Arrived).
    func noteNavProgressLocked(_ distM: Double) {
        guard s.navStartDist == nil else { return }
        s.navStartDist = distM
        if distM < 200 {
            s.destArrivedSpoken = true
            Log.i("NAV", "[GPX] near dest at nav start (\(Int(distM))m) — no Arrived sheet")
            finishToFreeRideLocked(spoken: .alreadyNearby, offerParking: false)
        }
    }

    /// `canDeclareArrival`: NAV_TO only; start ≥ 200 m and (≥ 15 s since Go or ≥ 80 m progressed).
    /// Parity mode reproduces Android's lazy capture (inside the arrival radius).
    func canDeclareArrivalLocked(_ distM: Double) -> Bool {
        guard isNavTo else { return false }
        if s.navStartDist == nil {
            s.navStartDist = distM
            if distM < 200 {
                s.destArrivedSpoken = true
                Log.i("NAV", "[GPX] near dest at nav start (\(Int(distM))m) — no Arrived sheet")
                finishToFreeRideLocked(spoken: .alreadyNearby, offerParking: false)
                return false
            }
        }
        guard let start = s.navStartDist, start >= 200 else { return false }
        let elapsed = clock.now() - (s.navEngagedAt ?? clock.now())
        let progressed = start - distM >= 80
        return elapsed >= 15 || progressed
    }

    private func declareArrivalLocked(spoken: NavPhrase, delay: TimeInterval) {
        s.destArrivedSpoken = true
        speakLocked(spoken)
        Log.i("NAV", "[GPX] arrival: \(strings.phrase(spoken))")
        if s.prefs.autoFinish {
            let gen = s.navGeneration
            scheduler.schedule(after: delay) { [weak self] in
                guard let self else { return }
                self.mutate {
                    guard self.s.navGeneration == gen, self.isNavTo else { return }
                    self.finishToFreeRideLocked(spoken: .arrived, offerParking: true)
                }
            }
        } else {
            s.arrival = ArrivalCard(title: strings.arrivalTitle(s.destination?.name), meta: strings.arrivalMeta)
            s.dirty = true
        }
    }

    /// `finishToFreeRideUi`: back to free ride (overlays kept), route / destination cleared, HUD
    /// metrics "—", status = `spoken` (spoken unless "Already nearby"), arrive card iff
    /// `offerParking`.
    func finishToFreeRideLocked(spoken: NavPhrase, offerParking: Bool) {
        if case .freeRide = s.mode, !offerParking { return }
        let arrivedName = s.destination?.name
        let str = strings
        s.mode = .freeRide
        s.trackName = str.phrase(.freeRide)
        s.destination = nil
        s.follower = nil
        s.route = nil
        s.progress = nil
        s.gpxTrack = nil
        s.gpxOriented = true
        s.navStartDist = nil
        s.navEngagedAt = nil
        s.routeRequested = false
        s.offRouteSince = nil
        s.navGeneration &+= 1
        s.routeToken &+= 1
        s.voice.reset()
        s.cue = nil
        s.metrics.time = "—"
        s.metrics.left = "—"
        s.metrics.arrive = "—"
        s.pinsRevision = nil
        let text = str.phrase(spoken)
        s.metrics.status = text
        s.metrics.statusWarning = false
        s.outEffects.append(.toast(text))
        if spoken != .alreadyNearby { speakLocked(text) }
        Log.i("NAV", "[GPX] finished → free ride (\(text))")
        s.arrival = offerParking ? ArrivalCard(title: str.arrivalTitle(arrivedName), meta: str.arrivalMeta) : nil
        s.dirty = true
    }

    // MARK: - Routing

    /// `requestOsrm`: single best route from `fix` to the destination; stale results are dropped.
    func requestRouteLocked(from fix: LocationFix, reason: RouteReason) {
        guard let dest = s.destination, isNavTo else { return }
        statusLocked(.routing)
        s.routeToken &+= 1
        let token = s.routeToken
        let gen = s.navGeneration
        let options = s.prefs.routeOptions
        let router = self.router
        _ = spawn { [weak self] in
            let route = await router.route(from: fix.point, to: dest.point, options: options)
            guard let self else { return }
            self.mutate {
                guard self.s.routeToken == token, self.s.navGeneration == gen, self.isNavTo,
                      self.s.destination == dest else { return }
                self.applyRoadRouteLocked(route, name: dest.name)
                self.statusLocked(.routeSummary(self.strings.distance(route.distanceM, self.units)))
                if route.distanceM >= 150 {
                    self.speakLocked(reason == .recalc ? .routeUpdated : .routeReady)
                }
                Log.i("NAV", "[GPX] route \(reason == .recalc ? "recalc" : "start") \(route.points.count) pts \(Int(route.distanceM))m")
            }
        }
    }

    /// `applyRoadRoute`: new follower for the route, heading-up follow (or overview without a fix).
    func applyRoadRouteLocked(_ route: Route, name: String) {
        s.follower = RouteFollower(route: route, name: name, parityMode: parityMode, strings: strings)
        s.route = route
        s.voice.reset()
        s.offRouteSince = nil
        s.dirty = true
        if let fix = s.lastFix {
            cameraLocked(.follow(headingUp: true))
            refreshNavigationLocked(fix: fix)
        } else {
            cameraLocked(.fit([route.points.map(\.point)], paddingPx: 72))
        }
    }
}
