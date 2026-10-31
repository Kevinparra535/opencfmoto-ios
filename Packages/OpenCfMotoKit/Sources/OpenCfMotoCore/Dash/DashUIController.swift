// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) GpxDashUi.kt (UI state machine, camera policy, focus engine,
// tap handlers) — docs/spec/navigation-dash.md §4.9, §11; input-controls.md §6.
//
// The dash UI controller: the app feeds a `DashModel` (navigation snapshot, fix, prefs, places…)
// and `DashInput`s (dash touches, handlebar keys/knob); the controller owns the UI state (sheets,
// focus, camera, toasts, scroll offsets), produces a `DashDisplayList` per frame for the renderer
// and reports `DashIntent`s for the app to perform.
//
// Thread-safety: final class guarded by an NSLock (`@unchecked Sendable`); every public method
// may be called from any thread (the render loop calls `displayList(now:)` on its own queue).
// `now` values must come from one monotonic clock (the same as `DashTouch.time`).
//
// Integration recipe (app layer):
//   let ui = DashUIController(measurer: CoreTextMeasurer())        // same measurer as the renderer
//   render loop (≥ 1 Hz, typically at the frame cap):
//       ui.update(model)                                           // NavSnapshot, fix, prefs, places…
//       perform(ui.tick(now: clock.now()))                         // long-press / auto-recenter / toasts
//       renderer.draw(ui.displayList(now: clock.now()))
//   dash touch (after GhostTouchFilter):  perform(ui.handle(.touch(t), now: t.time))
//   handlebar ButtonAction:               DashInput(buttonAction: a).map { perform(ui.handle($0, now:)) }
//   NavEffect.toast(text):                ui.showToast(text, now:)
//   going to background:                  encode ui.displayList(forHoldScreen: nil, now:) as an IDR
// where `perform` executes the returned `DashIntent`s (UI-only ones are already applied).

import Foundation

/// Read-only snapshot of the UI state (for the app / phone preview / tests).
public struct DashUIState: Sendable, Equatable {
    public var sheet: DashSheet
    public var camera: DashCamera
    public var focusedId: String?
    /// Current handlebar focus order (top-most interactive layer).
    public var focusOrder: [String]
    /// Toast currently shown (transient or the model's persistent text).
    public var toast: String?
    /// Bearing the puck is drawn with (degrees).
    public var puckBearingDeg: Double
    public var menuScroll: Double
    public var searchListScroll: Double
}

public final class DashUIController: @unchecked Sendable {
    /// Behaviour switches. Defaults = the iOS fixes recommended by the spec; set the flags to
    /// false for Android parity.
    public struct Options: Sendable, Equatable {
        /// Fix (h): restore follow / heading-up / speed-zoom when a preview is cancelled.
        public var restoreCameraAfterPreview = true
        /// Fix (f): a map pan / pinch / double-tap is a free pan (follow off, recenter after 12 s).
        public var panStopsFollow = true
        /// §4.9 / R9: cap the look-ahead so the puck stays above the bottom cards.
        public var clampLookAheadToVisibleMap = true
        /// Fix (i): the "Lap" pill label is part of the handlebar focus order.
        public var lapReachableByHandlebar = true
        /// The menu's settings segments are part of the handlebar focus order (Android: unreachable).
        public var handlebarReachesSettings = true
        /// After a touch, hide the focus ring for this long (until the next handlebar input); nil = always shown.
        public var hideFocusRingAfterTouch: TimeInterval? = 5
        /// Lifetime of transient toasts (`showToast`, UI feedback).
        public var toastDuration: TimeInterval = 2.5
        /// Feedback toasts for UI-only actions ("Centered on GPS", "Heading up"…) — iOS addition,
        /// Android's status line is hidden on landscape dashes.
        public var feedbackToasts = true
        public init() {}
    }

    public let options: Options
    private let measurer: any DashTextMeasurer
    private let lock = NSLock()

    private var model = DashModel()
    private var hasModel = false
    private var sheet: DashSheet = .none
    private var camera = DashCamera()
    private var focus = DashFocusEngine()
    private var pendingPreference: DashFocusPreference? = .default
    private var gestures = DashGestureRecognizer()
    private var puckBearing: Double = 0
    private var menuScroll = 0.0
    private var searchListScroll = 0.0
    private var searchChipScroll = 0.0
    private var previewChipScroll = 0.0
    private var toast: (text: String, until: TimeInterval)?
    private var lastTouchAt: TimeInterval?
    private var lastKeyAt: TimeInterval?
    private var savedCamera: (follow: Bool, headingUp: Bool, speedZoom: Bool)?
    private var scene: DashScene?
    /// Scroll the focused control into view at the next scene build (set by focus moves).
    private var revealFocus = false

