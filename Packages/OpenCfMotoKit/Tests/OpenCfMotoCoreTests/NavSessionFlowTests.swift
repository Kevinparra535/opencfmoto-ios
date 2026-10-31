// SPDX-License-Identifier: AGPL-3.0-or-later
// NavigationSession end-to-end flows with a scripted HTTP client and a manual clock:
// preview → Go → follow → turn cues → off-route → auto-reroute → arrival, GPX follow, free ride,
// straight-line phase, arrival variants and the Android parity switch.

import XCTest
@testable import OpenCfMotoCore

struct NavSessionEnv {
    let session: NavigationSession
    let clock: NavManualClock
    let scheduler: NavManualScheduler
    let rec: NavRecorder
    let places: PlacesStore
    let kv: InMemoryKeyValueStore

    /// 2023-11-14 22:13:20 UTC at clock 1000.
    static let wallBase = Date(timeIntervalSince1970: 1_700_000_000)

    init(http: HTTPClient, prefs: MapPreferences = MapPreferences(), parity: Bool = false, language: NavLanguage = .en,
         decimalSeparator: Character = ".", savedSlots: Bool = false) {
        let clock = NavManualClock(1000)
        let kv = InMemoryKeyValueStore()
        self.clock = clock
        self.kv = kv
        scheduler = NavManualScheduler(clock: clock)
        places = PlacesStore(store: kv)
        let cfg = NavigationSession.Configuration(language: language, decimalSeparator: decimalSeparator, parityMode: parity,
                                                  timeZone: TimeZone(identifier: "UTC")!)
        session = NavigationSession(http: http, places: places, preferences: prefs, configuration: cfg, clock: clock,
                                    wallClock: { NavSessionEnv.wallBase.addingTimeInterval(clock.now() - 1000) },
                                    scheduler: scheduler, savedSlots: savedSlots ? SavedPlaceSlots(store: kv) : nil)
        rec = NavRecorder()
        rec.attach(session)
    }

    func fix(_ lat: Double, _ lon: Double, speed: Double? = 10, course: Double? = nil, acc: Double? = 5, alt: Double? = 80) -> LocationFix {
        LocationFix(lat: lat, lon: lon, speedMps: speed, courseDeg: course, accuracyM: acc, altitudeM: alt,
                    timeMs: Int64((NavSessionEnv.wallBase.timeIntervalSince1970 + clock.now() - 1000) * 1000))
    }

    /// Feeds fixes every ~`stepM` metres (one per second) from `a` to `b` inclusive.
    func ride(_ a: (Double, Double), _ b: (Double, Double), stepM: Double = 10, speed: Double = 10, acc: Double = 5) {
        let d = GeoMath.haversineM(a.0, a.1, b.0, b.1)
        let n = max(1, Int(d / stepM))
        let course = GeoMath.bearingDeg(a.0, a.1, b.0, b.1)
        for k in 0 ... n {
            let t = Double(k) / Double(n)
            session.updateLocation(fix(a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, speed: speed, course: course, acc: acc))
            clock.advance(1)
        }
    }
}

final class NavSessionFlowTests: XCTestCase {
    static let dest = Place(name: "Destino", lat: 44.44, lon: 26.115, category: "city", subtitle: "Bucharest")

    /// Valhalla + OSRM alternatives for previews, the reroute fixture for single OSRM requests,
    /// Overpass maxspeed 50, via requests fail.
    static let routing: @Sendable (HTTPRequest) throws -> HTTPResponse = { r in
        let u = r.url.absoluteString
        if u.contains("overpass") { return .navOK(fixture: "overpass_maxspeed.json") }
        if u.contains("valhalla") { return .navOK(fixture: "valhalla_route.json") }
        if u.contains("project-osrm") {
            let path = u.components(separatedBy: "/driving/")[1].components(separatedBy: "?")[0]
            if path.split(separator: ";").count > 2 { throw NavFakeNetworkError("via") }
            if u.contains("alternatives=false") { return .navOK(fixture: "osrm_reroute.json") }
            return .navOK(fixture: "osrm_route_alts.json")
        }
        throw NavFakeNetworkError("offline")
    }

    /// OSRM always answers the L-shaped route (single best = route0, 240 s).
    static let osrmOnly: @Sendable (HTTPRequest) throws -> HTTPResponse = { r in
        let u = r.url.absoluteString
        if u.contains("project-osrm") { return .navOK(fixture: "osrm_route_alts.json") }
        if u.contains("overpass") { return .navOK(fixture: "overpass_empty.json") }
        throw NavFakeNetworkError("offline")
    }

