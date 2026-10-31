// SPDX-License-Identifier: AGPL-3.0-or-later
// WAVE-2 SKELETON — owner: logic-session. The PUBLIC SURFACE below is the contract the SwiftUI
// layer codes against: implement the bodies, add private helpers / new files freely, add new
// public members only if needed (report them), never rename or remove existing public members.
//
// The ride: location → navigation → dash UI → projection (docs/ARCHITECTURE.md §3, §5 rules 7–8;
// navigation-dash.md; app-features §5.4 trip auto-log).
//
// Behaviour to implement:
// - Owns ONE `DashUIController(measurer: services.projection.textMeasurer)`. Builds `DashModel`
//   from: canvas (negotiated by the link, else `previewCanvas.size`), effective margins
//   (CanvasFit.effectiveMargins(settings.screenMargins, profileDefault:)), the NavSnapshot, the
//   last fix + compass, MapPreferences, night (DashFormat.isNight / NightModePolicy, re-evaluated
//   ≥ every 60 s), wall clock, `DashLanguage` from `core.language`, places, dash search state
//   (NavigationModel results when the dash search sheet is open), recording/lap state, link
//   banner text, hold message. Calls `ui.update(model)` whenever an input changes, coalesced.
// - Projection: `services.projection.setDisplayListProvider { now in ui.displayList(now: now) }`
//   (DashUIController is thread-safe), hold provider = `ui.displayList(forHoldScreen:now:)`
//   with a localized "Phone locked — unlock to update the map" message; `invalidate()` after
//   every `ui.update`; `requestTiles(ui.visibleTiles())` after camera changes; corridor prefetch
//   when a route is applied; `onTileLoaded` → invalidate. A ~10 Hz main-actor timer calls
//   `ui.tick(now:)` (long-press + toasts) and performs returned intents.
// - Intents (`DashIntent`, from dash touches, handlebar and the phone preview): camera/UI-only
//   intents are already applied by the controller; map the rest onto `core.navigation`
//   (go/selectRoute/cancelPreview/startCircuit/dropPin/save…/endNavigation/parkHere/goHome/
//   setHomeHere/recalc/toggleVoice/toggleLapTimer/navigateSavedPlace/searchChip/
//   selectSearchResult/previewPlace/…), settings intents onto SettingsModel.setMapPreferences,
//   `.toggleRecording` onto TripsModel, `.typeOnPhone`/`.openSearch` onto
//   NavigationModel.requestTypeOnPhone(), `.findParking` = dismissArrival(announce:false) +
//   searchNearby(Parking). NavEffect.speak → `services.speech.speak` (muted when voice is off).
// - Location: `services.location.onFix` → `core.navigation.updateLocation`, `core.tripRecorder`
//   (+ TripAutoLogPolicy), UI model; `onRawHeading` → `core.navigation.updateHeading` + compass.
//   Start updates when a ride/link starts or the dash preview is visible; background location
//   only while a ride is active (`setRideActive`).
// - Ride Mode (foreground "pocket" mode): `isIdleTimerDisabled = true`, the UI shows a black
//   overlay; exiting restores the idle timer unless keepScreenOn while linked.
// - Scene phases: inactive → `projection.prepareHoldPicture()`; background →
//   `projection.enterBackground()`; active → `projection.enterForeground()`.
// - Encoder parameters: `EncoderPlanner.plan(...)` from the active profile + settings + the
//   AdaptivePolicy decision (AUTO power mode, ticked every 5 s with ThermalLevel / Low Power /
//   FrameQueue overflow); push with `projection.setEncoderParameters`.
//
// Ported from OpenCfMoto (Android) GpxDashUi.kt (bind / per-fix pipeline glue / menu handlers),
// GpxSession.kt, TripAutoLog.kt and AdaptiveVideoController.kt (the 5 s tick).
//
// Implementation notes:
// - Navigation snapshots and effects are consumed through `NavigationSession.snapshots()` /
//   `effects()` (multi-consumer streams) so NavigationModel can keep its own subscription.
// - The DashProjecting port exposes no FrameQueue overflow counter; the own-UI engine is
//   pull-paced (it renders only when the dash has taken the previous frame), so its queue does not
//   overflow and AdaptivePolicy's link factor stays at 1.0 — the AUTO tick adapts to heat.
// - A recording that the auto-log policy did not start is treated as manual and never stopped.

import Foundation
import Observation
import OpenCfMotoCore

/// Timers of the ride loop (Android values; tests shorten them).
struct RideTuning {
    /// UI timer: long-press, toasts, lap card, clock / night re-evaluation (~10 Hz).
    var uiTickInterval: TimeInterval = 0.1
    /// Trip auto-log + AdaptivePolicy + location policy (Android watchdog, 5 s).
    var housekeepingInterval: TimeInterval = AdaptivePolicy.tickInterval
    /// Minimum gap between compass-driven model updates (≤ 8 Hz).
    var compassModelInterval: TimeInterval = 0.125
    /// After a toast or intent, watch the controller's toast for this long (phone preview redraw).
    var toastWatch: TimeInterval = 3.5
}