    public init(measurer: any DashTextMeasurer = ApproximateTextMeasurer(), options: Options = Options()) {
        self.measurer = measurer
        self.options = options
    }

    // MARK: - Public API

    /// Feeds the latest model (call on every change or every frame). Detects preview /
    /// navigation / arrival transitions (camera + focus policies) and applies the follow camera.
    public func update(_ newModel: DashModel) {
        lock.lock(); defer { lock.unlock() }
        let prev = hasModel ? model : DashModel(canvas: newModel.canvas)
        model = newModel
        hasModel = true
        gestures.config = .scaled(newModel.scale)
        transitions(from: prev, to: newModel)
        if camera.follow && !newModel.inPreview {
            applyFollowCamera()
        } else {
            puckBearing = currentBearing()
        }
        if !camera.isPositioned { positionIfNeeded() }
        scene = nil
    }

    /// Handles one input. Returns the intents to perform (UI-only ones are already applied).
    public func handle(_ input: DashInput, now: TimeInterval) -> [DashIntent] {
        lock.lock(); defer { lock.unlock() }
        advance(now)
        switch input {
        case let .touch(t):
            if model.holdMessage != nil { return [] }
            lastTouchAt = now
            let sc = ensureScene()
            let p = DashPoint(min(max(0, Double(t.x)), max(0, model.canvas.width - 1)),
                              min(max(0, Double(t.y)), max(0, model.canvas.height - 1)))
            let events = gestures.process(t, point: p, now: now, hitTest: { self.hitTarget($0, sc) })
            return apply(events, now: now)
        case let .key(k):
            lastKeyAt = now
            return handleKey(k, now: now)
        case let .knob(d):
            lastKeyAt = now
            moveFocus(d)
            return []
        case let .savedPlace(slot):
            return [.navigateSavedPlace(slot)]
        }
    }

    /// Timers: long-press (450 ms), free-pan auto-recenter (12 s), toast expiry. Call ~10×/s
    /// (e.g. from the render loop); returns intents fired by timers (a long-press `dropPin`).
    public func tick(now: TimeInterval) -> [DashIntent] {
        lock.lock(); defer { lock.unlock() }
        advance(now)
        let events = gestures.tick(now: now)
        return events.isEmpty ? [] : apply(events, now: now)
    }

    /// Performs an intent as if its control had been activated (e.g. from the phone UI): applies
    /// the UI-side effects and returns `[intent]`.
    public func perform(_ intent: DashIntent, now: TimeInterval) -> [DashIntent] {
        lock.lock(); defer { lock.unlock() }
        advance(now)
        return activate(intent, now: now)
    }

    /// Shows a transient toast (e.g. `NavEffect.toast`) for `duration` (default options.toastDuration).
    public func showToast(_ text: String, now: TimeInterval, duration: TimeInterval? = nil) {
        lock.lock(); defer { lock.unlock() }
        toast = (text, now + (duration ?? options.toastDuration))
        scene = nil
    }

    /// The frame to render now. When the model has a `holdMessage`, the hold picture.
    public func displayList(now: TimeInterval) -> DashDisplayList {
        lock.lock(); defer { lock.unlock() }
        advance(now)
        if let msg = model.holdMessage { return holdList(message: msg) }
        let sc = ensureScene()
        var cmds = sc.commands
        cmds += overlays(sc, now: now)
        let regions = sc.widgets.filter { !$0.rect.isEmpty }.map {
            DashHitRegion(id: $0.id, rect: $0.rect, focusable: sc.focusOrder.contains($0.id))
        }
        return DashDisplayList(size: model.canvas, background: model.chromeColor, commands: cmds, hitRegions: regions)
    }

    /// The "hold" picture: the current scene dimmed with a centred message card (no hit regions).
    /// Encode it as an IDR before the app is backgrounded so the media plane can keep answering
    /// pulls with it. `message` nil → the model's `holdMessage` or a default text.
    public func displayList(forHoldScreen message: String?, now: TimeInterval) -> DashDisplayList {
        lock.lock(); defer { lock.unlock() }
        advance(now)
        return holdList(message: message ?? model.holdMessage ?? DashText.holdDefault.localized(model.language))
    }

    /// Current UI state snapshot.
    public var state: DashUIState {
        lock.lock(); defer { lock.unlock() }
        let sc = ensureScene()
        return DashUIState(sheet: sheet, camera: camera, focusedId: focus.focusedId, focusOrder: sc.focusOrder,
                           toast: toast?.text ?? model.toastText, puckBearingDeg: puckBearing, menuScroll: menuScroll,
                           searchListScroll: searchListScroll)
    }

