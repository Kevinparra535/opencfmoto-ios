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
//   last fix + compass, MapPreferences, night (NightModePolicy: AUTO follows the sun at the last fix,
//   P0 D06; re-evaluated ≥ every 60 s), wall clock, `DashLanguage` from `core.language`, places, dash search state
//   (NavigationModel results when the dash search sheet is open), recording/lap state, link
//   banner text, hold message. Calls `ui.update(model)` whenever an input changes, coalesced.
// - Projection: `services.projection.setDisplayListProvider { now in ui.displayList(now: now) }`
//   (DashUIController is thread-safe), hold provider = `ui.displayList(forHoldScreen:now:)`
//   with the dash's own card ("Map paused", P0 D17); `invalidate()` after
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
// - Ride Mode (foreground "pocket" mode, «Modo bolsillo» / "Pocket mode" on screen since the UI/UX
//   P0): `isIdleTimerDisabled = true`, the UI shows a black overlay; exiting restores the idle timer
//   unless keepScreenOn while linked. Offered by itself after a Connect / a Go: a 5-s cancellable
//   countdown (`pocketCountdown`, rules in PocketMode.swift).
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
    /// The «Modo bolsillo» countdown after a Connect / a Go (P0: 5 s).
    var pocketCountdown: TimeInterval = PocketModePolicy.countdownSeconds
}

@MainActor
@Observable
public final class RideModel {
    @ObservationIgnored let core: AppCore
    @ObservationIgnored let settings: SettingsModel
    @ObservationIgnored let navigation: NavigationModel
    @ObservationIgnored let trips: TripsModel

    /// Foreground pocket mode («Modo bolsillo» / "Pocket mode" on screen): screen kept awake, black
    /// overlay, dash keeps streaming.
    public private(set) var isRideModeActive = false
    /// ADDITION (UI/UX P0, UX-01): the running «Modo bolsillo» offer after a Connect / a Go — pocket
    /// mode starts when it runs out unless the rider taps «Quedarme aquí» (`cancelPocketCountdown()`).
    /// nil when none runs.
    public private(set) var pocketCountdown: PocketCountdown?
    /// ADDITION (UI/UX P0): the phone is in use in a way only the UI can see (the keyboard is up, a
    /// sheet presented from the root): no pocket-mode offer starts, and a running one ends.
    public var isPhoneInUse = false {
        didSet {
            if isPhoneInUse, !oldValue { endPocketCountdown(reason: "the phone is in use") }
        }
    }
    /// ADDITION (UI/UX P0): the UI's own look at the screen, asked when an offer would start and when
    /// it runs out: true while a sheet, a cover or an alert is up anywhere (pocket mode is never
    /// presented over another presentation). nil: nothing to ask.
    @ObservationIgnored public var isPhoneBusyNow: (() -> Bool)?
    /// ADDITION (review PH-5): VoiceOver or Switch Control is running (the UI asks UIAccessibility). The offer
    /// then counts `PocketModePolicy.assistiveCountdownFactor` × longer: announcing the card and moving to
    /// «Quedarme aquí» takes longer than 5 s. nil: no assistive technology.
    @ObservationIgnored public var isAssistiveTechnologyRunning: (() -> Bool)?
    /// ADDITION (UI/UX P0): false turns the automatic pocket-mode offer off (the E2E and screenshot
    /// launch modes, whose screens must stay as launched). The pocket-mode buttons still work.
    @ObservationIgnored public var offersPocketMode = true {
        didSet {
            if !offersPocketMode { endPocketCountdown(reason: "offer turned off") }
        }
    }
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
    /// ADDITION (locked iPhone, Phase 0): monotonic time (`services.clock`) of the last raw compass
    /// sample; nil before the first. The `[lock]` line's `heading=` age (does heading keep coming while
    /// the phone is locked? CM open question 11).
    @ObservationIgnored public private(set) var lastHeadingAt: TimeInterval?
    /// Current speed text in the rider's units ("47 km/h").
    public private(set) var speedText: String = ""
    /// Status of the location permission / GPS for the UI ("Waiting for GPS…").
    public private(set) var gpsStatus: String = ""
    /// Logs ▸ diagnostics (MP-7): the access units sent to the dash are being recorded to
    /// `dashVideoRecordingURL` (raw Annex-B H.264, the first `dashVideoRecordingFrameLimit`) — the
    /// day-one wire dump of media-video.md §15.8. False again within a housekeeping tick once the
    /// recorder closed the file by itself.
    public private(set) var isRecordingDashVideo = false
    /// The current / last recording (share it once recording is off).
    public private(set) var dashVideoRecordingURL: URL?
    /// Access units kept per recording (Android DUMP_H264's cap).
    public static let dashVideoRecordingFrameLimit = 600

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
    /// The canvas the link assumes for this own-UI session before REQ 16 (learned / 800×384): the
    /// dash UI is laid out (and the hold picture pre-encoded) for it until the dash negotiates.
    @ObservationIgnored private var sessionExpectedCanvas: VideoCanvas?
    @ObservationIgnored private var identifiedProfile: BikeProfile?
    @ObservationIgnored private var earlyProfile: BikeProfile = .legacy
    @ObservationIgnored private var linkBanner: String?
    @ObservationIgnored private var nightMonitor = NightModeMonitor()
    /// The model last handed to the dash UI (tests read it: the controller keeps its own private).
    @ObservationIgnored private(set) var lastModel: DashModel?
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
    @ObservationIgnored private var scenePhase: AppScenePhase = .active
    /// Which source the running recording is attached to (true = mirror relay).
    @ObservationIgnored private var dashVideoSourceIsMirror: Bool?
    /// Ends `pocketCountdown` with pocket mode when it runs out.
    @ObservationIgnored private var pocketTask: Task<Void, Never>?
    /// AppModel: what else needs the rider right now (a dialog, the manual Wi-Fi join, an opened file
    /// waiting for an answer, the dash's "type on the phone" request), for the pocket-mode offer; nil
    /// when nothing does.
    @ObservationIgnored var pocketOfferBusyReason: (() -> String?)?