    func testPreviewGoFollowRerouteArrive() async throws {
        let env = NavSessionEnv(http: NavFakeHTTPClient(Self.routing))
        let s = env.session
        s.updateLocation(env.fix(44.43, 26.10, speed: 0))
        await s.waitUntilIdle()
        XCTAssertEqual(s.snapshot.speedLimit, SpeedLimit(kmh: 50, label: "50"))
        XCTAssertEqual(s.snapshot.mode, .freeRide)
        XCTAssertNil(s.snapshot.cue)

        // Preview.
        s.previewPlace(Self.dest)
        var snap = s.snapshot
        XCTAssertEqual(snap.preview?.place, Self.dest)
        XCTAssertEqual(snap.preview?.loading, true)
        XCTAssertEqual(snap.preview?.meta, "Bucharest")
        await s.waitUntilIdle()
        snap = s.snapshot
        let pv = try XCTUnwrap(snap.preview)
        XCTAssertFalse(pv.loading)
        XCTAssertEqual(pv.routes.map(\.label), ["Fast", "Fun", "Alt"])
        XCTAssertEqual(pv.chipLabels, ["★ Fast · 22:17 · 2.3 km", "Fun · 22:20 · 2.9 km", "Alt · 22:19 · 2.3 km"])
        XCTAssertEqual(pv.meta, "2.3 km · 22:17 · Bucharest")
        XCTAssertTrue(env.rec.camera.contains { if case .fit = $0 { return true } else { return false } })
        s.selectRoute(1)
        XCTAssertEqual(s.snapshot.preview?.chipLabels[1], "★ Fun · 22:20 · 2.9 km")
        XCTAssertEqual(s.snapshot.preview?.selectedRoute?.label, "Fun")
        s.selectRoute(99)
        XCTAssertEqual(s.snapshot.preview?.selectedIndex, 2)
        s.selectRoute(0)

        // Go reuses the selected preview route (no new request).
        let requestsBeforeGo = (s.router.osrm.http as! NavFakeHTTPClient).requests.count
        env.rec.clear()
        s.go()
        snap = s.snapshot
        XCTAssertEqual(snap.mode, .navTo(Self.dest))
        XCTAssertNil(snap.preview)
        XCTAssertEqual(snap.route?.label, "Fast")
        XCTAssertEqual(snap.route?.durationSec, 250.5)
        XCTAssertEqual((s.router.osrm.http as! NavFakeHTTPClient).requests.count, requestsBeforeGo)
        XCTAssertEqual(env.rec.spoken.first, "Navigating to Destino")
        XCTAssertEqual(env.places.history().first, Self.dest)
        XCTAssertTrue(env.rec.effects.contains(.placesChanged))
        XCTAssertEqual(snap.cue, HudCue(dir: .right, distanceText: "1.1 km", text: "Strada Exemplu"))
        XCTAssertEqual(snap.metrics.left, "2.3 km")
        XCTAssertEqual(snap.metrics.status, "Route · 2.3 km")
        XCTAssertEqual(snap.metrics.time, "2m")      // 2302.8 m at the 50 km/h floor = 166 s
        XCTAssertEqual(snap.metrics.arrive, "22:16")
        XCTAssertEqual(snap.metrics.alt, "80")
        XCTAssertEqual(snap.puck, GeoPoint(lat: 44.43, lon: 26.10))

        // Ride north 500 m.
        env.rec.clear()
        env.ride((44.43, 26.10), (44.435, 26.10))
        snap = s.snapshot
        XCTAssertEqual(snap.cue?.dir, .right)
        XCTAssertEqual(snap.cue?.text, "Strada Exemplu")
        XCTAssertEqual(snap.cue?.distanceText, "556 m")
        XCTAssertEqual(snap.progress?.nearestIndex, 5)
        XCTAssertEqual(env.rec.spoken, []) // nothing within 150 m yet
        XCTAssertEqual(snap.metrics.time, "2m") // 1747 m at 10 m/s = 175 s

        // Off route: 103 m east for 10 s with good accuracy → join cue, then auto-reroute.
        env.rec.clear()
        for _ in 0 ..< 10 {
            s.updateLocation(env.fix(44.435, 26.1013, speed: 0, acc: 10))
            env.clock.advance(1)
        }
        snap = s.snapshot
        XCTAssertEqual(env.rec.spoken.first, "Turn left toward the route, 103 m")
        XCTAssertTrue(env.rec.spoken.contains("Rerouting"))
        XCTAssertTrue(env.rec.toasts.contains("Routing…"))
        await s.waitUntilIdle()
        snap = s.snapshot
        XCTAssertEqual(snap.route?.points.first, TrackPoint(lat: 44.435, lon: 26.1013))
        XCTAssertEqual(snap.route?.label, "Fast")
        XCTAssertTrue(env.rec.spoken.contains("Route updated"))
        XCTAssertFalse(snap.metrics.statusWarning)
        XCTAssertEqual(snap.cue, HudCue(dir: .right, distanceText: "556 m", text: "Strada Exemplu"))

        // Follow the new route: heads-up and execute for the "end of road" right turn.
        env.rec.clear()
        env.ride((44.435, 26.1013), (44.44, 26.1013))
        XCTAssertEqual(env.rec.spoken, ["In 150 meters, turn right onto Strada Exemplu", "Turn right onto Strada Exemplu"])
        // East to the destination → arrival (start distance ≥ 200 m, > 15 s since Go).
        env.rec.clear()
        env.ride((44.44, 26.1013), (44.44, 26.115))
        XCTAssertEqual(env.rec.spoken, ["Destination reached"])
        XCTAssertEqual(s.snapshot.mode, .navTo(Self.dest)) // finish is delayed 2 s
        XCTAssertEqual(env.scheduler.pendingCount, 1)
        env.scheduler.runDue()
        snap = s.snapshot
        XCTAssertEqual(snap.mode, .freeRide)
        XCTAssertEqual(snap.arrival, ArrivalCard(title: "Arrived · Destino", meta: "Mark parking, find a spot, or continue free ride"))
        XCTAssertEqual(snap.metrics.status, "Arrived")
        XCTAssertEqual(env.rec.spoken.last, "Arrived")
        XCTAssertNil(snap.route)
        XCTAssertNil(snap.cue)
        XCTAssertNil(snap.destination)
        XCTAssertEqual(snap.metrics.left, "—")

        // Arrive card: Park here.
        env.rec.clear()
        s.arrivalParkHere()
        XCTAssertNil(s.snapshot.arrival)
        XCTAssertEqual(env.places.parked()?.subtitle, "Marked on arrival")
        XCTAssertEqual(env.rec.spoken, ["Parking marked"])
        XCTAssertTrue(s.snapshot.pins.contains { $0.category == "parking" })
    }

