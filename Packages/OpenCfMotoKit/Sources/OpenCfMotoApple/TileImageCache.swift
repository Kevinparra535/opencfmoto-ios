// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) GpxOsmdroid.kt + CellularTileDownloader.kt
// Raster map tiles for the dash map (docs/spec/navigation-dash.md §10.1, §10.3, §9) — (osmdroid MAPNIK
// source: {z}/{x}/{y}.png, 256-px tiles, at most 2 download threads, 90-day expiry, 512 MiB disk
// cap, identifying User-Agent, redirects followed up to 3 times, non-200 → tile missing) and the
// night variant of the tiles (tiles only, chrome unchanged, §10.3). iOS deviation: the default night
// filter is a hue- and saturation-preserving HSL LIGHTNESS inversion (L' = 1 − L, then dimmed ×0.9)
// so parks stay green and water blue; osmdroid's INVERT_COLORS (R' = 255 − R, G' = 255 − G,
// B' = 255 − B, A' = A — parks turn magenta, water orange) is `nightStyle = .rgbInvert`.
// P0 (D05): the dash map draws the MUTED treatments (`DashTileTreatment.mutedDay` / `.mutedNight`):
// desaturated, flattened greys, so only the route, the puck and the pins carry colour; the classic
// variants (`.normal`, `.inverted`) stay available.
//
// Layers: memory LRU of decoded CGImages (day images + their variants keyed by their exact filter,
// ~256 entries; variants are never written to disk) → disk cache
// Caches/tiles/<source>/z/x/y.png (expiry by download date, LRU purge by last access) → network
// through the injected HTTPClient (cellular-preferring on iOS). Stale tiles are served when the
// network is unavailable and refreshed in the background when it is back.
//
// OSM tile usage policy: the OpenStreetMap Foundation servers (tile.openstreetmap.org, the default)
// forbid prefetching and offline / bulk downloads; Android never prefetches. `prefetch(corridor:…)`
// exists for the iOS cellular problem (navigation-dash.md §16 R3) and runs ONLY for a tile server the
// rider configured (`MapTileSource.allowsCorridorPrefetch`, navigation-dash.md §10.4): for an OSMF
// template it queues nothing, and a corridor queued for another server is dropped — never fetched from
// the new one — when the template changes. It is capped (`maxPrefetchTiles`) and meant for the active
// route corridor at the riding zooms.

import Foundation
import OpenCfMotoCore

// MARK: - Platform-neutral helpers (unit-tested on Linux)

/// Slippy-map tile address (z/x/y, y = 0 at the north).
public struct TileCacheKey: Hashable, Sendable, CustomStringConvertible {
    public var z: Int
    public var x: Int
    public var y: Int
    public init(z: Int, x: Int, y: Int) { self.z = z; self.x = x; self.y = y }

    public var isValid: Bool {
        guard z >= 0, z <= 24, x >= 0, y >= 0 else { return false }
        let n = 1 << z
        return x < n && y < n
    }

    /// The tile `levels` zoom levels up that contains this one.
    public func ancestor(levels: Int) -> TileCacheKey? {
        guard levels > 0, z - levels >= 0 else { return nil }
        return TileCacheKey(z: z - levels, x: x >> levels, y: y >> levels)
    }

    public var description: String { "\(z)/\(x)/\(y)" }
}

enum TileURLTemplate {
    /// Fills `{z}`, `{x}`, `{y}`.
    static func url(_ template: String, _ key: TileCacheKey) -> URL? {
        let s = template.replacingOccurrences(of: "{z}", with: String(key.z))
            .replacingOccurrences(of: "{x}", with: String(key.x))
            .replacingOccurrences(of: "{y}", with: String(key.y))
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    static func isValid(_ template: String) -> Bool {
        template.contains("{z}") && template.contains("{x}") && template.contains("{y}")
            && url(template, TileCacheKey(z: 1, x: 1, y: 1)) != nil
    }
}

enum TileDiskLayout {
    /// Folder name of a tile source: sanitized host + 8 hex digits of FNV-1a(template), so tiles of
    /// different styles never mix.
    static func sourceKey(for template: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in template.utf8 {
            hash ^= UInt64(b)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let host = URL(string: template.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: ""))?
            .host?.lowercased() ?? "tiles"
        let safeHost = String(host.unicodeScalars.map { c -> Character in
            let ok = (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "." || c == "-"
            return ok ? Character(c) : "_"
        })
        return safeHost + "-" + String(format: "%08x", UInt32(truncatingIfNeeded: hash ^ (hash >> 32)))
    }

    static func relativePath(_ key: TileCacheKey) -> String { "\(key.z)/\(key.x)/\(key.y).png" }
}

/// What the tile cache may write to the log. A tile URL template can carry an API key (in the
/// query or in the path, e.g. `…/{z}/{x}/{y}.png?apikey=…`), and logs are shared in problem
/// reports: log the source folder name (sanitized host + hash) instead of the template, and keep
/// only scheme + host of any URL inside an error description.
enum TileLogText {
    /// `TileDiskLayout.sourceKey`, e.g. "tile.openstreetmap.org-1a2b3c4d" — never the template.
    static func source(_ template: String) -> String { TileDiskLayout.sourceKey(for: template) }

    private static let urlPattern = try? NSRegularExpression(pattern: "(https?)://([^/\\s?#\"'<>,;]+)[^\\s\"'<>,;]*",
                                                             options: [.caseInsensitive])

    /// `text` with every http(s) URL reduced to `scheme://host/…` (path and query dropped).
    static func redactingURLs(_ text: String) -> String {
        guard let re = urlPattern else { return text }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1://$2/…")
    }

    /// An error description safe for the log.
    static func describe(_ error: Error) -> String { redactingURLs(String(describing: error)) }
}

/// Web-Mercator tile math and route-corridor coverage.
///
/// Every input is untrusted (GPX files, imported places, search results reach the corridor
/// prefetch): nothing here may trap on NaN, ±∞ or out-of-range coordinates (SEC-1). Invalid
/// corridor points are dropped, longitudes and latitudes are clamped before any `Int` conversion
/// and the per-segment sample count is bounded.
enum TileCoverage {
    static let maxLatitude = 85.051_128_779_806_59
    static let metersPerDegree = 111_320.0
    /// Larger radii are clamped (the app prefetches 250 m; nothing useful is wider).
    static let maxRadiusMeters = 50_000.0

    /// A coordinate the tile maths can use: finite, latitude in −90…90, longitude in −180…180.
    static func isUsable(_ p: GeoPoint) -> Bool {
        p.lat.isFinite && p.lon.isFinite && (-90 ... 90).contains(p.lat) && (-180 ... 180).contains(p.lon)
    }