    // MARK: Apple Music (iOS addition) — wired by AppModel to MusicModel

    /// The Music app's now playing for `DashModel.music` (MusicModel.dashNowPlaying).
    @ObservationIgnored var nowPlayingProvider: (() -> DashNowPlaying?)?
    /// The dash's ⏮ ⏯ ⏭ (`DashIntent.musicPrevious / musicPlayPause / musicNext`) → MusicModel.perform
    /// (command, fromDash).
    @ObservationIgnored var musicCommandSink: ((MusicCommand, Bool) -> Void)?
    /// The own dash UI went live (true) or stopped (false): a Connect session in own-UI mode, the phone
    /// preview (Dash view / Map hub) or Ride Mode. Mirror sessions draw no dash UI (contract R7).
    @ObservationIgnored var onDashActivityChange: ((Bool) -> Void)?
    /// What `onDashActivityChange` reported last.
    @ObservationIgnored private(set) var isDashUIActive = false

    // MARK: Fuel MVP — wired by AppModel to FuelModel

    /// ADDITION (fuel MVP): every fix after navigation and trips (AppModel → FuelModel.ingest).
    @ObservationIgnored var onLocationFix: ((LocationFix) -> Void)?
    /// ADDITION (fuel MVP): a pending fuel alert that could not be delivered on any channel (60 s, or the
    /// session ended): FuelModel restores its latch so the next odometer change retries with a fresh number.
    @ObservationIgnored var onFuelAlertDropped: ((FuelDashAlert) -> Void)?
    /// The most a fuel alert waits for a clear dash / voice before it is dropped.
    nonisolated static let fuelAlertMaxDeferral: TimeInterval = 60
    /// The fuel voice line never starts while a turn cue is this close.
    nonisolated static let fuelVoiceTurnClearanceM = 500.0

    /// The ONE pending fuel alert (a newer one replaces it; the slot never queues two).
    struct PendingFuelAlert {
        var alert: FuelDashAlert
        var since: TimeInterval
        /// Decided at DELIVERY time: true until a Mirror session makes it voice-only (the own UI may not be
        /// live yet when the alert fires: joining, linking, reconnecting, parked).
        var toastDue: Bool
        var voiceDue: Bool
        var toastDelivered = false
        var voiceDelivered = false
        var lastWait: String?
        var deliveredAny: Bool { toastDelivered || voiceDelivered }
        var done: Bool { (!toastDue || toastDelivered) && (!voiceDue || voiceDelivered) }
    }
    @ObservationIgnored private(set) var pendingFuelAlert: PendingFuelAlert?
    /// The level and blocker of the last alert dropped undelivered: its repeats (the same blocker for the whole
    /// ride, FuelModel re-firing after each drop) are not logged again.
    @ObservationIgnored private var lastFuelDrop: (level: FuelAlertLevel, reason: String)?

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

    /// Activates a dash control from the phone (as if the rider used it on the dash): the
    /// `-uiDashSheet` launch option and the E2E music timeline open / drive the Music sheet with it.
    public func performDashIntent(_ intent: DashIntent) {
        if updateScheduled { flushModel() } // the controller must see the current model (e.g. `music`)
        perform(ui.perform(intent, now: clock.now()), fromDash: false)
        uiChanged()
    }

