// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) GpxDashUi.kt (previewPlace, selectRoute, startNavigationTo,
// cancelPreview, startCircuit, showPinSetup, preview / arrive / menu handlers, lap timer),
// GpxSession.kt (prepareFreeRide / prepareGpx)
//
// User actions of the dash map (docs/spec/navigation-dash.md §11.8). Every action publishes a new
// snapshot; feedback texts are set on the status line and emitted as `NavEffect.toast`.

import Foundation

extension NavigationSession {
    // MARK: - Modes

    /// Free ride: no route, no destination (`GpxSession.prepareFreeRide`). With `recordHistory` the
    /// hub's history row ("Free ride", 0, 0, "mode", "Started free ride") is pushed.
    public func startFreeRide(overlays: [Place]? = nil, recordHistory: Bool = false) {
        mutate {
            cancelPreviewTaskLocked()
            let mark = s.outEffects.count
            finishToFreeRideLocked(spoken: .freeRide, offerParking: false)
            s.outEffects.removeSubrange(mark...) // a deliberate switch is not announced
            if let overlays { s.overlays = overlays }
            s.preview = nil
            s.arrival = nil
            statusLocked(.gpsFreeRide, toast: false)
            if recordHistory {
                places.pushHistory(Place(name: "Free ride", lat: 0, lon: 0, category: "mode", subtitle: "Started free ride"))
                placesChangedLocked()
            }
            s.dirty = true
        }
    }

    /// Follows a GPX track (`GpxSession.prepareGpx`). The track is oriented for the rider on the
    /// first fix; GPX mode never reroutes and has no arrival detection.
    public func loadGpx(_ track: GpxTrack, displayName: String? = nil, recordHistory: Bool = true) {
        mutate {
            cancelPreviewTaskLocked()
            let str = strings
            let name = (displayName?.isNavBlank == false ? displayName! : (track.name.isNavBlank ? "GPX" : track.name))
            s.mode = .gpx(name: name)
            s.trackName = name
            s.destination = nil
            s.gpxTrack = track
            s.gpxOriented = false
            let f = RouteFollower(track: track, parityMode: parityMode, strings: str)
            s.follower = f
            s.route = f.asRoute(label: "GPX")
            s.progress = nil
            s.preview = nil
            s.arrival = nil
            s.navGeneration &+= 1
            s.routeToken &+= 1
            s.routeRequested = false
            s.navStartDist = nil
            s.navEngagedAt = nil
            s.offRouteSince = nil
            s.voice.reset()
            s.cue = nil
            s.pinsRevision = nil
            s.headingUp = true
            s.metrics.time = "—"
            s.metrics.arrive = "—"
            s.metrics.left = f.totalM > 0 ? str.distance(f.totalM, units) : "—"
            statusLocked(f.totalM > 0 ? .gpsTrack(str.distance(f.totalM, units)) : .gpsOnly, toast: false)
            if recordHistory, let h = GpxParser.historyPlace(GpxTrack(name: name, points: track.points, waypoints: track.waypoints)) {
                places.pushHistory(h)
                placesChangedLocked()
            }
            if !track.points.isEmpty { cameraLocked(.fit([track.points.map(\.point)], paddingPx: 72)) }
            Log.i("NAV", "[GPX] dash map — mode=GPX pts=\(track.points.count) wpt=\(track.waypoints.count) len=\(str.distance(f.totalM, units))")
            if let fix = s.lastFix { processFixLocked(fix) }
            s.dirty = true
        }
    }

    /// Parses and follows a GPX file (validated like the hub import).
    public func loadGpx(data: Data, fileName: String) throws {
        let track = try GpxParser.importTrack(data, fileName: fileName)
        loadGpx(track, displayName: track.name)
    }

    /// Navigates to `place` immediately (no preview), e.g. a handlebar saved-place slot.
    public func navigate(to place: Place) {
        mutate { startNavigationLocked(to: place, cached: nil) }
    }

    /// The text title Android showed for the session ("Free ride", "→ <dest>", "<track> · <km> · ↑<ascent>").
    public var title: String {
        lock.lock(); defer { lock.unlock() }
        let str = strings
        switch s.mode {
        case .freeRide: return str.phrase(.freeRide)
        case let .navTo(p): return "→ " + p.name
        case let .gpx(name):
            var t = name
            if let f = s.follower, f.totalM > 0 { t += " · " + str.distance(f.totalM, units) }
            if let f = s.follower, f.hasElevation { t += " · " + NavFormat.formatAscent(f.totalAscentM, units: units) }
            return t
        }
    }

