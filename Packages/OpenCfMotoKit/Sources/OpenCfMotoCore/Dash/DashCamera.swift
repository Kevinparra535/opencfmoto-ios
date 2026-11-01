// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) DashMapController.kt (follow / zoomBy / zoomToRoute /
// offsetMeters), GpxNav.kt (zoomForSpeedKmh) and GpxDashUi.kt (followZoom, bumpFreePan, auto
// recenter) — docs/spec/navigation-dash.md §4.6, §4.9; input-controls.md §6.4.
//
// Value type: the dash UI controller owns one and mutates it under its lock.

import Foundation

/// The bike map camera: centre, fractional zoom, rotation, follow / heading-up / speed-zoom flags
/// and the 12 s free-pan auto-recenter.
///
/// This is the TARGET camera: every policy below jumps, like osmdroid. `DashUIController` eases
/// what it draws from the previous picture towards it after each follow update
/// (`DashUIController.Options.followEaseDuration`, DashFollowEase.swift).
public struct DashCamera: Hashable, Sendable {
    /// Bike zoom range (DashMapController: minZoomLevel 5, maxZoomLevel 20).
    public static let minZoom = 5.0
    public static let maxZoom = 20.0
    /// MapView initial zoom.
    public static let initialZoom = 16.0
    /// Follow zoom on the bike after any manual zoom (`speedZoom == false`).
    public static let fixedFollowZoom = 17.2
    /// The follow camera re-applies the zoom only when it differs by at least this much.
    public static let zoomHysteresis = 0.35
    /// Free pan → follow again after this delay (bumpFreePan).
    public static let autoRecenterDelay: TimeInterval = 12
    /// Bike offset on the speed ladder: min(phone zoom + 1.1, 18.6).
    public static let bikeZoomOffset = 1.1
    public static let bikeZoomCap = 18.6

    /// Geo point at the screen anchor; nil until the map has been positioned once.
    public var center: GeoPoint?
    public var zoom: Double
    /// Map rotation (direction pointing up). 0 = north-up.
    public var bearingDeg: Double
    /// Camera follows the rider on every update.
    public var follow: Bool
    /// Map rotated so travel points up (else north-up).
    public var headingUp: Bool
    /// Follow zoom from the speed ladder (false after a manual zoom → fixed 17.2).
    public var speedZoom: Bool
    /// Monotonic time at which a free pan returns to follow.
    public var autoRecenterAt: TimeInterval?
    /// `lastMapBearing` (GpxDashUi): the last bearing used for the map (fallback of bestBearing).
    public var lastMapBearing: Double

    public init(center: GeoPoint? = nil, zoom: Double = DashCamera.initialZoom, bearingDeg: Double = 0, follow: Bool = true,
                headingUp: Bool = true, speedZoom: Bool = true) {
        self.center = center
        self.zoom = zoom
        self.bearingDeg = bearingDeg
        self.follow = follow
        self.headingUp = headingUp
        self.speedZoom = speedZoom
        self.autoRecenterAt = nil
        self.lastMapBearing = 0
    }

    public var isPositioned: Bool { center != nil }

    /// Same centre, zoom and rotation (flags and timers ignored).
    public func hasSameGeometry(as o: DashCamera) -> Bool {
        center == o.center && zoom == o.zoom && bearingDeg == o.bearingDeg
    }

    // MARK: Ladders

    /// `GpxNav.zoomForSpeedKmh` (phone ladder): <8 → 17.8, <20 → 17.0, <35 → 16.2, <55 → 15.4,
    /// <80 → 14.6, <110 → 13.8, else 13.0.
    public static func zoomForSpeedKmh(_ v: Double) -> Double {
        let f = Float(v)
        switch f {
        case ..<8: return 17.8
        case ..<20: return 17.0
        case ..<35: return 16.2
        case ..<55: return 15.4
        case ..<80: return 14.6
        case ..<110: return 13.8
        default: return 13.0
        }
    }

    /// Bike follow zoom on the speed ladder: min(zoomForSpeedKmh + 1.1, 18.6).
    public static func bikeFollowZoom(speedKmh: Double) -> Double {
        min(zoomForSpeedKmh(speedKmh) + bikeZoomOffset, bikeZoomCap)
    }

    /// The follow zoom to request now: speed ladder, or the fixed 17.2 after a manual zoom.
    public func targetFollowZoom(speedKmh: Double) -> Double {
        speedZoom ? Self.bikeFollowZoom(speedKmh: speedKmh) : Self.fixedFollowZoom
    }

    /// Look-ahead distance (moving + heading-up only): zoom ≥ 17 → 40 m, ≥ 15.5 → 70 m,
    /// ≥ 14 → 110 m, else 160 m.
    public static func lookAheadMeters(zoom: Double, moving: Bool, headingUp: Bool) -> Double {
        guard moving, headingUp else { return 0 }
        if zoom >= 17 { return 40 }
        if zoom >= 15.5 { return 70 }
        if zoom >= 14 { return 110 }
        return 160
    }

    // MARK: Follow