@MainActor
@Observable
public final class RideModel {
    @ObservationIgnored let core: AppCore
    @ObservationIgnored let settings: SettingsModel
    @ObservationIgnored let navigation: NavigationModel
    @ObservationIgnored let trips: TripsModel

    /// Foreground pocket mode: screen kept awake, black overlay, dash keeps streaming.
    public private(set) var isRideModeActive = false
    /// Canvas the dash UI is laid out for (negotiated by the link, else `previewCanvas`).
    public private(set) var canvasSize: DashSize = DashPreviewCanvas.landscape800x384.size
    /// Canvas used for the phone preview while no dash is connected.
    public var previewCanvas: DashPreviewCanvas = .landscape800x384 {
        didSet { previewCanvasChanged() }
    }
    /// True while a dash is linked and the own UI is being projected.
    public private(set) var isProjecting = false
    /// Bumps whenever the dash picture changes (the phone preview redraws on change).
    public private(set) var revision: UInt64 = 0
    /// Latest fix (speed / accuracy for the home card).
    public private(set) var lastFix: LocationFix?
    /// Current speed text in the rider's units ("47 km/h").
    public private(set) var speedText: String = ""
    /// Status of the location permission / GPS for the UI ("Waiting for GPS…").
    public private(set) var gpsStatus: String = ""

    // MARK: Internal state

    /// The one dash UI (thread-safe; the render queue calls `displayList(now:)`).
    @ObservationIgnored nonisolated let ui: DashUIController
    /// Encoder planning inputs shared with the link.
    @ObservationIgnored let encoderPlan: RideEncoderPlan
    @ObservationIgnored var tuning = RideTuning()

    @ObservationIgnored private let clock: MonotonicClock
    @ObservationIgnored private var cachedSettings: BikeSettings
    @ObservationIgnored private var navSnapshot: NavSnapshot
    @ObservationIgnored private let dashLanguage: DashLanguage
    @ObservationIgnored private var places: DashPlaces
    @ObservationIgnored private var dashSearch = DashSearchState()
    @ObservationIgnored private var lastPhoneSearch: PhoneSearchState?
    @ObservationIgnored private var compass = HeadingSmoother()
    @ObservationIgnored private var compassDeg: Double?
    @ObservationIgnored private var lastCompassModelAt: TimeInterval = -.greatestFiniteMagnitude
    @ObservationIgnored private var negotiatedCanvas: VideoCanvas?
    @ObservationIgnored private var identifiedProfile: BikeProfile?
    @ObservationIgnored private var earlyProfile: BikeProfile = .legacy
    @ObservationIgnored private var linkBanner: String?
    @ObservationIgnored private var nightMonitor = NightModeMonitor()
    @ObservationIgnored private var lastModel: DashModel?
    @ObservationIgnored private var updateScheduled = false
    @ObservationIgnored private var lastRequestedTiles: [DashMapTile] = []
    @ObservationIgnored private var lastRouteKey: String?
    @ObservationIgnored private var lastPushedParameters: EncoderParameters?
    @ObservationIgnored private var sessionActive = false
    @ObservationIgnored private var sessionIsMirror = false
    @ObservationIgnored private var previewRequests = 0
    @ObservationIgnored private var appliedRideActive: Bool?
    @ObservationIgnored private var linkPhase: ConnectionPhase = .idle
    @ObservationIgnored private var autoStartedRecording = false
    @ObservationIgnored private var autoLogSuppressed = false
    @ObservationIgnored private var toastWatchUntil: TimeInterval = -.greatestFiniteMagnitude
    @ObservationIgnored private var lastToastText: String?
    @ObservationIgnored private var uiTickTask: Task<Void, Never>?
    @ObservationIgnored private var housekeepingTask: Task<Void, Never>?
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var effectTask: Task<Void, Never>?
    @ObservationIgnored private var chipSearchTask: Task<Void, Never>?
    @ObservationIgnored private var placesListener: UUID?
    @ObservationIgnored private let tileRefreshPending = Locked(false)

    public init(core: AppCore, settings: SettingsModel, navigation: NavigationModel, trips: TripsModel) {
        self.core = core
        self.settings = settings
        self.navigation = navigation
        self.trips = trips
        let services = core.services
        clock = services.clock
        ui = DashUIController(measurer: services.projection.textMeasurer)
        let current = core.currentSettings
        cachedSettings = current
        encoderPlan = RideEncoderPlan(settings: current, lowPowerMode: services.system.isLowPowerModeEnabled)
        navSnapshot = core.navigation.snapshot
        dashLanguage = DashLanguage(rawValue: core.language.rawValue) ?? .en
        places = Self.loadPlaces(core.places)
        earlyProfile = Self.earlyProfile(core: core, settings: current)
        services.speech.isMuted = !current.map.voiceOn
        wireProjection()
        wireLocation()
        wireNavigation()
        wireSettings()
        flushModel()
        updateGpsStatus()
        startHousekeeping()
    }

