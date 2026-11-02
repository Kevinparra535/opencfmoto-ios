// SPDX-License-Identifier: AGPL-3.0-or-later
// NavigationSession actions: pin mode, preview actions, menu, circuit, stale results, compass,
// streams, localisation, lap timer, saved-place slots and preference changes.

import XCTest
@testable import OpenCfMotoCore

final class NavSessionActionTests: XCTestCase {
    private let dest = NavSessionFlowTests.dest

    func testPinModeActions() {
        let env = NavSessionEnv(http: NavFakeHTTPClient { _ in throw NavFakeNetworkError() })
        let s = env.session
        s.dropPin(at: GeoPoint(lat: 44.4268, lon: 26.1025))
        var snap = s.snapshot
        let pv = try! XCTUnwrap(snap.preview)
        XCTAssertTrue(pv.pinMode)
        XCTAssertEqual(pv.place, Place(name: "Dropped pin", lat: 44.4268, lon: 26.1025, category: "pin", subtitle: "44.42680, 26.10250"))
        XCTAssertEqual(pv.meta, "44.42680, 26.10250")
        XCTAssertEqual(snap.metrics.status, "Save this pin — open it later to navigate")
        XCTAssertEqual(env.rec.spoken, ["Pin dropped"])
        XCTAssertEqual(env.rec.camera.last, .center(GeoPoint(lat: 44.4268, lon: 26.1025), zoom: 16))
        // Home renames "Dropped pin" → "Home" and closes the pin sheet.
        env.rec.clear()
        s.setHomeFromPreview()
        snap = s.snapshot
        XCTAssertNil(snap.preview)
        XCTAssertEqual(env.places.home(), Place(name: "Home", lat: 44.4268, lon: 26.1025, category: "home", subtitle: "Home"))
        XCTAssertEqual(env.rec.spoken, ["Home set"])
        XCTAssertTrue(env.rec.effects.contains(.placesChanged))
        XCTAssertTrue(snap.pins.contains { $0.category == "home" })
        // Marker / Save.
        s.dropPin(at: GeoPoint(lat: 44.5, lon: 26.2))
        s.addMarkerFromPreview()
        XCTAssertNil(s.snapshot.preview)
        XCTAssertEqual(env.places.markers().first?.lat, 44.5)
        s.dropPin(at: GeoPoint(lat: 44.6, lon: 26.3))
        env.rec.clear()
        s.saveFavoriteFromPreview()
        XCTAssertEqual(env.places.favorites().first?.lat, 44.6)
        XCTAssertEqual(env.rec.toasts, ["Saved Dropped pin to favorites"])
        XCTAssertEqual(env.rec.spoken, ["Saved"])
    }

    func testTripPreviewSaveKeepsPreviewAndCancelRestoresHeadingUp() async {
        let env = NavSessionEnv(http: NavFakeHTTPClient(NavSessionFlowTests.routing))
        let s = env.session
        s.updateLocation(env.fix(44.43, 26.10, speed: 0))
        XCTAssertTrue(s.headingUp)
        s.previewPlace(dest)
        XCTAssertFalse(s.headingUp)
        await s.waitUntilIdle()
        s.saveFavoriteFromPreview()
        XCTAssertNotNil(s.snapshot.preview) // a trip preview stays open
        XCTAssertEqual(env.places.favorites().first, dest)
        env.rec.clear()
        s.cancelPreview()
        XCTAssertNil(s.snapshot.preview)
        XCTAssertTrue(s.headingUp)
        XCTAssertEqual(env.rec.camera, [.follow(headingUp: true)])
        // End with a preview open = cancel the preview.
        s.previewPlace(dest)
        s.endNavigation()
        XCTAssertNil(s.snapshot.preview)
        await s.waitUntilIdle()
        XCTAssertNil(s.snapshot.preview) // the cancelled preview's result is dropped
    }

