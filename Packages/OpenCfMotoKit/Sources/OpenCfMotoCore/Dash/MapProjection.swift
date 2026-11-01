// SPDX-License-Identifier: AGPL-3.0-or-later
// Web Mercator (EPSG:3857) projection for the dash raster map: fractional zoom with 256-px slippy
// tiles (osmdroid-style; `tileSize = 256 × density` reproduces `isTilesScaledToDpi = true`),
// heading-up rotation about an anchor, geo ↔ canvas both ways, metres per pixel, the set of tiles
// covering a rotated viewport (integer tile zoom = floor(zoom), drawn scaled by 2^(zoom − floor),
// over-zoom past the source's max zoom), "fit these points into this rect" (overview), and the
// camera centre / Mercator interpolation helpers of the follow ease (DashFollowEase.swift).
//
// Coordinate spaces:
// - world px: Mercator pixels at `zoom` (x east, y south, origin = top-left of the world).
// - map-local px: world px minus the camera centre's world px (unrotated, small numbers).
// - screen px: dash canvas pixels (top-left origin) = rotation(−bearing) · map-local + anchor.

import Foundation

/// One raster tile to draw: slippy z/x/y (x wrapped into 0..<2^z) and its rect in map-local px.
public struct DashMapTile: Hashable, Sendable {
    public var z: Int
    public var x: Int
    public var y: Int
    public var rect: DashRect
    public init(z: Int, x: Int, y: Int, rect: DashRect) { self.z = z; self.x = x; self.y = y; self.rect = rect }
}

public struct MapProjection: Hashable, Sendable {
    /// WGS-84 equatorial circumference used by Web Mercator (2π·6 378 137 m).
    public static let earthCircumference = 2 * Double.pi * 6_378_137.0
    /// Mercator latitude limit.
    public static let maxLatitude = 85.051_128_779_806_59
    /// Highest zoom served by tile.openstreetmap.org (osmdroid MAPNIK 0–19); beyond it tiles are over-zoomed.
    public static let defaultMaxTileZoom = 19

    /// Geo point drawn at `anchor`.
    public var center: GeoPoint
    /// Fractional zoom (5…20 on the bike).
    public var zoom: Double
    /// Map rotation: the compass direction pointing UP on screen (heading-up = travel bearing,
    /// north-up = 0). The map is rotated by −bearing.
    public var bearingDeg: Double
    public var viewport: DashSize
    /// Screen point of `center` (default: viewport centre).
    public var anchor: DashPoint
    /// Pixel size of one tile at an integer zoom (256 × density).
    public var tileSize: Double

    public init(center: GeoPoint, zoom: Double, bearingDeg: Double = 0, viewport: DashSize, anchor: DashPoint? = nil,
                tileSize: Double = 256) {
        self.center = center
        self.zoom = zoom
        self.bearingDeg = bearingDeg
        self.viewport = viewport
        self.anchor = anchor ?? DashPoint(viewport.width / 2, viewport.height / 2)
        self.tileSize = tileSize
    }

    // MARK: Mercator maths

    /// World size in px at `zoom`.
    public static func worldSize(zoom: Double, tileSize: Double = 256) -> Double { tileSize * pow(2, zoom) }

    public var worldSize: Double { Self.worldSize(zoom: zoom, tileSize: tileSize) }

    /// Mercator world pixel of `p` at `zoom` (latitude clamped to ±85.0511°).
    public static func worldPoint(_ p: GeoPoint, zoom: Double, tileSize: Double = 256) -> DashPoint {
        let size = worldSize(zoom: zoom, tileSize: tileSize)
        let lat = min(max(p.lat, -maxLatitude), maxLatitude)
        let s = sin(lat * .pi / 180)
        let x = (p.lon + 180) / 360 * size
        let y = (0.5 - log((1 + s) / (1 - s)) / (4 * .pi)) * size
        return DashPoint(x, y)
    }