    // MARK: Phone dash preview (the same picture the dash shows)

    /// Thread-safe snapshot of the dash picture at monotonic time `now` (services.clock).
    /// The phone preview view draws it with the platform DashRenderer.
    public nonisolated func displayList(now: TimeInterval) -> DashDisplayList {
        ui.displayList(now: now)
    }

    /// Phone preview interactions (taps/drags on the preview are dash touches in canvas pixels;
    /// on-screen buttons may send handlebar keys).
    public func sendPreviewInput(_ input: DashInput) {
        if updateScheduled { flushModel() } // hit-test against the picture the rider sees
        let intents = ui.handle(input, now: clock.now())
        perform(intents, fromDash: false)
        uiChanged()
    }

    // MARK: Ride Mode

    public func enterRideMode() {
        guard !isRideModeActive else { return }
        isRideModeActive = true
        Log.i("RIDE", "Ride Mode on (screen kept awake)")
        applyIdleTimer()
        updateLoops()
    }

    public func exitRideMode() {
        guard isRideModeActive else { return }
        isRideModeActive = false
        Log.i("RIDE", "Ride Mode off")
        applyIdleTimer()
        updateLoops()
    }

    /// Starts GPS + navigation session use without a dash (preview / testing on the phone).
    public func startLocationPreview() {
        previewRequests += 1
        if core.services.location.permission == .notDetermined {
            core.services.location.requestPermission()
        }
        applyLocationPolicy()
        updateLoops()
    }

    public func stopLocationPreview() {
        previewRequests = max(0, previewRequests - 1)
        applyLocationPolicy()
        updateLoops()
    }

    // MARK: Model-to-model (internal) — called by ConnectionModel / AppModel / ControlsModel

    /// The own-UI frame source for EasyConnLink.
    var frameSource: VideoFrameSource { core.services.projection.frameSource }

    /// `LinkOptions.encoderParameters` for a link session (called on a link task at REQ 16).
    func encoderParametersProvider(ownUI: Bool) -> @Sendable (BikeProfile, VideoCanvas) -> EncoderParameters {
        let plan = encoderPlan
        return { profile, _ in plan.plan(profile: profile, ownUI: ownUI) }
    }

    /// A Connect / Mirror session started (true) or ended (false): GPS (background while riding),
    /// screen awake, the 5 s housekeeping (auto-log, AUTO power mode).
    func sessionChanged(active: Bool, mirror: Bool) {
        let changed = active != sessionActive || mirror != sessionIsMirror
        sessionActive = active
        sessionIsMirror = active && mirror
        guard changed else { return }
        autoLogSuppressed = false
        if active {
            encoderPlan.adaptive.reset()
            lastPushedParameters = nil
        }
        applyLocationPolicy()
        applyIdleTimer()
        evaluateTripAutoLog()
        updateLoops()
    }

    /// Link started projecting the own UI (true) / stopped (false).
    func projectionChanged(active: Bool) {
        guard active != isProjecting else { return }
        isProjecting = active
        Log.i("RIDE", active ? "own dash UI is live on the dash" : "own dash UI projection ended")
        if active {
            pushEncoderPlan(force: true)
        } else {
            negotiatedCanvas = nil
            identifiedProfile = nil
            linkBanner = nil
            flushModel()
        }
        evaluateTripAutoLog()
        applyIdleTimer()
    }

    /// REQ 16 negotiated a canvas.
    func canvasNegotiated(_ canvas: VideoCanvas) {
        negotiatedCanvas = canvas
        flushModel() // the next frame must be laid out for exactly this canvas
    }

    /// Dash identified: profile default margins / touch support.
    func profileIdentified(_ profile: BikeProfile) {
        identifiedProfile = profile
        flushModel()
        pushEncoderPlan(force: false)
    }

    /// Ghost-filtered dash touch (canvas pixels).
    func handleDashTouch(_ touch: DashTouch) {
        let intents = ui.handle(.touch(touch), now: clock.now())
        perform(intents, fromDash: true)
        uiChanged()
    }

    /// Handlebar command (ControlsModel) or other input.
    func handleDashInput(_ input: DashInput) {
        let intents = ui.handle(input, now: clock.now())
        perform(intents, fromDash: true)
        uiChanged()
    }

    /// Short banner on the dash ("Reconnecting…"), nil to clear.
    func setLinkBanner(_ text: String?) {
        guard text != linkBanner else { return }
        linkBanner = text
        setNeedsModelUpdate()
    }

    /// Link state for TripAutoLogPolicy.
    func linkPhaseChanged(_ phase: ConnectionPhase) {
        guard phase != linkPhase else { return }
        linkPhase = phase
        evaluateTripAutoLog()
    }