    func testMenuActions() {
        let env = NavSessionEnv(http: NavFakeHTTPClient { _ in throw NavFakeNetworkError() })
        let s = env.session
        s.parkHere()
        XCTAssertEqual(env.rec.toasts.last, "No GPS for parking")
        s.goHome()
        XCTAssertEqual(env.rec.toasts.last, "No Home set — long-press map or use Set Home")
        s.setHomeHere()
        XCTAssertEqual(env.rec.toasts.last, "No GPS to set Home")
        s.recalc()
        XCTAssertEqual(env.rec.toasts.last, "No GPS")
        s.endNavigation()
        XCTAssertEqual(env.rec.toasts.last, "Already free ride")

        s.updateLocation(env.fix(44.43, 26.10, speed: 0))
        env.rec.clear()
        s.parkHere()
        XCTAssertEqual(env.places.parked()?.subtitle, "Marked on dash")
        XCTAssertEqual(env.rec.spoken, ["Parking marked"])
        s.updateLocation(env.fix(44.4302, 26.10, speed: 0)) // 22 m away → clears
        s.parkHere()
        XCTAssertNil(env.places.parked())
        XCTAssertEqual(env.rec.toasts.last, "Parked spot cleared")
        XCTAssertEqual(env.rec.spoken.last, "Parking cleared")
        s.parkHere()
        s.updateLocation(env.fix(44.432, 26.10, speed: 0)) // 200 m away → replaces
        s.parkHere()
        XCTAssertEqual(env.rec.spoken.last, "Parking updated")
        XCTAssertEqual(env.places.parked()?.lat, 44.432)
        XCTAssertEqual(env.places.markers().filter { $0.category == "parking" }.count, 1)

        env.rec.clear()
        s.setHomeHere()
        XCTAssertEqual(env.places.home(), Place(name: "Home", lat: 44.432, lon: 26.10, category: "home", subtitle: "Home"))
        XCTAssertEqual(env.rec.toasts, ["Home set here"])
        XCTAssertEqual(env.rec.spoken, ["Home set"])
        s.goHome()
        XCTAssertEqual(s.snapshot.preview?.place.category, "home")
        s.cancelPreview()
        env.rec.clear()
        s.recalc()
        XCTAssertEqual(env.rec.toasts, ["Recentered"])
        XCTAssertEqual(env.rec.spoken, ["Centered"])
    }

    func testRecalcInGpxAndNavTo() async {
        let env = NavSessionEnv(http: NavFakeHTTPClient(NavSessionFlowTests.routing))
        let s = env.session
        s.loadGpx(GpxParser.parse(NavFixtures.data("sample_track.gpx")))
        s.updateLocation(env.fix(45.005, 25.0, speed: 0))
        env.rec.clear()
        s.recalc()
        XCTAssertEqual(env.rec.spoken, ["Back on track"])
        XCTAssertEqual(env.rec.toasts, ["Snap · back on track"])
        XCTAssertTrue(env.rec.camera.contains(.center(GeoPoint(lat: 45.005, lon: 25.0), zoom: 15)))

        s.updateLocation(env.fix(44.435, 26.1013, speed: 0))
        s.navigate(to: dest)
        await s.waitUntilIdle()
        env.rec.clear()
        s.recalc()
        XCTAssertEqual(env.rec.toasts.first, "Routing…")
        await s.waitUntilIdle()
        XCTAssertTrue(env.rec.spoken.contains("Route updated"))
    }