    // MARK: - Preview

    /// Opens the route preview for `place` (search result, idle-list row, Go Home): north-up
    /// overview, alternatives requested in the background (Fast / Fun / Alt chips).
    public func previewPlace(_ place: Place) {
        mutate { previewPlaceLocked(place) }
    }

    func previewPlaceLocked(_ place: Place) {
        cancelPreviewTaskLocked()
        s.previewToken &+= 1
        let str = strings
        if s.preview == nil { s.headingUpBeforePreview = s.headingUp }
        s.headingUp = false
        s.arrival = nil
        var p = RoutePreview(place: place, meta: place.subtitle.isNavBlank ? str.phrase(.gettingRoute) : place.subtitle)
        s.previewWaitingForFix = false
        guard let fix = s.lastFix else {
            p.meta = [place.subtitle.isNavBlank ? nil : place.subtitle, str.phrase(.waitingForGps)].compactMap { $0 }.joined(separator: " · ")
            s.preview = p
            s.previewOrigin = nil
            s.previewWaitingForFix = true
            cameraLocked(.center(place.point, zoom: 16))
            s.dirty = true
            return
        }
        p.loading = true
        s.preview = p
        s.previewOrigin = fix
        cameraLocked(.fit([[fix.point, place.point]], paddingPx: 160))
        s.dirty = true
        let token = s.previewToken
        let options = s.prefs.routeOptions
        let router = self.router
        previewTask = spawn { [weak self] in
            let result = await router.alternatives(from: fix.point, to: place.point, options: options)
            guard let self, !Task.isCancelled else { return }
            self.mutate {
                guard self.s.previewToken == token, var pv = self.s.preview, pv.place == place, !pv.pinMode else { return }
                pv.loading = false
                self.s.preview = pv
                self.s.dirty = true
                if result.routes.isEmpty { return }
                self.s.preview?.routes = result.routes
                self.selectRouteLocked(0)
                if !result.avoidHonored || result.warning != nil {
                    let warn = self.strings.routingWarning(result.warning ?? "Avoid setting not applied")
                    let meta = self.s.preview?.meta ?? ""
                    let joined = [meta.isNavBlank ? nil : meta, warn].compactMap { $0 }.joined(separator: " · ")
                    self.s.preview?.meta = joined
                    self.statusLocked(warn)
                    Log.i("NAV", "[GPX] \(warn)")
                }
            }
        }
    }

    /// Highlights route option `index` (clamped): meta "[Straight line (no road route) · ]<dist> ·
    /// <HH:mm>[ · <subtitle>]", chips "[★ ]<label> · <HH:mm> · <dist>".
    public func selectRoute(_ index: Int) {
        mutate { selectRouteLocked(index) }
    }

    func selectRouteLocked(_ index: Int) {
        guard var p = s.preview, !p.routes.isEmpty else { return }
        let str = strings
        let idx = min(max(index, 0), p.routes.count - 1)
        p.selectedIndex = idx
        let speed = s.previewOrigin?.speedMps ?? s.lastFix?.speedMps ?? 0
        let now = wallClock()
        func eta(_ r: Route) -> Int {
            let d = NavNumberFormat.truncateToInt(r.durationSec)
            return d > 0 ? d : NavFormat.etaSeconds(remainM: r.distanceM, speedMps: speed)
        }
        let route = p.routes[idx]
        var meta = route.isDirectFallback ? str.phrase(.straightLine) + " · " : ""
        meta += str.distance(route.distanceM, units) + " · " + NavFormat.formatArrival(eta(route), now: now, timeZone: timeZone)
        if !p.place.subtitle.isNavBlank { meta += " · " + p.place.subtitle }
        p.meta = meta
        p.chipLabels = p.routes.enumerated().map { i, r in
            let tag = r.label.isNavBlank ? (i == 0 ? "Fast" : "Alt") : r.label
            let label = str.routeLabel(tag) + " · " + NavFormat.formatArrival(eta(r), now: now, timeZone: timeZone)
                + " · " + str.distance(r.distanceM, units)
            return i == idx ? "★ " + label : label
        }
        s.preview = p
        s.headingUp = false
        var overview = p.routes.map { $0.points.map(\.point) }
        if let o = s.previewOrigin ?? s.lastFix { overview.append([o.point, p.place.point]) }
        cameraLocked(.fit(overview, paddingPx: 160))
        s.dirty = true
    }

