// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) GpxDashUi.kt (chrome visibility + content), DashMapController.kt
// (map overlays) and the presentation_gpx layouts — docs/spec/navigation-dash.md §11.
//
// Builds one dash frame as draw commands + hit-testable widgets + the handlebar focus order.
// Z-order (back → front): map (+ its tile credit, iOS) · search pill · lap card · nav card · metrics card ·
// preview card · arrive card · FAB column · (now-playing tile) · (clock) · dimmer · search sheet / menu
// sheet / confirm card · SPEED CHIP. P0 (D03, D19): the speed gauge and its limit sign are drawn last, over
// the menu and every sheet — speed and limit are never covered (Android drew them under the preview, the
// menu and the sheets). The Apple Music sheet (iOS addition) is opaque: the sheet, while navigating the nav
// card on top of it, then the speed chip. The controller adds the focus ring, toasts and the link banner on
// top, and builds the hold card itself.

import Foundation

/// Which sheet covers the map.
public enum DashSheet: String, Sendable, Equatable {
    case none, menu, search
    /// Apple Music (iOS addition).
    case music
    /// The confirm card (P0, D01): "End the route?" / "Change route?" with the safe option focused.
    case confirm
}

/// What the confirm card asks (P0, D01).
public enum DashConfirmKind: String, Sendable, Equatable {
    /// The menu's "End route…": its action ends the navigation.
    case endRoute
    /// Go on a preview while a route runs: its action replaces that route.
    case changeRoute
}

/// A hit-testable element of a built frame.
struct DashWidget: Sendable {
    enum Kind: Sendable {
        /// Tappable; `nil` intent = handled by the controller (none today).
        case control(DashIntent?)
        /// Card background: swallows touches.
        case blocker
        /// Scrollable container background.
        case scrollArea
    }
    var id: String
    /// Visible rect on screen (clipped to its scroll container; may be empty when scrolled out).
    var rect: DashRect
    /// Unclipped rect (for scroll-into-view).
    var fullRect: DashRect
    var kind: Kind
    /// Scroll container id ("menu", "search.list", "search.chips", "preview.chips").
    var container: String?
    var circular: Bool = false
}

struct DashScrollContainer: Sendable {
    enum Axis: Sendable { case vertical, horizontal }
    var id: String
    var viewport: DashRect
    var axis: Axis
    var contentLength: Double
    /// Drawn over part of the viewport (the speed chip, P0 D03): a focused control is scrolled clear of it.
    var obstacle: DashRect? = nil
    var maxOffset: Double { max(0, contentLength - (axis == .vertical ? viewport.height : viewport.width)) }
}

struct DashScene: Sendable {
    var commands: [DashDrawCommand] = []
    var widgets: [DashWidget] = []
    var focusOrder: [String] = []
    var containers: [String: DashScrollContainer] = [:]
    /// Bottom of the top chrome (pill / nav card / banner) — toasts go below it.
    var topChromeBottom: Double = 0
    var fabs: [DashRect] = []
    /// The speed chip (gauge + limit room) as drawn — the last thing the scene draws (P0, D03).
    var speedChip: DashRect?
    /// Apple Music: what the time-dependent drawing (progress, times) was built for
    /// (`DashSceneBuilder.musicTimeKey`); nil = nothing in this scene moves with time.
    var musicTimeKey: Int?
    /// px width of the now-playing tile's progress track (nil: no tile or no known duration).
    var musicTileBarWidth: Double?

    func widget(_ id: String) -> DashWidget? { widgets.last(where: { $0.id == id }) }
}

/// Everything the builder needs besides the model.
struct DashSceneInput: Sendable {
    var model: DashModel
    var sheet: DashSheet
    /// The camera as DRAWN (during a follow ease: the interpolated geometry; flags as the controller's).
    var camera: DashCamera
    var puckBearingDeg: Double
    /// Where the rider puck is drawn (during a follow ease: the interpolated position).
    var puck: GeoPoint?
    var anchor: DashPoint
    var menuScroll: Double
    var searchListScroll: Double
    var searchChipScroll: Double
    var previewChipScroll: Double
    var lapReachableByHandlebar: Bool
    var handlebarReachesSettings: Bool
    /// The time the Apple Music progress / times are drawn for (same clock as `positionAt`).
    var musicNow: TimeInterval = 0
    /// What the confirm card asks while `sheet == .confirm` (P0, D01).
    var confirm: DashConfirmKind? = nil
}

struct DashSceneBuilder {
    let input: DashSceneInput
    let c: DashLayoutContext
    private(set) var scene = DashScene()

    init(input: DashSceneInput, measurer: any DashTextMeasurer) {
        self.input = input
        self.c = DashLayoutContext(model: input.model, measurer: measurer)
    }

    private var model: DashModel { input.model }
    private var L: DashLanguage { model.language }

    // MARK: Primitive helpers

    private mutating func fill(_ path: DashPath, _ color: DashColor, _ rule: DashFillRule = .nonZero) {
        scene.commands.append(.fill(path, color, rule))
    }

    /// Android GradientDrawable: fill the rounded rect, stroke drawn inside the bounds.
    private mutating func roundRect(_ r: DashRect, radius: Double, fill color: DashColor?, stroke: DashColor? = nil,
                                    strokeWidth: Double = 0, corners: (Double, Double, Double, Double)? = nil) {
        let rad = min(radius, min(r.width, r.height) / 2)
        let cr = corners ?? (rad, rad, rad, rad)
        if let color {
            fill(DashPath.roundedRect(r, topLeft: cr.0, topRight: cr.1, bottomRight: cr.2, bottomLeft: cr.3), color)
        }
        if let stroke, strokeWidth > 0 {
            let h = strokeWidth / 2
            let ir = r.insetBy(dx: h, dy: h)
            let path = DashPath.roundedRect(ir, topLeft: max(0, cr.0 - h), topRight: max(0, cr.1 - h),
                                            bottomRight: max(0, cr.2 - h), bottomLeft: max(0, cr.3 - h))
            scene.commands.append(.stroke(path, DashStroke(width: strokeWidth, color: stroke, cap: .butt, join: .miter)))
        }
    }

    private mutating func circle(_ r: DashRect, fill color: DashColor?, stroke: DashColor? = nil, strokeWidth: Double = 0) {
        if let color { fill(DashPath.ellipse(in: r), color) }
        if let stroke, strokeWidth > 0 {
            let h = strokeWidth / 2
            scene.commands.append(.stroke(DashPath.ellipse(in: r.insetBy(dx: h, dy: h)),
                                          DashStroke(width: strokeWidth, color: stroke, cap: .butt, join: .miter)))
        }
    }

    private mutating func text(_ s: String, _ r: DashRect, _ font: DashFont, _ color: DashColor,
                               align: DashTextAlignment = .left, maxLines: Int = 1, spacing: Double = 0) {
        guard !s.isEmpty, r.width > 0, r.height > 0 else { return }
        scene.commands.append(.text(s, r, DashTextStyle(font: font, color: color, alignment: align, maxLines: maxLines,
                                                        letterSpacingEm: spacing)))
    }

    private mutating func icon(_ icon: DashIcon, in r: DashRect, tint: DashColor? = nil, alpha: Double = 1, rotation: Double = 0) {
        scene.commands.append(contentsOf: DashIcons.commands(icon, in: r, tint: tint, alpha: alpha, rotation: rotation))
    }

    private mutating func widget(_ id: String, _ r: DashRect, _ kind: DashWidget.Kind, container: String? = nil,
                                 clip: DashRect? = nil, circular: Bool = false) {
        var visible = r
        if let clip { visible = Self.intersect(r, clip) }
        scene.widgets.append(DashWidget(id: id, rect: visible, fullRect: r, kind: kind, container: container, circular: circular))
    }