    func testCircuitFlowAndGuards() async {
        let handler: @Sendable (HTTPRequest) throws -> HTTPResponse = { r in
            let u = r.url.absoluteString
            if u.contains("project-osrm") && u.components(separatedBy: "/driving/")[1].components(separatedBy: "?")[0]
                .split(separator: ";").count > 2 { return .navOK(fixture: "osrm_route_alts.json") }
            throw NavFakeNetworkError()
        }
        // The circuit's request waits at a gate while its in-flight state is checked: the fake answers
        // at once, so under CPU load the circuit could be built before the test read `loading` (a flaky
        // test). The guards and the previews before it go straight through.
        let gate = NavGatedHTTPClient(handler)
        gate.openGate()
        let env = NavSessionEnv(http: gate)
        let s = env.session
        s.startCircuit()
        XCTAssertEqual(env.rec.toasts.last, "Need GPS for a circuit")
        s.updateLocation(env.fix(44.43, 26.10, speed: 0))
        s.startCircuit()
        XCTAssertEqual(env.rec.toasts.last, "Pick a destination, then Circuit (there & back)")
        s.previewPlace(Place(name: "Near", lat: 44.4305, lon: 26.10))
        s.startCircuit()
        XCTAssertEqual(env.rec.toasts.last, "Pick a place away from you, then Circuit")
        await s.waitUntilIdle()

        s.previewPlace(dest)
        await s.waitUntilIdle()
        XCTAssertEqual(s.snapshot.preview?.routes.map(\.label), ["Direct"])
        XCTAssertEqual(s.snapshot.preview?.meta, "Straight line (no road route) · 1.6 km · 22:15 · Bucharest")
        env.rec.clear()
        gate.closeGate()
        let sent = gate.requestCount
        s.startCircuit()
        await gate.waitForRequests(sent + 1) // the circuit's request is out, held at the gate
        var snap = s.snapshot
        XCTAssertEqual(snap.preview?.isCircuit, true)
        XCTAssertEqual(snap.preview?.loading, true)
        XCTAssertEqual(snap.preview?.meta, "There & back · returning home")
        XCTAssertEqual(env.rec.toasts, ["Building there & back to Destino…"])
        XCTAssertEqual(env.rec.spoken, ["Building there and back circuit"])
        gate.openGate()
        await s.waitUntilIdle()
        snap = s.snapshot
        XCTAssertEqual(snap.preview?.routes.map(\.label), ["Circuit"])
        XCTAssertEqual(snap.preview?.chipLabels, ["★ Circuit · 22:17 · 2.3 km"])
        XCTAssertEqual(snap.preview?.meta, "2.3 km · 22:17 · Bucharest · There & back · returns home")
        s.go()
        XCTAssertEqual(s.snapshot.route?.label, "Circuit")
        XCTAssertEqual(s.snapshot.mode, .navTo(dest))
    }

    func testStalePreviewResultsAreDropped() async {
        let gate = NavGatedHTTPClient(NavSessionFlowTests.routing)
        let env = NavSessionEnv(http: gate)
        let s = env.session
        s.updateLocation(env.fix(44.43, 26.10, speed: 0))
        let first = Place(name: "First", lat: 44.45, lon: 26.12)
        s.previewPlace(first)
        await gate.waitForRequests(2)
        s.previewPlace(dest)
        gate.openGate()
        await s.waitUntilIdle()
        XCTAssertEqual(s.snapshot.preview?.place, dest)
        XCTAssertEqual(s.snapshot.preview?.routes.isEmpty, false)
        XCTAssertFalse(env.rec.snapshots.contains { $0.preview?.place == first && !($0.preview?.routes.isEmpty ?? true) })
    }

    func testPreviewWaitsForGpsThenRoutes() async {
        let env = NavSessionEnv(http: NavFakeHTTPClient(NavSessionFlowTests.routing))
        let s = env.session
        s.previewPlace(dest)
        var snap = s.snapshot
        XCTAssertEqual(snap.preview?.meta, "Bucharest · Waiting for GPS to route")
        XCTAssertEqual(snap.preview?.loading, false)
        XCTAssertEqual(env.rec.camera.last, .center(dest.point, zoom: 16))
        s.updateLocation(env.fix(44.43, 26.10, speed: 0))
        XCTAssertEqual(s.snapshot.preview?.loading, true)
        await s.waitUntilIdle()
        snap = s.snapshot
        XCTAssertEqual(snap.preview?.routes.count, 3)
    }

    func testRoutingPreferenceChangeRerunsPreviewAndWarnings() async {
        let env = NavSessionEnv(http: NavFakeHTTPClient(NavSessionFlowTests.osrmOnly))
        let s = env.session
        s.updateLocation(env.fix(44.43, 26.10, speed: 0))
        s.previewPlace(dest)
        await s.waitUntilIdle()
        env.rec.clear()
        var p = s.preferences
        p.avoidTolls = true
        s.updatePreferences(p)
        XCTAssertEqual(s.snapshot.preview?.loading, true)
        await s.waitUntilIdle()
        let pv = s.snapshot.preview!
        XCTAssertEqual(pv.routes.map(\.label), ["Fast"])
        XCTAssertTrue(pv.meta.hasSuffix(" · Couldn't avoid highways/tolls online — showing normal (may use motorway)"), pv.meta)
        XCTAssertEqual(env.rec.toasts.last, "Couldn't avoid highways/tolls online — showing normal (may use motorway)")
    }