    /// `DashMapController.follow`: heading-up rotates the map by −bearing (north-up: 0), the centre
    /// is pushed `lookAheadMeters` ahead along the bearing (so the puck sits below the anchor), and
    /// the zoom is re-applied only when it differs by ≥ 0.35. The camera jumps (osmdroid); the
    /// controller animates the drawn picture towards it.
    /// - Parameter maxLookAheadPx: iOS fix (navigation-dash.md §4.9 / R9) — caps the look-ahead in
    ///   screen pixels so the puck stays above the bottom cards; nil = Android parity.
    public mutating func applyFollow(me: GeoPoint, bearingDeg bearing: Double, targetZoom: Double, moving: Bool,
                                     maxLookAheadPx: Double? = nil, tileSize: Double = 256) {
        bearingDeg = headingUp ? bearing : 0
        if !isPositioned || abs(zoom - targetZoom) >= Self.zoomHysteresis {
            zoom = min(Self.maxZoom, max(Self.minZoom, targetZoom))
        }
        var ahead = Self.lookAheadMeters(zoom: targetZoom, moving: moving, headingUp: headingUp)
        if let cap = maxLookAheadPx, ahead > 0 {
            let mpp = MapProjection.metersPerPixel(latitude: me.lat, zoom: zoom, tileSize: tileSize)
            ahead = min(ahead, max(0, cap) * mpp)
        }
        center = ahead > 1 ? DashGeo.offset(me, bearingDeg: bearing, meters: ahead) : me
    }

    /// `setCenter(lat, lon, zoom)`.
    public mutating func setCenter(_ p: GeoPoint, zoom z: Double) {
        center = p
        zoom = min(Self.maxZoom, max(Self.minZoom, z))
    }

    /// `zoomBy(delta)` about the anchor, clamped to 5…20.
    public mutating func zoomBy(_ delta: Double) {
        zoom = min(Self.maxZoom, max(Self.minZoom, zoom + delta))
    }

    /// `resetNorth()`.
    public mutating func resetNorth() { bearingDeg = 0 }

    // MARK: Free pan

    /// `bumpFreePan()`: follow off, auto-recenter after 12 s.
    public mutating func bumpFreePan(now: TimeInterval) {
        follow = false
        autoRecenterAt = now + Self.autoRecenterDelay
    }

    public mutating func cancelAutoRecenter() { autoRecenterAt = nil }

    /// Fires the pending auto-recenter (follow = true) when due. Returns true when it fired.
    @discardableResult
    public mutating func advance(now: TimeInterval) -> Bool {
        guard let at = autoRecenterAt, now >= at else { return false }
        autoRecenterAt = nil
        if !follow {
            follow = true
            return true
        }
        return false
    }

    // MARK: Projection, gestures, overview

    /// The projection for a viewport (nil until positioned).
    public func projection(viewport: DashSize, anchor: DashPoint? = nil, tileSize: Double = 256) -> MapProjection? {
        guard let c = center else { return nil }
        return MapProjection(center: c, zoom: zoom, bearingDeg: bearingDeg, viewport: viewport, anchor: anchor, tileSize: tileSize)
    }

    /// Pans the map content by a screen delta (the content follows the finger).
    public mutating func pan(byScreenDelta d: DashPoint, viewport: DashSize, anchor: DashPoint? = nil, tileSize: Double = 256) {
        guard let proj = projection(viewport: viewport, anchor: anchor, tileSize: tileSize) else { return }
        let r = DashTransform.rotation(bearingDeg * .pi / 180) // screen delta → map-local delta
        let m = r.apply(d)
        let cw = proj.centerWorld
        center = MapProjection.geoPoint(world: DashPoint(cw.x - m.x, cw.y - m.y), zoom: zoom, tileSize: tileSize)
    }

    /// Sets the zoom keeping the geo point under `screenPoint` fixed (pinch focal / double tap).
    public mutating func setZoom(_ newZoom: Double, keeping screenPoint: DashPoint, viewport: DashSize,
                                 anchor: DashPoint? = nil, tileSize: Double = 256) {
        let z = min(Self.maxZoom, max(Self.minZoom, newZoom))
        guard let proj = projection(viewport: viewport, anchor: anchor, tileSize: tileSize) else { zoom = z; return }
        let g = proj.geoPoint(atScreen: screenPoint)
        let gw = MapProjection.worldPoint(g, zoom: z, tileSize: tileSize)
        let r = DashTransform.rotation(bearingDeg * .pi / 180)
        let off = r.apply(DashPoint(screenPoint.x - proj.anchor.x, screenPoint.y - proj.anchor.y))
        zoom = z
        center = MapProjection.geoPoint(world: DashPoint(gw.x - off.x, gw.y - off.y), zoom: z, tileSize: tileSize)
    }

    /// Overview: north-up, fit `points` into `rect` (osmdroid zoomToBoundingBox semantics; a
    /// single point is centred at `singlePointZoom`).
    public mutating func fit(_ points: [GeoPoint], in rect: DashRect, viewport: DashSize, anchor: DashPoint? = nil,
                             tileSize: Double = 256, singlePointZoom: Double = 16) {
        guard let p = MapProjection.fitting(points, in: rect, viewport: viewport, anchor: anchor, tileSize: tileSize,
                                            minZoom: Self.minZoom, maxZoom: Self.maxZoom,
                                            singlePointZoom: singlePointZoom) else { return }
        center = p.center
        zoom = p.zoom
        bearingDeg = 0
    }
}