    /// Go: navigate to the previewed place, reusing the selected preview route when it has ≥ 2
    /// points (no second request).
    public func go() {
        mutate {
            guard let p = s.preview else { return }
            startNavigationLocked(to: p.place, cached: p.selectedRoute)
        }
    }

    func startNavigationLocked(to place: Place, cached: Route?) {
        cancelPreviewTaskLocked()
        let str = strings
        s.preview = nil
        s.previewToken &+= 1
        s.previewWaitingForFix = false
        s.headingUpBeforePreview = nil
        places.pushHistory(place)
        placesChangedLocked()
        s.mode = .navTo(place)
        s.destination = place
        s.trackName = place.name
        s.gpxTrack = nil
        s.gpxOriented = true
        s.destArrivedSpoken = false
        s.navStartDist = nil
        s.navEngagedAt = clock.now()
        s.navGeneration &+= 1
        s.routeToken &+= 1
        s.offRouteSince = nil
        s.lastAutoReroute = nil
        s.voice.reset()
        s.headingUp = true
        s.arrival = nil
        s.progress = nil
        s.cue = seedCueLocked()
        s.metrics.time = "—"
        s.metrics.arrive = "—"
        s.metrics.left = "—"
        s.pinsRevision = nil
        // Announce first: applying the route runs the first progress, which may finish the
        // navigation right away ("Already nearby") and must have the last word.
        speakLocked(.navigatingTo(place.name))
        Log.i("NAV", "[GPX] Go → \(place.name) (cached=\(cached != nil))")
        if let cached, cached.points.count >= 2 {
            s.routeRequested = true
            statusLocked(.routeSummary(str.distance(cached.distanceM, units)))
            applyRoadRouteLocked(cached, name: place.name)
        } else {
            s.follower = nil
            s.route = nil
            if let fix = s.lastFix {
                s.routeRequested = true
                requestRouteLocked(from: fix, reason: .start)
                cameraLocked(.follow(headingUp: true))
                refreshNavigationLocked(fix: fix)
            } else {
                s.routeRequested = false
                statusLocked(.gpsNavigateTo(place.name))
                cameraLocked(.center(place.point, zoom: 16))
            }
        }
        s.dirty = true
    }

    /// Cancel (trip preview) / Done (pin setup): closes the preview; the live navigation (if any)
    /// is untouched. Outside parity mode heading-up is restored (§11.8 fix (h)).
    public func cancelPreview() {
        mutate { cancelPreviewLocked() }
    }

    func cancelPreviewLocked() {
        cancelPreviewTaskLocked()
        guard s.preview != nil else { return }
        s.preview = nil
        s.previewOrigin = nil
        s.previewWaitingForFix = false
        s.previewToken &+= 1
        if !parityMode, let restore = s.headingUpBeforePreview {
            s.headingUp = restore
            cameraLocked(.follow(headingUp: restore))
        }
        s.headingUpBeforePreview = nil
        s.dirty = true
    }

    func cancelPreviewTaskLocked() {
        previewTask?.cancel()
        previewTask = nil
    }

    /// Circuit (there & back): start → previewed place → start. Needs a fix and a previewed place
    /// ≥ 120 m away.
    public func startCircuit() {
        mutate { startCircuitLocked() }
    }

