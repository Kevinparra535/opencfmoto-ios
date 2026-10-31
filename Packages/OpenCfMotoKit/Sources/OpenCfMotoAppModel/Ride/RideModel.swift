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

import Foundation
import Observation
import OpenCfMotoCore

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

    public init(core: AppCore, settings: SettingsModel, navigation: NavigationModel, trips: TripsModel) {
        self.core = core
        self.settings = settings
        self.navigation = navigation
        self.trips = trips
        // TODO(logic-session): build the DashUIController, wire projection/location/speech.
    }

    // MARK: Phone dash preview (the same picture the dash shows)

    /// Thread-safe snapshot of the dash picture at monotonic time `now` (services.clock).
    /// The phone preview view draws it with the platform DashRenderer.
    public nonisolated func displayList(now: TimeInterval) -> DashDisplayList {
        DashDisplayList(size: DashSize(width: 800, height: 384), background: DashColor(argb: 0xFF000000),
                        commands: [], hitRegions: []) // TODO(logic-session)
    }

    /// Phone preview interactions (taps/drags on the preview are dash touches in canvas pixels;
    /// on-screen buttons may send handlebar keys).
    public func sendPreviewInput(_ input: DashInput) { /* TODO(logic-session) */ }

    // MARK: Ride Mode

    public func enterRideMode() { /* TODO(logic-session) */ }
    public func exitRideMode() { /* TODO(logic-session) */ }

    /// Starts GPS + navigation session use without a dash (preview / testing on the phone).
    public func startLocationPreview() { /* TODO(logic-session) */ }
    public func stopLocationPreview() { /* TODO(logic-session) */ }

    // MARK: Model-to-model (internal) — called by ConnectionModel / AppModel / ControlsModel

    /// The own-UI frame source for EasyConnLink.
    var frameSource: VideoFrameSource { core.services.projection.frameSource }
    /// Link started projecting the own UI (true) / stopped (false).
    func projectionChanged(active: Bool) { /* TODO(logic-session) */ }
    /// REQ 16 negotiated a canvas.
    func canvasNegotiated(_ canvas: VideoCanvas) { /* TODO(logic-session) */ }
    /// Dash identified: profile default margins / touch support.
    func profileIdentified(_ profile: BikeProfile) { /* TODO(logic-session) */ }
    /// Ghost-filtered dash touch (canvas pixels).
    func handleDashTouch(_ touch: DashTouch) { /* TODO(logic-session) */ }
    /// Handlebar command (ControlsModel) or other input.
    func handleDashInput(_ input: DashInput) { /* TODO(logic-session) */ }
    /// Short banner on the dash ("Reconnecting…"), nil to clear.
    func setLinkBanner(_ text: String?) { /* TODO(logic-session) */ }
    /// Link state for TripAutoLogPolicy.
    func linkPhaseChanged(_ phase: ConnectionPhase) { /* TODO(logic-session) */ }
    func scenePhaseChanged(_ phase: AppScenePhase) { /* TODO(logic-session) */ }

    private func previewCanvasChanged() { /* TODO(logic-session) */ }
}