    static func tileX(lon: Double, zoom: Int) -> Int {
        let z = min(max(0, zoom), 24)
        let n = Double(1 << z)
        let l = lon.isNaN ? 0 : min(max(lon, -180), 180) // ±∞ clamp to the world edge
        let x = Int(((l + 180) / 360 * n).rounded(.down))
        return min(max(0, x), (1 << z) - 1)
    }

    static func tileY(lat: Double, zoom: Int) -> Int {
        let z = min(max(0, zoom), 24)
        let n = Double(1 << z)
        let l = (lat.isNaN ? 0 : min(max(lat, -maxLatitude), maxLatitude)) * .pi / 180
        let v = ((1 - log(tan(l) + 1 / cos(l)) / .pi) / 2 * n).rounded(.down)
        let y = v.isFinite ? Int(min(max(v, 0), n)) : 0
        return min(max(0, y), (1 << z) - 1)
    }

    static func key(for p: GeoPoint, zoom: Int) -> TileCacheKey {
        TileCacheKey(z: zoom, x: tileX(lon: p.lon, zoom: zoom), y: tileY(lat: p.lat, zoom: zoom))
    }

    /// Ground size of one tile edge at `lat` (m).
    static func tileMeters(lat: Double, zoom: Int) -> Double {
        40_075_016.686 * max(cos(lat * .pi / 180), 0.01) / Double(1 << zoom)
    }

    /// Tiles within `radiusMeters` of the polyline, in corridor order (nearest the start first),
    /// at most `limit`. Unusable points (`isUsable`) are skipped.
    static func tiles(corridor rawCorridor: [GeoPoint], zoom: Int, radiusMeters: Double, limit: Int) -> [TileCacheKey] {
        let corridor = rawCorridor.filter(isUsable)
        guard let first = corridor.first, limit > 0, zoom >= 0, zoom <= 24 else { return [] }
        let r = min(max(0, radiusMeters.isFinite ? radiusMeters : 0), maxRadiusMeters)
        // Samples per segment: enough for `limit` tiles even on an antipodal segment; a longer
        // segment is sampled more coarsely (the capped prefetch could not use more tiles anyway).
        let maxSamples = Double(max(1, limit)) * 64
        var seen = Set<TileCacheKey>()
        var out: [TileCacheKey] = []
        func cover(_ p: GeoPoint) -> Bool {
            let dLat = r / metersPerDegree
            let dLon = r / (metersPerDegree * max(cos(p.lat * .pi / 180), 0.01))
            let x0 = tileX(lon: p.lon - dLon, zoom: zoom), x1 = tileX(lon: p.lon + dLon, zoom: zoom)
            let y0 = tileY(lat: p.lat + dLat, zoom: zoom), y1 = tileY(lat: p.lat - dLat, zoom: zoom)
            for y in y0 ... max(y0, y1) {
                for x in x0 ... max(x0, x1) {
                    let k = TileCacheKey(z: zoom, x: x, y: y)
                    if seen.insert(k).inserted {
                        out.append(k)
                        if out.count >= limit { return false }
                    }
                }
            }
            return true
        }
        guard cover(first) else { return out }
        for (a, b) in zip(corridor, corridor.dropFirst()) {
            let meanLat = (a.lat + b.lat) / 2
            let dx = (b.lon - a.lon) * metersPerDegree * max(cos(meanLat * .pi / 180), 0.01)
            let dy = (b.lat - a.lat) * metersPerDegree
            let dist = (dx * dx + dy * dy).squareRoot()
            let step = max(1, min(max(r, 1), tileMeters(lat: meanLat, zoom: zoom) / 2))
            let samples = (dist / step).rounded(.up)
            guard samples.isFinite else { continue }
            let n = max(1, Int(min(samples, maxSamples)))
            for i in 1 ... n {
                let t = Double(i) / Double(n)
                let p = GeoPoint(lat: a.lat + (b.lat - a.lat) * t, lon: a.lon + (b.lon - a.lon) * t)
                guard cover(p) else { return out }
            }
        }
        return out
    }
}

/// Small least-recently-used map (O(n) eviction; n ≈ a few hundred).
struct VideoLRU<Key: Hashable, Value> {
    let capacity: Int
    private var storage: [Key: (value: Value, tick: UInt64)] = [:]
    private var tick: UInt64 = 0

    init(capacity: Int) { self.capacity = max(1, capacity) }

    var count: Int { storage.count }
    func contains(_ key: Key) -> Bool { storage[key] != nil }
    func peek(_ key: Key) -> Value? { storage[key]?.value }

    /// Returns the value and marks it most recently used.
    mutating func get(_ key: Key) -> Value? {
        guard let entry = storage[key] else { return nil }
        tick &+= 1
        storage[key] = (entry.value, tick)
        return entry.value
    }

    /// Inserts / replaces; returns the evicted key, if any.
    @discardableResult
    mutating func set(_ key: Key, _ value: Value) -> Key? {
        tick &+= 1
        var evicted: Key?
        if storage[key] == nil, storage.count >= capacity,
           let oldest = storage.min(by: { $0.value.tick < $1.value.tick })?.key {
            storage[oldest] = nil
            evicted = oldest
        }
        storage[key] = (value, tick)
        return evicted
    }

    mutating func remove(_ key: Key) { storage[key] = nil }
    mutating func removeAll() { storage.removeAll() }
    mutating func removeAll(where shouldRemove: (Key) -> Bool) {
        storage = storage.filter { !shouldRemove($0.key) }
    }
}

/// Retry policy for tile downloads.
enum TileFetchPolicy {
    /// How long a tile is not requested again after an HTTP status (nil for success).
    static func retryDelay(status: Int) -> TimeInterval? {
        switch status {
        case 200 ..< 300: return nil
        case 404, 410: return 3_600   // missing tile: do not hammer the server
        case 429: return 60           // rate limited
        case 500 ..< 600: return 30
        default: return 600
        }
    }

    /// Global pause after `failures` consecutive transport errors (offline): 2, 4, 8 … 60 s.
    static func networkBackoff(consecutiveFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return min(60, 2 * pow(2, Double(min(failures, 6) - 1)))
    }