    func scenePhaseChanged(_ phase: AppScenePhase) {
        let projection = core.services.projection
        switch phase {
        case .inactive:
            if isProjecting { projection.prepareHoldPicture() }
        case .background:
            projection.enterBackground()
        case .active:
            projection.enterForeground()
            setNeedsModelUpdate()
        }
    }

    /// Location permission changed (PermissionsModel → AppModel).
    func locationPermissionChanged(_ permission: LocationPermission) {
        applyLocationPolicy()
    }

    private func previewCanvasChanged() {
        guard negotiatedCanvas == nil else { return }
        flushModel()
    }

    // MARK: - Wiring

    private func wireProjection() {
        let projection = core.services.projection
        let ui = self.ui
        projection.setDisplayListProvider { now in ui.displayList(now: now) }
        let hold = SessionText.holdMessage(core.language)
        projection.setHoldDisplayListProvider { now in ui.displayList(forHoldScreen: hold, now: now) }
        let pending = tileRefreshPending
        projection.onTileLoaded = { [weak self, weak projection] in
            projection?.invalidate()
            let schedule = pending.withLock { p -> Bool in
                if p { return false }
                p = true
                return true
            }
            guard schedule else { return }
            Task { @MainActor [weak self] in
                pending.set(false)
                self?.revision &+= 1
            }
        }
        projection.setTileURLTemplate(cachedSettings.tileURLTemplate)
        projection.setThermalCapsEnabled(cachedSettings.powerMode != .auto)
    }

    private func wireLocation() {
        let loc = core.services.location
        loc.onFix = { [weak self] fix in self?.handleFix(fix) }
        loc.onRawHeading = { [weak self] deg in self?.handleHeading(deg) }
        if let fix = loc.lastFix { lastFix = fix }
    }

    private func wireNavigation() {
        let nav = core.navigation
        let snapshots = nav.snapshots()
        snapshotTask = Task { [weak self] in
            for await snap in snapshots {
                guard let self else { return }
                self.navSnapshotChanged(snap)
            }
        }
        let effects = nav.effects()
        effectTask = Task { [weak self] in
            for await effect in effects {
                guard let self else { return }
                self.handleNavEffect(effect)
            }
        }
        placesListener = core.places.addChangeListener { [weak self] _ in
            Task { @MainActor [weak self] in self?.placesChanged() }
        }
    }

    private func wireSettings() {
        settings.observe { [weak self] _ in self?.settingsChanged() }
        core.settings.subscribe { [weak self] in
            Task { @MainActor [weak self] in self?.settingsChanged() }
        }
        core.services.system.onPowerStateChange = { [weak self] in self?.powerStateChanged() }
    }

    // MARK: - Inputs

    private func handleFix(_ fix: LocationFix) {
        lastFix = fix
        core.navigation.updateLocation(fix)
        core.tripRecorder.ingest(fix) // no-op unless recording
        let units = cachedSettings.map.units
        let text = DashFormat.speed(mps: fix.speedMps ?? 0, units: units) + " " + DashFormat.speedUnit(units)
        if text != speedText { speedText = text }
        updateGpsStatus()
        setNeedsModelUpdate()
    }

    private func handleHeading(_ raw: Double) {
        guard raw.isFinite else { return }
        core.navigation.updateHeading(raw)
        compassDeg = compass.add(raw)
        let now = clock.now()
        if now - lastCompassModelAt >= tuning.compassModelInterval {
            lastCompassModelAt = now
            setNeedsModelUpdate()
        }
    }

    private func navSnapshotChanged(_ snap: NavSnapshot) {
        navSnapshot = snap
        let key = Self.routeKey(snap.route)
        if key != lastRouteKey {
            lastRouteKey = key
            if let route = snap.route, route.points.count >= 2 {
                core.services.projection.prefetchCorridor(Self.sampled(route.points.map(\.point), max: 400))
            }
        }
        setNeedsModelUpdate()
    }

    private func handleNavEffect(_ effect: NavEffect) {
        switch effect {
        case let .speak(text):
            speak(text)
        case let .toast(text):
            showDashToast(text)
        case .placesChanged:
            placesChanged()
        }
    }

    private func placesChanged() {
        let p = Self.loadPlaces(core.places)
        guard p != places else { return }
        places = p
        setNeedsModelUpdate()
    }