    /// The map projection of the current camera (nil until positioned).
    public func mapProjection() -> MapProjection? {
        lock.lock(); defer { lock.unlock() }
        return projection()
    }

    /// Raster tiles the current frame draws (for tile prefetch / cache warm-up).
    public func visibleTiles() -> [DashMapTile] {
        lock.lock(); defer { lock.unlock() }
        return projection()?.visibleTiles(maxTileZoom: model.maxTileZoom) ?? []
    }

    // MARK: - Geometry helpers

    private var layoutContext: DashLayoutContext { DashLayoutContext(model: model, measurer: measurer) }

    /// Map anchor: the centre of the safe area.
    private var anchor: DashPoint { let s = model.safeRect; return DashPoint(s.midX, s.midY) }

    private func projection() -> MapProjection? {
        camera.projection(viewport: model.canvas, anchor: anchor, tileSize: model.tileSize)
    }

    // MARK: - Camera policy (navigation-dash.md §4.9)

    /// Bearing for the map / puck: GPS course while moving → compass in heading-up → track
    /// bearing → bearing to the destination → the nav engine's puck bearing.
    private func currentBearing() -> Double {
        if let f = model.fix, f.isMoving, let c = f.courseDeg { return c }
        if camera.headingUp, let h = model.compassHeadingDeg { return h }
        if let p = model.nav.progress { return p.trackBearingDeg }
        if let d = model.nav.destination, let me = model.riderPosition { return DashGeo.bearingDeg(from: me, to: d.point) }
        return model.nav.puckBearingDeg
    }

    /// `bestBearing()`: GPS course while moving, else compass, else the last map bearing.
    private func bestBearing() -> Double {
        if let f = model.fix, f.isMoving, let c = f.courseDeg { return c }
        if let h = model.compassHeadingDeg { return h }
        return camera.lastMapBearing
    }

    private func lookAheadCap() -> Double? {
        guard options.clampLookAheadToVisibleMap else { return nil }
        let c = layoutContext
        var bottom = c.safe.maxY
        if model.navigating {
            bottom = DashSceneBuilder.metricsLayout(model, c).frame.minY
        }
        return max(0, bottom - c.dp(24 + 8) - anchor.y)
    }

    private func applyFollowCamera() {
        guard let me = model.riderPosition else { return }
        let fix = model.fix
        let moving = fix?.isMoving ?? false
        let brng = currentBearing()
        puckBearing = brng
        let speedKmh = (fix?.speedMps ?? 0) * 3.6
        let z = camera.targetFollowZoom(speedKmh: speedKmh)
        camera.applyFollow(me: me, bearingDeg: brng, targetZoom: z, moving: moving, maxLookAheadPx: lookAheadCap(),
                           tileSize: model.tileSize)
        camera.lastMapBearing = camera.headingUp ? brng : 0
    }

    /// First positioning when the follow camera did not run: on the rider (e.g. zoomed before
    /// the first fix), else the route / destination (GpxDashUi bind).
    private func positionIfNeeded() {
        if let me = model.riderPosition {
            camera.center = me
            return
        }
        if let route = model.nav.route, route.points.count >= 2 {
            fit(Self.sample(route.points), rect: mapFreeRect(previewTop: nil))
        } else if let d = model.nav.destination {
            camera.setCenter(d.point, zoom: 15.5)
        }
    }

    private static func sample(_ pts: [TrackPoint], max: Int = 500) -> [GeoPoint] {
        guard !pts.isEmpty else { return [] }
        let step = Swift.max(1, pts.count / max)
        var out: [GeoPoint] = []
        for (i, p) in pts.enumerated() where i % step == 0 || i == pts.count - 1 { out.append(p.point) }
        return out
    }

    /// Free map area for overviews: below the top chrome (`topY`, default: under the search
    /// pill), above `previewTop` (a bottom card), left of the FABs.
    private func mapFreeRect(previewTop: Double?, topY: Double? = nil) -> DashRect {
        let c = layoutContext
        let fabs = DashLayout.fabColumn(c)
        let top = topY ?? c.safe.minY + c.dp(DashDimens.pillMarginTop + DashDimens.pillHeight + 8)
        var bottom = (previewTop ?? c.safe.maxY) - c.dp(8)
        if bottom - top < c.dp(64) { bottom = min(c.safe.maxY - c.dp(8), top + c.dp(64)) }
        let left = c.safe.minX + c.dp(8)
        let right = (fabs.first?.minX ?? c.safe.maxX) - c.dp(8)
        return DashRect(x: left, y: top, width: max(c.dp(64), right - left), height: max(c.dp(48), bottom - top))
    }