    func testGpxFollowWithGeometricTurnAndWaypointCues() {
        let env = NavSessionEnv(http: NavFakeHTTPClient { _ in throw NavFakeNetworkError() })
        let s = env.session
        let track = GpxParser.parse(NavFixtures.data("sample_track.gpx"))
        s.loadGpx(track)
        var snap = s.snapshot
        XCTAssertEqual(snap.mode, .gpx(name: "Transfăgărășan test"))
        XCTAssertEqual(snap.cue, HudCue(dir: .arrive, distanceText: "GPS", text: "To Transfăgărășan test"))
        XCTAssertEqual(snap.metrics.left, "6.6 km")
        XCTAssertEqual(snap.metrics.status, "GPS… · 6.6 km track")
        XCTAssertEqual(snap.route?.label, "GPX")
        XCTAssertTrue(snap.pins.contains { $0.name == "Peak" && $0.category == "wpt" })
        XCTAssertEqual(env.places.history().first?.category, "gpx")
        XCTAssertEqual(s.title, "Transfăgărășan test · 6.6 km · ↑150")

        env.ride((45.0, 25.0), (45.03, 25.0), speed: 12)
        XCTAssertEqual(env.rec.spoken, ["Approaching Peak", "In 200 meters, turn right", "Turn right"])
        snap = s.snapshot
        XCTAssertEqual(snap.cue?.text, "To Transfăgărășan test") // no turn ahead after the corner
        XCTAssertTrue(snap.metrics.status.hasPrefix("Route · 6.6 km"))
        env.rec.clear()
        env.ride((45.03, 25.0), (45.03, 25.042), speed: 12)
        XCTAssertEqual(env.rec.spoken, ["Approaching Fuel & Food"])
        snap = s.snapshot
        XCTAssertEqual(snap.mode, .gpx(name: "Transfăgărășan test")) // GPX has no arrival detection
        XCTAssertEqual(snap.metrics.left, "0 m")
        XCTAssertEqual(snap.cue, HudCue(dir: .arrive, distanceText: "0 m", text: "To Transfăgărășan test"))
    }

