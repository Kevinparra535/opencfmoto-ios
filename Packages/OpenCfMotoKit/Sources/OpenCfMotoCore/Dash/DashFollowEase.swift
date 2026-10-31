// SPDX-License-Identifier: AGPL-3.0-or-later
// iOS addition — the smooth follow camera (docs/spec/navigation-dash.md §4.9 and §15.3: "consider
// interpolating the camera between 0.8 s fixes"). Android's osmdroid bike map jumps to every fix;
// its MapLibre phone map eases the camera over 280 ms (MapLibreDashController.follow →
// easeCamera(…, 280)). Here the map the dash UI draws — camera centre (incl. the look-ahead),
// heading-up bearing, speed zoom AND the rider puck — glides from what is on screen to the new
// targets with an ease-out curve. `DashUIController.Options.followEaseDuration = 0` restores the
// jump (osmdroid parity).
//
// Pure value types evaluated with the injected monotonic `now` (no wall clock). The controller owns
// one `DashFollowEase` under its lock; the camera it stores (`DashCamera`) is always the target.

import Foundation

/// Deterministic easing curve and bearing helpers.
public enum DashEasing {
    /// Cubic ease-out `1 − (1 − t)³` (fast start, soft landing), clamped to 0…1: 0 → 0, 1 → 1.
    public static func easeOut(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        guard t < 1 else { return 1 }
        let u = 1 - t
        return 1 - u * u * u
    }

    /// `a + (b − a)·k`.
    public static func lerp(_ a: Double, _ b: Double, _ k: Double) -> Double { a + (b - a) * k }

    /// Bearing in 0..<360.
    public static func normalizedBearing(_ deg: Double) -> Double {
        guard deg.isFinite else { return 0 }
        var r = deg.truncatingRemainder(dividingBy: 360)
        if r < 0 { r += 360 }
        return r >= 360 ? r - 360 : r
    }

    /// Signed shortest turn from `a` to `b` in degrees, in (−180, 180] (359° → 1° is +2°).
    public static func shortestTurnDeg(from a: Double, to b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d <= -180 { d += 360 }
        return d
    }

    /// `a` turned a fraction `k` of the shortest way towards `b`, normalised to 0..<360.
    public static func interpolateBearing(_ a: Double, _ b: Double, _ k: Double) -> Double {
        normalizedBearing(a + shortestTurnDeg(from: a, to: b) * k)
    }
}

/// What the dash map layer draws: the camera geometry and the rider puck.
struct DashMapView: Equatable, Sendable {
    var center: GeoPoint
    var zoom: Double
    var bearingDeg: Double
    var puck: GeoPoint?
    var puckBearingDeg: Double

    func hasSameCamera(as o: DashMapView) -> Bool { center == o.center && zoom == o.zoom && bearingDeg == o.bearingDeg }

    /// Screen offset (px, x right / y down) of `p` from the map anchor in this view.
    func screenOffset(of p: GeoPoint, tileSize: Double) -> DashPoint {
        MapProjection(center: center, zoom: zoom, bearingDeg: bearingDeg, viewport: DashSize(width: 0, height: 0),
                      anchor: .zero, tileSize: tileSize).screenPoint(p)
    }
}

/// One ease of the drawn map from `from` (what was on screen when the target changed) to `to`.
///
/// Follow updates (`movesCamera`) interpolate the puck on the Mercator plane, the zoom linearly,
/// the bearings along the shortest arc and the puck's SCREEN offset from the anchor linearly; the
/// drawn camera centre is derived from those (`MapProjection.center(placing:atScreenOffset:…)`), so
/// in heading-up with look-ahead the puck never leaves the vertical centre line and the map never
/// slides sideways under it. Without `movesCamera` only the puck (position + bearing) glides and
/// the controller's camera is drawn as it is (free pan, preview overview, a gesture in progress).
struct DashFollowEase: Equatable, Sendable {
    let from: DashMapView
    let to: DashMapView
    let duration: TimeInterval
    let tileSize: Double
    var movesCamera: Bool
    /// Puck offsets from the anchor at both ends (screen px).
    let offsetFrom: DashPoint
    let offsetTo: DashPoint
    /// Monotonic time of the first evaluation (the ease starts when it is first drawn).
    private(set) var start: TimeInterval?
    /// Linear time fraction 0…1; never decreases (a slightly older `now` from another caller does
    /// not rewind the animation).
    private(set) var progress: Double = 0

    /// nil when there is nothing to animate (no duration, no puck at either end).
    init?(from: DashMapView, to: DashMapView, duration: TimeInterval, tileSize: Double, movesCamera: Bool) {
        guard duration > 0, duration.isFinite, let pf = from.puck, let pt = to.puck else { return nil }
        self.from = from
        self.to = to
        self.duration = duration
        self.tileSize = tileSize
        self.movesCamera = movesCamera
        offsetFrom = from.screenOffset(of: pf, tileSize: tileSize)
        offsetTo = to.screenOffset(of: pt, tileSize: tileSize)
    }

    /// Advances the clock to `now` (the first call starts it). Returns false once the ease is over
    /// (exactly at `start + duration`): the caller then draws the targets themselves.
    mutating func advance(to now: TimeInterval) -> Bool {
        let t0 = start ?? now
        start = t0
        let elapsed = now - t0
        if elapsed >= duration - 1e-9 {
            progress = 1
            return false
        }
        progress = max(progress, elapsed / duration)
        return true
    }

    /// The drawn view at the current progress. `base` supplies the camera geometry when the camera
    /// is not animated (the controller's camera, i.e. the target view).
    func view(base: DashMapView) -> DashMapView {
        let k = DashEasing.easeOut(progress)
        var v = movesCamera ? from : base
        if k <= 0 || k >= 1 { // exact end points
            let end = k <= 0 ? from : to
            if movesCamera { v = end }
            v.puck = end.puck
            v.puckBearingDeg = end.puckBearingDeg
            return v
        }
        guard let pf = from.puck, let pt = to.puck else { return to }
        let puck = MapProjection.interpolate(pf, pt, fraction: k)
        v.puck = puck
        v.puckBearingDeg = DashEasing.interpolateBearing(from.puckBearingDeg, to.puckBearingDeg, k)
        if movesCamera {
            v.zoom = DashEasing.lerp(from.zoom, to.zoom, k)
            v.bearingDeg = DashEasing.interpolateBearing(from.bearingDeg, to.bearingDeg, k)
            let offset = DashPoint(DashEasing.lerp(offsetFrom.x, offsetTo.x, k), DashEasing.lerp(offsetFrom.y, offsetTo.y, k))
            v.center = MapProjection.center(placing: puck, atScreenOffset: offset, zoom: v.zoom, bearingDeg: v.bearingDeg,
                                            tileSize: tileSize)
        }
        return v
    }
}