    /// Room for the markers drawn around fitted points: the destination pin rises 44 dp above
    /// its point, the puck is 48 dp wide.
    private func markerInset(_ r: DashRect) -> DashRect {
        let c = layoutContext
        let side = c.dp(24), top = c.dp(44), bottom = c.dp(24), minSide = c.dp(32)
        let w = max(minSide, r.width - 2 * side)
        let x = r.midX - w / 2
        if r.height - top - bottom >= minSide {
            return DashRect(x: x, y: r.minY + top, width: w, height: r.height - top - bottom)
        }
        return DashRect(x: x, y: r.midY - minSide / 2, width: w, height: minSide)
    }

    private func fit(_ points: [GeoPoint], rect: DashRect) {
        camera.fit(points, in: markerInset(rect), viewport: model.canvas, anchor: anchor, tileSize: model.tileSize)
    }

    private func fitPreview(_ p: RoutePreview) {
        if p.pinMode {
            camera.setCenter(p.place.point, zoom: 16)
            return
        }
        let me = model.riderPosition
        if p.routes.isEmpty && me == nil {
            camera.setCenter(p.place.point, zoom: 16)
            return
        }
        var pts: [GeoPoint] = []
        for r in p.routes { pts += Self.sample(r.points) }
        if let me { pts.append(me) }
        pts.append(p.place.point)
        let c = layoutContext
        let card = DashLayout.previewCard(c, preview: p, language: model.language)
        // Candidate free areas: above the card (full width) and, in landscape, right of the card
        // (down to the speed chip). Keep the one giving the closest overview.
        var candidates = [mapFreeRect(previewTop: card.frame.minY)]
        if c.isLandscape {
            let top = candidates[0].minY
            let fabX = DashLayout.fabColumn(c).first?.minX ?? c.safe.maxX
            let chip = DashLayout.speedChip(c, hasLimit: DashSceneBuilder.speedLimitLabel(model) != nil, navigating: false)
            let right = DashRect(x: card.frame.maxX + c.dp(8), y: top, width: fabX - c.dp(8) - card.frame.maxX - c.dp(8),
                                 height: chip.frame.minY - c.dp(8) - top)
            if right.width > c.dp(120), right.height > c.dp(120) { candidates.append(right) }
        }
        var best = candidates[0]
        var bestZoom = -Double.infinity
        for r in candidates {
            if let proj = MapProjection.fitting(pts, in: markerInset(r), viewport: model.canvas, anchor: anchor,
                                                tileSize: model.tileSize, minZoom: DashCamera.minZoom, maxZoom: DashCamera.maxZoom),
               proj.zoom > bestZoom + 1e-9 {
                bestZoom = proj.zoom
                best = r
            }
        }
        fit(pts, rect: best)
    }

    // MARK: - Transitions (navigation-dash.md §11.6, §11.8)

    /// Identity of the running navigation: GPX track name or NAV_TO destination location
    /// (names / subtitles may be refreshed by the nav engine without a new navigation).
    static func navIdentity(_ m: DashModel) -> String? {
        switch m.nav.mode {
        case .freeRide: return nil
        case let .gpx(name): return "gpx:\(name)"
        case let .navTo(p): return "nav:" + String(format: "%.5f,%.5f", p.lat, p.lon)
        }
    }

    private func transitions(from prev: DashModel, to new: DashModel) {
        let navStarted = new.navigating && Self.navIdentity(prev) != Self.navIdentity(new)
        if let p = new.nav.preview {
            if let old = prev.nav.preview, old.place == p.place, old.pinMode == p.pinMode {
                if Self.routesChanged(old, p) {
                    fitPreview(p)
                    pendingPreference = .go
                }
            } else {
                previewStarted(p, fresh: prev.nav.preview == nil)
            }
        } else if prev.nav.preview != nil && !navStarted {
            if options.restoreCameraAfterPreview, let s = savedCamera {
                camera.follow = s.follow
                camera.headingUp = s.headingUp
                camera.speedZoom = s.speedZoom
            }
            savedCamera = nil
            pendingPreference = DashFocusEngine.defaultPreference(inPreview: false, navigating: new.navigating)
        }
        if navStarted {
            savedCamera = nil
            camera.follow = true
            camera.speedZoom = true
            camera.headingUp = true
            camera.cancelAutoRecenter()
            sheet = .none
            if new.riderPosition == nil {
                if let route = new.nav.route, route.points.count >= 2 {
                    fit(Self.sample(route.points), rect: mapFreeRect(previewTop: nil))
                } else if let d = new.nav.destination {
                    camera.setCenter(d.point, zoom: 16)
                }
            }
            pendingPreference = .end
        } else if prev.navigating && !new.nav.mode.isNavigating && new.nav.preview == nil {
            pendingPreference = .default
        }
        if new.showsArrival && !prev.showsArrival {
            focus.clear()
            pendingPreference = .default
        }
        if prev.search.results != new.search.results { searchListScroll = 0 }
    }