    /// Inverse of `worldPoint` (longitude normalised to −180…180).
    public static func geoPoint(world w: DashPoint, zoom: Double, tileSize: Double = 256) -> GeoPoint {
        let size = worldSize(zoom: zoom, tileSize: tileSize)
        var lon = w.x / size * 360 - 180
        lon = (lon + 180).truncatingRemainder(dividingBy: 360)
        if lon < 0 { lon += 360 }
        lon -= 180
        let n = Double.pi - 2 * Double.pi * w.y / size
        let lat = atan(sinh(n)) * 180 / .pi
        return GeoPoint(lat: lat, lon: lon)
    }

    /// Ground resolution (m/px) at a latitude and zoom.
    public static func metersPerPixel(latitude: Double, zoom: Double, tileSize: Double = 256) -> Double {
        earthCircumference * cos(latitude * .pi / 180) / worldSize(zoom: zoom, tileSize: tileSize)
    }

    /// Ground resolution at the camera centre.
    public var metersPerPixel: Double { Self.metersPerPixel(latitude: center.lat, zoom: zoom, tileSize: tileSize) }

    /// Integer tile zoom used for drawing: floor(zoom) clamped to 0…maxTileZoom (0 for a
    /// non-finite zoom — never traps).
    public static func tileZoom(for zoom: Double, maxTileZoom: Int = defaultMaxTileZoom) -> Int {
        let top = max(0, maxTileZoom)
        guard zoom.isFinite else { return 0 }
        let z = min(Double(top), max(0, (zoom + 1e-9).rounded(.down)))
        return Int(z)
    }

    /// A geo point the projection maths can use: finite, latitude in −90…90, longitude in −180…180.
    /// Route and place coordinates come from untrusted files (GPX, map-data imports): anything else
    /// is skipped by `fitting` and makes `visibleTiles` empty instead of trapping (SEC-1).
    public static func isUsable(_ p: GeoPoint) -> Bool {
        p.lat.isFinite && p.lon.isFinite && (-90 ... 90).contains(p.lat) && (-180 ... 180).contains(p.lon)
    }

    /// Largest tile count `visibleTiles` returns (a dash canvas needs a few dozen).
    static let maxVisibleTiles = 4_096

    // MARK: Transforms

    public var centerWorld: DashPoint { Self.worldPoint(center, zoom: zoom, tileSize: tileSize) }

    /// map-local px → screen px (rotate by −bearing about the centre, then move to the anchor).
    public var mapToScreen: DashTransform {
        DashTransform.rotation(-bearingDeg * .pi / 180).concatenating(.translation(anchor.x, anchor.y))
    }

    /// screen px → map-local px.
    public var screenToMap: DashTransform {
        DashTransform.translation(-anchor.x, -anchor.y).concatenating(.rotation(bearingDeg * .pi / 180))
    }

    /// Map-local px of `p` (the world copy closest to the centre, so routes near the antimeridian stay continuous).
    public func mapLocal(_ p: GeoPoint) -> DashPoint {
        let w = Self.worldPoint(p, zoom: zoom, tileSize: tileSize)
        let c = centerWorld
        var dx = w.x - c.x
        let size = worldSize
        if dx > size / 2 { dx -= size } else if dx < -size / 2 { dx += size }
        return DashPoint(dx, w.y - c.y)
    }

    /// Screen px of a geo point.
    public func screenPoint(_ p: GeoPoint) -> DashPoint { mapToScreen.apply(mapLocal(p)) }

    /// Geo point under a screen px.
    public func geoPoint(atScreen s: DashPoint) -> GeoPoint {
        let m = screenToMap.apply(s)
        let c = centerWorld
        return Self.geoPoint(world: DashPoint(c.x + m.x, c.y + m.y), zoom: zoom, tileSize: tileSize)
    }

    /// The camera centre that draws `p` at `offset` screen px from the anchor (x right, y down)
    /// for a zoom and map rotation — the inverse of `screenPoint(p) − anchor`. The animated follow
    /// camera uses it to keep the rider puck exactly where the follow policy puts it.
    public static func center(placing p: GeoPoint, atScreenOffset offset: DashPoint, zoom: Double, bearingDeg: Double,
                              tileSize: Double = 256) -> GeoPoint {
        let w = worldPoint(p, zoom: zoom, tileSize: tileSize)
        let m = DashTransform.rotation(bearingDeg * .pi / 180).apply(offset) // screen axes → map-local
        return geoPoint(world: DashPoint(w.x - m.x, w.y - m.y), zoom: zoom, tileSize: tileSize)
    }