    /// The server-side status should also pause every request for a while (429 / 5xx).
    static func globalPause(status: Int) -> TimeInterval {
        switch status {
        case 429: return 10
        case 500 ..< 600: return 5
        default: return 0
        }
    }
}

/// How the night variant of a raster tile is derived from the day tile (`DashDisplayList`
/// `.tile(invert: true)`, navigation-dash.md §10.3).
public enum TileNightStyle: String, Sendable, Hashable, CaseIterable {
    /// iOS default: HSL lightness inversion — L' = 1 − L with hue and saturation kept (white roads →
    /// black, light land → near-black, light green parks → dark green, light blue water → dark
    /// blue), then dimmed by `TileImageCache.Configuration.nightDimming` against night glare.
    case lightnessInvert
    /// Android parity: osmdroid `TilesOverlay.INVERT_COLORS` (c' = 255 − c, alpha kept), which turns
    /// parks magenta and water orange.
    case rgbInvert
}

/// The exact night recipe (style + dimming): the cache identity of a night variant.
struct TileNightFilter: Hashable, Sendable {
    let style: TileNightStyle
    /// Colour multiplier applied after the lightness inversion (0…1); always 1 for `.rgbInvert`.
    let dimming: Double

    init(style: TileNightStyle, dimming: Double = 1) {
        self.style = style
        self.dimming = style == .lightnessInvert ? TileNightInversion.clampedDimming(dimming) : 1
    }

    /// Applies the filter in place to premultiplied 4-byte pixels.
    func apply(to buffer: UnsafeMutableRawBufferPointer, width: Int, height: Int, bytesPerRow: Int, alphaIndex: Int = 3) {
        switch style {
        case .lightnessInvert:
            TileNightInversion.lightnessInvertPremultiplied(buffer, width: width, height: height, bytesPerRow: bytesPerRow,
                                                           alphaIndex: alphaIndex, dimming: dimming)
        case .rgbInvert:
            TileNightInversion.invertPremultiplied(buffer, width: width, height: height, bytesPerRow: bytesPerRow,
                                                   alphaIndex: alphaIndex)
        }
    }
}

/// Night filters as pure functions (platform-neutral, unit-tested on Linux; the Apple tile cache
/// runs them over the CGContext bitmap of each 256×256 tile once and caches the result).
enum TileNightInversion {
    /// HSL lightness inversion of one colour, components 0…1 (un-premultiplied): every channel is
    /// shifted by 1 − (max + min). Then max' = 1 − min and min' = 1 − max, so L' = 1 − L while the
    /// chroma max − min — hence hue and HSL saturation — is unchanged; results stay in 0…1.
    static func lightnessInverted(r: Double, g: Double, b: Double) -> (r: Double, g: Double, b: Double) {
        let shift = 1 - (max(r, g, b) + min(r, g, b))
        return (r + shift, g + shift, b + shift)
    }

    /// `lightnessInverted` of an opaque 0xRRGGBB colour (exact integer maths), then × `dimming`.
    static func lightnessInverted(rgb: UInt32, dimming: Double = 1) -> UInt32 {
        let r = Int((rgb >> 16) & 0xFF), g = Int((rgb >> 8) & 0xFF), b = Int(rgb & 0xFF)
        let shift = 255 - max(r, g, b) - min(r, g, b)
        let d = clampedDimming(dimming)
        func ch(_ c: Int) -> UInt32 { UInt32(dimmed(c + shift, d)) }
        return (ch(r) << 16) | (ch(g) << 8) | ch(b)
    }

    /// `lightnessInverted` of one 8-bit PREMULTIPLIED pixel (channels ≤ alpha; larger values are
    /// clamped to alpha). With c = a·cᵤ the shift becomes a − (max + min) in premultiplied units, so
    /// c' = c + a − max − min is exact without un-premultiplying (alpha 0 stays 0). Alpha unchanged.
    static func lightnessInvertedPremultiplied(_ c0: UInt8, _ c1: UInt8, _ c2: UInt8, alpha: UInt8,
                                               dimming: Double = 1) -> (UInt8, UInt8, UInt8) {
        let a = Int(alpha)
        let x = min(Int(c0), a), y = min(Int(c1), a), z = min(Int(c2), a)
        let shift = a - max(x, y, z) - min(x, y, z)
        let d = clampedDimming(dimming)
        return (dimmed(x + shift, d), dimmed(y + shift, d), dimmed(z + shift, d))
    }

    /// `lightnessInvertedPremultiplied` over premultiplied 4-byte pixels, in place. `alphaIndex` =
    /// byte offset of alpha inside a pixel (3 for BGRA premultipliedFirst-little-endian and RGBA
    /// premultipliedLast); the other three bytes are colour (their order does not matter).
    static func lightnessInvertPremultiplied(_ buffer: UnsafeMutableRawBufferPointer, width: Int, height: Int,
                                             bytesPerRow: Int, alphaIndex: Int = 3, dimming: Double = 1) {
        guard width > 0, height > 0, (0 ..< 4).contains(alphaIndex), bytesPerRow >= width * 4,
              buffer.count >= bytesPerRow * (height - 1) + width * 4 else { return }
        let colour = (0 ..< 4).filter { $0 != alphaIndex }
        let (o0, o1, o2) = (colour[0], colour[1], colour[2])
        let d = clampedDimming(dimming)
        let table = (0 ... 255).map { dimmed($0, d) } // × dimming, rounded
        for row in 0 ..< height {
            var i = row * bytesPerRow
            let end = i + width * 4
            while i < end {
                let a = Int(buffer[i + alphaIndex])
                let x = min(Int(buffer[i + o0]), a), y = min(Int(buffer[i + o1]), a), z = min(Int(buffer[i + o2]), a)
                let shift = a - max(x, y, z) - min(x, y, z)
                buffer[i + o0] = table[x + shift]
                buffer[i + o1] = table[y + shift]
                buffer[i + o2] = table[z + shift]
                i += 4
            }
        }
    }

    /// osmdroid INVERT_COLORS on premultiplied 4-byte pixels, in place: every colour channel
    /// c' = a − c (= 255 − c for opaque pixels), alpha unchanged. `alphaIndex` = byte offset of
    /// alpha inside a pixel (3 for BGRA premultipliedFirst-little-endian and RGBA premultipliedLast).
    static func invertPremultiplied(_ buffer: UnsafeMutableRawBufferPointer, width: Int, height: Int,
                                    bytesPerRow: Int, alphaIndex: Int = 3) {
        guard width > 0, height > 0, bytesPerRow >= width * 4, buffer.count >= bytesPerRow * (height - 1) + width * 4 else { return }
        for row in 0 ..< height {
            var i = row * bytesPerRow
            let end = i + width * 4
            while i < end {
                let a = buffer[i + alphaIndex]
                for c in 0 ..< 4 where c != alphaIndex {
                    let v = buffer[i + c]
                    buffer[i + c] = a &- min(v, a)
                }
                i += 4
            }
        }
    }

    /// Dimming factor clamped to 0…1 (a factor above 1 could break the premultiplied c ≤ a rule).
    static func clampedDimming(_ d: Double) -> Double { d.isFinite ? min(max(d, 0), 1) : 1 }