    private static func routesChanged(_ a: RoutePreview, _ b: RoutePreview) -> Bool {
        if a.routes.count != b.routes.count || a.selectedIndex != b.selectedIndex { return true }
        for (x, y) in zip(a.routes, b.routes) where x.points.count != y.points.count || x.distanceM != y.distanceM {
            return true
        }
        return false
    }

    private func previewStarted(_ p: RoutePreview, fresh: Bool) {
        if fresh { savedCamera = (camera.follow, camera.headingUp, camera.speedZoom) }
        sheet = .none
        camera.follow = false
        camera.speedZoom = false
        camera.cancelAutoRecenter()
        if !p.pinMode {
            camera.headingUp = false // overview is always north-up
            camera.resetNorth()
        }
        previewChipScroll = 0
        fitPreview(p)
        pendingPreference = .go
    }

    // MARK: - Timers

    private func advance(_ now: TimeInterval) {
        if camera.advance(now: now) {
            if !model.inPreview { applyFollowCamera() }
            scene = nil
        }
        if let t = toast, now >= t.until {
            toast = nil
            scene = nil
        }
    }

    // MARK: - Scene

    private func buildScene() -> DashScene {
        let input = DashSceneInput(model: model, sheet: sheet, camera: camera, puckBearingDeg: puckBearing, anchor: anchor,
                                   menuScroll: menuScroll, searchListScroll: searchListScroll,
                                   searchChipScroll: searchChipScroll, previewChipScroll: previewChipScroll,
                                   lapReachableByHandlebar: options.lapReachableByHandlebar,
                                   handlebarReachesSettings: options.handlebarReachesSettings)
        var b = DashSceneBuilder(input: input, measurer: measurer)
        return b.build()
    }

    private func ensureScene() -> DashScene {
        if let s = scene { return s }
        var s = buildScene()
        let defaultPref = DashFocusEngine.defaultPreference(inPreview: model.inPreview, navigating: model.navigating)
        let before = focus.focusedId
        if let pref = pendingPreference {
            focus.ensure(s.focusOrder, prefer: pref)
            pendingPreference = nil
        } else if focus.focusedId.map({ !s.focusOrder.contains($0) }) ?? true {
            focus.ensure(s.focusOrder, prefer: defaultPref)
        }
        // Scroll the focused control into view only when the focus moved (never fight a drag).
        if focus.focusedId != before || revealFocus {
            revealFocus = false
            if scrollFocusedIntoView(s) { s = buildScene() }
        }
        clampScrolls(s)
        scene = s
        return s
    }

    private func clampScrolls(_ s: DashScene) {
        func clamp(_ v: inout Double, _ id: String) {
            if let c = s.containers[id] { v = min(max(0, v), c.maxOffset) }
        }
        clamp(&menuScroll, "menu")
        clamp(&searchListScroll, "search.list")
        clamp(&searchChipScroll, "search.chips")
        clamp(&previewChipScroll, "preview.chips")
    }

    private func scrollOffset(_ id: String) -> Double {
        switch id {
        case "menu": return menuScroll
        case "search.list": return searchListScroll
        case "search.chips": return searchChipScroll
        case "preview.chips": return previewChipScroll
        default: return 0
        }
    }

    private func setScrollOffset(_ id: String, _ v: Double) {
        switch id {
        case "menu": menuScroll = v
        case "search.list": searchListScroll = v
        case "search.chips": searchChipScroll = v
        case "preview.chips": previewChipScroll = v
        default: break
        }
    }

    /// Keeps the focused control inside its scroll container (`requestRectangleOnScreen`).
    private func scrollFocusedIntoView(_ s: DashScene) -> Bool {
        guard let id = focus.focusedId, let w = s.widget(id), let cid = w.container, let cont = s.containers[cid] else { return false }
        let margin = layoutContext.dp(8)
        let old = scrollOffset(cid)
        var off = old
        switch cont.axis {
        case .vertical:
            if w.fullRect.minY < cont.viewport.minY {
                off -= cont.viewport.minY - w.fullRect.minY + margin
            } else if w.fullRect.maxY > cont.viewport.maxY {
                off += w.fullRect.maxY - cont.viewport.maxY + margin
            }
        case .horizontal:
            if w.fullRect.minX < cont.viewport.minX {
                off -= cont.viewport.minX - w.fullRect.minX + margin
            } else if w.fullRect.maxX > cont.viewport.maxX {
                off += w.fullRect.maxX - cont.viewport.maxX + margin
            }
        }
        off = min(max(0, off), cont.maxOffset)
        guard abs(off - old) > 0.01 else { return false }
        setScrollOffset(cid, off)
        return true
    }