    func testGpxOrientationFlipOnFirstFix() {
        let env = NavSessionEnv(http: NavFakeHTTPClient { _ in throw NavFakeNetworkError() })
        env.session.loadGpx(GpxParser.parse(NavFixtures.data("sample_track.gpx")))
        env.session.updateLocation(env.fix(45.03, 25.042, speed: 8, course: 270))
        XCTAssertEqual(env.rec.spoken, ["Following the track the other way"])
        XCTAssertEqual(env.session.snapshot.route?.points.first, TrackPoint(lat: 45.03, lon: 25.042, ele: 650))
        // Only once.
        env.session.updateLocation(env.fix(45.03, 25.041, speed: 8, course: 270))
        XCTAssertEqual(env.rec.spoken.count, 1)
    }

    func testFreeRide() {
        let env = NavSessionEnv(http: NavFakeHTTPClient { _ in throw NavFakeNetworkError() })
        let s = env.session
        XCTAssertEqual(s.snapshot.metrics.status, "GPS… · free ride")
        s.updateLocation(env.fix(44.43, 26.10, speed: 10, course: 45, alt: 123.4))
        let snap = s.snapshot
        XCTAssertEqual(snap.mode, .freeRide)
        XCTAssertNil(snap.cue)
        XCTAssertNil(snap.route)
        XCTAssertNil(snap.progress)
        XCTAssertEqual(snap.metrics.time, "—")
        XCTAssertEqual(snap.metrics.left, "—")
        XCTAssertEqual(snap.metrics.arrive, "—")
        XCTAssertEqual(snap.metrics.alt, "123")
        XCTAssertEqual(snap.metrics.status, "36 km/h · free ride · avg 0")
        XCTAssertEqual(snap.puck, GeoPoint(lat: 44.43, lon: 26.10))
        XCTAssertEqual(snap.puckBearingDeg, 45)
        XCTAssertFalse(snap.showStraightLineToDestination)
        XCTAssertNil(snap.speedLimit) // lookup failed → hidden
        // Average after ≥ 5 s of moving time.
        env.ride((44.43, 26.10), (44.431, 26.10), stepM: 10, speed: 10)
        XCTAssertTrue(s.snapshot.metrics.status.hasSuffix("avg 36"), s.snapshot.metrics.status)
    }

    func testStraightLinePhaseThenRouteReady() async {
        let gate = NavGatedHTTPClient(Self.osrmOnly)
        let env = NavSessionEnv(http: gate)
        let s = env.session
        s.navigate(to: Self.dest)
        var snap = s.snapshot
        XCTAssertEqual(snap.mode, .navTo(Self.dest))
        XCTAssertEqual(snap.cue, HudCue(dir: .arrive, distanceText: "GPS", text: "To Destino"))
        XCTAssertEqual(snap.metrics.status, "GPS… · navigate to Destino")
        XCTAssertFalse(snap.showStraightLineToDestination)
        XCTAssertEqual(env.rec.spoken, ["Navigating to Destino"])

        env.rec.clear()
        s.updateLocation(env.fix(44.43, 26.10, speed: 10, course: 45))
        snap = s.snapshot
        XCTAssertTrue(snap.showStraightLineToDestination)
        XCTAssertNil(snap.route)
        XCTAssertEqual(snap.cue, HudCue(dir: .straight, distanceText: "1.6 km", text: "Go ahead"))
        XCTAssertEqual(snap.metrics.left, "1.6 km")
        XCTAssertEqual(snap.metrics.status, "36 km/h · 1.6 km to Destino · avg 0")
        XCTAssertEqual(env.rec.spoken, ["Go ahead to the route, 1.6 km"])
        XCTAssertEqual(snap.puckBearingDeg, 45)
        // The next fix must not duplicate the in-flight route request.
        env.clock.advance(1)
        s.updateLocation(env.fix(44.4301, 26.1001, speed: 10, course: 45))
        await gate.waitForRequests(2) // route + speed limit
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(gate.requestCount, 2)
        gate.openGate()
        await s.waitUntilIdle()
        snap = s.snapshot
        XCTAssertFalse(snap.showStraightLineToDestination)
        XCTAssertEqual(snap.route?.label, "Fast")
        XCTAssertEqual(snap.route?.durationSec, 240)
        XCTAssertTrue(env.rec.spoken.contains("Route ready"))
        XCTAssertEqual(snap.cue?.text, "Strada Exemplu")
    }