    /// The point a `fraction` of the way from `a` to `b` on the Web Mercator plane (a straight line
    /// on the map, the short way across the antimeridian). 0 → `a` and 1 → `b` exactly.
    public static func interpolate(_ a: GeoPoint, _ b: GeoPoint, fraction k: Double) -> GeoPoint {
        if k <= 0 || a == b { return a }
        if k >= 1 { return b }
        let wa = worldPoint(a, zoom: 0, tileSize: 1), wb = worldPoint(b, zoom: 0, tileSize: 1) // 0…1 coordinates
        var dx = wb.x - wa.x
        if dx > 0.5 { dx -= 1 } else if dx < -0.5 { dx += 1 }
        return geoPoint(world: DashPoint(wa.x + dx * k, wa.y + (wb.y - wa.y) * k), zoom: 0, tileSize: 1)
    }

    // MARK: Tiles

    /// Tiles (at `tileZoom`) covering the whole rotated viewport (plus `overscan` px), sorted by
    /// row then column. Rows outside the world are skipped; columns wrap around the antimeridian.
    /// Empty (never a trap) for a non-finite or absurd camera (centre, zoom, bearing, size). The
    /// centre may sit slightly past ±180° (a look-ahead offset near the antimeridian): columns wrap.
    public func visibleTiles(maxTileZoom: Int = defaultMaxTileZoom, overscan: Double = 0) -> [DashMapTile] {
        guard center.lat.isFinite, center.lon.isFinite, zoom.isFinite, bearingDeg.isFinite, tileSize.isFinite,
              viewport.width.isFinite, viewport.height.isFinite, anchor.x.isFinite, anchor.y.isFinite else { return [] }
        let tz = Self.tileZoom(for: zoom, maxTileZoom: maxTileZoom)
        let tilePx = tileSize * pow(2, zoom - Double(tz))
        guard tilePx.isFinite, tilePx > 0, viewport.width > 0, viewport.height > 0 else { return [] }
        let inv = screenToMap
        let o = overscan.isFinite ? overscan : 0
        let corners = [DashPoint(-o, -o), DashPoint(viewport.width + o, -o),
                       DashPoint(viewport.width + o, viewport.height + o), DashPoint(-o, viewport.height + o)].map(inv.apply)
        let minX = corners.map(\.x).min()!, maxX = corners.map(\.x).max()!
        let minY = corners.map(\.y).min()!, maxY = corners.map(\.y).max()!
        let c = centerWorld
        let n = 1 << tz
        // Tile indices as doubles first: only convert values that fit an Int comfortably.
        let fx0 = ((c.x + minX) / tilePx).rounded(.down)
        let fx1 = ((c.x + maxX) / tilePx - 1e-9).rounded(.down)
        let fy0 = ((c.y + minY) / tilePx).rounded(.down)
        let fy1 = ((c.y + maxY) / tilePx - 1e-9).rounded(.down)
        let limit = Double(1 << 40)
        guard [fx0, fx1, fy0, fy1].allSatisfy({ $0.isFinite && abs($0) < limit }) else { return [] }
        let tx0 = Int(fx0), tx1 = Int(fx1)
        let ty0 = max(0, Int(fy0))
        let ty1 = min(n - 1, Int(fy1))
        guard ty0 <= ty1, tx0 <= tx1 else { return [] }
        let columns = tx1 - tx0 + 1, rows = ty1 - ty0 + 1 // each < 2^41: the checks below cannot overflow
        guard columns <= Self.maxVisibleTiles, rows <= Self.maxVisibleTiles, columns * rows <= Self.maxVisibleTiles else { return [] }
        var out: [DashMapTile] = []
        out.reserveCapacity((ty1 - ty0 + 1) * (tx1 - tx0 + 1))
        for ty in ty0 ... ty1 {
            for tx in tx0 ... tx1 {
                let wrapped = ((tx % n) + n) % n
                let rect = DashRect(x: Double(tx) * tilePx - c.x, y: Double(ty) * tilePx - c.y, width: tilePx, height: tilePx)
                out.append(DashMapTile(z: tz, x: wrapped, y: ty, rect: rect))
            }
        }
        return out
    }