    // MARK: - Input

    private func hitTarget(_ p: DashPoint, _ s: DashScene) -> DashTouchTarget {
        guard model.safeRect.contains(p) else { return .ignored }
        guard let w = s.widgets.last(where: { !$0.rect.isEmpty && $0.rect.contains(p) }) else { return .map }
        switch w.kind {
        case .control:
            if let cid = w.container { return .controlInScroll(id: w.id, rect: w.rect, container: cid) }
            return .control(id: w.id, rect: w.rect)
        case .scrollArea:
            return .scrollArea(container: w.container ?? w.id)
        case .blocker:
            return .blocker
        }
    }

    private func apply(_ events: [DashGestureEvent], now: TimeInterval) -> [DashIntent] {
        var out: [DashIntent] = []
        for e in events {
            switch e {
            case let .tap(id):
                guard let w = (scene ?? ensureScene()).widget(id), case let .control(intent) = w.kind, let intent else { continue }
                if let order = scene?.focusOrder { focus.focus(id, in: order) }
                out += activate(intent, now: now)
            case .mapTap:
                break
            case let .longPress(p):
                if let proj = projection() { out += activate(.dropPin(proj.geoPoint(atScreen: p)), now: now) }
            case let .doubleTap(p):
                guard camera.isPositioned else { continue }
                if options.panStopsFollow { camera.bumpFreePan(now: now) }
                camera.speedZoom = false
                camera.setZoom(camera.zoom + 1, keeping: p, viewport: model.canvas, anchor: anchor, tileSize: model.tileSize)
                scene = nil
            case .panBegan:
                if options.panStopsFollow, camera.isPositioned { camera.bumpFreePan(now: now) }
            case let .pan(d):
                guard camera.isPositioned else { continue }
                if options.panStopsFollow { camera.bumpFreePan(now: now) }
                camera.pan(byScreenDelta: d, viewport: model.canvas, anchor: anchor, tileSize: model.tileSize)
                scene = nil
            case .panEnded:
                break
            case let .pinch(scale, focal, translation):
                guard camera.isPositioned, scale > 0 else { continue }
                if options.panStopsFollow { camera.bumpFreePan(now: now) }
                camera.speedZoom = false
                camera.setZoom(camera.zoom + log2(scale), keeping: focal, viewport: model.canvas, anchor: anchor, tileSize: model.tileSize)
                camera.pan(byScreenDelta: translation, viewport: model.canvas, anchor: anchor, tileSize: model.tileSize)
                scene = nil
            case let .scroll(container, delta):
                guard let cont = (scene ?? ensureScene()).containers[container] else { continue }
                let d = cont.axis == .vertical ? delta.y : delta.x
                setScrollOffset(container, min(max(0, scrollOffset(container) - d), cont.maxOffset))
                scene = nil
            }
        }
        return out
    }

    private func handleKey(_ k: HandlebarKey, now: TimeInterval) -> [DashIntent] {
        switch k {
        case .enter:
            let sc = ensureScene()
            focus.ensure(sc.focusOrder, prefer: .default)
            guard let id = focus.focusedId, let w = sc.widget(id), case let .control(intent) = w.kind, let intent else {
                Log.d("GPX", "[GPX] Select — nothing focused")
                return []
            }
            return activate(intent, now: now)
        case .back:
            var out: [DashIntent] = []
            if sheet != .none {
                out = activate(.closeSheets, now: now)
            } else if model.showsArrival {
                out = [.dismissArrival]
            } else if model.inPreview {
                out = [.cancelPreview]
            } else {
                Log.d("GPX", "[GPX] Back — idle")
            }
            pendingPreference = DashFocusEngine.defaultPreference(inPreview: model.inPreview, navigating: model.navigating)
            scene = nil
            return out
        case .home:
            return activate(sheet == .menu ? .closeSheets : .openMenu, now: now)
        case .assistant:
            return activate(sheet == .search ? .closeSheets : .openSearch, now: now)
        case .left, .up:
            moveFocus(-1)
            return []
        case .right, .down:
            moveFocus(1)
            return []
        }
    }

    private func moveFocus(_ delta: Int) {
        let sc = ensureScene()
        focus.move(sc.focusOrder, by: delta)
        revealFocus = true
        scene = nil
    }

    // MARK: - Intents

    private func feedback(_ t: DashText, now: TimeInterval) {
        guard options.feedbackToasts else { return }
        toast = (t.localized(model.language), now + options.toastDuration)
    }