    private static func dimmed(_ c: Int, _ d: Double) -> UInt8 {
        d >= 1 ? UInt8(c) : UInt8((Double(c) * d).rounded())
    }
}

/// The muted dash map (P0, D05) as pure functions (platform-neutral, unit-tested on Linux; the Apple tile
/// cache runs them over each decoded 256×256 tile once per treatment and caches the result). Both keep a
/// little of the colour (`saturation` of the chroma around the luma) and remap the luma (Rec. 709 weights)
/// through a table, aiming at the proposal's map tokens:
/// - day: `ink + (1 − ink)·y^2.8` — OSM's land #F2EFE9 → ≈ #E4E4E2 (token #E5E4E0), white roads stay white,
///   the #BBBBBB road casings → ≈ #A0A0A0 (≈ 2:1 against the land; token #9EA3AA), black labels → ≈ #5C5C5C
///   (token #5E646C: still ≈ 5:1, but recessive next to the route, the puck and the pins);
/// - night: a V around the land's luma (0.94) — land → ≈ #161615 (token #16191D), white roads a step lighter
///   (≈ #383838; tokens #252A31…#3C434C), everything darker than the land (labels, water, woods, casings)
///   folded towards a mid grey (black labels ≈ #858585, #222 ones ≈ #757575; token #737B85).
enum TileMutedFilter {
    static let daySaturation = 0.20
    static let dayGamma = 2.8, dayInk = 0.36
    static let nightSaturation = 0.15
    static let nightKnee = 0.94, nightGround = 0.085, nightRoad = 0.22, nightInk = 0.52

    /// Luma → output level tables (0…255).
    static let dayTable: [UInt8] = (0 ... 255).map { y in
        let f = dayInk + (1 - dayInk) * pow(Double(y) / 255, dayGamma)
        return UInt8(min(255, max(0, (255 * f).rounded())))
    }
    static let nightTable: [UInt8] = (0 ... 255).map { y8 in
        let y = Double(y8) / 255
        let f = y >= nightKnee
            ? nightGround + (y - nightKnee) / (1 - nightKnee) * (nightRoad - nightGround)
            : nightGround + (nightKnee - y) / nightKnee * (nightInk - nightGround)
        return UInt8(min(255, max(0, (255 * f).rounded())))
    }
    /// The saturation as a /256 factor.
    static func saturation256(night: Bool) -> Int { Int(((night ? nightSaturation : daySaturation) * 256).rounded()) }

    /// Rec. 709 luma of 8-bit channels (weights /256: 54, 183, 19).
    @inline(__always) static func luma(_ r: Int, _ g: Int, _ b: Int) -> Int { (54 * r + 183 * g + 19 * b + 128) >> 8 }

    /// One opaque 8-bit colour through the filter.
    @inline(__always) static func filtered(_ r: Int, _ g: Int, _ b: Int, table: [UInt8], sat: Int) -> (Int, Int, Int) {
        let y = luma(r, g, b)
        let base = Int(table[y])
        func ch(_ c: Int) -> Int { min(255, max(0, base + ((sat * (c - y)) >> 8))) }
        return (ch(r), ch(g), ch(b))
    }

    /// An opaque 0xRRGGBB colour through the day or night filter.
    static func apply(rgb: UInt32, night: Bool) -> UInt32 {
        let (r, g, b) = filtered(Int((rgb >> 16) & 0xFF), Int((rgb >> 8) & 0xFF), Int(rgb & 0xFF),
                                 table: night ? nightTable : dayTable, sat: saturation256(night: night))
        return (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
    }

    /// The filter over premultiplied 4-byte pixels, in place. `alphaIndex` / `redIndex` / `greenIndex` /
    /// `blueIndex` = byte offsets inside a pixel (defaults: BGRA in memory, i.e. CoreGraphics
    /// premultipliedFirst + byteOrder32Little). Transparent pixels stay as they are; translucent ones are
    /// filtered un-premultiplied.
    static func applyPremultiplied(_ buffer: UnsafeMutableRawBufferPointer, width: Int, height: Int, bytesPerRow: Int,
                                   night: Bool, alphaIndex: Int = 3, redIndex: Int = 2, greenIndex: Int = 1, blueIndex: Int = 0) {
        let offsets = [alphaIndex, redIndex, greenIndex, blueIndex]
        guard width > 0, height > 0, bytesPerRow >= width * 4, offsets.allSatisfy({ (0 ..< 4).contains($0) }),
              Set(offsets).count == 4, buffer.count >= bytesPerRow * (height - 1) + width * 4 else { return }
        let table = night ? nightTable : dayTable
        let sat = saturation256(night: night)
        for row in 0 ..< height {
            var i = row * bytesPerRow
            let end = i + width * 4
            while i < end {
                let a = Int(buffer[i + alphaIndex])
                if a == 255 {
                    let (r, g, b) = filtered(Int(buffer[i + redIndex]), Int(buffer[i + greenIndex]), Int(buffer[i + blueIndex]),
                                             table: table, sat: sat)
                    buffer[i + redIndex] = UInt8(r); buffer[i + greenIndex] = UInt8(g); buffer[i + blueIndex] = UInt8(b)
                } else if a > 0 {
                    func un(_ c: UInt8) -> Int { min(255, (min(Int(c), a) * 255 + a / 2) / a) }
                    func pre(_ c: Int) -> UInt8 { UInt8((c * a + 127) / 255) }
                    let (r, g, b) = filtered(un(buffer[i + redIndex]), un(buffer[i + greenIndex]), un(buffer[i + blueIndex]),
                                             table: table, sat: sat)
                    buffer[i + redIndex] = pre(r); buffer[i + greenIndex] = pre(g); buffer[i + blueIndex] = pre(b)
                }
                i += 4
            }
        }
    }
}

/// A tile variant's recipe — the cache identity of a variant built from the decoded day image (P0, D05).
enum TileVariantFilter: Hashable, Sendable {
    /// The classic night map (`DashTileTreatment.inverted`) with the cache's night style.
    case night(TileNightFilter)
    case mutedDay
    case mutedNight