    func startCircuitLocked() {
        guard let fix = s.lastFix else { statusLocked(.needGpsForCircuit); return }
        guard let place = s.preview?.place else { statusLocked(.pickDestinationForCircuit); return }
        if GeoMath.haversineM(fix.lat, fix.lon, place.lat, place.lon) < 120 {
            statusLocked(.pickPlaceAwayForCircuit)
            return
        }
        cancelPreviewTaskLocked()
        let str = strings
        statusLocked(.buildingCircuitTo(place.name))
        if s.preview == nil { s.headingUpBeforePreview = s.headingUp }
        s.previewToken &+= 1
        s.preview = RoutePreview(place: place, meta: str.phrase(.thereAndBackReturning), loading: true, isCircuit: true)
        s.previewOrigin = fix
        s.previewWaitingForFix = false
        s.headingUp = false
        s.dirty = true
        let token = s.previewToken
        let options = s.prefs.routeOptions
        let router = self.router
        previewTask = spawn { [weak self] in
            let outcome: Result<RouteResult, Error>
            do { outcome = .success(try await router.circuit(from: fix.point, to: place.point, options: options)) } catch { outcome = .failure(error) }
            guard let self, !Task.isCancelled else { return }
            self.mutate {
                guard self.s.previewToken == token, self.s.preview?.place == place, self.s.preview?.isCircuit == true else { return }
                self.s.preview?.loading = false
                self.s.dirty = true
                switch outcome {
                case let .success(result):
                    if result.routes.isEmpty {
                        let text = self.strings.phrase(.noCircuitFound)
                        self.s.preview?.meta = text
                        return
                    }
                    self.s.preview?.routes = result.routes
                    self.selectRouteLocked(0)
                    let meta = self.s.preview?.meta ?? ""
                    let suffix = self.strings.phrase(.thereAndBackReturns)
                    let joined = [meta.isNavBlank ? nil : meta, suffix].compactMap { $0 }.joined(separator: " · ")
                    self.s.preview?.meta = joined
                case let .failure(error):
                    let msg = self.strings.routingWarning(NavServiceError.message(for: error, fallback: RouteOrchestrator.errorCircuitFailed))
                    self.s.preview?.meta = msg
                    self.statusLocked(msg)
                }
            }
        }
        speakLocked(.buildingCircuit)
    }

    // MARK: - Pin mode

    /// Long-press on the map: "Dropped pin" setup sheet (Save / Home / Marker / Done, no Go).
    public func dropPin(at point: GeoPoint) {
        mutate {
            cancelPreviewTaskLocked()
            let str = strings
            let coords = NavNumberFormat.fixed(point.lat, decimals: 5) + ", " + NavNumberFormat.fixed(point.lon, decimals: 5)
            let place = Place(name: str.droppedPinName, lat: point.lat, lon: point.lon, category: "pin", subtitle: coords)
            speakLocked(.pinDropped)
            if s.preview == nil { s.headingUpBeforePreview = s.headingUp }
            s.previewToken &+= 1
            s.preview = RoutePreview(place: place, meta: place.subtitle.isNavBlank ? coords : place.subtitle, pinMode: true)
            s.previewWaitingForFix = false
            s.arrival = nil
            cameraLocked(.center(place.point, zoom: 16))
            statusLocked(.savePinHint)
        }
    }

    /// ★ Save: adds the previewed place to favorites (closes the pin sheet).
    public func saveFavoriteFromPreview() {
        mutate {
            guard let p = s.preview else { return }
            places.addFavorite(p.place)
            placesChangedLocked()
            statusLocked(.savedToFavorites(p.place.name))
            speakLocked(.saved)
            if p.pinMode { cancelPreviewLocked() }
        }
    }

    /// Home: stores the previewed place as Home ("Dropped pin" is renamed "Home").
    public func setHomeFromPreview() {
        mutate {
            guard let p = s.preview else { return }
            let str = strings
            var h = p.place
            if h.name == "Dropped pin" || h.name == str.droppedPinName { h.name = str.homeName }
            places.setHome(h, defaultName: str.homeName, subtitle: str.homeName)
            placesChangedLocked()
            statusLocked(.homeSet)
            speakLocked(.homeSet)
            if p.pinMode { cancelPreviewLocked() }
        }
    }

    /// ＋ Marker: adds the previewed place as a map marker.
    public func addMarkerFromPreview() {
        mutate {
            guard let p = s.preview else { return }
            places.addMarker(p.place)
            placesChangedLocked()
            statusLocked(.markerAdded)
            speakLocked(.markerAdded)
            if p.pinMode { cancelPreviewLocked() }
        }
    }

    // MARK: - Arrive card

    /// Park here: parked pin at the fix ("Marked on arrival"), closes the card.
    public func arrivalParkHere() {
        mutate {
            guard let fix = s.lastFix else { statusLocked(.noGpsForParking); return }
            let str = strings
            places.setParked(Place(name: str.parkedName, lat: fix.lat, lon: fix.lon, category: "parking",
                                   subtitle: str.markedOnArrivalSubtitle),
                             defaultName: str.parkedName, historySubtitle: str.parkedHereSubtitle)
            placesChangedLocked()
            s.arrival = nil
            statusLocked(.parkingMarked)
            speakLocked(.parkingMarked)
        }
    }