    func testUnitsChangeReformatsHud() async {
        let env = NavSessionEnv(http: NavFakeHTTPClient(NavSessionFlowTests.osrmOnly))
        let s = env.session
        s.updateLocation(env.fix(44.43, 26.10, speed: 0, alt: 100))
        s.navigate(to: dest)
        await s.waitUntilIdle()
        var p = s.preferences
        p.units = .imperial
        s.updatePreferences(p)
        let snap = s.snapshot
        XCTAssertEqual(snap.metrics.altUnit, "ft")
        XCTAssertEqual(snap.metrics.alt, "328")
        XCTAssertEqual(snap.metrics.left, "1.4 mi")
        XCTAssertEqual(snap.cue?.distanceText, "0.7 mi")
    }

    func testCompassSmoothingThrottleAndHeadingUp() {
        let env = NavSessionEnv(http: NavFakeHTTPClient { _ in throw NavFakeNetworkError() })
        let s = env.session
        s.updateLocation(env.fix(44.43, 26.10, speed: 0))
        var smoother = HeadingSmoother()
        s.updateHeading(90)
        XCTAssertEqual(s.snapshot.puckBearingDeg, smoother.add(90))
        env.clock.advance(0.05)
        s.updateHeading(180) // smoothed but not processed (< 120 ms)
        _ = smoother.add(180)
        XCTAssertEqual(s.snapshot.puckBearingDeg, 90)
        env.clock.advance(0.1)
        s.updateHeading(180)
        let expected = smoother.add(180)
        XCTAssertEqual(s.snapshot.puckBearingDeg, expected)
        XCTAssertEqual(expected, 111.0, accuracy: 0.1)
        // North-up: the compass no longer rotates the puck.
        s.setHeadingUp(false)
        XCTAssertEqual(env.rec.toasts.last, "North up")
        env.clock.advance(0.2)
        s.updateHeading(270)
        XCTAssertEqual(s.snapshot.puckBearingDeg, expected)
        // Moving: the GPS course wins.
        s.updateLocation(env.fix(44.4301, 26.10, speed: 10, course: 10))
        XCTAssertEqual(s.snapshot.puckBearingDeg, 10)
    }

    func testCompassRefreshesJoinArrowWhileStopped() async {
        let env = NavSessionEnv(http: NavFakeHTTPClient(NavSessionFlowTests.osrmOnly))
        let s = env.session
        s.updateLocation(env.fix(44.435, 26.1013, speed: 0)) // 103 m east of the north leg
        s.navigate(to: dest)
        await s.waitUntilIdle()
        s.updateHeading(270) // facing the route (west)
        XCTAssertEqual(s.snapshot.cue?.text, "Go ahead")
        env.clock.advance(0.2)
        for _ in 0 ..< 40 { s.updateHeading(90); env.clock.advance(0.13) } // turn around: facing east
        XCTAssertEqual(s.snapshot.cue?.text, "Turn around")
        XCTAssertEqual(s.snapshot.cue?.dir, .uturn)
    }

    func testSnapshotAndEffectStreams() async {
        let env = NavSessionEnv(http: NavFakeHTTPClient { _ in throw NavFakeNetworkError() })
        let s = env.session
        var snaps = s.snapshots().makeAsyncIterator()
        let first = await snaps.next()
        XCTAssertEqual(first?.mode, .freeRide)
        var effects = s.effects().makeAsyncIterator()
        s.dropPin(at: GeoPoint(lat: 1, lon: 1))
        let next = await snaps.next()
        XCTAssertGreaterThan(next!.revision, first!.revision)
        XCTAssertEqual(next?.preview?.pinMode, true)
        let e1 = await effects.next()
        let e2 = await effects.next()
        XCTAssertEqual(e1, .speak("Pin dropped"))
        XCTAssertEqual(e2, .toast("Save this pin — open it later to navigate"))
        let revs = env.rec.snapshots.map(\.revision)
        XCTAssertEqual(revs, revs.sorted())
        XCTAssertEqual(Set(revs).count, revs.count)
    }