    // MARK: Fitting

    /// Zoom (and centre) that fits `points` inside `rect` (screen px, north-up), like osmdroid
    /// `zoomToBoundingBox`: zoom = min(lon zoom, lat zoom) clamped to minZoom…maxZoom, the box
    /// centre (Mercator midpoint) placed at the rect centre. A single point (or zero span) is
    /// centred at `singlePointZoom`. Returns nil for no points or an empty rect. Unusable points
    /// (`isUsable`: NaN, ±∞, out of range — from a corrupt GPX or import) are ignored.
    public static func fitting(_ allPoints: [GeoPoint], in rect: DashRect, viewport: DashSize, anchor: DashPoint? = nil,
                               tileSize: Double = 256, minZoom: Double = 5, maxZoom: Double = 20,
                               singlePointZoom: Double = 16) -> MapProjection? {
        let points = allPoints.filter(isUsable)
        guard !points.isEmpty, rect.width > 0, rect.height > 0, rect.width.isFinite, rect.height.isFinite,
              rect.midX.isFinite, rect.midY.isFinite, tileSize.isFinite, tileSize > 0 else { return nil }
        let w0 = points.map { worldPoint($0, zoom: 0, tileSize: 1) } // 0…1 coordinates
        let minX = w0.map(\.x).min()!, maxX = w0.map(\.x).max()!
        let minY = w0.map(\.y).min()!, maxY = w0.map(\.y).max()!
        let spanX = maxX - minX, spanY = maxY - minY
        var zoom: Double
        if spanX <= 0 && spanY <= 0 {
            zoom = singlePointZoom
        } else {
            let zx = spanX > 0 ? log2(rect.width / (spanX * tileSize)) : Double.infinity
            let zy = spanY > 0 ? log2(rect.height / (spanY * tileSize)) : Double.infinity
            zoom = min(zx, zy)
        }
        zoom = min(maxZoom, max(minZoom, zoom))
        guard zoom.isFinite else { return nil }
        let anchorPt = anchor ?? DashPoint(viewport.width / 2, viewport.height / 2)
        let size = worldSize(zoom: zoom, tileSize: tileSize)
        let boxCentre = DashPoint((minX + maxX) / 2 * size, (minY + maxY) / 2 * size)
        // North-up: screen offset == map-local offset.
        let centreWorld = DashPoint(boxCentre.x - (rect.midX - anchorPt.x), boxCentre.y - (rect.midY - anchorPt.y))
        let centre = geoPoint(world: centreWorld, zoom: zoom, tileSize: tileSize)
        return MapProjection(center: centre, zoom: zoom, bearingDeg: 0, viewport: viewport, anchor: anchorPt, tileSize: tileSize)
    }
}

/// Spherical helpers used by the camera (GpxNav.kt:353-379 conventions).
public enum DashGeo {
    /// Haversine distance (R = 6 371 000 m).
    public static func distanceM(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let r = 6_371_000.0
        let p1 = a.lat * .pi / 180, p2 = b.lat * .pi / 180
        let dp = (b.lat - a.lat) * .pi / 180, dl = (b.lon - a.lon) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, h.squareRoot()))
    }

    /// Initial bearing a → b in degrees 0…360 (`bearingDeg`).
    public static func bearingDeg(from a: GeoPoint, to b: GeoPoint) -> Double {
        let p1 = a.lat * .pi / 180, p2 = b.lat * .pi / 180
        let dl = (b.lon - a.lon) * .pi / 180
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    /// `offsetMeters` (DashMapController.kt:402-407): dLat = m·cos(b)/111 320,
    /// dLon = m·sin(b)/(111 320·max(cos(lat), 0.2)).
    public static func offset(_ p: GeoPoint, bearingDeg: Double, meters: Double) -> GeoPoint {
        let br = bearingDeg * .pi / 180
        let dLat = meters * cos(br) / 111_320.0
        let dLon = meters * sin(br) / (111_320.0 * max(cos(p.lat * .pi / 180), 0.2))
        return GeoPoint(lat: p.lat + dLat, lon: p.lon + dLon)
    }
}