    /// Applies the UI-side effect of an intent and returns it for the app.
    private func activate(_ intent: DashIntent, now: TimeInterval) -> [DashIntent] {
        let navPref = DashFocusEngine.defaultPreference(inPreview: model.inPreview, navigating: model.navigating)
        switch intent {
        case .recenter:
            camera.follow = true
            camera.cancelAutoRecenter()
            if let fix = model.fix, model.riderPosition != nil {
                let brng = camera.headingUp ? bestBearing() : 0
                camera.lastMapBearing = brng
                if !model.inPreview {
                    let me = model.riderPosition!
                    puckBearing = currentBearing()
                    camera.applyFollow(me: me, bearingDeg: brng, targetZoom: DashCamera.bikeFollowZoom(speedKmh: (fix.speedMps ?? 0) * 3.6),
                                       moving: fix.isMoving, maxLookAheadPx: lookAheadCap(), tileSize: model.tileSize)
                }
                feedback(.centeredOnGps, now: now)
            } else {
                feedback(.noGpsYet, now: now)
            }
        case .zoomIn, .zoomOut:
            camera.bumpFreePan(now: now)
            camera.speedZoom = false
            camera.zoomBy(intent == .zoomIn ? 1 : -1)
        case .toggleCompass, .toggleHeadingUp:
            camera.headingUp.toggle()
            if !camera.headingUp {
                camera.resetNorth()
                camera.lastMapBearing = 0
            } else {
                let brng = bestBearing()
                camera.lastMapBearing = brng
                if camera.follow, !model.inPreview, let fix = model.fix, let me = model.riderPosition {
                    camera.applyFollow(me: me, bearingDeg: brng, targetZoom: DashCamera.bikeFollowZoom(speedKmh: (fix.speedMps ?? 0) * 3.6),
                                       moving: fix.isMoving, maxLookAheadPx: lookAheadCap(), tileSize: model.tileSize)
                }
            }
            if intent == .toggleCompass { feedback(camera.headingUp ? .headingUp : .northUp, now: now) }
        case .toggleFollow:
            camera.follow.toggle()
            camera.cancelAutoRecenter()
            if camera.follow && !model.inPreview { applyFollowCamera() }
        case .overview:
            camera.bumpFreePan(now: now)
            camera.headingUp = false
            camera.resetNorth()
            camera.lastMapBearing = 0
            let route = model.nav.route?.points ?? []
            let k = min(max(0, model.nav.progress?.nearestIndex ?? 0), max(0, route.count - 1))
            if route.count - k >= 2 {
                let c = layoutContext
                var top: Double?
                var bottom: Double?
                if model.navigating {
                    top = DashLayout.navCard(c, cue: model.nav.cue ?? HudCue(dir: .arrive, distanceText: "GPS", text: "")).frame.maxY + c.dp(8)
                    bottom = DashSceneBuilder.metricsLayout(model, c).frame.minY
                }
                fit(Self.sample(Array(route[k...])), rect: mapFreeRect(previewTop: bottom, topY: top))
                feedback(.routeOverview, now: now)
            } else {
                if let p = model.nav.destination?.point ?? model.riderPosition { camera.setCenter(p, zoom: 14) }
                feedback(.overview, now: now)
            }
        case .openMenu:
            sheet = .menu
            menuScroll = 0
            pendingPreference = .default
        case .openSearch:
            sheet = .search
            searchListScroll = 0
            searchChipScroll = 0
            pendingPreference = .default
        case .closeSheets:
            sheet = .none
            pendingPreference = navPref
        case .findParking:
            sheet = .search
            searchListScroll = 0
            pendingPreference = .default
        case .recalc:
            sheet = .none
            camera.follow = true
            camera.cancelAutoRecenter()
            if !model.inPreview { applyFollowCamera() }
            pendingPreference = navPref
        case .go:
            sheet = .none
            camera.follow = true
            camera.speedZoom = true
            camera.headingUp = true
            camera.cancelAutoRecenter()
        case .dropPin, .previewPlace, .selectSearchResult, .endNavigation, .goHome, .setHomeHere, .parkHere, .startCircuit:
            if sheet != .none {
                sheet = .none
                pendingPreference = navPref
            }
        case .searchChip:
            searchListScroll = 0
        default:
            break
        }
        scene = nil
        return [intent]
    }

    // MARK: - Overlays (focus ring, toast, link banner, hold)

    private func ringVisible(now: TimeInterval) -> Bool {
        guard model.handlebarFocus, focus.focusedId != nil else { return false }
        if let hide = options.hideFocusRingAfterTouch, let t = lastTouchAt, now - t < hide {
            if let k = lastKeyAt, k >= t { return true }
            return false
        }
        return true
    }