    /// Applies the filter in place to premultiplied BGRA pixels (alpha byte 3).
    func apply(to buffer: UnsafeMutableRawBufferPointer, width: Int, height: Int, bytesPerRow: Int) {
        switch self {
        case let .night(f):
            f.apply(to: buffer, width: width, height: height, bytesPerRow: bytesPerRow, alphaIndex: 3)
        case .mutedDay:
            TileMutedFilter.applyPremultiplied(buffer, width: width, height: height, bytesPerRow: bytesPerRow, night: false)
        case .mutedNight:
            TileMutedFilter.applyPremultiplied(buffer, width: width, height: height, bytesPerRow: bytesPerRow, night: true)
        }
    }
}

// MARK: - Tile cache (Apple platforms)

#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO

/// Counters of the tile cache (diagnostics, phone UI).
public struct TileCacheStats: Sendable, Equatable {
    public var memoryHits = 0
    public var memoryMisses = 0
    public var diskHits = 0
    public var staleServed = 0
    public var downloads = 0
    public var downloadFailures = 0
    public var bytesDownloaded: Int64 = 0
    public var nightVariantsBuilt = 0
    /// Muted day / night variants built (P0, D05).
    public var mutedVariantsBuilt = 0
    public var prefetchQueued = 0
    public var memoryCount = 0
    public var diskBytes: Int64 = 0
    public init() {}
}

/// Memory + disk + network raster tile cache. Thread-safe. `image(z:x:y:treatment:)` is a fast
/// synchronous memory lookup for the render loop (a variant is built once from the decoded day image and
/// kept); `request` loads asynchronously and reports through `onTileLoaded` (re-render trigger).
public final class TileImageCache: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// Raster tile URL template with {z}/{x}/{y} (BikeSettings.tileURLTemplate).
        public var urlTemplate: String
        /// Root folder; nil = <Caches>/tiles.
        public var directory: URL?
        /// Decoded images kept in memory (day and night variants count separately).
        public var memoryCapacity: Int
        /// Disk cap; the least recently used tiles are purged down to 80 %.
        public var diskCapacityBytes: Int64
        /// Tiles older than this are refreshed (still served while offline).
        public var expiry: TimeInterval
        /// Concurrent downloads (OSM policy / osmdroid: 2).
        public var maxConcurrentDownloads: Int
        /// Pending visible-tile requests kept (newest first; older ones are dropped).
        public var maxQueuedRequests: Int
        /// Cap for one `prefetch` call (custom tile servers only: never the OSMF ones).
        public var maxPrefetchTiles: Int
        /// Highest zoom the server provides (OSM 19); deeper tiles are drawn from ancestors.
        public var maxFetchZoom: Int
        public var requestTimeout: TimeInterval
        /// Night variant of the tiles: `.lightnessInvert` (iOS default — parks stay green, water
        /// blue) or `.rgbInvert` (osmdroid INVERT_COLORS, Android parity).
        public var nightStyle: TileNightStyle
        /// Colour multiplier after the `.lightnessInvert` night filter, 0…1 (1 = none); ignored by
        /// `.rgbInvert`.
        public var nightDimming: Double

        public init(urlTemplate: String = BikeSettings().tileURLTemplate, directory: URL? = nil, memoryCapacity: Int = 256,
                    diskCapacityBytes: Int64 = 512 * 1024 * 1024, expiry: TimeInterval = 90 * 24 * 3600,
                    maxConcurrentDownloads: Int = 2, maxQueuedRequests: Int = 96, maxPrefetchTiles: Int = 400,
                    maxFetchZoom: Int = 19, requestTimeout: TimeInterval = 15, nightStyle: TileNightStyle = .lightnessInvert,
                    nightDimming: Double = 0.9) {
            self.urlTemplate = urlTemplate
            self.directory = directory
            self.memoryCapacity = memoryCapacity
            self.diskCapacityBytes = diskCapacityBytes
            self.expiry = expiry
            self.maxConcurrentDownloads = maxConcurrentDownloads
            self.maxQueuedRequests = maxQueuedRequests
            self.maxPrefetchTiles = maxPrefetchTiles
            self.maxFetchZoom = maxFetchZoom
            self.requestTimeout = requestTimeout
            self.nightStyle = nightStyle
            self.nightDimming = nightDimming
        }
    }

    private struct MemoryKey: Hashable {
        let tile: TileCacheKey
        /// nil = the decoded day image; else the exact filter the variant was built with, so variants of
        /// different treatments, night styles or dimmings never mix (variants live in memory only).
        let variant: TileVariantFilter?
    }

    public let configuration: Configuration
    private let http: any HTTPClient
    private let root: URL
    private let ioQueue = DispatchQueue(label: "ocm.tiles.io", qos: .utility)
    private let lock = NSLock()
    private let fileManager = FileManager()

    // Guarded by `lock`.
    private var template: String
    /// `MapTileSource.allowsCorridorPrefetch(template:)`: false for the OSMF servers.
    private var prefetchAllowed: Bool
    private var sourceDirectory: URL
    private var generation: UInt64 = 0
    private var memory: VideoLRU<MemoryKey, CGImage>
    private var diskPending = Set<TileCacheKey>()
    private var diskStack: [TileCacheKey] = []
    private var diskDrainScheduled = false
    private var netPending = Set<TileCacheKey>()
    private var netStack: [TileCacheKey] = []
    private var prefetchQueue: [TileCacheKey] = []
    private var activeDownloads = 0
    private var retryNotBefore: [TileCacheKey: TimeInterval] = [:]
    private var networkPausedUntil: TimeInterval = 0
    private var resumeScheduled = false
    private var consecutiveNetworkErrors = 0
    private var approxDiskBytes: Int64 = -1
    private var writesSincePurge = 0
    private var _stats = TileCacheStats()
    private var _onTileLoaded: (@Sendable (TileCacheKey) -> Void)?
    private var memoryWarningToken: NSObjectProtocol?
    private var nightFilter: TileNightFilter

    public init(httpClient: any HTTPClient, configuration: Configuration = Configuration()) {
        http = httpClient
        self.configuration = configuration
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        root = configuration.directory ?? caches.appendingPathComponent("tiles", isDirectory: true)
        template = configuration.urlTemplate
        prefetchAllowed = MapTileSource.allowsCorridorPrefetch(template: configuration.urlTemplate)
        sourceDirectory = root.appendingPathComponent(TileDiskLayout.sourceKey(for: configuration.urlTemplate), isDirectory: true)
        memory = VideoLRU(capacity: configuration.memoryCapacity)
        nightFilter = TileNightFilter(style: configuration.nightStyle, dimming: configuration.nightDimming)
        // UIApplication.didReceiveMemoryWarningNotification by name (no UIKit import; never fires on macOS).
        memoryWarningToken = NotificationCenter.default.addObserver(
            forName: Notification.Name("UIApplicationDidReceiveMemoryWarningNotification"), object: nil, queue: nil
        ) { [weak self] _ in self?.purgeMemory() }
        ioQueue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.purgeDiskIfNeeded(force: true) }
        if !TileURLTemplate.isValid(configuration.urlTemplate) {
            Log.w("OSM", "tile URL template looks invalid (source \(TileLogText.source(configuration.urlTemplate)))")
        }
    }

    deinit {
        if let t = memoryWarningToken { NotificationCenter.default.removeObserver(t) }
    }