    func testVoiceMutedProducesNoSpeech() {
        var prefs = MapPreferences()
        prefs.voiceOn = false
        let env = NavSessionEnv(http: NavFakeHTTPClient { _ in throw NavFakeNetworkError() }, prefs: prefs)
        env.session.dropPin(at: GeoPoint(lat: 1, lon: 1))
        XCTAssertEqual(env.rec.spoken, [])
        XCTAssertEqual(env.rec.toasts.count, 1)
        env.session.setVoiceEnabled(true)
        env.session.dropPin(at: GeoPoint(lat: 2, lon: 2))
        XCTAssertEqual(env.rec.spoken, ["Pin dropped"])
    }

    func testSpanishSession() async {
        let env = NavSessionEnv(http: NavFakeHTTPClient(NavSessionFlowTests.osrmOnly), language: .es, decimalSeparator: ",")
        let s = env.session
        XCTAssertEqual(s.snapshot.metrics.status, "GPS… · ruta libre")
        s.navigate(to: dest)
        var snap = s.snapshot
        XCTAssertEqual(snap.metrics.status, "GPS… · navegar a Destino")
        XCTAssertEqual(snap.cue, HudCue(dir: .arrive, distanceText: "GPS", text: "Hacia Destino"))
        XCTAssertEqual(env.rec.spoken, ["Navegando a Destino"])
        s.updateLocation(env.fix(44.43, 26.10, speed: 0))
        await s.waitUntilIdle()
        snap = s.snapshot
        XCTAssertEqual(snap.metrics.left, "2,3 km")
        XCTAssertEqual(snap.cue, HudCue(dir: .right, distanceText: "1,1 km", text: "Strada Exemplu", lanes: "↑ ↑"))
        XCTAssertTrue(env.rec.spoken.contains("Ruta lista"))
        XCTAssertEqual(s.title, "→ Destino")
        s.setLanguage(.en, decimalSeparator: ".")
        XCTAssertEqual(s.snapshot.metrics.left, "2.3 km")
    }

    func testLapTimerInSession() {
        let env = NavSessionEnv(http: NavFakeHTTPClient { _ in throw NavFakeNetworkError() })
        let s = env.session
        s.toggleLapTimer()
        XCTAssertEqual(env.rec.toasts.last, "Need GPS for lap timer")
        s.updateLocation(env.fix(45.0, 7.0, speed: 0))
        s.toggleLapTimer()
        XCTAssertTrue(s.isLapTimerOn)
        XCTAssertEqual(env.rec.spoken.last, "Lap timer armed")
        XCTAssertTrue(s.snapshot.pins.contains { $0.name == "S/F" && $0.category == "lap" })
        XCTAssertEqual(s.lapCard()?.current, "Pass start/finish")
        func at(_ lat: Double, _ dt: TimeInterval) { env.clock.advance(dt); s.updateLocation(env.fix(lat, 7.0, speed: 20)) }
        at(45.00072, 5); at(45.0, 5)   // start
        at(45.00072, 10); at(45.0, 20)  // lap 1 = 30 s
        XCTAssertEqual(env.rec.spoken.last, "Lap 1")
        XCTAssertTrue(env.rec.toasts.contains("Lap 1  0:30.00"))
        XCTAssertEqual(s.lapCard()?.meta, "LAST 0:30.00   BEST 0:30.00")
        s.toggleLapTimer()
        XCTAssertFalse(s.isLapTimerOn)
        XCTAssertEqual(env.rec.toasts.last, "Lap timer off")
        XCTAssertFalse(s.snapshot.pins.contains { $0.name == "S/F" })
    }

    func testSavedPlaceSlots() async {
        let env = NavSessionEnv(http: NavFakeHTTPClient(SearchPlaceTests.photonHandler), savedSlots: true)
        let s = env.session
        await s.navigateToSavedPlace(2)
        XCTAssertEqual(env.rec.toasts.last, "Saved place 2 is not set")
        s.savedSlots!.set(0, name: "Work", query: "44.44, 26.115")
        await s.navigateToSavedPlace(1)
        XCTAssertEqual(s.snapshot.mode, .navTo(Place(name: "Work", lat: 44.44, lon: 26.115, category: "saved", subtitle: "44.44, 26.115")))
        s.savedSlots!.set(1, name: "", query: "Câmpina")
        await s.navigateToSavedPlace(2)
        XCTAssertEqual(s.snapshot.destination?.name, "Câmpina")
        XCTAssertEqual(s.snapshot.destination?.category, "administrative") // Nominatim (no position yet)
    }