    func testAlreadyNearbyFinishesSilently() async {
        let env = NavSessionEnv(http: NavFakeHTTPClient(Self.osrmOnly))
        let s = env.session
        s.updateLocation(env.fix(44.4395, 26.115, speed: 0))
        s.navigate(to: Self.dest)
        let snap = s.snapshot
        XCTAssertEqual(snap.mode, .freeRide)
        XCTAssertEqual(snap.metrics.status, "Already nearby")
        XCTAssertNil(snap.arrival)
        XCTAssertEqual(env.rec.spoken, ["Navigating to Destino"])
        XCTAssertTrue(env.rec.toasts.contains("Already nearby"))
        await s.waitUntilIdle()
        XCTAssertNil(s.snapshot.route) // the stale route result is dropped
        XCTAssertEqual(s.snapshot.mode, .freeRide)
    }

    func testArrivalWithoutAutoFinishShowsCardAndKeepsNavigating() async {
        var prefs = MapPreferences()
        prefs.autoFinish = false
        let env = NavSessionEnv(http: NavFakeHTTPClient(Self.osrmOnly), prefs: prefs)
        let s = env.session
        s.updateLocation(env.fix(44.43, 26.10, speed: 0))
        s.navigate(to: Self.dest)
        await s.waitUntilIdle()
        env.ride((44.43, 26.10), (44.44, 26.10))
        env.ride((44.44, 26.10), (44.44, 26.115))
        let snap = s.snapshot
        XCTAssertEqual(snap.arrival, ArrivalCard(title: "Arrived · Destino", meta: "Mark parking, find a spot, or continue free ride"))
        XCTAssertEqual(snap.mode, .navTo(Self.dest))
        XCTAssertEqual(env.scheduler.pendingCount, 0)
        XCTAssertEqual(env.rec.spoken.filter { $0 == "Destination reached" }.count, 1)
        env.rec.clear()
        s.dismissArrival()
        XCTAssertNil(s.snapshot.arrival)
        XCTAssertEqual(s.snapshot.metrics.status, "Free ride")
        s.endNavigation()
        XCTAssertEqual(s.snapshot.mode, .freeRide)
        XCTAssertNil(s.snapshot.arrival) // manual End never shows the arrive card
        XCTAssertEqual(env.rec.spoken, ["Navigation finished"])
    }

    func testParityModeReproducesAndroidArrivalBug() async {
        let env = NavSessionEnv(http: NavFakeHTTPClient(Self.osrmOnly), parity: true)
        let s = env.session
        s.updateLocation(env.fix(44.43, 26.10, speed: 0))
        s.navigate(to: Self.dest)
        await s.waitUntilIdle()
        env.ride((44.43, 26.10), (44.44, 26.10))
        env.ride((44.44, 26.10), (44.44, 26.115))
        // Android records the start distance only inside the arrival radius → silent "Already nearby".
        XCTAssertFalse(env.rec.spoken.contains("Destination reached"))
        XCTAssertEqual(s.snapshot.mode, .freeRide)
        XCTAssertTrue(env.rec.toasts.contains("Already nearby"))
        XCTAssertFalse(env.rec.spoken.contains("Already nearby"))
        XCTAssertNil(s.snapshot.arrival)
    }

    func testEndNavigationAndDelayedFinishIsCancelledByNewNavigation() async {
        let env = NavSessionEnv(http: NavFakeHTTPClient(Self.osrmOnly))
        let s = env.session
        s.updateLocation(env.fix(44.43, 26.10, speed: 0))
        s.navigate(to: Self.dest)
        await s.waitUntilIdle()
        env.ride((44.43, 26.10), (44.44, 26.10))
        env.ride((44.44, 26.10), (44.44, 26.115))
        XCTAssertEqual(env.scheduler.pendingCount, 1)
        // The rider ends and starts another navigation before the 2 s finish fires.
        s.endNavigation()
        let other = Place(name: "Other", lat: 44.43, lon: 26.10)
        s.navigate(to: other)
        env.scheduler.runDue()
        XCTAssertEqual(s.snapshot.mode, .navTo(other))
        XCTAssertNil(s.snapshot.arrival)
    }
}