    /// Called (on a background thread) whenever a tile became available in memory.
    public var onTileLoaded: (@Sendable (TileCacheKey) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onTileLoaded }
        set { lock.lock(); _onTileLoaded = newValue; lock.unlock() }
    }

    /// Changing the template switches to another disk folder and drops memory + queues.
    public var urlTemplate: String {
        get { lock.lock(); defer { lock.unlock() }; return template }
        set {
            lock.lock()
            guard newValue != template else { lock.unlock(); return }
            template = newValue
            prefetchAllowed = MapTileSource.allowsCorridorPrefetch(template: newValue)
            sourceDirectory = root.appendingPathComponent(TileDiskLayout.sourceKey(for: newValue), isDirectory: true)
            generation &+= 1
            memory.removeAll()
            diskPending.removeAll(); diskStack.removeAll()
            netPending.removeAll(); netStack.removeAll(); prefetchQueue.removeAll()
            retryNotBefore.removeAll()
            lock.unlock()
            Log.i("OSM", "tile source → \(TileLogText.source(newValue))\(TileURLTemplate.isValid(newValue) ? "" : " (template looks invalid)")")
        }
    }

    /// The night filter in use (initially `configuration.nightStyle`). Switching it drops the night
    /// variants built with the previous one; day images are kept.
    public var nightStyle: TileNightStyle {
        get { lock.lock(); defer { lock.unlock() }; return nightFilter.style }
        set {
            lock.lock()
            defer { lock.unlock() }
            let filter = TileNightFilter(style: newValue, dimming: configuration.nightDimming)
            guard filter != nightFilter else { return }
            nightFilter = filter
            memory.removeAll { if case .night = $0.variant { return true } else { return false } }
        }
    }

    public var stats: TileCacheStats {
        lock.lock(); defer { lock.unlock() }
        var s = _stats
        s.memoryCount = memory.count
        s.diskBytes = max(0, approxDiskBytes)
        return s
    }

    // MARK: lookup (render thread)

    /// The classic day tile (`night` false) or its night variant (`.inverted`): `image(z:x:y:treatment:)`.
    public func image(z: Int, x: Int, y: Int, night: Bool) -> CGImage? {
        image(z: z, x: x, y: y, treatment: night ? .inverted : .normal)
    }

    /// The decoded tile from memory with `treatment`, or nil. A variant is built from the day image once
    /// (the night one with the current `nightStyle`) and cached. Never touches disk or network (call
    /// `request` for a missing tile).
    public func image(z: Int, x: Int, y: Int, treatment: DashTileTreatment) -> CGImage? {
        let key = TileCacheKey(z: z, x: x, y: y)
        if let img = lookup(key, treatment: treatment) {
            lock.lock(); _stats.memoryHits += 1; lock.unlock()
            return img
        }
        lock.lock(); _stats.memoryMisses += 1; lock.unlock()
        return nil
    }

    /// `fallbackImage(z:x:y:treatment:maxLevels:)` for the classic day / night tiles.
    public func fallbackImage(z: Int, x: Int, y: Int, night: Bool, maxLevels: Int = 4) -> CGImage? {
        fallbackImage(z: z, x: x, y: y, treatment: night ? .inverted : .normal, maxLevels: maxLevels)
    }

    /// The best cached ancestor of a missing tile with `treatment`, cropped to the tile's area (drawn
    /// scaled up while the tile loads), or nil.
    public func fallbackImage(z: Int, x: Int, y: Int, treatment: DashTileTreatment, maxLevels: Int = 4) -> CGImage? {
        let key = TileCacheKey(z: z, x: x, y: y)
        guard key.isValid else { return nil }
        for levels in 1 ... max(1, maxLevels) {
            guard let parent = key.ancestor(levels: levels) else { break }
            guard let img = lookup(parent, treatment: treatment) else { continue }
            let n = Double(1 << levels)
            let subW = Double(img.width) / n
            let subH = Double(img.height) / n
            guard subW >= 1, subH >= 1 else { continue }
            let ox = Double(x - (parent.x << levels)) * subW
            let oy = Double(y - (parent.y << levels)) * subH
            if let cropped = img.cropping(to: CGRect(x: ox, y: oy, width: subW, height: subH)) { return cropped }
        }
        return nil
    }

    /// The variant recipe of a treatment (nil: the decoded image as is). Lock held.
    private func variantLocked(_ treatment: DashTileTreatment) -> TileVariantFilter? {
        switch treatment {
        case .normal: return nil
        case .inverted: return .night(nightFilter)
        case .mutedDay: return .mutedDay
        case .mutedNight: return .mutedNight
        }
    }

    private func lookup(_ key: TileCacheKey, treatment: DashTileTreatment) -> CGImage? {
        lock.lock()
        let filter = variantLocked(treatment)
        if let img = memory.get(MemoryKey(tile: key, variant: filter)) { lock.unlock(); return img }
        guard let filter, let day = memory.get(MemoryKey(tile: key, variant: nil)) else { lock.unlock(); return nil }
        let gen = generation
        lock.unlock()
        guard let variant = Self.variantImage(day, filter: filter) else { return nil }
        lock.lock()
        if gen == generation, filter == variantLocked(treatment) {
            memory.set(MemoryKey(tile: key, variant: filter), variant)
            if case .night = filter { _stats.nightVariantsBuilt += 1 } else { _stats.mutedVariantsBuilt += 1 }
        }
        lock.unlock()
        return variant
    }

    // MARK: loading

    /// Loads a tile asynchronously (disk, then network). Cheap and de-duplicated: the render loop
    /// may call it for every missing tile on every frame.
    public func request(z: Int, x: Int, y: Int) {
        let key = TileCacheKey(z: z, x: x, y: y)
        guard key.isValid else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if memory.contains(MemoryKey(tile: key, variant: nil)) || diskPending.contains(key) || netPending.contains(key) {
            lock.unlock()
            return
        }
        if let until = retryNotBefore[key], now < until { lock.unlock(); return }
        diskPending.insert(key)
        diskStack.append(key)
        if diskStack.count > configuration.maxQueuedRequests {
            diskPending.remove(diskStack.removeFirst())
        }
        let schedule = !diskDrainScheduled
        diskDrainScheduled = true
        lock.unlock()
        if schedule { ioQueue.async { [weak self] in self?.drainDisk() } }
    }

    /// Queues the tiles around a route corridor (disk-fresh tiles are skipped). Returns the number
    /// of tiles considered (≤ `maxPrefetchTiles`). Only for a tile server the rider configured: with an
    /// OSMF template (`MapTileSource.allowsCorridorPrefetch` false) nothing is queued and 0 is returned.
    @discardableResult
    public func prefetch(corridor rawCorridor: [GeoPoint], zooms: ClosedRange<Int>, radiusMeters: Double) -> Int {
        let (allowed, gen, tpl) = lock.withLock { (prefetchAllowed, generation, template) }
        guard allowed else {
            Log.i("OSM", "corridor prefetch skipped: \(TileLogText.source(tpl)) does not allow prefetching (OSM tile usage policy)")
            return 0
        }
        let lo = max(0, zooms.lowerBound)
        let hi = min(configuration.maxFetchZoom, zooms.upperBound)
        let corridor = rawCorridor.filter(TileCoverage.isUsable) // untrusted route points (SEC-1)
        guard lo <= hi, !corridor.isEmpty else { return 0 }
        var keys: [TileCacheKey] = []
        var budget = configuration.maxPrefetchTiles
        for z in lo ... hi where budget > 0 {
            let t = TileCoverage.tiles(corridor: corridor, zoom: z, radiusMeters: radiusMeters, limit: budget)
            keys += t
            budget -= t.count
        }
        let r = radiusMeters.isFinite ? Int(min(max(radiusMeters, 0), TileCoverage.maxRadiusMeters)) : 0
        Log.i("OSM", "prefetch \(keys.count) tile(s) z\(lo)…\(hi) r=\(r) m (cap \(configuration.maxPrefetchTiles))")
        let corridorKeys = keys
        ioQueue.async { [weak self] in
            guard let self else { return }
            var queued = 0
            for k in corridorKeys {
                // The tile source changed since the call: this corridor was for the old server, never the new one.
                let (dir, expiry, current) = self.lock.withLock { (self.sourceDirectory, self.configuration.expiry, self.generation) }
                guard current == gen else { break }
                if let created = self.fileDate(dir.appendingPathComponent(TileDiskLayout.relativePath(k))),
                   Date().timeIntervalSince(created) <= expiry {
                    continue
                }
                self.lock.withLock { () -> Void in
                    if self.generation == gen, self.enqueueNetworkLocked(k, prefetch: true) { queued += 1 }
                }
            }
            self.lock.withLock { () -> Void in self._stats.prefetchQueued += queued }
            self.pumpNetwork()
        }
        return keys.count
    }

    /// Drops every decoded image (memory warning, background).
    public func purgeMemory() {
        lock.lock()
        memory.removeAll()
        lock.unlock()
    }

    /// Deletes every cached tile on disk (all sources) and the memory cache.
    public func clearDisk() {
        purgeMemory()
        ioQueue.async { [weak self] in
            guard let self else { return }
            try? self.fileManager.removeItem(at: self.root)
            self.lock.withLock { () -> Void in self.approxDiskBytes = 0 }
            Log.i("OSM", "tile cache cleared")
        }
    }

    // MARK: private — disk

    private func drainDisk() {
        while true {
            lock.lock()
            guard let key = diskStack.popLast() else {
                diskDrainScheduled = false
                lock.unlock()
                return
            }
            let gen = generation
            let dir = sourceDirectory
            let expiry = configuration.expiry
            lock.unlock()

            let file = dir.appendingPathComponent(TileDiskLayout.relativePath(key))
            var loaded = false
            var stale = false
            if let created = fileDate(file) {
                if let data = try? Data(contentsOf: file), let image = Self.decode(data) {
                    stale = Date().timeIntervalSince(created) > expiry
                    try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path) // LRU access
                    lock.lock()
                    if gen == generation {
                        memory.set(MemoryKey(tile: key, variant: nil), image)
                        _stats.diskHits += 1
                        if stale { _stats.staleServed += 1 }
                        loaded = true
                    }
                    lock.unlock()
                } else {
                    try? fileManager.removeItem(at: file) // corrupt
                }
            }
            lock.lock()
            diskPending.remove(key)
            if gen == generation, !loaded || stale { _ = enqueueNetworkLocked(key, prefetch: false) }
            let handler = _onTileLoaded
            lock.unlock()
            if loaded { handler?(key) }
            pumpNetwork()
        }
    }

    /// Download date of a cached file (creation date; modification date is the LRU access stamp).
    private func fileDate(_ file: URL) -> Date? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: file.path) else { return nil }
        return (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date)
    }

    private func writeToDisk(_ data: Data, key: TileCacheKey, directory: URL) {
        let file = directory.appendingPathComponent(TileDiskLayout.relativePath(key))
        do {
            try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            Log.shared.throttled("tile-write", interval: 30, .warn, "OSM", "tile write failed: \(error)")
            return
        }
        let mustPurge: Bool = lock.withLock {
            if approxDiskBytes >= 0 { approxDiskBytes += Int64(data.count) }
            writesSincePurge += 1
            return approxDiskBytes > configuration.diskCapacityBytes || writesSincePurge >= 1_000
        }
        if mustPurge { purgeDiskIfNeeded(force: false) }
    }

    /// Recomputes the disk usage and deletes the least recently used tiles above the cap.
    private func purgeDiskIfNeeded(force: Bool) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            lock.withLock { () -> Void in approxDiskBytes = 0; writesSincePurge = 0 }
            return
        }
        var files: [(url: URL, size: Int64, used: Date)] = []
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let size = Int64(v.fileSize ?? 0)
            total += size
            files.append((url, size, v.contentModificationDate ?? .distantPast))
        }
        let cap = configuration.diskCapacityBytes
        var remaining = total
        if total > cap {
            files.sort { $0.used < $1.used }
            let target = cap / 10 * 8
            for f in files {
                if remaining <= target { break }
                if (try? fileManager.removeItem(at: f.url)) != nil { remaining -= f.size }
            }
            Log.i("OSM", "tile cache purged \((total - remaining) / 1_048_576) MiB (now \(remaining / 1_048_576) MiB)")
        } else if force {
            Log.d("OSM", "tile cache \(total / 1_048_576) MiB in \(files.count) file(s)")
        }
        lock.withLock { () -> Void in
            approxDiskBytes = remaining
            writesSincePurge = 0
        }
    }

    // MARK: private — network

    /// Must be called with `lock` held. Returns true if the key was queued. A prefetch is refused while
    /// the template is an OSMF server (`prefetchAllowed`).
    private func enqueueNetworkLocked(_ key: TileCacheKey, prefetch: Bool) -> Bool {
        guard key.z <= configuration.maxFetchZoom, !netPending.contains(key) else { return false }
        if prefetch, !prefetchAllowed { return false }
        if let until = retryNotBefore[key], ProcessInfo.processInfo.systemUptime < until { return false }
        netPending.insert(key)
        if prefetch {
            prefetchQueue.append(key)
        } else {
            netStack.append(key)
            if netStack.count > configuration.maxQueuedRequests { netPending.remove(netStack.removeFirst()) }
        }
        return true
    }

    private func pumpNetwork() {
        let now = ProcessInfo.processInfo.systemUptime
        var starts: [(TileCacheKey, UInt64)] = []
        var resumeAfter: TimeInterval?
        lock.lock()
        if now < networkPausedUntil {
            if !resumeScheduled, !(netStack.isEmpty && prefetchQueue.isEmpty) {
                resumeScheduled = true
                resumeAfter = networkPausedUntil - now
            }
        } else {
            while activeDownloads < max(1, configuration.maxConcurrentDownloads) {
                let next: TileCacheKey?
                if let k = netStack.popLast() { next = k } // newest visible request first
                else if !prefetchQueue.isEmpty { next = prefetchQueue.removeFirst() }
                else { next = nil }
                guard let key = next else { break }
                activeDownloads += 1
                starts.append((key, generation))
            }
        }
        lock.unlock()
        if let delay = resumeAfter {
            ioQueue.asyncAfter(deadline: .now() + delay + 0.05) { [weak self] in
                guard let self else { return }
                self.lock.withLock { () -> Void in self.resumeScheduled = false }
                self.pumpNetwork()
            }
        }
        for (key, gen) in starts {
            Task.detached(priority: .utility) { [weak self] in
                await self?.download(key, generation: gen)
            }
        }
    }

    private func download(_ key: TileCacheKey, generation gen: UInt64) async {
        let (tpl, dir, current) = lock.withLock { (template, sourceDirectory, generation) }
        guard current == gen else {
            // Queued for the previous tile source: never fetched from the new one (a corridor prefetched for
            // a custom server must not reach an OSMF one; the render loop asks again for what it still needs).
            _ = finishDownload(key, generation: gen, outcome: nil, retryDelay: nil, pause: 0, transportError: false)
            pumpNetwork()
            return
        }
        var outcome: (image: CGImage, data: Data)?
        var retryDelay: TimeInterval?
        var pause: TimeInterval = 0
        var transportError = false
        if let url = TileURLTemplate.url(tpl, key) {
            do {
                var current = url
                var response: HTTPResponse?
                for _ in 0 ... 3 {
                    let r = try await http.send(HTTPRequest(url: current, headers: [
                        "User-Agent": AppHTTPIdentity.userAgent,
                        "Accept": "image/png,image/*;q=0.8",
                    ], timeout: configuration.requestTimeout))
                    if [301, 302, 303, 307, 308].contains(r.status), let location = r.headers["location"],
                       let next = URL(string: location, relativeTo: current)?.absoluteURL {
                        current = next
                        continue
                    }
                    response = r
                    break
                }
                if let r = response {
                    if let delay = TileFetchPolicy.retryDelay(status: r.status) {
                        retryDelay = delay
                        pause = TileFetchPolicy.globalPause(status: r.status)
                        Log.shared.throttled("tile-http-\(r.status)", interval: 30, .warn, "OSM", "tile \(key) HTTP \(r.status)")
                    } else if let image = Self.decode(r.body) {
                        outcome = (image, r.body)
                    } else {
                        retryDelay = 600
                        let type = r.headers["content-type"] ?? "?"
                        Log.shared.throttled("tile-decode", interval: 30, .warn, "OSM", "tile \(key) is not an image (\(type))")
                    }
                } else {
                    retryDelay = 600 // redirect loop
                }
            } catch {
                transportError = true
                retryDelay = 5
                Log.shared.throttled("tile-net", interval: 30, .warn, "OSM", "tile download failed: \(TileLogText.describe(error))")
            }
        } else {
            retryDelay = 3_600
        }

        let (loaded, handler) = finishDownload(key, generation: gen, outcome: outcome, retryDelay: retryDelay,
                                               pause: pause, transportError: transportError)
        if loaded, let o = outcome {
            ioQueue.async { [weak self] in self?.writeToDisk(o.data, key: key, directory: dir) }
            handler?(key)
        }
        pumpNetwork()
    }

    /// Books the result of a download (synchronous: called from the async download task).
    private func finishDownload(_ key: TileCacheKey, generation gen: UInt64, outcome: (image: CGImage, data: Data)?,
                                retryDelay: TimeInterval?, pause initialPause: TimeInterval,
                                transportError: Bool) -> (loaded: Bool, handler: (@Sendable (TileCacheKey) -> Void)?) {
        let now = ProcessInfo.processInfo.systemUptime
        var pause = initialPause
        var loaded = false
        lock.lock()
        defer { lock.unlock() }
        activeDownloads = max(0, activeDownloads - 1)
        netPending.remove(key)
        if gen == generation {
            if let o = outcome {
                memory.set(MemoryKey(tile: key, variant: nil), o.image)
                memory.removeAll { $0.tile == key && $0.variant != nil } // refreshed: rebuild its variants
                _stats.downloads += 1
                _stats.bytesDownloaded += Int64(o.data.count)
                consecutiveNetworkErrors = 0
                loaded = true
            } else {
                _stats.downloadFailures += 1
                if let d = retryDelay { retryNotBefore[key] = now + d }
                if transportError {
                    consecutiveNetworkErrors += 1
                    pause = max(pause, TileFetchPolicy.networkBackoff(consecutiveFailures: consecutiveNetworkErrors))
                }
                if pause > 0 { networkPausedUntil = max(networkPausedUntil, now + pause) }
            }
            if retryNotBefore.count > 4_096 { retryNotBefore = retryNotBefore.filter { $0.value > now } }
        }
        return (loaded, _onTileLoaded)
    }

    // MARK: private — images

    private static let colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    /// Same pixel layout as the dash canvas (32BGRA premultiplied) so tile blits need no conversion.
    private static let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    static func decode(_ data: Data) -> CGImage? {
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return redraw(image, filter: nil)
    }

    /// The night variant of a (decoded) day tile.
    static func nightImage(_ image: CGImage, filter: TileNightFilter) -> CGImage? { redraw(image, filter: .night(filter)) }

    /// A variant (night, muted day / night) of a (decoded) day tile.
    static func variantImage(_ image: CGImage, filter: TileVariantFilter) -> CGImage? { redraw(image, filter: filter) }

    /// Decodes into a 32BGRA premultiplied bitmap (forces decoding off the render thread) and
    /// optionally runs a variant filter over its pixels (BGRA in memory, alpha byte 3).
    private static func redraw(_ image: CGImage, filter: TileVariantFilter?) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= 2_048, h <= 2_048,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: bitmapInfo) else { return nil }
        ctx.interpolationQuality = .none
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        if let filter, let data = ctx.data {
            filter.apply(to: UnsafeMutableRawBufferPointer(start: data, count: ctx.bytesPerRow * h),
                         width: w, height: h, bytesPerRow: ctx.bytesPerRow)
        }
        return ctx.makeImage()
    }
}
#endif