    /// Done: hides the arrive card ("Free ride"). For "Find parking" pass `announce: false` and run
    /// the Parking POI chip (`searchNearby(PlaceSearch.poiChips[3])`).
    public func dismissArrival(announce: Bool = true) {
        mutate {
            s.arrival = nil
            if announce { statusLocked(.freeRide) } else { s.dirty = true }
        }
    }

    /// Recenter FAB: resumes following the rider ("Centered on GPS"), or "No GPS yet — wait for a
    /// fix". The camera itself is the dash's (`NavCameraHint.follow`).
    public func recenter() {
        mutate {
            guard s.lastFix != nil else { statusLocked(.noGpsYet); return }
            cameraLocked(.follow(headingUp: s.headingUp))
            statusLocked(.centeredOnGps)
        }
    }

    // MARK: - Menu

    /// End (metrics card / menu): cancels a preview, else finishes navigation without arrival.
    public func endNavigation() {
        mutate {
            if s.preview != nil { cancelPreviewLocked(); return }
            if case .freeRide = s.mode { statusLocked(.alreadyFreeRide); return }
            // Manual stop ≠ arrival — never the Arrived card.
            finishToFreeRideLocked(spoken: .navigationFinished, offerParking: false)
        }
    }

    /// Park here (menu): sets / replaces the parked spot at the fix ("Marked on dash"). P0 (D22): it only
    /// sets — Android's toggle cleared a parked pin less than 40 m away, so a second ★ meant to confirm erased
    /// the spot. Clearing it is a deliberate action elsewhere (the search list's Delete, the phone).
    public func parkHere() {
        mutate {
            guard let fix = s.lastFix else { statusLocked(.noGpsForParking); return }
            let str = strings
            let existing = places.parked()
            places.setParked(Place(name: str.parkedName, lat: fix.lat, lon: fix.lon, category: "parking",
                                   subtitle: str.markedOnDashSubtitle),
                             defaultName: str.parkedName, historySubtitle: str.parkedHereSubtitle)
            placesChangedLocked()
            statusLocked(existing != nil ? .parkingUpdated : .parkingMarked)
            speakLocked(existing != nil ? .parkingUpdated : .parkingMarked)
        }
    }

    /// Go Home: previews Home, or tells the rider how to set one.
    public func goHome() {
        mutate {
            guard let home = places.home() else { statusLocked(.noHomeSet); return }
            previewPlaceLocked(home)
        }
    }

    /// Set Home here: Home = current fix ("Set on dash").
    public func setHomeHere() {
        mutate {
            guard let fix = s.lastFix else { statusLocked(.noGpsToSetHome); return }
            let str = strings
            places.setHome(Place(name: str.homeName, lat: fix.lat, lon: fix.lon, category: "home", subtitle: str.setOnDashSubtitle),
                           defaultName: str.homeName, subtitle: str.homeName)
            placesChangedLocked()
            statusLocked(.homeSetHere)
            speakLocked(.homeSet)
        }
    }

    /// Recenter / Recalc: NAV_TO → reroute from the fix; GPX / route → snap back on the track;
    /// free ride → recentre.
    public func recalc() {
        mutate {
            cameraLocked(.follow(headingUp: s.headingUp))
            guard let fix = s.lastFix else { statusLocked(.noGps); return }
            if isNavTo, s.destination != nil {
                requestRouteLocked(from: fix, reason: .recalc)
            } else if s.follower != nil {
                let p = s.follower!.progress(lat: fix.lat, lon: fix.lon, speedMps: fix.speedMps ?? 0,
                                             gpsAltitudeM: fix.altitudeM, units: units)
                if let p, let first = s.follower!.pointsRemain(p.nearestIndex).first {
                    cameraLocked(.center(first.point, zoom: 15))
                    statusLocked(.snapBackOnTrack)
                    speakLocked(.backOnTrack)
                }
            } else {
                statusLocked(.recentered)
                speakLocked(.centered)
            }
        }
    }