    private func settingsChanged() {
        let s = core.currentSettings
        let old = cachedSettings
        cachedSettings = s
        let projection = core.services.projection
        if s.tileURLTemplate != old.tileURLTemplate { projection.setTileURLTemplate(s.tileURLTemplate) }
        if s.map.voiceOn != old.map.voiceOn { core.services.speech.isMuted = !s.map.voiceOn }
        if s.powerMode != old.powerMode { projection.setThermalCapsEnabled(s.powerMode != .auto) }
        if s.videoQuality != old.videoQuality || s.powerMode != old.powerMode {
            encoderPlan.update(quality: s.videoQuality, powerMode: s.powerMode,
                               lowPowerMode: core.services.system.isLowPowerModeEnabled)
            pushEncoderPlan(force: false)
        }
        if s.keepScreenOn != old.keepScreenOn { applyIdleTimer() }
        if s.logTrips != old.logTrips { evaluateTripAutoLog() }
        if s.map.units != old.map.units, let fix = lastFix {
            speedText = DashFormat.speed(mps: fix.speedMps ?? 0, units: s.map.units) + " " + DashFormat.speedUnit(s.map.units)
        }
        earlyProfile = Self.earlyProfile(core: core, settings: s) // the selected bike may have changed
        setNeedsModelUpdate()
    }

    private func powerStateChanged() {
        let s = cachedSettings
        if encoderPlan.update(quality: s.videoQuality, powerMode: s.powerMode,
                              lowPowerMode: core.services.system.isLowPowerModeEnabled) {
            pushEncoderPlan(force: false)
        }
    }

    // MARK: - Dash model

