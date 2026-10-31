// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) GpxDashUi.kt click handlers — docs/spec/navigation-dash.md
// §11.8 (every tap target), input-controls.md §6.3/§6.6.
//
// Every user action on the dash (touch tap, long-press, handlebar Select…) becomes a
// `DashIntent`. UI-only intents (camera, sheets) are applied by `DashUIController` itself AND
// reported, so the app can log them / give voice feedback. All other intents must be performed by
// the app (navigation session, places store, preferences, recorder…); the dash reflects the
// result through the next `DashModel`.

import Foundation

public enum DashIntent: Sendable, Equatable {
    // MARK: Camera & sheets — applied internally by the controller (and reported)

    /// Recenter FAB: follow on, cancel auto-recenter, follow at the speed zoom ("Centered on GPS").
    case recenter
    /// Zoom FABs / menu －＋: free pan 12 s, speed zoom off (fixed 17.2 afterwards), zoom ±1.
    case zoomIn
    case zoomOut
    /// Compass FAB: heading-up ⇄ north-up (toast "Heading up" / "North up").
    case toggleCompass
    /// Menu "Heading up / North up" (same as the compass, without toast).
    case toggleHeadingUp
    /// Menu "Follow on / Free pan" (cancels the auto-recenter).
    case toggleFollow
    /// Android's hidden "Fit route" FAB: free pan, north-up, fit the remaining route ("Route
    /// overview · north up"), else centre on the destination / rider at zoom 14 ("Overview · north up").
    case overview
    /// Menu FAB / HOME key.
    case openMenu
    /// Search pill / ASSISTANT key. The app should prompt "Type your search on the phone"
    /// (Android: DashRemote.requestTypeOnPhone + voice).
    case openSearch
    /// Dimmer, menu Close, search ←, BACK.
    case closeSheets

    // MARK: Map gestures

    /// Long-press on the map: `MapPlace("Dropped pin", lat, lon, "pin", "%.5f, %.5f")`, speak
    /// "Pin dropped", open the pin-setup preview. (The controller closes sheets.)
    case dropPin(GeoPoint)

    // MARK: Navigation / preview / arrival (performed by the app)

    /// End (metrics card) / menu End navigation → `endRouteNow()`: in preview → cancel preview;
    /// free ride → "Already free ride"; else finish ("Navigation finished").
    case endNavigation
    /// Preview Go → start navigation to the pending place (reuse the selected route).
    case go
    /// Route chip tapped → select candidate route i.
    case selectRoute(Int)
    /// Preview Cancel (trip) / Done (pin setup).
    case cancelPreview
    /// Pill / menu / preview "Circuit" → `startCircuit()` (there & back).
    case startCircuit
    /// Preview ★ Save → favorite of the pending place.
    case saveFavorite
    /// Preview Home (pin setup only): set home ("Dropped pin" renamed "Home").
    case setHome
    /// Preview ＋ Marker (pin setup only).
    case addMarker
    /// Arrive card "Park here": parked pin at the fix ("Marked on arrival").
    case markArrivalParking
    /// Arrive card "Find parking": hide the card and run the Parking POI search (the controller
    /// opens the search sheet itself).
    case findParking
    /// Arrive card "Done".
    case dismissArrival
    /// Menu "Park here": toggle/replace the parked pin ("Marked on dash"; < 40 m → clear).
    case parkHere
    /// Menu "Go Home": preview home (or "No Home set — long-press map or use Set Home").
    case goHome
    /// Menu "Set Home here": `MapPlace("Home", fix, "home", "Set on dash")`.
    case setHomeHere
    /// Menu "Recenter / Recalc": follow on (applied), reload prefs, reroute / snap / recentre.
    case recalc
    /// Menu "Record ride" / "Stop recording".
    case toggleRecording
    /// Menu "Voice on" / "Voice muted".
    case toggleVoice
    /// Search pill "Lap" / "Stop".
    case toggleLapTimer

    // MARK: Settings segments (persist immediately; route mode / avoids re-run a pending preview)

    case setUnits(MapUnits)
    case setTheme(MapTheme)
    case setVoice(Bool)
    case setNextStop(Bool)
    case setAutoFinish(Bool)
    case setChrome(MapChrome)
    case setRouteMode(RouteMode)
    case setAvoidTolls(Bool)
    case setAvoidHighways(Bool)

    // MARK: Search sheet

    /// "Type on your phone" row / input field: prompt the rider to type on the phone.
    case typeOnPhone
    /// POI chip (id from `DashSearchState.poiChips`, e.g. "Fuel") → Overpass "near me".
    case searchChip(String)
    /// Row i of `DashSearchState.results` tapped → preview it (the controller closes the sheet).
    case selectSearchResult(Int)
    /// An idle-list row (recent & favorites) tapped → preview it (the controller closes the sheet).
    case previewPlace(Place)
    /// Row action "★ Save".
    case savePlace(Place)
    /// Row action "＋ Marker".
    case addMarkerFor(Place)
    /// Row action "Delete".
    case deletePlace(Place)

    // MARK: Handlebar

    /// ButtonAction nav1…nav3: navigate to saved place slot 1…3 (geocode the slot query and
    /// start our own navigation).
    case navigateSavedPlace(Int)

    /// Intents whose whole effect is inside the dash UI (camera / sheets).
    public var isUIOnly: Bool {
        switch self {
        case .recenter, .zoomIn, .zoomOut, .toggleCompass, .toggleHeadingUp, .toggleFollow, .overview,
             .openMenu, .openSearch, .closeSheets:
            return true
        default:
            return false
        }
    }
}