    /// Voice on / muted (persisted by the app through `updatePreferences`).
    public func setVoiceEnabled(_ on: Bool) {
        mutate {
            s.prefs.voiceOn = on
            s.dirty = true
        }
    }

    // MARK: - Lap timer

    /// Lap / Stop pill: arms the flying-lap gate at the fix, or switches the timer off.
    public func toggleLapTimer() {
        mutate {
            if s.lapTimer.isOn {
                s.lapTimer.stop()
                s.pinsRevision = nil
                statusLocked(.lapTimerOff)
                return
            }
            guard let fix = s.lastFix else { statusLocked(.needGpsForLap); return }
            s.lapTimer.arm(lat: fix.lat, lon: fix.lon)
            s.pinsRevision = nil
            statusLocked(.lapArmedHint)
            speakLocked(.lapTimerArmed)
            Log.i("NAV", "[LAP] armed at \(fix.lat),\(fix.lon)")
        }
    }

    /// Lap card lines ("LAP 2  1:02.03", "LAST 1:01.50   BEST 1:01.50"); nil when off. Repaint
    /// every ~100 ms while armed.
    public func lapCard() -> (current: String, meta: String)? {
        lock.lock(); defer { lock.unlock() }
        return s.lapTimer.cardLines(nowMs: wallMs, strings: strings)
    }

    public var isLapTimerOn: Bool {
        lock.lock(); defer { lock.unlock() }
        return s.lapTimer.isOn
    }

    // MARK: - Search helpers

    /// Text search near the last fix (Photon / Nominatim).
    public func searchPlaces(_ query: String) async throws -> [Place] {
        let near = currentFix?.point
        return try await search.search(query, near: near)
    }

    /// POI chip near the last fix; throws "Need GPS for nearby POI" without a fix.
    public func searchNearby(_ chip: PlaceSearch.PoiChip) async throws -> [Place] {
        let (fix, units, sep, str) = withState { ($0.lastFix, $0.prefs.units, $0.decimalSeparator, self.strings) }
        guard let fix else { throw NavServiceError.service(str.phrase(.needGpsForPoi)) }
        return try await search.nearby(chip, near: fix.point, units: units, decimalSeparator: sep)
    }

    /// Search-sheet idle list (home, parked, favorites, markers, history; 12 max).
    public func idleSuggestions() -> [Place] { places.idleSuggestions() }

    /// Handlebar nav1…nav3 (`number` 1…3): geocodes the saved query (or parses "lat,lon") and
    /// starts navigation in-app. While a route runs the place opens as a preview instead: its Go asks
    /// before replacing the running route, as every other way to a new route does (P0, D01; review
    /// DASH-SAFE-5 — a mapped gesture used to replace it at once).
    public func navigateToSavedPlace(_ number: Int) async {
        guard let slots = savedSlots, (1 ... SavedPlaceSlots.count).contains(number), slots.isSet(number - 1) else {
            mutate { statusLocked(.savedPlaceNotSet(number)) }
            return
        }
        let slot = number - 1
        let query = slots.query(slot)
        let name = slots.name(slot)
        if let p = SavedPlaceSlots.parseCoordinate(query) {
            startSavedPlace(Place(name: name.isNavBlank ? query : name, lat: p.lat, lon: p.lon, category: "saved", subtitle: query))
            return
        }
        do {
            let results = try await searchPlaces(query)
            guard var first = results.first else {
                mutate { statusLocked(.noResults) }
                return
            }
            if !name.isNavBlank { first.name = name }
            startSavedPlace(first)
        } catch {
            let msg = NavServiceError.message(for: error, fallback: "Search failed")
            mutate { statusLocked(msg) }
        }
    }

    /// A saved place: guidance at once in free ride, a preview over a running route.
    private func startSavedPlace(_ place: Place) {
        mutate {
            if s.mode.isNavigating { previewPlaceLocked(place) } else { startNavigationLocked(to: place, cached: nil) }
        }
    }

    // MARK: - State access

    /// The last GPS fix fed to the session.
    public var currentFix: LocationFix? {
        lock.lock(); defer { lock.unlock() }
        return s.lastFix
    }

    /// The active follower's last progress (nil in free ride / without a fix).
    public var currentProgress: RouteProgress? {
        lock.lock(); defer { lock.unlock() }
        return s.progress
    }

    func withState<T>(_ body: (State) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(s)
    }
}