    private func overlays(_ sc: DashScene, now: TimeInterval) -> [DashDrawCommand] {
        let c = layoutContext
        var cmds: [DashDrawCommand] = []
        // Focus ring (fill #66FF9800, 5 dp stroke #FF9800, radius 12 dp; circular for FABs).
        if ringVisible(now: now), let id = focus.focusedId, let w = sc.widget(id), !w.rect.isEmpty {
            let clip = w.container.flatMap { sc.containers[$0]?.viewport }
            if let clip { cmds += [.save, .clip(DashPath.rect(clip))] }
            let sw = c.dp(DashPalette.focusStrokeWidth)
            let r = w.fullRect
            if w.circular {
                cmds.append(.fill(DashPath.ellipse(in: r), DashPalette.focusFill, .nonZero))
                cmds.append(.stroke(DashPath.ellipse(in: r.insetBy(dx: sw / 2, dy: sw / 2)),
                                    DashStroke(width: sw, color: DashPalette.focusStroke, cap: .butt, join: .round)))
            } else {
                let rad = min(c.dp(DashPalette.focusRadius), min(r.width, r.height) / 2)
                cmds.append(.fill(DashPath.roundedRect(r, radius: rad), DashPalette.focusFill, .nonZero))
                cmds.append(.stroke(DashPath.roundedRect(r.insetBy(dx: sw / 2, dy: sw / 2), radius: max(0, rad - sw / 2)),
                                    DashStroke(width: sw, color: DashPalette.focusStroke, cap: .butt, join: .round)))
            }
            if clip != nil { cmds.append(.restore) }
        }
        var top = sc.topChromeBottom
        if sheet == .search { top = c.safe.minY + c.dp(DashDimens.searchHeaderHeight) + c.dp(8) }
        // Link banner (amber)
        if let banner = model.linkBanner, !banner.isEmpty {
            let font = c.font(14, .bold)
            let (r, lines) = DashLayout.overlayPill(c, text: banner, font: font, topY: top)
            cmds.append(.fill(DashPath.roundedRect(r, radius: min(r.height / 2, c.dp(18))), DashPalette.bannerFill, .nonZero))
            cmds.append(.text(banner, r.insetBy(dx: c.dp(16), dy: 0),
                              DashTextStyle(font: font, color: DashPalette.bannerText, alignment: .center, maxLines: lines)))
            top = r.maxY + c.dp(6)
        }
        // Toast
        if let t = toast?.text ?? model.toastText, !t.isEmpty {
            let font = c.font(15, .medium)
            let (r, lines) = DashLayout.overlayPill(c, text: t, font: font, topY: top)
            cmds.append(.fill(DashPath.roundedRect(r, radius: min(r.height / 2, c.dp(18))), DashPalette.toastFill, .nonZero))
            cmds.append(.text(t, r.insetBy(dx: c.dp(16), dy: 0),
                              DashTextStyle(font: font, color: DashPalette.toastText, alignment: .center, maxLines: lines)))
        }
        return cmds
    }

    private func holdList(message: String) -> DashDisplayList {
        let sc = ensureScene()
        let c = layoutContext
        var cmds = sc.commands
        let full = DashRect(x: 0, y: 0, width: model.canvas.width, height: model.canvas.height)
        cmds.append(.fill(DashPath.rect(full), DashPalette.holdDimmer, .nonZero))
        let font = c.font(18, .bold)
        let cardW = min(c.safe.width - c.dp(48), c.dp(480))
        let pad = c.dp(24)
        let lines = DashTextLayout.wrap(message, maxWidth: cardW - 2 * pad, font: font, maxLines: 3, measurer: measurer)
        let textH = Double(lines.count) * c.lineHeight(font)
        let iconSize = c.dp(40)
        let cardH = pad + iconSize + c.dp(12) + textH + pad
        let card = DashRect(x: c.safe.midX - cardW / 2, y: c.safe.midY - cardH / 2, width: cardW, height: cardH)
        cmds.append(.fill(DashPath.roundedRect(card, radius: c.dp(DashPalette.cardRadius)), DashPalette.cardFill, .nonZero))
        cmds += DashIcons.commands(.navArrow, in: DashRect(x: card.midX - iconSize / 2, y: card.minY + pad, width: iconSize, height: iconSize))
        cmds.append(.text(message, DashRect(x: card.minX + pad, y: card.minY + pad + iconSize + c.dp(12), width: cardW - 2 * pad, height: textH),
                          DashTextStyle(font: font, color: DashPalette.primaryText, alignment: .center, maxLines: 3)))
        return DashDisplayList(size: model.canvas, background: model.chromeColor, commands: cmds, hitRegions: [])
    }
}