    func setNeedsModelUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        Task { @MainActor [weak self] in self?.flushModel() }
    }

    /// Builds the model now and feeds the controller if anything changed.
    func flushModel() {
        updateScheduled = false
        let m = buildModel()
        if canvasSize != m.canvas { canvasSize = m.canvas }
        guard m != lastModel else { return }
        lastModel = m
        ui.update(m)
        uiChanged()
    }

    private func buildModel() -> DashModel {
        let s = cachedSettings
        let canvas = negotiatedCanvas.map(DashModel.canvasSize) ?? previewCanvas.size
        let profileDefault = (identifiedProfile ?? earlyProfile).defaultMargins
        let margins = CanvasFit.effectiveMargins(s.screenMargins, profileDefault: profileDefault)
        let wall = core.services.now()
        let night = nightMonitor.evaluate(theme: s.map.theme, phoneDarkMode: false, date: wall, now: clock.now())
        let lap = core.navigation.lapCard().map { DashLapTimer(title: $0.current, meta: $0.meta) }
        // The clock chip shows HH:mm: a minute-aligned date keeps the model stable within a minute.
        let minute = Date(timeIntervalSince1970: (wall.timeIntervalSince1970 / 60).rounded(.down) * 60)
        return DashModel(canvas: canvas, margins: margins, nav: navSnapshot, fix: lastFix, compassHeadingDeg: compassDeg,
                         preferences: s.map, isNight: night, date: minute, timeZone: .current, language: dashLanguage,
                         places: places, search: dashSearch, recording: core.tripRecorder.isRecording, lapTimer: lap,
                         toastText: nil, linkBanner: linkBanner, holdMessage: nil, showClock: true,
                         handlebarFocus: s.handlebarControl)
    }

    /// The dash picture changed: re-render, warm the visible tiles, redraw the phone preview.
    private func uiChanged() {
        let projection = core.services.projection
        projection.invalidate()
        let tiles = ui.visibleTiles()
        if tiles != lastRequestedTiles {
            lastRequestedTiles = tiles
            if !tiles.isEmpty { projection.requestTiles(tiles) }
        }
        revision &+= 1
    }

    /// A toast may be on screen: let the UI tick redraw the phone preview when it expires.
    private func watchToast() {
        toastWatchUntil = clock.now() + tuning.toastWatch
    }

    private func showDashToast(_ text: String) {
        guard !text.isEmpty else { return }
        ui.showToast(text, now: clock.now())
        watchToast()
        uiChanged()
    }

    private func speak(_ text: String) {
        guard cachedSettings.map.voiceOn, !text.isEmpty else { return }
        core.services.speech.speak(text)
    }

    // MARK: - Timers

    private func updateLoops() {
        let wanted = sessionActive || previewRequests > 0 || isRideModeActive
        if wanted, uiTickTask == nil {
            uiTickTask = Task { [weak self] in
                var n = 0
                while !Task.isCancelled {
                    let interval = self?.tuning.uiTickInterval ?? 0.1
                    await sleepSeconds(interval)
                    guard !Task.isCancelled, let self else { return }
                    n &+= 1
                    self.uiTick(slow: n % 10 == 0)
                }
            }
        } else if !wanted, let t = uiTickTask {
            t.cancel()
            uiTickTask = nil
        }
    }

    private func startHousekeeping() {
        housekeepingTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.tuning.housekeepingInterval ?? AdaptivePolicy.tickInterval
                await sleepSeconds(interval)
                guard !Task.isCancelled, let self else { return }
                self.housekeeping()
            }
        }
    }

    /// ~10 Hz: long-press / auto-recenter timers, lap card, toasts, clock / night, phone search.
    private func uiTick(slow: Bool) {
        let now = clock.now()
        let intents = ui.tick(now: now)
        if !intents.isEmpty {
            perform(intents, fromDash: true)
            uiChanged()
        }
        if now < toastWatchUntil {
            let toast = ui.state.toast
            if toast != lastToastText {
                lastToastText = toast
                revision &+= 1
            }
        }
        syncPhoneSearch()
        if slow || core.navigation.isLapTimerOn { flushModel() }
    }

    /// Runs the 5 s duties now (tests, and right after a settings change that matters).
    func runHousekeeping() { housekeeping() }

    /// Android's 5 s watchdog duties: trip auto-log, AUTO power mode, GPS policy.
    private func housekeeping() {
        evaluateTripAutoLog()
        adaptiveTick()
        applyLocationPolicy()
    }

    // MARK: - Location, screen, trips, encoder

    private func applyLocationPolicy() {
        let loc = core.services.location
        let recording = core.tripRecorder.isRecording
        let wanted = sessionActive || previewRequests > 0 || recording
        let background = sessionActive || recording
        if wanted, loc.permission.isAuthorized {
            if !loc.isUpdating {
                loc.start(rideActive: background)
                appliedRideActive = background
                Log.i("RIDE", "GPS on (background=\(background))")
            } else if appliedRideActive != background {
                loc.setRideActive(background)
                appliedRideActive = background
            }
        } else if !wanted, loc.isUpdating {
            loc.stop()
            appliedRideActive = nil
            Log.i("RIDE", "GPS off")
        }
        updateGpsStatus()
    }

    private func updateGpsStatus() {
        let loc = core.services.location
        let l = core.language
        let status: String
        if !loc.permission.isAuthorized {
            status = SessionText.locationPermissionNeeded(l)
        } else if !loc.isUpdating {
            status = SessionText.gpsOff(l)
        } else if let fix = lastFix {
            status = loc.isPrecise ? SessionText.gpsFix(accuracyM: fix.accuracyM.map { Int($0.rounded()) }, l)
                : SessionText.approximateLocation(l)
        } else {
            status = SessionText.waitingForGps(l)
        }
        if status != gpsStatus { gpsStatus = status }
    }

    private func applyIdleTimer() {
        let keepAwake = isRideModeActive || (sessionActive && cachedSettings.keepScreenOn)
        let system = core.services.system
        if system.isIdleTimerDisabled != keepAwake { system.isIdleTimerDisabled = keepAwake }
    }

    /// TripAutoLogPolicy on every link-phase change and every 5 s (app-features §5.4, iOS rules).
    private func evaluateTripAutoLog() {
        let recorder = core.tripRecorder
        let recording = recorder.isRecording
        if !recording { autoStartedRecording = false }
        let manual = trips.isManualRecording || (recording && !autoStartedRecording)
        let streaming = linkPhase == .streaming
        let action = TripAutoLogPolicy.action(logTrips: cachedSettings.logTrips && !autoLogSuppressed, streaming: streaming,
                                              dashUILive: isProjecting, recording: recording, manualRecording: manual)
        switch action {
        case .start:
            if recorder.start() {
                autoStartedRecording = true
                Log.i("trip", TripAutoLogPolicy.startLogMessage(streaming: streaming, dashUILive: isProjecting))
                trips.recorderStateChanged()
                applyLocationPolicy()
                setNeedsModelUpdate()
            }
        case .stopAndSave:
            recorder.stopAndSave()
            autoStartedRecording = false
            trips.recorderStateChanged()
            applyLocationPolicy()
            setNeedsModelUpdate()
        case .none:
            break
        }
    }

    private func adaptiveTick() {
        guard sessionActive, !sessionIsMirror, isProjecting else { return }
        let profile = identifiedProfile ?? earlyProfile
        let base = encoderPlan.baseBitrate(profile: profile, ownUI: true)
        let adjustment = encoderPlan.adaptive.tick(powerMode: cachedSettings.powerMode, baseBitrate: base,
                                                   thermal: core.services.system.thermalLevel, overflowTotal: 0)
        if adjustment != nil { pushEncoderPlan(force: false) }
    }

    /// Pushes the current encoder plan to the projection (own UI only).
    private func pushEncoderPlan(force: Bool) {
        guard isProjecting, !sessionIsMirror else { return }
        let p = encoderPlan.plan(profile: identifiedProfile ?? earlyProfile, ownUI: true)
        guard force || p != lastPushedParameters else { return }
        lastPushedParameters = p
        core.services.projection.setEncoderParameters(p)
    }

    // MARK: - Intents

    /// Performs dash intents (UI-only ones are already applied by the controller).
    func perform(_ intents: [DashIntent], fromDash: Bool) {
        guard !intents.isEmpty else { return }
        watchToast() // UI-only intents show feedback toasts ("Centered on GPS", "Heading up"…)
        for intent in intents { performIntent(intent, fromDash: fromDash) }
    }

    private func performIntent(_ intent: DashIntent, fromDash: Bool) {
        let nav = core.navigation
        let l = core.language
        let strings = NavStrings(language: l)
        Log.d("RIDE", "[dash] \(intent)")
        switch intent {
        case .recenter, .zoomIn, .zoomOut, .toggleFollow, .overview, .openMenu:
            break
        case .toggleCompass, .toggleHeadingUp:
            let up = ui.state.camera.headingUp
            if nav.headingUp != up { nav.setHeadingUp(up) }
        case .openSearch:
            adoptPhoneSearch(force: true)
            if fromDash { requestTypeOnPhone(announce: true) }
        case .typeOnPhone:
            requestTypeOnPhone(announce: fromDash)
        case .closeSheets:
            chipSearchTask?.cancel()
            dashSearch = DashSearchState()
            setNeedsModelUpdate()
        case let .dropPin(point):
            nav.dropPin(at: point)
        case .endNavigation:
            nav.endNavigation()
        case .go:
            nav.go()
        case let .selectRoute(index):
            nav.selectRoute(index)
        case .cancelPreview:
            nav.cancelPreview()
        case .startCircuit:
            nav.startCircuit()
        case .saveFavorite:
            nav.saveFavoriteFromPreview()
        case .setHome:
            nav.setHomeFromPreview()
        case .addMarker:
            nav.addMarkerFromPreview()
        case .markArrivalParking:
            nav.arrivalParkHere()
        case .findParking:
            nav.dismissArrival(announce: false)
            if let chip = PlaceSearch.poiChips.first(where: { $0.label == "Parking" }) { runChipSearch(chip) }
        case .dismissArrival:
            nav.dismissArrival()
        case .parkHere:
            nav.parkHere()
        case .goHome:
            nav.goHome()
        case .setHomeHere:
            nav.setHomeHere()
        case .recalc:
            nav.updatePreferences(cachedSettings.map)
            nav.recalc()
            nightMonitor = NightModeMonitor()
            setNeedsModelUpdate()
        case .toggleRecording:
            toggleRecording()
        case .toggleVoice:
            setVoice(!cachedSettings.map.voiceOn, announce: true)
        case .toggleLapTimer:
            nav.toggleLapTimer()
        case let .setUnits(u):
            updateMapPreferences { $0.units = u }
        case let .setTheme(t):
            updateMapPreferences { $0.theme = t }
        case let .setVoice(on):
            setVoice(on, announce: false)
        case let .setNextStop(on):
            updateMapPreferences { $0.showNextStop = on }
        case let .setAutoFinish(on):
            updateMapPreferences { $0.autoFinish = on }
        case let .setChrome(c):
            updateMapPreferences { $0.chrome = c }
        case let .setRouteMode(m):
            updateMapPreferences { $0.routeMode = m }
        case let .setAvoidTolls(on):
            updateMapPreferences { $0.avoidTolls = on }
        case let .setAvoidHighways(on):
            updateMapPreferences { $0.avoidHighways = on }
        case let .searchChip(id):
            if let chip = PlaceSearch.poiChips.first(where: { $0.label == id }) { runChipSearch(chip) }
        case let .selectSearchResult(index):
            if let results = dashSearch.results, results.indices.contains(index) { nav.previewPlace(results[index]) }
        case let .previewPlace(place):
            nav.previewPlace(place)
        case let .savePlace(place):
            navigation.saveFavorite(place)
            showDashToast(strings.phrase(.savedToFavorites(place.name)))
        case let .addMarkerFor(place):
            navigation.addMarker(place)
            showDashToast(strings.phrase(.markerAdded))
        case let .deletePlace(place):
            navigation.delete(place)
            showDashToast(SessionText.placeDeleted(l))
        case let .navigateSavedPlace(slot):
            Task { await nav.navigateToSavedPlace(slot) }
        }
    }

    /// "Type on your phone" (DashRemote.requestTypeOnPhone): focus the phone search field, buzz,
    /// and tell the rider by voice when the request came from the dash.
    private func requestTypeOnPhone(announce: Bool) {
        navigation.requestTypeOnPhone()
        guard announce else { return }
        core.services.system.hapticTap()
        speak(NavStrings(language: core.language).phrase(.typeSearchOnPhone))
    }

    private func toggleRecording() {
        let l = core.language
        let recorder = core.tripRecorder
        if recorder.isRecording {
            if autoStartedRecording {
                // The rider stopped the automatic log: do not restart it until the session ends.
                autoLogSuppressed = true
                recorder.stopAndSave()
                autoStartedRecording = false
                trips.recorderStateChanged()
            } else {
                trips.stopRecording()
                if recorder.isRecording { // whoever started it: the dash button always stops it
                    recorder.stopAndSave()
                    trips.recorderStateChanged()
                }
            }
            showDashToast(SessionText.recordingSavedToast(l))
            speak(SessionText.recordingSavedVoice(l))
        } else {
            if core.services.location.permission.isAuthorized {
                trips.startRecording()
                if !recorder.isRecording, recorder.start() { trips.recorderStateChanged() }
            }
            if recorder.isRecording {
                showDashToast(SessionText.recordingRide(l))
                speak(SessionText.recordingStartedVoice(l))
            } else {
                showDashToast(SessionText.cannotRecord(l))
            }
        }
        applyLocationPolicy()
        setNeedsModelUpdate()
    }

    private func setVoice(_ on: Bool, announce: Bool) {
        updateMapPreferences { $0.voiceOn = on }
        core.navigation.setVoiceEnabled(on)
        if !on { core.services.speech.stop() }
        if announce { showDashToast((on ? DashText.voiceOn : DashText.voiceMuted).localized(dashLanguage)) }
    }

    /// Persists a dash settings segment (SettingsModel) and applies it at once.
    private func updateMapPreferences(_ change: (inout MapPreferences) -> Void) {
        var prefs = cachedSettings.map
        change(&prefs)
        guard prefs != cachedSettings.map else { return }
        cachedSettings.map = prefs
        settings.setMapPreferences(prefs)
        core.navigation.updatePreferences(prefs)
        core.services.speech.isMuted = !prefs.voiceOn
        flushModel()
    }

    // MARK: - Dash search sheet

    private func runChipSearch(_ chip: PlaceSearch.PoiChip) {
        chipSearchTask?.cancel()
        let strings = NavStrings(language: core.language)
        let label = strings.poiChipLabel(chip.label)
        dashSearch = DashSearchState(query: "", results: nil, status: strings.phrase(.findingNearby(label)))
        setNeedsModelUpdate()
        let nav = core.navigation
        chipSearchTask = Task { [weak self] in
            do {
                let found = try await nav.searchNearby(chip)
                guard !Task.isCancelled, let self else { return }
                self.dashSearch = DashSearchState(
                    query: "", results: found,
                    status: found.isEmpty ? strings.phrase(.noneFoundNearby(label.lowercased()))
                        : strings.phrase(.foundNearby(found.count, label.lowercased())))
                self.setNeedsModelUpdate()
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.dashSearch = DashSearchState(query: "", results: [],
                                                  status: NavServiceError.message(for: error, fallback: strings.phrase(.noResults)))
                self.setNeedsModelUpdate()
            }
        }
    }

    /// Mirrors the phone search (NavigationModel) into the dash sheet when it changes.
    private func syncPhoneSearch() {
        adoptPhoneSearch(force: false)
    }

    private func adoptPhoneSearch(force: Bool) {
        let state = PhoneSearchState(query: navigation.query, results: navigation.results, searching: navigation.isSearching)
        guard force || state != lastPhoneSearch else { return }
        let changed = state != lastPhoneSearch
        lastPhoneSearch = state
        let q = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.count >= 2 {
            chipSearchTask?.cancel()
            let strings = NavStrings(language: core.language)
            dashSearch = DashSearchState(query: state.query,
                                         results: state.searching && state.results.isEmpty ? nil : state.results,
                                         status: state.searching ? strings.phrase(.searching) : nil)
        } else if changed || force {
            if force { chipSearchTask?.cancel() }
            dashSearch = DashSearchState(query: state.query)
        }
        setNeedsModelUpdate()
    }

    // MARK: - Helpers

    private static func loadPlaces(_ store: PlacesStore) -> DashPlaces {
        DashPlaces(home: store.home(), parked: store.parked(), favorites: store.favorites(), markers: store.markers(),
                   history: store.history())
    }

    /// The profile guessed before CLIENT_INFO (QR model id / override / learned canvas).
    private static func earlyProfile(core: AppCore, settings: BikeSettings) -> BikeProfile {
        guard let bike = core.garage.selected, let qr = core.garage.qr(for: bike.id) else {
            return settings.profileOverride.map { BikeProfile.profile($0) } ?? .legacy
        }
        return BikeProfiles.selectByQR(qr, override: settings.profileOverride,
                                       learnedCanvas: core.dashMemory.learnedCanvas(forSSID: qr.ssid))
    }

    private static func routeKey(_ route: Route?) -> String? {
        guard let r = route, let first = r.points.first, let last = r.points.last else { return nil }
        return "\(r.points.count)|\(first.lat),\(first.lon)|\(last.lat),\(last.lon)|\(Int(r.distanceM))|\(r.label)"
    }

    /// At most `max` points, evenly spaced, always keeping the last one.
    nonisolated static func sampled(_ points: [GeoPoint], max limit: Int) -> [GeoPoint] {
        guard points.count > limit, limit >= 2 else { return points }
        let step = Double(points.count - 1) / Double(limit - 1)
        return (0 ..< limit).map { points[Int((Double($0) * step).rounded())] }
    }
}

/// What the phone search field shows (NavigationModel), compared to detect changes.
struct PhoneSearchState: Equatable {
    var query: String
    var results: [Place]
    var searching: Bool
}