    func testSearchHelpers() async throws {
        let env = NavSessionEnv(http: NavFakeHTTPClient { r in
            if r.url.absoluteString.contains("overpass") { return .navOK(fixture: "overpass_fuel.json") }
            return try SearchPlaceTests.photonHandler(r)
        })
        let s = env.session
        do {
            _ = try await s.searchNearby(PlaceSearch.poiChips[0])
            XCTFail("expected Need GPS")
        } catch {
            XCTAssertEqual(NavServiceError.message(for: error, fallback: ""), "Need GPS for nearby POI")
        }
        s.updateLocation(env.fix(44.4268, 26.1025, speed: 0))
        let fuel = try await s.searchNearby(PlaceSearch.poiChips[0])
        XCTAssertEqual(fuel.first?.name, "OMV")
        let places = try await s.searchPlaces("Câmpina")
        XCTAssertEqual(places.first?.name, "Câmpina")
        env.places.addFavorite(Place(name: "Fav", lat: 1, lon: 1))
        XCTAssertEqual(s.idleSuggestions().map(\.name), ["Fav"])
    }

    func testOverlayPinsFiltering() {
        let env = NavSessionEnv(http: NavFakeHTTPClient { _ in throw NavFakeNetworkError() })
        env.session.setOverlayPlaces([Place(name: "Fuel", lat: 1, lon: 1, category: "fuel"), Place(name: "Home", lat: 2, lon: 2, category: "home"),
                                      Place(name: "Parked", lat: 3, lon: 3), Place(name: "x", lat: 4, lon: 4, subtitle: "parked here"),
                                      Place(name: "Zero", lat: 0, lon: 0), Place(name: "Fuel", lat: 1.000001, lon: 1)])
        XCTAssertEqual(env.session.snapshot.pins.map(\.name), ["Fuel"])
        env.places.addMarker(Place(name: "M", lat: 5, lon: 5))
        XCTAssertEqual(env.session.snapshot.pins.map(\.name), ["M", "Fuel"]) // places store changes are picked up
    }

    func testStartFreeRideRecordsHistoryAndClearsNavigation() async {
        let env = NavSessionEnv(http: NavFakeHTTPClient(NavSessionFlowTests.osrmOnly))
        let s = env.session
        s.updateLocation(env.fix(44.43, 26.10, speed: 0))
        s.navigate(to: dest)
        await s.waitUntilIdle()
        env.rec.clear()
        s.startFreeRide(recordHistory: true)
        let snap = s.snapshot
        XCTAssertEqual(snap.mode, .freeRide)
        XCTAssertNil(snap.route)
        XCTAssertEqual(snap.metrics.status, "GPS… · free ride")
        XCTAssertEqual(env.rec.spoken, [])
        XCTAssertEqual(env.places.history().first, Place(name: "Free ride", lat: 0, lon: 0, category: "mode", subtitle: "Started free ride"))
        XCTAssertEqual(s.idleSuggestions().map(\.name), ["Destino"]) // mode rows hidden
    }
}

final class NavSessionSmallActionTests: XCTestCase {
    func testRecenterAndQuietArrivalDismiss() {
        let env = NavSessionEnv(http: NavFakeHTTPClient { _ in throw NavFakeNetworkError() })
        let s = env.session
        s.recenter()
        XCTAssertEqual(env.rec.toasts.last, "No GPS yet — wait for a fix")
        s.updateLocation(env.fix(44.43, 26.10, speed: 0))
        s.recenter()
        XCTAssertEqual(env.rec.toasts.last, "Centered on GPS")
        XCTAssertEqual(env.rec.camera.last, .follow(headingUp: true))
        env.rec.clear()
        s.dismissArrival(announce: false)
        XCTAssertEqual(env.rec.toasts, [])
    }
}