    /// The dash UI's state (open sheet, focus order…) for the phone UI and the E2E status.
    public var dashUIState: DashUIState { ui.state }

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
        endPocketCountdown(reason: "pocket mode turned on")
        isRideModeActive = true
        Log.i("RIDE", "Pocket mode on (screen kept awake)")
        applyIdleTimer()
        updateLoops()
    }

    public func exitRideMode() {
        guard isRideModeActive else { return }
        isRideModeActive = false
        Log.i("RIDE", "Pocket mode off")
        applyIdleTimer()
        updateLoops()
    }

    // MARK: «Modo bolsillo» offer (UI/UX P0, UX-01)

    /// «Quedarme aquí» / "Stay here": the running countdown ends; nothing else changes.
    public func cancelPocketCountdown() {
        endPocketCountdown(reason: "the rider stays on the phone")
    }

    /// The screenshot launch mode `-uiScreen pocketOffer` (review PH-5: the card had no screenshot): the card as
    /// it first shows, held at its full count — it "starts" an hour from now, so the ring stays full — and no
    /// pocket mode at its end. Only the launch modes call it (their `offersPocketMode` is off).
    public func showPocketOfferForScreenshot() {
        pocketTask?.cancel()
        pocketTask = nil
        pocketCountdown = PocketCountdown(trigger: .connected, startedAt: clock.now() + 3600, duration: tuning.pocketCountdown)
    }

    /// A touch anywhere on the phone (the UI reports every touch-down): the rider is using the phone, so a
    /// running countdown ends — pocket mode never drops onto a pan, a tap or a scroll in progress (review PH-2).
    public func phoneTouched() {
        guard pocketCountdown != nil else { return }
        endPocketCountdown(reason: "the rider touched the phone")
    }

    /// Offers pocket mode with a countdown, if the rules allow it now (PocketModePolicy). A running
    /// countdown is kept as it is.
    func offerPocketMode(_ trigger: PocketCountdown.Trigger) {
        guard pocketCountdown == nil else { return }
        if let reason = PocketModePolicy.blocker(pocketContext) {
            Log.d("RIDE", "pocket mode not offered (\(trigger.rawValue)): \(reason)")
            return
        }
        let assistive = isAssistiveTechnologyRunning?() == true
        let duration = tuning.pocketCountdown * (assistive ? PocketModePolicy.assistiveCountdownFactor : 1)
        let countdown = PocketCountdown(trigger: trigger, startedAt: clock.now(), duration: duration)
        pocketCountdown = countdown
        Log.i("RIDE", "pocket mode in \(Self.seconds(countdown.duration)) s (\(trigger.rawValue)) \u{2014} unless the rider stays")
        pocketTask?.cancel()
        let delay = countdown.duration
        pocketTask = Task { [weak self] in
            await sleepSeconds(delay)
            guard !Task.isCancelled, let self, self.pocketCountdown == countdown else { return }
            self.finishPocketCountdown()
        }
    }

    /// The countdown ran out: pocket mode, if the rules still allow it (else the offer just ends).
    private func finishPocketCountdown() {
        guard let countdown = pocketCountdown else { return }
        if let reason = PocketModePolicy.blocker(pocketContext) {
            endPocketCountdown(reason: reason)
            return
        }
        pocketTask = nil
        pocketCountdown = nil
        Log.i("RIDE", "pocket mode by the countdown (\(countdown.trigger.rawValue))")
        enterRideMode()
    }

    /// Ends a running countdown without pocket mode.
    private func endPocketCountdown(reason: String) {
        pocketTask?.cancel()
        pocketTask = nil
        guard pocketCountdown != nil else { return }
        pocketCountdown = nil
        Log.i("RIDE", "pocket mode countdown ended: \(reason)")
    }

    private var pocketContext: PocketModePolicy.Context {
        PocketModePolicy.Context(isEnabled: offersPocketMode, isProjecting: isProjecting,
                                 isSceneActive: scenePhase == .active, isPocketModeActive: isRideModeActive,
                                 busyReason: pocketBusyReason)
    }

    /// The phone is in use (UI flags, something presented on screen) or something in the model waits
    /// for the rider; nil when nothing does.
    private var pocketBusyReason: String? {
        if isPhoneInUse { return "the phone is in use" }
        if isPhoneBusyNow?() == true { return "something is open on the phone" }
        return pocketOfferBusyReason?()
    }

    private static func seconds(_ value: TimeInterval) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    // MARK: Dash video recording (diagnostics)

    /// Starts / stops recording what is sent to the dash (MP-7): the own-UI projection, or the
    /// mirror relay during a mirror session. Each recording is a new file in the exports folder.
    public func setDashVideoRecording(_ on: Bool) {
        guard on != isRecordingDashVideo else { return }
        if on {
            startDashVideoRecording(mirror: sessionIsMirror)
        } else {
            stopDashVideoRecording()
            Log.i("RIDE", "dash video recording stopped (\(dashVideoRecordingURL?.lastPathComponent ?? "-"))")
        }
    }

    private func startDashVideoRecording(mirror: Bool) {
        let services = core.services
        let url = services.files.exportsDirectory.appendingPathComponent("opencfmoto-wire-\(Self.fileStamp(services.now())).h264")
        do {
            try FileManager.default.createDirectory(at: services.files.exportsDirectory, withIntermediateDirectories: true)
            if mirror {
                try services.mirror.startWireDump(to: url, maxFrames: Self.dashVideoRecordingFrameLimit)
            } else {
                try services.projection.startWireDump(to: url, maxFrames: Self.dashVideoRecordingFrameLimit)
            }
        } catch {
            Log.w("RIDE", "dash video recording unavailable: \(error)")
            return
        }
        dashVideoSourceIsMirror = mirror
        dashVideoRecordingURL = url
        isRecordingDashVideo = true
        Log.i("RIDE", "recording the dash video stream (\(mirror ? "mirror" : "own UI"), first \(Self.dashVideoRecordingFrameLimit) frames) → \(url.lastPathComponent)")
    }

    private func stopDashVideoRecording() {
        if let mirror = dashVideoSourceIsMirror {
            if mirror { core.services.mirror.stopWireDump() } else { core.services.projection.stopWireDump() }
        }
        dashVideoSourceIsMirror = nil
        isRecordingDashVideo = false
    }

    /// The recorder closes the file by itself after `dashVideoRecordingFrameLimit` access units (or when a
    /// write fails). The toggle follows, so the Logs screen offers the file and the next tap starts a new
    /// recording (the Phase 0 checklist records once per condition). Housekeeping and `.active` call it.
    private func refreshDashVideoRecording() {
        guard isRecordingDashVideo, let mirror = dashVideoSourceIsMirror else { return }
        let services = core.services
        guard mirror ? services.mirror.isWireDumpFinished : services.projection.isWireDumpFinished else { return }
        stopDashVideoRecording()
        Log.i("RIDE", "dash video recording ended (\(dashVideoRecordingURL?.lastPathComponent ?? "-")): the recorder closed the file")
    }

    /// "20261101-142530" (POSIX, local time) for file names.
    private static func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
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
        // A hard switch (Connect / Mirror while a session runs): the old session's alert is not this one's.
        if active, sessionActive { dropPendingFuelAlert(reason: "session restarted") }
        let changed = active != sessionActive || mirror != sessionIsMirror
        sessionActive = active
        sessionIsMirror = active && mirror
        guard changed else { return }
        autoLogSuppressed = false
        if !active { dropPendingFuelAlert(reason: "session ended") }
        if isRecordingDashVideo, active, let wasMirror = dashVideoSourceIsMirror, wasMirror != sessionIsMirror {
            // The recording follows what is sent to the dash: a new file on the other source.
            stopDashVideoRecording()
            startDashVideoRecording(mirror: sessionIsMirror)
        }
        if active {
            encoderPlan.adaptive.reset()
            lastPushedParameters = nil
            sessionExpectedCanvas = sessionIsMirror ? nil : expectedCanvasForSelectedBike()
            flushModel()
            // Pre-encode the hold picture right away (the hardware encoder is available now): a
            // rider who taps Connect and pockets the phone before the dash's REQ 16 still gets a
            // picture (MP-2). Refreshed when the app leaves the foreground.
            if !sessionIsMirror, scenePhase == .active { requestHoldPicture() }
        } else if negotiatedCanvas != nil || identifiedProfile != nil || sessionExpectedCanvas != nil {
            // Ended before the first frame (no projectionChanged(false)): back to the preview layout.
            negotiatedCanvas = nil
            identifiedProfile = nil
            sessionExpectedCanvas = nil
            flushModel()
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
            if !sessionActive { sessionExpectedCanvas = nil }
            linkBanner = nil
            flushModel()
        }
        evaluateTripAutoLog()
        applyIdleTimer()
        // «Modo bolsillo» (P0, UX-01): the dash is live → offer pocket mode; it is not → no offer.
        if active {
            offerPocketMode(.connected)
        } else {
            endPocketCountdown(reason: "the dash is not showing the map")
        }
    }

    /// REQ 16 negotiated a canvas.
    func canvasNegotiated(_ canvas: VideoCanvas) {
        negotiatedCanvas = canvas
        linkBanner = nil // the dash is talking again: no "Reconnecting…" in its next picture
        flushModel() // the next frame must be laid out for exactly this canvas
    }

    /// The own-UI encoder was prepared at `canvas` (projection port, MP-6). Usually the same canvas
    /// as `canvasNegotiated`; it also covers the link's guard paths that never emit a canvas event:
    /// a REQ 16 without a usable size (the previous canvas is kept and replied) and 112 without 16.
    func canvasPrepared(_ canvas: VideoCanvas) {
        guard sessionActive, !sessionIsMirror, canvas.width >= 16, canvas.height >= 16 else { return }
        guard negotiatedCanvas.map({ $0.width != canvas.width || $0.height != canvas.height }) ?? true else { return }
        Log.i("RIDE", "laying the dash UI out for the prepared canvas \(canvas.width)x\(canvas.height)")
        canvasNegotiated(canvas)
    }

    /// Dash identified: profile default margins / touch support. CLIENT_INFO also means the dash
    /// is back after a reconnect — well before it re-opens media and asks for the resync IDR — so
    /// the "Reconnecting…" banner goes now and is not in the first picture after the reconnect.
    func profileIdentified(_ profile: BikeProfile) {
        identifiedProfile = profile
        linkBanner = nil
        flushModel()
        pushEncoderPlan(force: false)
    }

    /// P0 (D17): while the dash shows the hold picture (the app in the background without a background
    /// encoder, or the phone locked), the rider sees no live controls: dash keys and touches act on nothing.
    var dashShowsHoldPicture: Bool { core.services.projection.stats.mode == "hold" }

    /// Ghost-filtered dash touch (canvas pixels). Ignored while the hold picture shows (P0, D17).
    func handleDashTouch(_ touch: DashTouch) {
        guard !dashShowsHoldPicture else {
            Log.d("RIDE", "[dash] touch ignored: the dash shows the hold picture")
            return
        }
        let intents = ui.handle(.touch(touch), now: clock.now())
        perform(intents, fromDash: true)
        uiChanged()
    }

    /// Handlebar command (ControlsModel) or other input. Ignored while the hold picture shows (P0, D17).
    func handleDashInput(_ input: DashInput) {
        guard !dashShowsHoldPicture else {
            Log.d("RIDE", "[dash] input ignored: the dash shows the hold picture")
            return
        }
        let intents = ui.handle(input, now: clock.now())
        perform(intents, fromDash: true)
        uiChanged()
    }

    /// Contract R2: the rider started Apple Music while the phone media remote drives the dash — the
    /// Music app took Now Playing, so the bars control the music now. The Music sheet closes (the bars
    /// could not close it any more) and the dash says so.
    func handlebarHandedToMusic() {
        Log.i("BTN", "[BTN] Apple Music took the handlebar buttons")
        if ui.state.sheet == .music {
            perform(ui.perform(.closeSheets, now: clock.now()), fromDash: false)
        }
        showDashToast(SessionText.musicTakesHandlebar(core.language))
    }

    /// Contract R3: the song was paused and the phone media remote claimed the buttons back.
    func handlebarBackToDash() {
        showDashToast(SessionText.handlebarBackToDash(core.language))
    }

    /// Short banner on the dash ("Reconnecting…"), nil to clear.
    func setLinkBanner(_ text: String?) {
        guard text != linkBanner else { return }
        linkBanner = text
        setNeedsModelUpdate()
    }

    /// Link state for TripAutoLogPolicy and the idle timer (no screen kept awake while parked).
    func linkPhaseChanged(_ phase: ConnectionPhase) {
        guard phase != linkPhase else { return }
        linkPhase = phase
        evaluateTripAutoLog()
        applyIdleTimer()
    }

    func scenePhaseChanged(_ phase: AppScenePhase) {
        let projection = core.services.projection
        let previous = scenePhase
        scenePhase = phase
        // A countdown never runs out of sight (lock, app switcher, call): pocket mode needs the app open.
        if phase != .active { endPocketCountdown(reason: "the app left the foreground") }
        switch phase {
        case .inactive:
            // Leaving the foreground (not coming back from the background): pre-encode the hold
            // picture while the hardware encoder is still available — for the whole own-UI
            // session, also before the dash negotiated (MP-2: REQ 16 may come while locked). Then,
            // still in the foreground, pre-warm the background encoder (locked iPhone, P0-4): the
            // engine runs both on its render queue in this order, so the hold IDRs are ready before the
            // pre-warm session is created and probed (a forced IDR of the last live picture, never sent).
            if previous == .active, sessionActive, !sessionIsMirror {
                requestHoldPicture()
                projection.prepareBackgroundEncoder()
            }
        case .background:
            projection.enterBackground()
        case .active:
            projection.enterForeground()
            setNeedsModelUpdate()
            refreshDashVideoRecording() // a recording that filled up while locked: the Logs toggle is off
        }
    }

    /// Asks the projection to pre-encode the hold picture at the negotiated canvas, or the
    /// session's expected one (the dash UI is laid out for it, so the picture is not stretched).
    private func requestHoldPicture() {
        if updateScheduled { flushModel() } // the hold provider renders the current model
        let canvas = negotiatedCanvas ?? sessionExpectedCanvas ?? .defaultLandscape
        core.services.projection.prepareHoldPicture(expectedCanvas: canvas)
    }

    /// The canvas the link will assume for the selected bike before REQ 16.
    private func expectedCanvasForSelectedBike() -> VideoCanvas {
        let learned = core.garage.selected.flatMap { core.garage.qr(for: $0.id) }
            .flatMap { core.dashMemory.learnedCanvas(forSSID: $0.ssid) }
        return VideoCanvas.expectedSessionCanvas(learned: learned)
    }

    /// Location permission changed (PermissionsModel → AppModel).
    func locationPermissionChanged(_ permission: LocationPermission) {
        applyLocationPolicy()
    }

    private func previewCanvasChanged() {
        guard negotiatedCanvas == nil, sessionExpectedCanvas == nil else { return }
        flushModel()
    }

    // MARK: - Wiring

    private func wireProjection() {
        let projection = core.services.projection
        let ui = self.ui
        projection.setDisplayListProvider { now in ui.displayList(now: now) }
        // P0 (D17): the dash's own hold card — "Map paused", no stale numbers, honest copy.
        projection.setHoldDisplayListProvider { now in ui.displayList(forHoldScreen: nil, now: now) }
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
        projection.onCanvasPrepared = { @Sendable [weak self] canvas in
            Task { @MainActor [weak self] in self?.canvasPrepared(canvas) }
        }
        pushStoredLockedStreamPolicy()
    }

    /// Locked iPhone (Phase 0): a valid locked-phone policy stored under `ios.locked_stream_policy`
    /// reaches the projection at start (nothing writes the key in Phase 0; the Phase 1 setting will).
    /// Without one the projection keeps the build's own default.
    private func pushStoredLockedStreamPolicy() {
        guard let raw = core.services.keyValueStore.string(forKey: LockDiagnostics.lockedStreamPolicyKey) else { return }
        guard let policy = LockedStreamPolicy(rawValue: raw) else {
            Log.w("RIDE", "unknown locked-phone policy in the settings (\(raw.prefix(16))) \u{2014} keeping the default")
            return
        }
        core.services.projection.setLockedStreamPolicy(policy)
        Log.i("RIDE", "locked-phone policy from the settings: \(policy.rawValue)")
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
        onLocationFix?(fix) // fuel MVP: the km counter (independent of trip logging)
    }

    private func handleHeading(_ raw: Double) {
        guard raw.isFinite else { return }
        let now = clock.now()
        lastHeadingAt = now
        core.navigation.updateHeading(raw)
        compassDeg = compass.add(raw)
        if now - lastCompassModelAt >= tuning.compassModelInterval {
            lastCompassModelAt = now
            setNeedsModelUpdate()
        }
    }

    /// Navigation (or an open route preview) needs fixes even when no screen asked for GPS.
    static func needsGuidanceFixes(_ snap: NavSnapshot) -> Bool {
        snap.mode.isNavigating || snap.preview != nil
    }

    private func navSnapshotChanged(_ snap: NavSnapshot) {
        let guidanceChanged = Self.needsGuidanceFixes(snap) != Self.needsGuidanceFixes(navSnapshot)
            || snap.mode.isNavigating != navSnapshot.mode.isNavigating
        let guidanceStarted = PocketModePolicy.guidanceStarted(from: navSnapshot.mode, to: snap.mode)
        navSnapshot = snap
        if guidanceStarted { offerPocketMode(.guidance) } // «Modo bolsillo» after a Go (P0, UX-01)
        if guidanceChanged { applyLocationPolicy() }
        let key = Self.routeKey(snap.route)
        if key != lastRouteKey {
            lastRouteKey = key
            if let route = snap.route {
                // Route points come from untrusted GPX files / imports: never hand NaN, ±∞ or
                // out-of-range coordinates to the tile maths (SEC-1). The OSMF tile servers (the default
                // tile.openstreetmap.org) forbid prefetching: only a tile server the rider set gets the corridor.
                let corridor = Self.corridorPoints(route)
                if corridor.count >= 2, MapTileSource.allowsCorridorPrefetch(template: cachedSettings.tileURLTemplate) {
                    core.services.projection.prefetchCorridor(Self.sampled(corridor, max: 400))
                }
            }
        }
        setNeedsModelUpdate()
    }

    /// The usable vertices of a route for the tile-corridor prefetch: finite, latitude −90…90,
    /// longitude −180…180 (`MapProjection.isUsable`).
    nonisolated static func corridorPoints(_ route: Route) -> [GeoPoint] {
        Array(route.points.lazy.map(\.point).filter(MapProjection.isUsable))
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
        // The system port also reports appearance changes here (the dash no longer follows dark mode: P0, D06).
        setNeedsModelUpdate()
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
        let canvas = (negotiatedCanvas ?? sessionExpectedCanvas).map(DashModel.canvasSize) ?? previewCanvas.size
        let profileDefault = (identifiedProfile ?? earlyProfile).defaultMargins
        let margins = CanvasFit.effectiveMargins(s.screenMargins, profileDefault: profileDefault)
        let wall = core.services.now()
        // AUTO = the sun below the horizon at the last fix (P0, D06: computed on the phone, the phone's dark mode
        // plays no part); no fix yet → 19:00–06:59.
        let night = nightMonitor.evaluate(theme: s.map.theme, position: lastFix?.point, date: wall, now: clock.now())
        let lap = core.navigation.lapCard().map { DashLapTimer(title: $0.current, meta: $0.meta) }
        // The clock chip shows HH:mm: a minute-aligned date keeps the model stable within a minute.
        let minute = Date(timeIntervalSince1970: (wall.timeIntervalSince1970 / 60).rounded(.down) * 60)
        return DashModel(canvas: canvas, margins: margins, nav: navSnapshot, fix: lastFix, compassHeadingDeg: compassDeg,
                         preferences: s.map, isNight: night, date: minute, timeZone: .current, language: dashLanguage,
                         places: places, search: dashSearch, recording: core.tripRecorder.isRecording, lapTimer: lap,
                         toastText: nil, linkBanner: linkBanner, holdMessage: nil, showClock: true,
                         handlebarFocus: s.handlebarControl, music: nowPlayingProvider?(),
                         mapAttribution: MapTileSource.attribution(template: s.tileURLTemplate)) // OSMF tiles: "© OpenStreetMap"
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

    /// A toast of `duration` may be on screen: the UI tick redraws the phone preview until it expires.
    private func watchToast(for duration: TimeInterval) {
        toastWatchUntil = max(toastWatchUntil, clock.now() + duration + 0.5)
    }

    // MARK: - Fuel alert (fuel MVP)

    /// ADDITION (fuel MVP): the low-range / reserve alert. A toast once the own UI is live on the dash
    /// (projecting and streaming; never in a Mirror session), for `FuelAlertPolicy.toastSeconds`; the voice
    /// line when voice prompts are on. Never shown or spoken over something more important: it waits in ONE
    /// pending slot (a newer alert replaces it). The toast channel is decided at delivery time.
    func announceFuel(_ alert: FuelDashAlert) {
        let now = clock.now()
        pendingFuelAlert = PendingFuelAlert(alert: alert, since: now, toastDue: true, voiceDue: cachedSettings.map.voiceOn)
        retryPendingFuelAlert(now: now)
    }

    /// ADDITION (fuel MVP): drops a pending fuel alert silently (a refuel / an edit made it pointless).
    func cancelFuelAlert() {
        lastFuelDrop = nil
        guard pendingFuelAlert != nil else { return }
        pendingFuelAlert = nil
        Log.i("RIDE", "fuel alert cancelled")
    }

    /// ADDITION (fuel MVP): the estimate turned unsure (aged / unknown) while the alert may still wait: it is
    /// never shown or spoken on an unsure number. When no channel delivered it, `onFuelAlertDropped` lets
    /// FuelModel restore the latch, so it fires again once the estimate is trustworthy.
    func dropFuelAlertIfUndelivered() {
        guard let p = pendingFuelAlert else { return }
        pendingFuelAlert = nil
        Log.i("RIDE", "fuel alert dropped (the estimate turned unsure): \(p.alert.level.rawValue)")
        if !p.deliveredAny { onFuelAlertDropped?(p.alert) }
    }

    /// ADDITION (fuel MVP): delivers each due channel of the pending fuel alert as soon as it is clear; drops
    /// the rest after `fuelAlertMaxDeferral`. Called from the UI tick (~10 Hz while a session runs) and by tests.
    func retryPendingFuelAlert(now: TimeInterval) {
        guard var p = pendingFuelAlert else { return }
        if sessionIsMirror { p.toastDue = false } // Mirror sessions draw nothing of ours: voice only
        var waits: [String] = []
        if p.toastDue, !p.toastDelivered {
            if let busy = fuelToastBlocker(now: now) {
                waits.append(busy)
            } else {
                let text = DashStrings.fuelToast(p.alert.level, range: FuelFormat.range(p.alert.kmToReserve, units: cachedSettings.map.units),
                                                 dashLanguage)
                ui.showToast(text, now: now, duration: FuelAlertPolicy.toastSeconds)
                watchToast(for: FuelAlertPolicy.toastSeconds)
                uiChanged()
                p.toastDelivered = true
                lastFuelDrop = nil
                Log.i("RIDE", "fuel alert shown on the dash: \(p.alert.level.rawValue)")
            }
        }
        if p.voiceDue, !p.voiceDelivered {
            if let busy = fuelVoiceBlocker() {
                waits.append(busy)
            } else {
                speak(DashStrings.fuelVoice(p.alert.level, range: FuelFormat.range(p.alert.kmToReserve, units: cachedSettings.map.units),
                                            dashLanguage))
                p.voiceDelivered = true
                lastFuelDrop = nil
                Log.i("RIDE", "fuel alert spoken: \(p.alert.level.rawValue)")
            }
        }
        if p.done {
            pendingFuelAlert = nil
            return
        }
        let wait = waits.joined(separator: ", ")
        let repeatsLastDrop = lastFuelDrop?.level == p.alert.level && lastFuelDrop?.reason == wait
        if now - p.since >= Self.fuelAlertMaxDeferral {
            pendingFuelAlert = nil
            if !repeatsLastDrop {
                Log.i("RIDE", "fuel alert dropped after \(Int(Self.fuelAlertMaxDeferral)) s (\(wait)): \(p.alert.level.rawValue)")
            }
            if !p.deliveredAny {
                lastFuelDrop = (p.alert.level, wait)
                onFuelAlertDropped?(p.alert)
            }
            return
        }
        if wait != p.lastWait {
            p.lastWait = wait
            if !repeatsLastDrop { Log.i("RIDE", "fuel alert waiting: \(wait)") }
        }
        pendingFuelAlert = p
    }

    /// Why the fuel toast cannot be drawn now (nil = clear): the own UI is not live on the dash (not projecting,
    /// or the link is joining / linking / reconnecting / parked / in error: frames do not reach it), a sheet or
    /// card on the dash, the arrival card, a preview, the hold picture (the engine's mode: the phone is locked
    /// or in the background without a background encoder), or another toast (it never replaces one: `overlays`
    /// draws over anything).
    private func fuelToastBlocker(now: TimeInterval) -> String? {
        guard isProjecting, linkPhase == .streaming else { return "dash not live" }
        return Self.fuelToastBlocker(sheet: ui.state.sheet, model: lastModel, toastShowing: isToastShowing(now: now),
                                     holdShowing: dashShowsHoldPicture || lastModel?.holdMessage != nil)
    }

    nonisolated static func fuelToastBlocker(sheet: DashSheet, model: DashModel?, toastShowing: Bool,
                                             holdShowing: Bool) -> String? {
        switch sheet {
        case .confirm: return "confirm card"
        case .menu: return "menu"
        case .search: return "search"
        case .music: return "Music sheet"
        case .none: break
        }
        if holdShowing { return "hold picture" }
        if model?.showsArrival == true { return "arrival card" }
        if model?.inPreview == true { return "dash preview" }
        if toastShowing { return "another toast" }
        return nil
    }

    /// The controller's toast, expired as of `now` (the state is advanced only when a toast was reported).
    private func isToastShowing(now: TimeInterval) -> Bool {
        guard ui.state.toast != nil else { return false }
        _ = ui.displayList(now: now) // advances the controller: an expired toast goes
        return ui.state.toast != nil
    }

    /// Why the fuel voice line cannot start now (nil = clear): something is being spoken (a new line would cut
    /// it), or the next turn cue is within 500 m.
    private func fuelVoiceBlocker() -> String? {
        Self.fuelVoiceBlocker(isSpeaking: core.services.speech.isSpeaking, model: lastModel)
    }

    nonisolated static func fuelVoiceBlocker(isSpeaking: Bool, model: DashModel?) -> String? {
        if isSpeaking { return "voice busy" }
        if model?.navigating == true, let d = model?.nav.progress?.upcomingTurn?.distanceFromRiderM, d <= fuelVoiceTurnClearanceM {
            return "turn cue near"
        }
        return nil
    }

    /// The session ended (or a hard switch replaced it) with an alert still pending: dropped the same way (the
    /// latch is restored when no channel delivered it, so the next session's fixes fire it again).
    private func dropPendingFuelAlert(reason: String) {
        lastFuelDrop = nil
        guard let p = pendingFuelAlert else { return }
        pendingFuelAlert = nil
        Log.i("RIDE", "fuel alert dropped (\(reason)): \(p.alert.level.rawValue)")
        if !p.deliveredAny { onFuelAlertDropped?(p.alert) }
    }

    // MARK: - Timers

    private func updateLoops() {
        let dashUI = (sessionActive && !sessionIsMirror) || previewRequests > 0 || isRideModeActive
        if dashUI != isDashUIActive {
            isDashUIActive = dashUI
            onDashActivityChange?(dashUI)
        }
        let wanted = sessionActive || previewRequests > 0 || isRideModeActive
        if wanted, uiTickTask == nil {
            uiTickTask = Task { [weak self] in
                var n = 0
                while !Task.isCancelled {
                    // Backgrounded (screen locked, pocket): long-press / toast timers barely matter.
                    let interval = self.map { $0.scenePhase == .background ? max($0.tuning.uiTickInterval, 0.5) : $0.tuning.uiTickInterval } ?? 0.1
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
        if pendingFuelAlert != nil { retryPendingFuelAlert(now: now) }
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

    /// Android's 5 s watchdog duties: trip auto-log, AUTO power mode, GPS policy; and the iOS dash video
    /// recording toggle, which follows a recorder that closed its file by itself.
    private func housekeeping() {
        evaluateTripAutoLog()
        adaptiveTick()
        applyLocationPolicy()
        refreshDashVideoRecording()
    }

    // MARK: - Location, screen, trips, encoder

    private func applyLocationPolicy() {
        let loc = core.services.location
        let recording = core.tripRecorder.isRecording
        // Phone-only guidance (no dash yet) keeps GPS too, like any navigation app.
        let guiding = Self.needsGuidanceFixes(navSnapshot)
        let wanted = sessionActive || previewRequests > 0 || recording || guiding
        let background = sessionActive || recording || navSnapshot.mode.isNavigating
        if wanted, loc.permission.isAuthorized {
            if !loc.isUpdating {
                loc.start(rideActive: background)
                appliedRideActive = background
                Log.i("RIDE", "GPS on (background=\(background))")
            } else if appliedRideActive != background {
                if background, scenePhase == .active {
                    // Locked iPhone (P0-10): updates already run for the phone's dash preview. Apple
                    // documents only "set allowsBackgroundLocationUpdates, then start in the foreground"
                    // as the order that keeps the app running in the background, so restart them that
                    // way rather than flipping the flag on running updates.
                    loc.stop()
                    loc.start(rideActive: true)
                    appliedRideActive = true
                    Log.i("RIDE", LockDiagnostics.gpsRestartedForBackground)
                } else {
                    // Turning background updates off, or already in the background, where a When-In-Use
                    // app cannot start updates: flip the flag on the running updates.
                    loc.setRideActive(background)
                    appliedRideActive = background
                }
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

    /// "Keep screen on while projecting" (session-network §11.4) holds only while the dash can be
    /// linked: not while the session is parked waiting for the bike (§11.6, the iOS battery park)
    /// or sits in an error. Pocket mode (Ride Mode) always keeps the screen awake.
    private func applyIdleTimer() {
        let linked = sessionActive && linkPhase != .waitingForBike && linkPhase != .error
        let keepAwake = isRideModeActive || (linked && cachedSettings.keepScreenOn)
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
        case .openMusic:
            break // UI-only (the controller opened the Music sheet)
        case .musicPlayPause:
            musicCommandSink?(.playPause, fromDash)
        case .musicNext:
            musicCommandSink?(.next, fromDash)
        case .musicPrevious:
            musicCommandSink?(.previous, fromDash)
        }
    }

    /// "Type on your phone" (DashRemote.requestTypeOnPhone): focus the phone search field, buzz,
    /// and tell the rider by voice when the request came from the dash.
    private func requestTypeOnPhone(announce: Bool) {
        endPocketCountdown(reason: "the dash asks to type on the phone")
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

    /// Identity of a route for "apply once" work (corridor prefetch). Never traps on a corrupt
    /// route: the distance is converted with Kotlin `toInt()` semantics (NaN → 0, saturating).
    nonisolated static func routeKey(_ route: Route?) -> String? {
        guard let r = route, let first = r.points.first, let last = r.points.last else { return nil }
        let metres = NavNumberFormat.truncateToInt(r.distanceM)
        return "\(r.points.count)|\(first.lat),\(first.lon)|\(last.lat),\(last.lon)|\(metres)|\(r.label)"
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