    static func intersect(_ a: DashRect, _ b: DashRect) -> DashRect {
        let x0 = max(a.minX, b.minX), y0 = max(a.minY, b.minY)
        let x1 = min(a.maxX, b.maxX), y1 = min(a.maxY, b.maxY)
        return x1 > x0 && y1 > y0 ? DashRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0) : DashRect(x: x0, y: y0, width: 0, height: 0)
    }

    // MARK: Build

    mutating func build() -> DashScene {
        let navigating = model.navigating
        let fabs = DashLayout.fabColumn(c)
        scene.fabs = fabs
        if input.sheet == .music, let music = model.music {
            buildMusicSheet(music, navigating: navigating)
            return scene
        }
        let mapDrawn = drawMap()
        let mapLayerEnd = scene.commands.count // the map credit joins the map layer once the chrome is placed

        // Search pill (free ride & preview)
        var pillFrame: DashRect?
        if !navigating {
            pillFrame = drawSearchPill()
        }
        // Bottom-left geometry decided up front (lap card + speed chip depend on it)
        let metrics: DashMetricsLayout? = navigating ? Self.metricsLayout(model, c) : nil
        let preview: DashPreviewCardLayout? = model.nav.preview.map {
            DashLayout.previewCard(c, preview: $0, language: L, chipScroll: input.previewChipScroll)
        }
        let arrive: DashArriveCardLayout? = model.showsArrival ? model.nav.arrival.map {
            DashLayout.arriveCard(c, arrival: $0, language: L)
        } : nil
        var lapFrame: DashRect?
        if let lap = model.lapTimer {
            let above = [metrics?.frame.minY, preview?.frame.minY, arrive?.frame.minY].compactMap { $0 }.min()
            let l = DashLayout.lapCard(c, lap: lap, aboveY: above)
            drawLapCard(l)
            lapFrame = l.frame
        }
        var navFrame: DashRect?
        if navigating { navFrame = drawNavCard() }
        // The speed chip's place (drawn last): beside / above the metrics card, never under a card.
        var speed = Self.speedChipLayout(model, c, metrics: metrics, bannerBottom: navFrame?.maxY,
                                         covering: [preview?.frame, arrive?.frame].compactMap { $0 })
        var confirm: DashConfirmCardLayout?
        if input.sheet == .confirm, let kind = input.confirm {
            let l = confirmLayout(kind, speed: speed, metrics: metrics)
            if l.frame.intersects(speed.frame) {
                speed = Self.speedChipLayout(model, c, metrics: metrics, bannerBottom: navFrame?.maxY,
                                             covering: [preview?.frame, arrive?.frame, l.frame].compactMap { $0 })
            }
            confirm = l
        }
        // Landscape: the confirm card sits over the metrics card. Where it does not cover all of it (544x512,
        // whose gauge stacks above the card) the trip numbers would show as cut fragments («NTE», a bare
        // «km») beside it: the metrics card waits for the card to close (review DASH-LOOK-6). Portrait keeps
        // it: the card sits above the bar there.
        if navigating, let metrics, confirm == nil || !c.isLandscape { drawMetrics(metrics) }
        // The confirm card stands in for the preview card it asks about («Change route?»): one card at a time.
        if let preview, let p = model.nav.preview, confirm == nil { drawPreview(preview, p) }
        if let arrive { drawArrive(arrive) }
        // FAB lane (no sheet): FABs, the Apple Music now-playing tile under them, the clock chip.
        var tile: DashMusicTileLayout?
        var lane: [DashRect] = []
        if input.sheet == .none {
            let clock = model.showClock ? clockChip(fabs) : nil
            if model.music != nil {
                let cards = [metrics?.frame, speed.frame, preview?.frame, arrive?.frame, lapFrame].compactMap { $0 }
                tile = DashLayout.musicTile(c, fabs: fabs, clock: clock?.rect, avoiding: cards)
            }
            drawFabs(fabs)
            if let tile, let music = model.music { drawMusicTile(tile, music) }
            if let clock, !(tile?.hidesClock ?? false) { drawClock(clock) }
            lane = fabs + [tile?.frame, (tile?.hidesClock ?? false) ? nil : clock?.rect].compactMap { $0 }
        }
        scene.topChromeBottom = (navFrame?.maxY ?? pillFrame?.maxY ?? c.safe.minY) + c.dp(8)
        // Map credit ("© OpenStreetMap" on OSMF tiles, iOS addition): in the map layer, under every piece of
        // chrome and sheet, and clear of all the chrome drawn on the map (navigation-dash.md §10.4).
        if mapDrawn, let credit = model.mapAttribution {
            let chrome = [pillFrame, navFrame, lapFrame, metrics?.frame, speed.frame, preview?.frame, arrive?.frame]
                .compactMap { $0 } + lane
            if let l = DashLayout.mapAttribution(c, text: credit, avoiding: chrome,
                                                 topLimit: navFrame?.maxY ?? pillFrame?.maxY ?? c.safe.minY) {
                scene.commands.insert(contentsOf: Self.attributionCommands(l), at: mapLayerEnd)
            }
        }

        switch input.sheet {
        case .menu:
            drawMenu(speed: speed.frame)
        case .search:
            drawSearch(speed: speed.frame)
        case .confirm:
            if let confirm, let kind = input.confirm { drawConfirm(confirm, kind) }
        case .music, .none:
            break // .music without a song: nothing to show (the controller closes the sheet)
        }
        drawSpeedChip(speed) // last: over the menu and every sheet (P0, D03)
        if let tile, model.music?.knownDuration != nil { scene.musicTileBarWidth = tile.progressRect.width }
        scene.musicTimeKey = Self.musicTimeKey(model.music, sheetOpen: false, tileBarWidth: scene.musicTileBarWidth,
                                               now: input.musicNow)
        scene.focusOrder = focusOrder(pillVisible: pillFrame != nil, tileVisible: tile != nil)
        return scene
    }

    /// What the time-dependent Apple Music drawing depends on (nil: nothing moves with time): only
    /// while playing with a known duration; the open sheet → the whole elapsed seconds (labels and
    /// bar); the tile → the whole px of its progress fill. The controller rebuilds the scene when the
    /// key changes, so a playing song re-renders at most once per second (the tile less often).
    static func musicTimeKey(_ music: DashNowPlaying?, sheetOpen: Bool, tileBarWidth: Double?, now: TimeInterval) -> Int? {
        guard let music, music.state == .playing, music.knownDuration != nil else { return nil }
        if sheetOpen { return music.elapsedSeconds(at: now) }
        guard let width = tileBarWidth, let fill = musicFill(music, width: width, now: now) else { return nil }
        return DashFormat.roundHalfUp(fill)
    }

    /// Filled width (whole px) of a `width`-px progress bar at `now`, nil without a known duration.
    /// It follows the whole elapsed seconds, like the time labels: the bar never steps more than once
    /// per second, even for a song shorter than the bar is wide (no animation on the dash).
    static func musicFill(_ music: DashNowPlaying, width: Double, now: TimeInterval) -> Double? {
        guard let duration = music.knownDuration, width.isFinite, width > 0 else { return nil }
        // elapsed × width / duration (not fraction × width): exact on whole-px boundaries
        let px = (Double(music.elapsedSeconds(at: now)) * width / duration + 1e-9).rounded(.down)
        return min(max(0, px), width.rounded(.down))
    }

    // MARK: Map layer

    private static func outcode(_ p: DashPoint, _ r: DashRect) -> Int {
        var code = 0
        if p.x < r.minX { code |= 1 } else if p.x > r.maxX { code |= 2 }
        if p.y < r.minY { code |= 4 } else if p.y > r.maxY { code |= 8 }
        return code
    }

    /// Map-local polyline, culled to `cull` (segments entirely on one outer side are dropped)
    /// and decimated (points closer than 1 px to the last kept one are skipped).
    static func polyline(_ pts: ArraySlice<TrackPoint>, proj: MapProjection, cull: DashRect, minStep: Double = 1) -> DashPath {
        var path = DashPath()
        var prev: DashPoint?
        var prevCode = 0
        var penDown = false
        var lastAdded = DashPoint.zero
        for tp in pts {
            let q = proj.mapLocal(GeoPoint(lat: tp.lat, lon: tp.lon))
            let code = outcode(q, cull)
            if let a = prev {
                if (code & prevCode) != 0 {
                    if penDown {
                        if lastAdded != a { path.line(to: a) }
                        penDown = false
                    }
                } else {
                    if !penDown {
                        path.move(to: a)
                        lastAdded = a
                        penDown = true
                    }
                    let dx = q.x - lastAdded.x, dy = q.y - lastAdded.y
                    if dx * dx + dy * dy >= minStep * minStep {
                        path.line(to: q)
                        lastAdded = q
                    }
                }
            }
            prev = q
            prevCode = code
        }
        if penDown, let a = prev, lastAdded != a { path.line(to: a) }
        return path
    }

    /// A route line, optionally over a wider casing (P0, D05: the remaining route, the preview routes).
    private mutating func strokeRoute(_ pts: ArraySlice<TrackPoint>, proj: MapProjection, cull: DashRect, color: DashColor,
                                      widthDp: Double, casing: DashColor? = nil, casingWidthDp: Double = 0, dash: [Double] = []) {
        guard pts.count >= 2 else { return }
        let path = Self.polyline(pts, proj: proj, cull: cull)
        guard !path.isEmpty else { return }
        if let casing, casingWidthDp > widthDp {
            scene.commands.append(.stroke(path, DashStroke(width: c.dp(casingWidthDp), color: casing, cap: .round, join: .round)))
        }
        scene.commands.append(.stroke(path, DashStroke(width: c.dp(widthDp), color: color, cap: .round, join: .round,
                                                       dash: dash.map { c.dp($0) })))
    }

    /// The rider puck (P0, D05): a halo disc (dark by day, white at night) under a white chevron with a
    /// 3-dp dark outline, `size` px wide, rotated by `rotation` radians (clockwise) about `center`.
    static func puckCommands(center: DashPoint, size: Double, rotation: Double, night: Bool) -> [DashDrawCommand] {
        let r = size / 2
        let k = size / DashPalette.puckSize // px per design unit
        // Chevron in a 56-unit design around the centre (the mockups' puck): tip up, notch at the back.
        let design: [(Double, Double)] = [(0, -25), (18, 19), (0, 9), (-18, 19)]
        let cs = cos(rotation), sn = sin(rotation)
        let pts = design.map { p -> DashPoint in
            let x = p.0 * k, y = p.1 * k
            return DashPoint(center.x + x * cs - y * sn, center.y + x * sn + y * cs)
        }
        let chevron = DashPath.polyline(pts, closed: true)
        return [
            .fill(DashPath.circle(center: center, radius: r), DashPalette.puckHalo(night: night), .nonZero),
            .fill(chevron, DashPalette.puckFill, .nonZero),
            .stroke(chevron, DashStroke(width: DashPalette.puckEdgeWidth * k, color: DashPalette.puckEdge, cap: .round, join: .round)),
        ]
    }

    /// The tile credit: a rounded plate with its text centred (map layer, no hit region: touches reach the map).
    static func attributionCommands(_ l: DashMapAttributionLayout) -> [DashDrawCommand] {
        [.fill(DashPath.roundedRect(l.frame, radius: min(l.cornerRadius, l.frame.height / 2)), DashPalette.attributionFill, .nonZero),
         .text(l.text, l.frame, DashTextStyle(font: l.font, color: DashPalette.attributionText, alignment: .center))]
    }

    /// Returns false when there is no camera to draw the map with (nothing drawn).
    @discardableResult
    private mutating func drawMap() -> Bool {
        let m = model
        guard let proj = input.camera.projection(viewport: m.canvas, anchor: input.anchor, tileSize: m.tileSize) else { return false }
        scene.commands.append(.save)
        scene.commands.append(.transform(proj.mapToScreen))
        let treatment = m.tileTreatment
        for t in proj.visibleTiles(maxTileZoom: m.maxTileZoom) {
            scene.commands.append(.tile(z: t.z, x: t.x, y: t.y, rect: t.rect, treatment: treatment))
        }
        // Visible map-local box, padded so round caps / wide lines never pop at the edges.
        let corners = [DashPoint(0, 0), DashPoint(m.canvas.width, 0), DashPoint(m.canvas.width, m.canvas.height),
                       DashPoint(0, m.canvas.height)].map(proj.screenToMap.apply)
        let pad = c.dp(64)
        let minX = corners.map(\.x).min()! - pad, maxX = corners.map(\.x).max()! + pad
        let minY = corners.map(\.y).min()! - pad, maxY = corners.map(\.y).max()! + pad
        let cull = DashRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let rider = input.puck

        let night = m.isNight
        let casing = DashPalette.routeCasing(night: night)
        if let preview = m.nav.preview {
            if !preview.pinMode, !preview.routes.isEmpty {
                let sel = min(max(0, preview.selectedIndex), preview.routes.count - 1)
                // Alternatives (≤ 4) under the selected green route.
                let alternatives = preview.routes.enumerated().filter { $0.offset != sel }.prefix(4)
                for alt in alternatives {
                    strokeRoute(alt.element.points[...], proj: proj, cull: cull, color: DashPalette.routeAlternative(night: night),
                                widthDp: DashPalette.routeAlternativeWidth, casing: casing,
                                casingWidthDp: DashPalette.routeAlternativeCasingWidth)
                }
                strokeRoute(preview.routes[sel].points[...], proj: proj, cull: cull, color: DashPalette.routePreview,
                            widthDp: DashPalette.routePreviewWidth, casing: casing, casingWidthDp: DashPalette.routePreviewCasingWidth)
            }
        } else if let route = m.nav.route, route.points.count >= 2 {
            let remain = DashPalette.routeRemain(night: night)
            if let k0 = m.nav.progress?.nearestIndex {
                let k = min(max(0, k0), route.points.count - 1)
                strokeRoute(route.points[0 ... k], proj: proj, cull: cull, color: DashPalette.routeDone(night: night),
                            widthDp: DashPalette.routeDoneWidth)
                strokeRoute(route.points[k...], proj: proj, cull: cull, color: remain,
                            widthDp: DashPalette.routeRemainWidth, casing: casing, casingWidthDp: DashPalette.routeCasingWidth)
            } else {
                strokeRoute(route.points[...], proj: proj, cull: cull, color: remain,
                            widthDp: DashPalette.routeRemainWidth, casing: casing, casingWidthDp: DashPalette.routeCasingWidth)
            }
        }
        // Dashed rider → destination line (preview without a road route yet / NAV_TO without route).
        var toDest: GeoPoint?
        if let p = m.nav.preview {
            if !p.pinMode, p.routes.isEmpty { toDest = p.place.point }
        } else if m.nav.showStraightLineToDestination {
            toDest = m.nav.destination?.point
        }
        if let me = rider, let d = toDest {
            let a = proj.mapLocal(me), b = proj.mapLocal(d)
            scene.commands.append(.stroke(DashPath.polyline([a, b]),
                                          DashStroke(width: c.dp(DashPalette.routeToDestinationWidth), color: DashPalette.routeToDestination,
                                                     cap: .round, join: .round, dash: DashPalette.routeToDestinationDash.map { c.dp($0) })))
        }
        scene.commands.append(.restore)

        // Pins (screen space, upright, anchor bottom-centre)
        let margin = c.dp(60)
        let screen = DashRect(x: -margin, y: -margin, width: m.canvas.width + 2 * margin, height: m.canvas.height + 2 * margin)
        for p in m.nav.pins where !(p.lat == 0 && p.lon == 0) {
            let s = proj.screenPoint(p.point)
            guard screen.contains(s) else { continue }
            let w = c.dp(28), h = c.dp(34)
            icon(.destPin, in: DashRect(x: s.x - w / 2, y: s.y - h, width: w, height: h))
        }
        if let me = rider {
            let s = proj.screenPoint(me)
            if screen.contains(s) {
                let rot = (input.puckBearingDeg - input.camera.bearingDeg) * .pi / 180
                scene.commands += Self.puckCommands(center: s, size: c.dp(DashPalette.puckSize), rotation: rot, night: m.isNight)
            }
        }
        let dest = m.nav.preview?.place ?? m.nav.destination
        if let d = dest, !(d.lat == 0 && d.lon == 0) {
            let s = proj.screenPoint(d.point)
            if screen.contains(s) {
                let w = c.dp(36), h = c.dp(44)
                icon(.destPin, in: DashRect(x: s.x - w / 2, y: s.y - h, width: w, height: h))
            }
        }
        return true
    }

    // MARK: Chrome

    /// The search pill / sheet colours: white by day, dark at night (P0, D06).
    private var searchColors: DashPalette.SearchSurface { DashPalette.search(night: model.isNight) }

    /// A card: the opaque card fill with its edge (P0, D12).
    private mutating func card(_ r: DashRect, radius: Double, fill color: DashColor = DashPalette.cardFill,
                               corners: (Double, Double, Double, Double)? = nil) {
        roundRect(r, radius: radius, fill: color, stroke: DashPalette.cardEdge, strokeWidth: c.dp(DashPalette.cardEdgeWidth),
                  corners: corners)
    }

    private mutating func drawSearchPill() -> DashRect {
        let lapLabel = (model.lapTimer != nil ? DashText.lapStop : DashText.lap).localized(L)
        let pill = DashLayout.searchPill(c, circuitLabel: DashText.circuit.localized(L), lapLabel: lapLabel)
        let col = searchColors
        if model.isNight {
            roundRect(pill.frame, radius: c.dp(DashPalette.searchPillRadius), fill: col.pillFill, stroke: DashPalette.cardEdge,
                      strokeWidth: c.dp(DashPalette.cardEdgeWidth))
        } else {
            roundRect(pill.frame, radius: c.dp(DashPalette.searchPillRadius), fill: col.pillFill)
        }
        icon(.search, in: pill.iconRect, tint: col.pillIcon)
        let label = model.nav.preview?.place.name ?? DashText.searchHere.localized(L)
        text(label, pill.textRect, pill.textFont, col.pillText)
        text(DashText.circuit.localized(L), pill.circuitRect, pill.labelFont, col.pillAccent, align: .center)
        text(lapLabel, pill.lapRect, pill.labelFont, col.pillAccent, align: .center)
        widget("pill", pill.frame, .control(.openSearch))
        widget("pill.circuit", pill.circuitRect, .control(.startCircuit))
        widget("pill.lap", pill.lapRect, .control(.toggleLapTimer))
        return pill.frame
    }

    private mutating func drawLapCard(_ l: DashLapCardLayout) {
        let r = c.dp(DashPalette.cardRadius)
        card(l.frame, radius: r, fill: DashPalette.bottomBarFill, corners: (r, r, 0, 0))
        text(model.lapTimer?.title ?? "", l.titleRect, l.titleFont, DashPalette.primaryText)
        text(model.lapTimer?.meta ?? "", l.metaRect, l.metaFont, DashPalette.statusText)
        widget("lap.card", l.frame, .blocker)
    }

    /// The cue to show while navigating (seeded when the nav engine has none yet).
    private var effectiveCue: HudCue {
        if let cue = model.nav.cue, !cue.text.isEmpty || !cue.distanceText.isEmpty { return cue }
        return HudCue(dir: .arrive, distanceText: "GPS", text: DashStrings.toDestination(Self.routeName(model), L))
    }

    /// The name of the running route: the GPX track or the destination ("" in free ride).
    static func routeName(_ model: DashModel) -> String {
        switch model.nav.mode {
        case let .gpx(n): return n
        case let .navTo(p): return model.nav.destination?.name ?? p.name
        case .freeRide: return model.nav.destination?.name ?? ""
        }
    }

    private mutating func drawNavCard() -> DashRect {
        let cue = effectiveCue
        let l = DashLayout.navCard(c, cue: cue)
        let r = c.dp(DashPalette.cardRadius)
        if l.isBanner {
            card(l.frame, radius: r, fill: DashPalette.topBannerFill, corners: (0, 0, r, r))
        } else {
            card(l.frame, radius: r)
        }
        icon(DashIcons.icon(for: cue.dir), in: l.iconRect, tint: DashPalette.primaryText)
        text(l.distanceText, l.distanceRect, l.distanceFont, DashPalette.primaryText)
        let road = cue.text.isEmpty ? DashStrings.maneuverWord(cue.dir, L) : cue.text
        text(road, l.roadRect, l.roadFont, DashPalette.roadText, maxLines: 2)
        if let lanes = l.lanesText, let lr = l.lanesRect {
            text(lanes, lr, l.lanesFont, DashPalette.laneText, spacing: DashLayout.laneLetterSpacingEm)
        }
        widget("nav.card", l.frame, .blocker)
        return l.frame
    }

    /// TIME, ARRIVE, LEFT (P0, D12: ALT left the strip).
    static func metricsLabels(_ model: DashModel) -> [String] {
        let L = model.language
        return [DashText.time.localized(L), DashText.arrive.localized(L), DashText.left.localized(L)]
    }

    /// The speed-limit sign text, nil when hidden (blank or "—").
    static func speedLimitLabel(_ model: DashModel) -> String? {
        guard let label = model.nav.speedLimit?.label.trimmingCharacters(in: .whitespaces), !label.isEmpty, label != "—" else { return nil }
        return label
    }

    static func stacksSpeedChip(_ model: DashModel, _ c: DashLayoutContext) -> Bool {
        DashLayout.speedChipStacksAboveMetrics(c, labels: metricsLabels(model))
    }

    /// The metrics card / bar for a navigating model (shared with the camera's look-ahead cap). Its right edge
    /// never depends on the speed limit: the chip's limit room is always reserved (P0, D19).
    static func metricsLayout(_ model: DashModel, _ c: DashLayoutContext) -> DashMetricsLayout {
        let mt = model.nav.metrics
        var maxRight = c.safe.maxX - c.dp(DashDimens.fabLane)
        if c.isLandscape && !stacksSpeedChip(model, c) {
            let chip = DashLayout.speedChip(c, hasLimit: true, navigating: true)
            maxRight = min(maxRight, chip.frame.minX - c.dp(DashDimens.edge))
        }
        return DashLayout.metricsCard(c, labels: metricsLabels(model), values: [mt.time, mt.arrive, mt.left], maxRight: maxRight,
                                      landscapeStatus: mt.statusWarning ? mt.status : nil)
    }

    private mutating func drawMetrics(_ l: DashMetricsLayout) {
        let r = c.dp(DashPalette.cardRadius)
        if l.isBar {
            card(l.frame, radius: r, fill: DashPalette.bottomBarFill, corners: (r, r, 0, 0))
        } else {
            card(l.frame, radius: r)
        }
        for col in l.columns {
            text(col.label, col.labelRect, col.labelFont, DashPalette.metricLabel, align: .center)
            text(col.value, col.valueRect, col.valueFont, DashPalette.primaryText, align: .center)
        }
        if let sr = l.statusRect {
            let mt = model.nav.metrics
            text(mt.status, sr, l.statusFont, mt.statusWarning ? DashPalette.statusWarning : DashPalette.statusText)
        }
        widget("metrics.card", l.frame, .blocker)
    }

    /// Where the speed chip goes in this state: beside the metrics card (stacked above it on narrow canvases),
    /// lifted above a card that would cover it (preview, arrival, confirm), its limit room always reserved.
    /// The Music sheet keeps the place of the map underneath (constant geometry, P0 D19).
    static func speedChipLayout(_ model: DashModel, _ c: DashLayoutContext, metrics: DashMetricsLayout?, bannerBottom: Double?,
                                covering: [DashRect]) -> DashSpeedChipLayout {
        let navigating = model.navigating
        let hasLimit = speedLimitLabel(model) != nil
        let stackY: Double? = (c.isLandscape && navigating && stacksSpeedChip(model, c)) ? metrics?.frame.minY : nil
        var l = DashLayout.speedChip(c, hasLimit: hasLimit, navigating: navigating, belowY: bannerBottom, stackAboveY: stackY)
        // iOS: never leave the gauge hidden under (nor drawn over) a preview / arrive / confirm card.
        let covers = covering.filter { l.frame.intersects($0) }
        if let top = covers.map(\.minY).min(), !(navigating && !c.isLandscape) {
            l = DashLayout.speedChip(c, hasLimit: hasLimit, navigating: navigating, belowY: bannerBottom, stackAboveY: top)
        }
        return l
    }

    /// The speed text's font: the chip's size, shrunk to fit the gauge for three-digit speeds (P0, D11:
    /// 44 sp would ellipsise "120").
    static func speedFont(_ text: String, _ l: DashSpeedChipLayout, _ c: DashLayoutContext) -> DashFont {
        let inner = l.gaugeRect.width - 2 * c.dp(6)
        let w = c.width(text, l.speedFont)
        guard w > inner, w > 0 else { return l.speedFont }
        var f = l.speedFont
        f.size = (f.size * inner / w * 100).rounded(.down) / 100
        return f
    }

    /// The speed gauge and the limit sign — the scene's last commands and last widget (P0, D03).
    private mutating func drawSpeedChip(_ l: DashSpeedChipLayout) {
        let limit = Self.speedLimitLabel(model)
        circle(l.gaugeRect, fill: DashPalette.gaugeFill, stroke: DashPalette.gaugeStroke, strokeWidth: c.dp(DashPalette.gaugeStrokeWidth))
        let speed = model.fix == nil ? "—" : DashFormat.speed(mps: model.fix?.speedMps ?? 0, units: model.units)
        let font = Self.speedFont(speed, l, c)
        let sh = c.lineHeight(l.speedFont), uh = c.lineHeight(l.unitFont)
        let top = l.gaugeRect.midY - (sh + uh) / 2
        let inner = l.gaugeRect.insetBy(dx: c.dp(4), dy: 0)
        text(speed, DashRect(x: inner.minX, y: top, width: inner.width, height: sh), font, DashPalette.primaryText, align: .center)
        text(DashFormat.speedUnit(model.units), DashRect(x: inner.minX, y: top + sh, width: inner.width, height: uh), l.unitFont,
             DashPalette.secondaryText, align: .center)
        if let lr = l.limitRect, let limit {
            circle(lr, fill: DashPalette.limitRed)
            let inset = c.dp(DashPalette.limitInset)
            circle(lr.insetBy(dx: inset, dy: inset), fill: DashPalette.limitInner)
            text(limit, lr.insetBy(dx: inset, dy: 0), l.limitFont, DashPalette.limitText, align: .center)
        }
        scene.speedChip = l.frame
        widget("speed.chip", l.frame, .blocker)
    }

    private mutating func drawPreview(_ l: DashPreviewCardLayout, _ p: RoutePreview) {
        card(l.frame, radius: c.dp(DashPalette.cardRadius))
        widget("preview.card", l.frame, .blocker)
        text(p.place.name, l.nameRect, l.nameFont, DashPalette.primaryText)
        text(p.meta, l.metaRect, l.metaFont, DashPalette.secondaryText)
        if let vp = l.chipsViewport {
            widget("preview.chips", vp, .scrollArea, container: "preview.chips")
            scene.containers["preview.chips"] = DashScrollContainer(id: "preview.chips", viewport: vp, axis: .horizontal,
                                                                    contentLength: l.chipsContentWidth)
            scene.commands.append(.save)
            scene.commands.append(.clip(DashPath.rect(vp)))
            for (i, r) in l.chipRects.enumerated() {
                let sel = i == p.selectedIndex
                if r.maxX >= vp.minX && r.minX <= vp.maxX {
                    roundRect(r, radius: c.dp(DashPalette.routeChipRadius),
                              fill: sel ? DashPalette.routeChipSelectedFill : DashPalette.routeChipFill,
                              stroke: sel ? DashPalette.routeChipSelectedStroke : DashPalette.routeChipStroke, strokeWidth: c.dp(1))
                    text(l.chipLabels[i], r, l.chipFont, sel ? DashPalette.routeChipSelectedText : DashPalette.routeChipText, align: .center)
                }
            }
            scene.commands.append(.restore)
            for (i, r) in l.chipRects.enumerated() {
                widget("preview.chip.\(i)", r, .control(.selectRoute(i)), container: "preview.chips", clip: vp)
            }
        }
        for a in l.actions {
            text(a.label, a.rect, l.actionFont, a.color, align: .center)
            let intent: DashIntent
            switch a.id {
            case "preview.save": intent = .saveFavorite
            case "preview.home": intent = .setHome
            case "preview.marker": intent = .addMarker
            case "preview.circuit": intent = .startCircuit
            default: intent = .cancelPreview
            }
            widget(a.id, a.rect, .control(intent))
        }
        if let g = l.goRect {
            roundRect(g, radius: c.dp(DashPalette.blueActionRadius), fill: DashPalette.blueAction)
            text(DashText.go.localized(L), g, l.goFont, DashPalette.primaryText, align: .center)
            widget(DashFocusEngine.goId, g, .control(.go))
        }
    }

    /// The arrival card (P0, D22): Done is the primary (blue) button and the default focus; Park here only
    /// sets the parked spot; the same labels on every canvas.
    private mutating func drawArrive(_ l: DashArriveCardLayout) {
        guard let a = model.nav.arrival else { return }
        card(l.frame, radius: c.dp(DashPalette.cardRadius))
        widget("arrive.card", l.frame, .blocker)
        text(a.title, l.titleRect, l.titleFont, DashPalette.primaryText)
        text(a.meta, l.metaRect, l.metaFont, DashPalette.secondaryText, maxLines: 2)
        roundRect(l.doneRect, radius: c.dp(DashPalette.blueActionRadius), fill: DashPalette.blueAction)
        text(DashText.done.localized(L), l.doneRect, l.buttonFont, DashPalette.primaryText, align: .center)
        widget("arrive.done", l.doneRect, .control(.dismissArrival))
        roundRect(l.parkRect, radius: c.dp(DashPalette.routeChipRadius), fill: DashPalette.routeChipFill,
                  stroke: DashPalette.routeChipStroke, strokeWidth: c.dp(1))
        text(DashText.parkHere.localized(L), l.parkRect, l.buttonFont, DashPalette.primaryText, align: .center)
        widget("arrive.park", l.parkRect, .control(.markArrivalParking))
        roundRect(l.findRect, radius: c.dp(DashPalette.routeChipRadius), fill: DashPalette.routeChipFill,
                  stroke: DashPalette.routeChipStroke, strokeWidth: c.dp(1))
        text(DashText.findParking.localized(L), l.findRect, l.buttonFont, DashPalette.primaryText, align: .center)
        widget("arrive.find", l.findRect, .control(.findParking))
    }

    // MARK: Confirm card (P0, D01)

    /// The confirm card's texts for `kind`: question, consequence, safe option, action.
    static func confirmTexts(_ kind: DashConfirmKind, _ model: DashModel) -> (question: String, consequence: String, keep: String, act: String) {
        let L = model.language
        switch kind {
        case .endRoute:
            return (DashText.confirmEndQuestion.localized(L), DashStrings.endConsequence(routeName(model), L),
                    DashText.confirmKeep.localized(L), DashText.confirmEndAction.localized(L))
        case .changeRoute:
            return (DashText.confirmChangeQuestion.localized(L),
                    DashStrings.changeConsequence(from: routeName(model), to: model.nav.preview?.place.name ?? "", L),
                    DashText.confirmKeep.localized(L), DashText.confirmChangeAction.localized(L))
        }
    }

    /// Landscape: over the metrics card's corner, left of the speed chip. Portrait: above the metrics bar, so the
    /// trip numbers stay in view.
    private func confirmLayout(_ kind: DashConfirmKind, speed: DashSpeedChipLayout, metrics: DashMetricsLayout?) -> DashConfirmCardLayout {
        let t = Self.confirmTexts(kind, model)
        let maxRight: Double? = c.isLandscape ? min(c.safe.maxX - c.dp(DashDimens.fabLane), speed.frame.minX - c.dp(DashDimens.edge)) : nil
        let bottom: Double? = c.isLandscape ? nil : metrics.map { $0.frame.minY - c.dp(DashDimens.edge) }
        let (model, measurer) = (model, c.measurer)
        return DashLayout.confirmCard(c, question: t.question, consequence: t.consequence, keepLabel: t.keep, actLabel: t.act,
                                      maxRight: maxRight, bottom: bottom) { width, font in
            Self.fittedConsequence(kind, model, width: width, font: font, measurer: measurer)
        }
    }

    /// The consequence line at `width`: the place names lose words from their end («…») until the whole line
    /// fits the card's 2 lines, so its fixed part («Sigues en ruta libre.») always shows (review DASH-COPY-9).
    /// Whole words go first, the longest name first; a name that is one long word is cut last.
    static func fittedConsequence(_ kind: DashConfirmKind, _ model: DashModel, width: Double, font: DashFont,
                                  measurer: any DashTextMeasurer) -> String {
        let L = model.language
        let names = kind == .endRoute ? [routeName(model)] : [routeName(model), model.nav.preview?.place.name ?? ""]
        func text(_ n: [String]) -> String {
            kind == .endRoute ? DashStrings.endConsequence(n[0], L) : DashStrings.changeConsequence(from: n[0], to: n[1], L)
        }
        func fits(_ n: [String]) -> Bool {
            DashTextLayout.wrap(text(n), maxWidth: width, font: font, maxLines: 3, measurer: measurer).count <= 2
        }
        if fits(names) { return text(names) }
        let original = names.map { $0.split(separator: " ").map(String.init) }
        var words = original
        func shortened() -> [String] {
            names.indices.map { words[$0].count < original[$0].count ? words[$0].joined(separator: " ") + "\u{2026}" : names[$0] }
        }
        while !fits(shortened()) {
            let current = shortened()
            guard let i = names.indices.filter({ words[$0].count > 1 }).max(by: { current[$0].count < current[$1].count }) else { break }
            words[i].removeLast()
        }
        var fitted = shortened()
        var w = width
        while !fits(fitted), w > 1 { // one-word names still too long: cut them by width
            w *= 0.8
            fitted = fitted.map { DashTextLayout.truncate($0, maxWidth: w, font: font, measurer: measurer) }
        }
        return text(fitted)
    }

    /// The safe option is a plain secondary button; the action is red text on dark red (it acts only here).
    private mutating func drawConfirm(_ l: DashConfirmCardLayout, _ kind: DashConfirmKind) {
        let t = Self.confirmTexts(kind, model)
        card(l.frame, radius: c.dp(DashPalette.cardRadius))
        widget("confirm.card", l.frame, .blocker)
        text(t.question, l.questionRect, l.questionFont, DashPalette.primaryText, maxLines: l.questionLines)
        text(l.consequence, l.consequenceRect, l.consequenceFont, DashPalette.secondaryText, maxLines: l.consequenceLines)
        roundRect(l.keepRect, radius: c.dp(DashPalette.menuButtonRadius), fill: DashPalette.menuButtonFill,
                  stroke: DashPalette.menuButtonStroke, strokeWidth: c.dp(1))
        text(t.keep, l.keepRect, l.buttonFont, DashPalette.menuButtonText, align: .center)
        widget(DashFocusEngine.confirmKeepId, l.keepRect, .control(.closeSheets))
        roundRect(l.actRect, radius: c.dp(DashPalette.menuButtonRadius), fill: DashPalette.destructiveFill,
                  stroke: DashPalette.destructiveStroke, strokeWidth: c.dp(1))
        text(t.act, l.actRect, l.buttonFont, DashPalette.endText, align: .center)
        widget(DashFocusEngine.confirmActId, l.actRect, .control(kind == .endRoute ? .endNavigation : .go))
    }

    private mutating func drawFabs(_ fabs: [DashRect]) {
        let specs: [(String, DashIcon, DashIntent)] = [
            ("fab.recenter", .fabGps, .recenter), ("fab.zoomIn", .fabPlus, .zoomIn), ("fab.zoomOut", .fabMinus, .zoomOut),
            ("fab.compass", .fabCompass, .toggleCompass), ("fab.menu", .fabMenu, .openMenu),
        ]
        for (i, r) in fabs.enumerated() where i < specs.count {
            let (id, ic, intent) = specs[i]
            let isCompass = ic == .fabCompass
            let alpha = isCompass && !input.camera.headingUp ? DashPalette.compassNorthUpAlpha : 1
            func a(_ col: DashColor) -> DashColor { alpha >= 1 ? col : col.withAlpha(col.alpha * alpha) }
            circle(r, fill: a(DashPalette.fabFill), stroke: a(DashPalette.fabStroke), strokeWidth: c.dp(1))
            let iconSize = c.dp(DashDimens.fabIcon)
            let ir = DashRect(x: r.midX - iconSize / 2, y: r.midY - iconSize / 2, width: iconSize, height: iconSize)
            // Compass needle points north: rotated by −mapBearing.
            let rot = isCompass ? -input.camera.bearingDeg * .pi / 180 : 0
            icon(ic, in: ir, tint: DashPalette.fabIcon, alpha: alpha, rotation: rot)
            widget(id, r, .control(intent), circular: true)
        }
    }

    private struct ClockChip {
        var rect: DashRect
        var text: String
        var font: DashFont
    }

    private func clockChip(_ fabs: [DashRect]) -> ClockChip {
        let font = c.font(15, .bold, digits: true)
        let s = DashFormat.clock(model.date, timeZone: model.timeZone)
        return ClockChip(rect: DashLayout.clockChip(c, text: s, font: font, fabs: fabs), text: s, font: font)
    }

    private mutating func drawClock(_ clock: ClockChip) {
        let r = clock.rect
        card(r, radius: r.height / 2)
        text(clock.text, r, clock.font, DashPalette.primaryText, align: .center)
        widget("clock", r, .blocker)
    }

    // MARK: Apple Music (iOS addition)

    /// Artwork: placeholder (rounded fill + note icon at 40 %) → the registered raster (drawn by the
    /// renderer; an unknown id draws nothing) → night dim (never inverted).
    private mutating func drawArtwork(_ r: DashRect, radius: Double, artworkId: String?) {
        roundRect(r, radius: radius, fill: DashPalette.musicPlaceholder)
        let side = min(r.width, r.height) * 0.4
        icon(.musicNote, in: DashRect(x: r.midX - side / 2, y: r.midY - side / 2, width: side, height: side),
             tint: DashPalette.musicPlaceholderIcon)
        if let id = artworkId, !id.isEmpty { scene.commands.append(.image(id: id, rect: r, cornerRadius: radius)) }
        if model.isNight { roundRect(r, radius: radius, fill: DashPalette.musicNightDim) }
    }

    /// A round button with a white glyph at `glyph` × its diameter.
    private mutating func roundButton(_ r: DashRect, _ ic: DashIcon, glyph: Double, fill: DashColor, stroke: DashColor?) {
        circle(r, fill: fill, stroke: stroke, strokeWidth: stroke == nil ? 0 : c.dp(1))
        let s = r.width * glyph
        icon(ic, in: DashRect(x: r.midX - s / 2, y: r.midY - s / 2, width: s, height: s), tint: .white)
    }

    /// The now-playing tile (no text): artwork, outline, progress (known duration only; whole px),
    /// paused → dimmed with a ❚❚ badge. Tap / ★ → the Music sheet.
    private mutating func drawMusicTile(_ t: DashMusicTileLayout, _ music: DashNowPlaying) {
        let f = t.frame
        drawArtwork(f, radius: t.cornerRadius, artworkId: music.artworkId)
        roundRect(f, radius: t.cornerRadius, fill: nil, stroke: DashPalette.musicTileStroke, strokeWidth: c.dp(1))
        let bar = t.progressRect
        if let w = Self.musicFill(music, width: bar.width, now: input.musicNow) {
            roundRect(bar, radius: bar.height / 2, fill: DashPalette.musicTileBarTrack)
            if w > 0 {
                roundRect(DashRect(x: bar.minX, y: bar.minY, width: w, height: bar.height), radius: bar.height / 2,
                          fill: DashPalette.musicFill)
            }
        }
        if music.state == .paused {
            roundRect(f, radius: t.cornerRadius, fill: DashPalette.musicPausedDim)
            roundButton(t.badgeRect, .pause, glyph: 0.6, fill: DashPalette.musicBadge, stroke: nil)
        }
        // Over a route preview or the arrival card the tile only shows what plays (R3-FOCUS-2): it swallows
        // touches (no map gesture under a drawn control) and opens nothing.
        widget(DashFocusEngine.musicTileId, f, model.offersMusicSheet ? .control(.openMusic) : .blocker)
    }

    private var musicFocus: [String] = []

    /// The Music sheet is opaque: nothing of the map or its chrome is drawn under it. While
    /// navigating the nav card is drawn again on top (guidance is never hidden) and the layout keeps
    /// clear of it; then the speed chip, at its place on the map underneath (P0, D03: speed and limit
    /// stay visible; the sheet's text and controls keep clear of it).
    private mutating func buildMusicSheet(_ music: DashNowPlaying, navigating: Bool) {
        let navLayout = navigating ? DashLayout.navCard(c, cue: effectiveCue) : nil
        let metrics: DashMetricsLayout? = navigating ? Self.metricsLayout(model, c) : nil
        let speed = Self.speedChipLayout(model, c, metrics: metrics, bannerBottom: navLayout?.frame.maxY, covering: [])
        drawMusicSheet(music, reserved: navLayout?.frame, avoid: speed.frame)
        let navFrame = navigating ? drawNavCard() : nil
        drawSpeedChip(speed)
        scene.topChromeBottom = (navFrame?.maxY ?? c.safe.minY) + c.dp(8)
        scene.musicTimeKey = Self.musicTimeKey(music, sheetOpen: true, tileBarWidth: nil, now: input.musicNow)
        scene.focusOrder = focusOrder(pillVisible: false, tileVisible: false)
    }

    private mutating func drawMusicSheet(_ music: DashNowPlaying, reserved: DashRect?, avoid: DashRect?) {
        let l = DashLayout.musicSheet(c, music: music, language: L, reserved: reserved, avoid: avoid)
        fill(DashPath.rect(l.sheet), DashPalette.musicSheet)
        widget("music.sheet", l.sheet, .blocker)
        if l.arrangement != .textOnly { drawArtwork(l.artworkRect, radius: l.artworkRadius, artworkId: music.artworkId) }
        text(DashLayout.musicTitle(music, L), l.titleRect, l.titleFont, DashPalette.primaryText, align: .center,
             maxLines: l.titleMaxLines)
        if let r = l.artistRect { text(DashLayout.musicText(music.artist), r, l.artistFont, DashPalette.musicArtist, align: .center) }
        if let r = l.albumRect { text(DashLayout.musicText(music.album), r, l.albumFont, DashPalette.secondaryText, align: .center) }
        // Progress and times move in whole seconds only (one re-render per second while playing).
        let now = input.musicNow
        let elapsed = music.elapsedSeconds(at: now)
        if let bar = l.progressRect, let w = Self.musicFill(music, width: bar.width, now: now) {
            let radius = c.dp(3)
            roundRect(bar, radius: radius, fill: DashPalette.musicTrack)
            if w > 0 { roundRect(DashRect(x: bar.minX, y: bar.minY, width: w, height: bar.height), radius: radius, fill: DashPalette.musicFill) }
        }
        if let er = l.elapsedRect, let rr = l.remainingRect {
            text(DashMusicFormat.time(elapsed), er, l.timeFont, DashPalette.secondaryText)
            text(DashMusicFormat.remaining(music, at: now) ?? "", rr, l.timeFont, DashPalette.secondaryText, align: .right)
        }
        roundButton(l.previousRect, .skipPrevious, glyph: 0.5, fill: DashPalette.fabFill, stroke: DashPalette.fabStroke)
        roundButton(l.playPauseRect, music.state == .playing ? .pause : .play, glyph: 0.45, fill: DashPalette.blueAction, stroke: nil)
        roundButton(l.nextRect, .skipNext, glyph: 0.5, fill: DashPalette.fabFill, stroke: DashPalette.fabStroke)
        roundButton(l.closeRect, .close, glyph: 0.5, fill: DashPalette.musicClose, stroke: DashPalette.musicTileStroke)
        widget("music.previous", l.previousRect, .control(.musicPrevious), circular: true)
        widget(DashFocusEngine.musicPlayPauseId, l.playPauseRect, .control(.musicPlayPause), circular: true)
        widget("music.next", l.nextRect, .control(.musicNext), circular: true)
        widget("music.close", l.closeRect, .control(.closeSheets), circular: true)
        musicFocus = ["music.previous", DashFocusEngine.musicPlayPauseId, "music.next", "music.close"]
    }

    // MARK: Menu sheet

    static func menuIntent(_ id: String) -> DashIntent? {
        switch id {
        case "menu.end": return .endNavigation
        case "menu.park": return .parkHere
        case "menu.goHome": return .goHome
        case "menu.setHome": return .setHomeHere
        case "menu.recenter": return .recenter
        case "menu.recalc": return .recalc
        case "menu.record": return .toggleRecording
        case "menu.circuit": return .startCircuit
        case "menu.music": return .openMusic
        case "menu.follow": return .toggleFollow
        case "menu.heading": return .toggleHeadingUp
        case "menu.voice": return .toggleVoice
        case "menu.zoomOut": return .zoomOut
        case "menu.zoomIn": return .zoomIn
        case "menu.close": return .closeSheets
        case "menu.units.metric": return .setUnits(.metric)
        case "menu.units.imperial": return .setUnits(.imperial)
        case "menu.theme.auto": return .setTheme(.auto)
        case "menu.theme.day": return .setTheme(.day)
        case "menu.theme.night": return .setTheme(.night)
        case "menu.voiceSeg.on": return .setVoice(true)
        case "menu.voiceSeg.off": return .setVoice(false)
        case "menu.nextStop.on": return .setNextStop(true)
        case "menu.nextStop.off": return .setNextStop(false)
        case "menu.autoFinish.on": return .setAutoFinish(true)
        case "menu.autoFinish.off": return .setAutoFinish(false)
        case "menu.chrome.dark": return .setChrome(.dark)
        case "menu.chrome.black": return .setChrome(.black)
        case "menu.chrome.slate": return .setChrome(.slate)
        case "menu.chrome.forest": return .setChrome(.forest)
        case "menu.routeMode.fast": return .setRouteMode(.fast)
        case "menu.routeMode.fun": return .setRouteMode(.fun)
        case "menu.avoidTolls.on": return .setAvoidTolls(true)
        case "menu.avoidTolls.off": return .setAvoidTolls(false)
        case "menu.avoidHighways.on": return .setAvoidHighways(true)
        case "menu.avoidHighways.off": return .setAvoidHighways(false)
        default: return nil
        }
    }

    /// Menu focus order (input-controls.md §6.6) — settings segments optionally appended (iOS).
    /// "menu.music" (iOS addition) only exists while Apple Music shows on the dash, "menu.recalc" and
    /// "menu.end" only while a route runs: the order is filtered by the buttons actually drawn. P0 (D01):
    /// harmless items first — the menu opens on Recenter (the camera only) — and Reroute (it replaces the
    /// running route) and "End route…" (which opens the confirm card) last of the Ride section.
    static let menuFocusBase = ["menu.recenter", "menu.music", "menu.circuit", "menu.goHome", "menu.park", "menu.record",
                                "menu.setHome", "menu.recalc", "menu.end", "menu.follow", "menu.heading", "menu.voice",
                                "menu.zoomOut", "menu.zoomIn"]

    private func menuContent() -> DashMenuContent {
        DashMenuContent(language: L, follow: input.camera.follow, headingUp: input.camera.headingUp,
                        recording: model.recording, preferences: model.preferences, showsMusic: model.offersMusicSheet,
                        showsEnd: model.navigating)
    }

    /// Where the speed chip covers a vertical scroll viewport (P0, D03): the focused control is scrolled clear
    /// of it, and the content gets the room its last items need to get above a chip at the bottom.
    private func speedObstacle(_ viewport: DashRect, _ speed: DashRect) -> (obstacle: DashRect?, endPadding: Double) {
        guard viewport.intersects(speed) else { return (nil, 0) }
        let below = speed.midY > viewport.midY
        return (speed, below ? max(0, viewport.maxY - (speed.minY - c.dp(8))) : 0)
    }

    private mutating func drawMenu(speed: DashRect) {
        // Dimmer (tap → close)
        let full = DashRect(x: 0, y: 0, width: model.canvas.width, height: model.canvas.height)
        fill(DashPath.rect(full), DashPalette.dimmer)
        widget("dimmer", full, .control(.closeSheets))
        var layout = DashLayout.menu(c, content: menuContent())
        let panel = layout.panel
        let (obstacle, endPadding) = speedObstacle(panel, speed)
        if endPadding > 0 { layout = DashLayout.menu(c, content: menuContent(), endPadding: endPadding) }
        fill(DashPath.rect(DashRect(x: panel.minX, y: 0, width: panel.width, height: model.canvas.height)), DashPalette.menuSheet)
        widget("menu.panel", panel, .scrollArea, container: "menu")
        scene.containers["menu"] = DashScrollContainer(id: "menu", viewport: panel, axis: .vertical, contentLength: layout.contentHeight,
                                                       obstacle: obstacle)
        let scroll = min(max(0, input.menuScroll), layout.maxScroll)
        let dy = panel.minY - scroll
        scene.commands.append(.save)
        scene.commands.append(.clip(DashPath.rect(panel)))
        var focusIds: [String] = []
        for item in layout.items {
            let r = item.rect.offsetBy(dx: 0, dy: dy)
            let visible = r.maxY >= panel.minY && r.minY <= panel.maxY
            switch item.kind {
            case let .title(t):
                if visible { text(t, r, c.font(15, .bold), DashPalette.primaryText) }
            case let .label(t):
                if visible { text(t, r, c.font(13, .bold), DashPalette.primaryText, maxLines: 1) }
            case let .button(id, label, destructive, sp):
                if visible {
                    roundRect(r, radius: c.dp(DashPalette.menuButtonRadius), fill: DashPalette.menuButtonFill,
                              stroke: DashPalette.menuButtonStroke, strokeWidth: c.dp(1))
                    text(label, r.insetBy(dx: c.dp(8), dy: 0), c.font(sp, .medium),
                         destructive ? DashPalette.endText : DashPalette.menuButtonText, align: .center)
                }
                focusIds.append(id)
            case let .segment(id, label, selected):
                if visible {
                    roundRect(r, radius: c.dp(DashPalette.segmentRadius),
                              fill: selected ? DashPalette.segmentSelected : DashPalette.segmentUnselected)
                    text(label, r.insetBy(dx: c.dp(4), dy: 0), c.font(13, selected ? .semibold : .regular),
                         selected ? DashPalette.segmentSelectedText : DashPalette.segmentUnselectedText, align: .center, maxLines: 2)
                }
                focusIds.append(id)
            }
        }
        scene.commands.append(.restore)
        for item in layout.items {
            guard let id = item.id, let intent = Self.menuIntent(id) else { continue }
            widget(id, item.rect.offsetBy(dx: 0, dy: dy), .control(intent), container: "menu", clip: panel)
        }
        menuFocus = focusIds
    }

    private var menuFocus: [String] = []

    // MARK: Search sheet

    private var searchFocus: [String] = []

    private mutating func drawSearch(speed: DashRect) {
        let col = searchColors
        var l = DashLayout.searchSheet(c, search: model.search, places: model.places, language: L,
                                       chipScroll: input.searchChipScroll)
        let (obstacle, endPadding) = speedObstacle(l.listViewport, speed)
        if endPadding > 0 {
            l = DashLayout.searchSheet(c, search: model.search, places: model.places, language: L,
                                       chipScroll: input.searchChipScroll, endPadding: endPadding)
        }
        fill(DashPath.rect(l.sheet), col.sheetBackground)
        widget("search.sheet", l.sheet, .blocker)
        // Header
        text("←", l.backRect, l.backFont, col.pillText, align: .center)
        widget("search.back", l.backRect, .control(.closeSheets))
        roundRect(l.inputRect, radius: c.dp(DashPalette.searchPillRadius), fill: col.poiChipFill,
                  stroke: col.sheetDivider, strokeWidth: c.dp(1))
        let q = model.search.query
        if q.isEmpty {
            text(DashText.typeOnPhoneHint.localized(L), l.inputTextRect, l.inputFont, col.sheetHint)
        } else {
            text(q, l.inputTextRect, l.inputFont, col.sheetInput)
        }
        let iconSize = l.goRect.width - 2 * c.dp(9)
        icon(.search, in: DashRect(x: l.goRect.midX - iconSize / 2, y: l.goRect.midY - iconSize / 2, width: iconSize, height: iconSize),
             tint: col.pillIcon)
        widget("search.input", l.inputRect, .control(.typeOnPhone))
        // POI chips
        widget("search.chips", l.chipsViewport, .scrollArea, container: "search.chips")
        scene.containers["search.chips"] = DashScrollContainer(id: "search.chips", viewport: l.chipsViewport, axis: .horizontal,
                                                               contentLength: l.chipsContentWidth)
        scene.commands.append(.save)
        scene.commands.append(.clip(DashPath.rect(l.chipsViewport)))
        for (i, r) in l.chipRects.enumerated() where r.maxX >= l.chipsViewport.minX && r.minX <= l.chipsViewport.maxX {
            roundRect(r, radius: c.dp(DashPalette.poiChipRadius), fill: col.poiChipFill, stroke: col.poiChipStroke,
                      strokeWidth: c.dp(1))
            text(l.chipLabels[i], r, l.chipFont, col.poiChipText, align: .center)
        }
        scene.commands.append(.restore)
        var focus: [String] = []
        for (i, r) in l.chipRects.enumerated() where i < model.search.poiChips.count {
            let id = "search.chip.\(i)"
            widget(id, r, .control(.searchChip(model.search.poiChips[i])), container: "search.chips", clip: l.chipsViewport)
            focus.append(id)
        }
        // Status
        text(l.statusText, l.statusRect, l.statusFont, l.statusAccent ? col.pillAccent : col.sheetStatus,
             maxLines: 2)
        // List
        let vp = l.listViewport
        widget("search.list", vp, .scrollArea, container: "search.list")
        scene.containers["search.list"] = DashScrollContainer(id: "search.list", viewport: vp, axis: .vertical,
                                                              contentLength: l.listContentHeight, obstacle: obstacle)
        let scroll = min(max(0, input.searchListScroll), l.maxListScroll)
        let dy = vp.minY - scroll
        scene.commands.append(.save)
        scene.commands.append(.clip(DashPath.rect(vp)))
        for row in l.rows {
            let r = row.rect.offsetBy(dx: 0, dy: dy)
            guard r.maxY >= vp.minY && r.minY <= vp.maxY else { continue }
            fill(DashPath.rect(r), col.sheetRow)
            switch row.kind {
            case .typeOnPhone:
                text(DashText.typeOnPhoneRow.localized(L), row.nameRect.offsetBy(dx: 0, dy: dy), l.typeOnPhoneFont,
                     col.pillAccent)
            case let .place(place, _):
                text(place.name, row.nameRect.offsetBy(dx: 0, dy: dy), l.nameFont, col.sheetName)
                if let sr = row.subtitleRect {
                    text(row.subtitle, sr.offsetBy(dx: 0, dy: dy), l.subtitleFont, col.sheetSubtitle)
                }
                for a in row.actions {
                    let tint = a.id.hasSuffix(".delete") ? col.sheetDelete : col.sheetAction
                    text(a.label, a.rect.offsetBy(dx: 0, dy: dy), l.actionFont, tint, align: .center)
                }
            }
            fill(DashPath.rect(DashRect(x: r.minX, y: r.maxY, width: r.width, height: 1)), col.sheetDivider)
        }
        scene.commands.append(.restore)
        for row in l.rows {
            let r = row.rect.offsetBy(dx: 0, dy: dy)
            let intent: DashIntent
            switch row.kind {
            case .typeOnPhone: intent = .typeOnPhone
            case let .place(place, resultIndex):
                intent = resultIndex.map { .selectSearchResult($0) } ?? .previewPlace(place)
            }
            widget(row.id, r, .control(intent), container: "search.list", clip: vp)
            focus.append(row.id)
            if case let .place(place, _) = row.kind {
                for a in row.actions {
                    let ai: DashIntent
                    if a.id.hasSuffix(".save") { ai = .savePlace(place) } else if a.id.hasSuffix(".marker") { ai = .addMarkerFor(place) } else { ai = .deletePlace(place) }
                    widget(a.id, a.rect.offsetBy(dx: 0, dy: dy), .control(ai), container: "search.list", clip: vp)
                }
            }
        }
        focus.append("search.back")
        searchFocus = focus
    }

    // MARK: Focus order (top-most interactive layer first)

    private func focusOrder(pillVisible: Bool, tileVisible: Bool) -> [String] {
        switch input.sheet {
        case .menu:
            let base = Self.menuFocusBase.filter { menuFocus.contains($0) }
            if input.handlebarReachesSettings {
                let settings = menuFocus.filter { !Self.menuFocusBase.contains($0) && $0 != "menu.close" }
                return base + settings + ["menu.close"]
            }
            return base + ["menu.close"]
        case .search:
            return searchFocus
        case .music:
            return musicFocus
        case .confirm:
            // The safe option first (the default), the action one deliberate ▶ away (P0, D01).
            return input.confirm == nil ? [] : [DashFocusEngine.confirmKeepId, DashFocusEngine.confirmActId]
        case .none:
            break
        }
        if model.showsArrival {
            // P0 (D22): Done first — the default — then Park here (sets the parked spot) and Find parking.
            return ["arrive.done", "arrive.park", "arrive.find"]
        }
        if let p = model.nav.preview {
            var ids: [String] = []
            if !p.pinMode { ids += [DashFocusEngine.goId, "preview.circuit"] }
            ids += ["preview.cancel", "preview.save"]
            if p.pinMode { ids += ["preview.home", "preview.marker"] }
            if !p.pinMode { ids += p.chipLabels.indices.map { "preview.chip.\($0)" } }
            return ids
        }
        // The map. P0 (D01): no End here any more (Android's metrics card listed it first, the default while
        // navigating); Recenter is the default while navigating.
        var ids: [String] = []
        if pillVisible {
            ids += ["pill", "pill.circuit"]
            if input.lapReachableByHandlebar { ids.append("pill.lap") }
        }
        ids += ["fab.recenter", "fab.zoomIn", "fab.zoomOut", "fab.compass", "fab.menu"]
        // The now-playing tile closes the map list: one knob step back from the first item.
        if tileVisible { ids.append(DashFocusEngine.musicTileId) }
        return ids
    }
}
