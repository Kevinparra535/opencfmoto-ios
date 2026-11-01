// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoApple

final class VideoTileCacheTests: XCTestCase {
    // MARK: keys and URLs

    func testKeyValidityAndAncestors() {
        XCTAssertTrue(TileCacheKey(z: 0, x: 0, y: 0).isValid)
        XCTAssertTrue(TileCacheKey(z: 17, x: 70_406, y: 42_987).isValid)
        XCTAssertFalse(TileCacheKey(z: 1, x: 2, y: 0).isValid)
        XCTAssertFalse(TileCacheKey(z: -1, x: 0, y: 0).isValid)
        XCTAssertFalse(TileCacheKey(z: 3, x: 0, y: -1).isValid)
        XCTAssertFalse(TileCacheKey(z: 25, x: 0, y: 0).isValid)
        let k = TileCacheKey(z: 17, x: 70_406, y: 42_987)
        XCTAssertEqual(k.ancestor(levels: 1), TileCacheKey(z: 16, x: 35_203, y: 21_493))
        XCTAssertEqual(k.ancestor(levels: 3), TileCacheKey(z: 14, x: 8_800, y: 5_373))
        XCTAssertNil(TileCacheKey(z: 2, x: 1, y: 1).ancestor(levels: 3))
        XCTAssertNil(k.ancestor(levels: 0))
        XCTAssertEqual(k.description, "17/70406/42987")
    }

    func testURLTemplate() {
        let osm = BikeSettings().tileURLTemplate
        XCTAssertEqual(TileURLTemplate.url(osm, TileCacheKey(z: 16, x: 37_444, y: 23_549))?.absoluteString,
                       "https://tile.openstreetmap.org/16/37444/23549.png")
        XCTAssertTrue(TileURLTemplate.isValid(osm))
        XCTAssertTrue(TileURLTemplate.isValid("https://tiles.example.com/v1/{z}/{y}/{x}@2x.jpg?key=abc"))
        XCTAssertEqual(TileURLTemplate.url("https://t.example/{z}/{y}/{x}.jpg", TileCacheKey(z: 2, x: 1, y: 3))?.absoluteString,
                       "https://t.example/2/3/1.jpg")
        XCTAssertFalse(TileURLTemplate.isValid("https://tile.openstreetmap.org/{z}/{x}.png"))
        XCTAssertFalse(TileURLTemplate.isValid("ftp://x/{z}/{x}/{y}.png"))
        XCTAssertNil(TileURLTemplate.url("not a url {z}{x}{y}", TileCacheKey(z: 1, x: 1, y: 1)))
    }

    func testDiskLayoutIsStablePerTemplate() {
        let a = TileDiskLayout.sourceKey(for: "https://tile.openstreetmap.org/{z}/{x}/{y}.png")
        let b = TileDiskLayout.sourceKey(for: "https://tile.openstreetmap.org/{z}/{x}/{y}.png")
        let c = TileDiskLayout.sourceKey(for: "https://tiles.example.com/{z}/{x}/{y}.png")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertTrue(a.hasPrefix("tile.openstreetmap.org-"), a)
        XCTAssertEqual(a.count, "tile.openstreetmap.org-".count + 8)
        XCTAssertTrue(c.hasPrefix("tiles.example.com-"))
        XCTAssertEqual(TileDiskLayout.relativePath(TileCacheKey(z: 5, x: 17, y: 11)), "5/17/11.png")
        XCTAssertTrue(TileDiskLayout.sourceKey(for: "garbage").hasPrefix("tiles-"))
    }

    /// INT:SEC-2-tilelog: a template may carry an API key — the log only ever sees the source key
    /// (host + hash) and URLs inside error descriptions are cut down to scheme + host.
    func testLogTextNeverContainsTheTemplateOrItsKey() {
        let template = "https://tile.thunderforest.com/cycle/{z}/{x}/{y}.png?apikey=SECRET123"
        let source = TileLogText.source(template)
        XCTAssertEqual(source, TileDiskLayout.sourceKey(for: template))
        XCTAssertTrue(source.hasPrefix("tile.thunderforest.com-"), source)
        XCTAssertFalse(source.contains("SECRET123"))
        XCTAssertFalse(source.contains("{z}"))
        let pathKey = "https://maps.example.com/KEY-IN-PATH/{z}/{x}/{y}.png"
        XCTAssertFalse(TileLogText.source(pathKey).contains("KEY-IN-PATH"))

        struct FakeURLError: Error, CustomStringConvertible {
            var description: String {
                "Error Domain=NSURLErrorDomain Code=-1001 \"timed out\" UserInfo={NSErrorFailingURLStringKey=https://tile.thunderforest.com/cycle/16/1/2.png?apikey=SECRET123, NSErrorFailingURLKey=http://a.example.org/KEY-IN-PATH/1/2/3.png}"
            }
        }
        let text = TileLogText.describe(FakeURLError())
        XCTAssertFalse(text.contains("SECRET123"), text)
        XCTAssertFalse(text.contains("KEY-IN-PATH"), text)
        XCTAssertTrue(text.contains("https://tile.thunderforest.com/…"), text)
        XCTAssertTrue(text.contains("http://a.example.org/…"), text)
        XCTAssertTrue(text.contains("timed out"), text)
        XCTAssertEqual(TileLogText.redactingURLs("no url here"), "no url here")
    }

    // MARK: Web Mercator (reference values: independent Python implementation of the OSM wiki formula)

    func testTileCoordinates() {
        func t(_ lat: Double, _ lon: Double, _ z: Int) -> [Int] {
            let k = TileCoverage.key(for: GeoPoint(lat: lat, lon: lon), zoom: z)
            return [k.x, k.y]
        }
        XCTAssertEqual(t(52.5163, 13.3777, 17), [70_406, 42_987])  // Berlin
        XCTAssertEqual(t(45.1000, 25.6900, 16), [37_444, 23_549])  // Câmpina area
        XCTAssertEqual(t(4.7110, -74.0721, 15), [9_641, 15_954])   // Bogotá
        XCTAssertEqual(t(-33.8688, 151.2093, 12), [3_768, 2_457])  // Sydney
        XCTAssertEqual(t(0, 0, 1), [1, 1])
        XCTAssertEqual(t(85.1, 179.999, 3), [7, 0])                // clamped
        XCTAssertEqual(t(-85.1, -180, 3), [0, 7])
        XCTAssertEqual(t(0, 0, 0), [0, 0])
    }

    func testTileMeters() {
        XCTAssertEqual(TileCoverage.tileMeters(lat: 0, zoom: 0), 40_075_016.686, accuracy: 0.01)
        XCTAssertEqual(TileCoverage.tileMeters(lat: 60, zoom: 16), 40_075_016.686 * 0.5 / 65_536, accuracy: 0.01)
    }

    func testCorridorCoverageSinglePoint() {
        let p = GeoPoint(lat: 52.5163, lon: 13.3777)
        let center = TileCoverage.key(for: p, zoom: 17)
        let zero = TileCoverage.tiles(corridor: [p], zoom: 17, radiusMeters: 0, limit: 100)
        XCTAssertEqual(zero, [center])
        // r = 300 m at z17 (tile ≈ 186 m here): a 5×5-ish block around the point.
        let block = TileCoverage.tiles(corridor: [p], zoom: 17, radiusMeters: 300, limit: 100)
        XCTAssertTrue(block.contains(center))
        XCTAssertEqual(Set(block).count, block.count, "no duplicates")
        let xs = block.map(\.x), ys = block.map(\.y)
        XCTAssertLessThanOrEqual(xs.max()! - xs.min()!, 5)
        XCTAssertGreaterThanOrEqual(xs.max()! - xs.min()!, 2)
        XCTAssertLessThanOrEqual(ys.max()! - ys.min()!, 5)
        XCTAssertTrue(block.allSatisfy { $0.z == 17 && $0.isValid })
    }

    func testCorridorCoverageAlongARouteIsContiguousAndOrdered() {
        // ~5.5 km due east at 45° N.
        let a = GeoPoint(lat: 45.0, lon: 25.0), b = GeoPoint(lat: 45.0, lon: 25.07)
        let tiles = TileCoverage.tiles(corridor: [a, b], zoom: 15, radiusMeters: 100, limit: 1_000)
        let ka = TileCoverage.key(for: a, zoom: 15), kb = TileCoverage.key(for: b, zoom: 15)
        XCTAssertFalse(tiles.isEmpty)
        XCTAssertTrue(tiles.contains(ka))
        XCTAssertTrue(tiles.contains(kb))
        // Every column between the ends is covered.
        for x in ka.x ... kb.x { XCTAssertTrue(tiles.contains { $0.x == x }, "column \(x)") }
        // Corridor order: the start tile comes before the end tile.
        XCTAssertLessThan(tiles.firstIndex(of: ka)!, tiles.firstIndex(of: kb)!)
    }

    /// SEC-1: a GPX / import with NaN, ±∞ or out-of-range coordinates reaches the corridor prefetch
    /// on the main actor. It used to trap ("Double value cannot be converted to Int because it is
    /// either infinite or NaN"); now bad points are skipped and the good ones are still covered.
    func testCorridorCoverageNeverTrapsOnCorruptCoordinates() {
        let good = [GeoPoint(lat: 45.10, lon: 25.00), GeoPoint(lat: 45.13, lon: 25.03)]
        let poison: [GeoPoint] = [
            GeoPoint(lat: 45.1, lon: 1e300), GeoPoint(lat: .nan, lon: 25.01), GeoPoint(lat: 45.11, lon: .infinity),
            GeoPoint(lat: 200, lon: 25.02), GeoPoint(lat: 45.12, lon: 1e20), GeoPoint(lat: -.infinity, lon: -.infinity),
            GeoPoint(lat: 45.1, lon: -181),
        ]
        let mixed = [good[0]] + poison + [good[1]]
        for z in [0, 14, 17, 24] {
            let tiles = TileCoverage.tiles(corridor: mixed, zoom: z, radiusMeters: 250, limit: 400)
            let clean = TileCoverage.tiles(corridor: good, zoom: z, radiusMeters: 250, limit: 400)
            XCTAssertEqual(tiles, clean, "z\(z): bad points are skipped, the route between the good ones is kept")
            XCTAssertTrue(tiles.allSatisfy { $0.isValid })
        }
        XCTAssertEqual(TileCoverage.tiles(corridor: poison, zoom: 15, radiusMeters: 250, limit: 400), [])
        // Absurd radii and zooms are clamped / rejected, never converted unchecked.
        XCTAssertFalse(TileCoverage.tiles(corridor: good, zoom: 3, radiusMeters: 1e300, limit: 50).isEmpty)
        XCTAssertFalse(TileCoverage.tiles(corridor: good, zoom: 15, radiusMeters: .nan, limit: 50).isEmpty)
        XCTAssertEqual(TileCoverage.tiles(corridor: good, zoom: 25, radiusMeters: 250, limit: 50), [])
        // An antipodal segment is sampled within the cap and stops at the limit.
        let far = TileCoverage.tiles(corridor: [GeoPoint(lat: 0, lon: -179.9), GeoPoint(lat: 0.1, lon: 179.9)],
                                     zoom: 17, radiusMeters: 250, limit: 400)
        XCTAssertEqual(far.count, 400)
        // The tile index helpers clamp instead of trapping.
        XCTAssertEqual(TileCoverage.tileX(lon: .nan, zoom: 3), 4)
        XCTAssertEqual(TileCoverage.tileX(lon: 1e300, zoom: 3), 7)
        XCTAssertEqual(TileCoverage.tileX(lon: -.infinity, zoom: 3), 0)
        XCTAssertEqual(TileCoverage.tileY(lat: .nan, zoom: 3), 4)
        XCTAssertEqual(TileCoverage.tileY(lat: .infinity, zoom: 3), 0)
        XCTAssertFalse(TileCoverage.isUsable(GeoPoint(lat: 91, lon: 0)))
        XCTAssertTrue(TileCoverage.isUsable(GeoPoint(lat: -90, lon: 180)))
    }

    func testCorridorCoverageRespectsTheLimit() {
        let route = (0 ..< 50).map { GeoPoint(lat: 45 + Double($0) * 0.01, lon: 25 + Double($0) * 0.01) }
        let tiles = TileCoverage.tiles(corridor: route, zoom: 16, radiusMeters: 500, limit: 37)
        XCTAssertEqual(tiles.count, 37)
        XCTAssertEqual(TileCoverage.tiles(corridor: [], zoom: 16, radiusMeters: 500, limit: 37), [])
        XCTAssertEqual(TileCoverage.tiles(corridor: route, zoom: 16, radiusMeters: 500, limit: 0), [])
    }

    // MARK: LRU

    func testLRUEvictsLeastRecentlyUsed() {
        var lru = VideoLRU<String, Int>(capacity: 3)
        XCTAssertNil(lru.set("a", 1))
        XCTAssertNil(lru.set("b", 2))
        XCTAssertNil(lru.set("c", 3))
        XCTAssertEqual(lru.get("a"), 1) // a is now the most recent
        XCTAssertEqual(lru.set("d", 4), "b")
        XCTAssertFalse(lru.contains("b"))
        XCTAssertEqual(lru.count, 3)
        XCTAssertNil(lru.set("c", 33)) // replace, no eviction
        XCTAssertEqual(lru.peek("c"), 33)
        XCTAssertEqual(lru.set("e", 5), "a") // peek does not refresh; a was used before c was replaced
        lru.remove("c")
        XCTAssertEqual(lru.count, 2)
        lru.removeAll()
        XCTAssertEqual(lru.count, 0)
    }

    // MARK: retry policy

    func testFetchPolicy() {
        XCTAssertNil(TileFetchPolicy.retryDelay(status: 200))
        XCTAssertEqual(TileFetchPolicy.retryDelay(status: 404), 3_600)
        XCTAssertEqual(TileFetchPolicy.retryDelay(status: 410), 3_600)
        XCTAssertEqual(TileFetchPolicy.retryDelay(status: 429), 60)
        XCTAssertEqual(TileFetchPolicy.retryDelay(status: 503), 30)
        XCTAssertEqual(TileFetchPolicy.retryDelay(status: 403), 600)
        XCTAssertEqual(TileFetchPolicy.globalPause(status: 429), 10)
        XCTAssertEqual(TileFetchPolicy.globalPause(status: 502), 5)
        XCTAssertEqual(TileFetchPolicy.globalPause(status: 404), 0)
        XCTAssertEqual((0 ... 8).map { TileFetchPolicy.networkBackoff(consecutiveFailures: $0) }, [0, 2, 4, 8, 16, 32, 60, 60, 60])
    }

    // MARK: night inversion (osmdroid INVERT_COLORS: 255 − c, alpha kept)

    func testNightInversionOpaqueAndPremultipliedPixels() {
        // 2×2 BGRA with 4 bytes of row padding.
        var px: [UInt8] = [
            10, 20, 30, 255, 0, 0, 0, 255, 0xAA, 0xAA, 0xAA, 0xAA,
            50, 25, 0, 128, 0, 0, 0, 0, 0xBB, 0xBB, 0xBB, 0xBB,
        ]
        px.withUnsafeMutableBytes { TileNightInversion.invertPremultiplied($0, width: 2, height: 2, bytesPerRow: 12) }
        XCTAssertEqual(Array(px[0 ..< 8]), [245, 235, 225, 255, 255, 255, 255, 255])
        XCTAssertEqual(Array(px[8 ..< 12]), [0xAA, 0xAA, 0xAA, 0xAA], "padding untouched")
        XCTAssertEqual(Array(px[12 ..< 20]), [78, 103, 128, 128, 0, 0, 0, 0], "premultiplied: c' = a − c")
        XCTAssertEqual(Array(px[20 ..< 24]), [0xBB, 0xBB, 0xBB, 0xBB])
    }

    func testNightInversionIsAnInvolutionForOpaquePixels() {
        var px = (0 ..< 64).map { UInt8(truncatingIfNeeded: $0 * 37) }
        for i in stride(from: 3, to: px.count, by: 4) { px[i] = 255 }
        let original = px
        px.withUnsafeMutableBytes { TileNightInversion.invertPremultiplied($0, width: 4, height: 4, bytesPerRow: 16) }
        XCTAssertNotEqual(px, original)
        px.withUnsafeMutableBytes { TileNightInversion.invertPremultiplied($0, width: 4, height: 4, bytesPerRow: 16) }
        XCTAssertEqual(px, original)
    }

    func testNightInversionRejectsShortBuffers() {
        var px: [UInt8] = [1, 2, 3, 255]
        px.withUnsafeMutableBytes { TileNightInversion.invertPremultiplied($0, width: 2, height: 1, bytesPerRow: 8) }
        XCTAssertEqual(px, [1, 2, 3, 255])
        px.withUnsafeMutableBytes { TileNightInversion.lightnessInvertPremultiplied($0, width: 2, height: 1, bytesPerRow: 8) }
        XCTAssertEqual(px, [1, 2, 3, 255])
        px.withUnsafeMutableBytes { TileNightInversion.lightnessInvertPremultiplied($0, width: 1, height: 1, bytesPerRow: 4, alphaIndex: 4) }
        XCTAssertEqual(px, [1, 2, 3, 255], "invalid alpha index")
    }

    // MARK: night lightness inversion (iOS default: HSL L' = 1 − L, hue and saturation kept)

    /// HSL (hue degrees, saturation, lightness) of an opaque 0xRRGGBB colour.
    private func hsl(_ rgb: UInt32) -> (h: Double, s: Double, l: Double) {
        let r = Double((rgb >> 16) & 0xFF) / 255, g = Double((rgb >> 8) & 0xFF) / 255, b = Double(rgb & 0xFF) / 255
        let mx = max(r, g, b), mn = min(r, g, b), c = mx - mn
        let l = (mx + mn) / 2
        let s = c == 0 ? 0 : c / (1 - abs(2 * l - 1))
        var h = 0.0
        if c > 0 {
            if mx == r {
                h = 60 * ((g - b) / c).truncatingRemainder(dividingBy: 6)
            } else if mx == g {
                h = 60 * ((b - r) / c + 2)
            } else {
                h = 60 * ((r - g) / c + 4)
            }
        }
        return (h < 0 ? h + 360 : h, s, l)
    }

    func testLightnessInversionOfOSMColours() {
        // (day colour, night colour without dimming): c' = c + 255 − (max + min)
        let vectors: [(String, UInt32, UInt32)] = [
            ("white", 0xFFFFFF, 0x000000),
            ("black", 0x000000, 0xFFFFFF),
            ("OSM land", 0xF2EFE9, 0x16130D),
            ("park", 0xC8FACC, 0x053709),
            ("water", 0xAAD3DF, 0x204955),
            ("road (minor)", 0xFFFFFF, 0x000000),
            ("road (secondary)", 0xF7FABF, 0x3D4005),
            ("mid grey", 0x808080, 0x7F7F7F),
            ("pure red", 0xFF0000, 0xFF0000), // L = 0.5 is its own mirror image
        ]
        for (name, day, night) in vectors {
            let got = TileNightInversion.lightnessInverted(rgb: day)
            XCTAssertEqual(got, night, "\(name): got \(String(format: "%06X", got))")
        }
        // greys behave exactly like osmdroid's 255 − c
        for grey: UInt32 in [0x000000, 0x404040, 0x808080, 0xBBBBBB, 0xFFFFFF] {
            XCTAssertEqual(TileNightInversion.lightnessInverted(rgb: grey), 0xFFFFFF - grey)
        }
        // hue and saturation kept, lightness mirrored (within 8-bit quantisation)
        for (name, day, night) in vectors where hsl(day).s > 0.05 {
            let a = hsl(day), b = hsl(night)
            XCTAssertEqual(b.l, 1 - a.l, accuracy: 0.5 / 255, name)
            XCTAssertEqual(b.s, a.s, accuracy: 0.02, name)
            XCTAssertLessThanOrEqual(abs(DashEasing.shortestTurnDeg(from: a.h, to: b.h)), 1.5, name)
        }
        // osmdroid's 255 − c turned parks magenta and water orange (hue + 180°)
        XCTAssertEqual(0xFFFFFF - 0xC8FACC, 0x370533)
        XCTAssertEqual(abs(DashEasing.shortestTurnDeg(from: hsl(0xC8FACC).h, to: hsl(0x370533).h)), 180, accuracy: 1.5)
        XCTAssertEqual(abs(DashEasing.shortestTurnDeg(from: hsl(0xAAD3DF).h, to: hsl(0xFFFFFF - 0xAAD3DF).h)), 180, accuracy: 1.5)
    }

    func testLightnessInversionDoublesAndDimming() {
        let w = TileNightInversion.lightnessInverted(r: 1, g: 1, b: 1)
        XCTAssertEqual([w.r, w.g, w.b], [0, 0, 0])
        let k = TileNightInversion.lightnessInverted(r: 0, g: 0, b: 0)
        XCTAssertEqual([k.r, k.g, k.b], [1, 1, 1])
        let p = TileNightInversion.lightnessInverted(r: 200 / 255, g: 250 / 255, b: 204 / 255)
        XCTAssertEqual(p.r * 255, 5, accuracy: 1e-9)
        XCTAssertEqual(p.g * 255, 55, accuracy: 1e-9)
        XCTAssertEqual(p.b * 255, 9, accuracy: 1e-9)
        for _ in 0 ..< 200 {
            let (r, g, b) = (Double.random(in: 0 ... 1), Double.random(in: 0 ... 1), Double.random(in: 0 ... 1))
            let o = TileNightInversion.lightnessInverted(r: r, g: g, b: b)
            for c in [o.r, o.g, o.b] { XCTAssertTrue(c >= -1e-12 && c <= 1 + 1e-12, "\(c)") }
            XCTAssertEqual(max(o.r, o.g, o.b) - min(o.r, o.g, o.b), max(r, g, b) - min(r, g, b), accuracy: 1e-12) // chroma kept
            let back = TileNightInversion.lightnessInverted(r: o.r, g: o.g, b: o.b) // an involution
            XCTAssertEqual(back.r, r, accuracy: 1e-12)
            XCTAssertEqual(back.b, b, accuracy: 1e-12)
        }
        // ×0.9 against night glare, rounded half away from zero; 1 = none; clamped to 0…1
        XCTAssertEqual(TileNightInversion.lightnessInverted(rgb: 0xF2EFE9, dimming: 0.9), 0x14110C) // (22,19,13) → (20,17,12)
        XCTAssertEqual(TileNightInversion.lightnessInverted(rgb: 0x808080, dimming: 0.9), 0x727272) // 127 → 114.3
        XCTAssertEqual(TileNightInversion.lightnessInverted(rgb: 0x000000, dimming: 0.9), 0xE6E6E6) // 229.5 → 230
        XCTAssertEqual(TileNightInversion.lightnessInverted(rgb: 0xF2EFE9, dimming: 1), 0x16130D)
        XCTAssertEqual(TileNightInversion.lightnessInverted(rgb: 0x000000, dimming: 7), 0xFFFFFF)
        XCTAssertEqual(TileNightInversion.lightnessInverted(rgb: 0x000000, dimming: -1), 0x000000)
        XCTAssertEqual(TileNightInversion.lightnessInverted(rgb: 0x000000, dimming: .nan), 0xFFFFFF)
    }

    func testLightnessInversionOfPremultipliedPixels() {
        // opaque: same as the 0xRRGGBB maths
        XCTAssertTrue(TileNightInversion.lightnessInvertedPremultiplied(200, 250, 204, alpha: 255) == (5, 55, 9))
        // park at half alpha, premultiplied (100,125,102,128): c' = c + a − max − min = c − 97 …
        XCTAssertTrue(TileNightInversion.lightnessInvertedPremultiplied(100, 125, 102, alpha: 128) == (3, 28, 5))
        // … which is the un-premultiplied maths, premultiplied again
        let u = TileNightInversion.lightnessInverted(r: 100 / 128, g: 125 / 128, b: 102 / 128)
        XCTAssertEqual(u.r * 128, 3, accuracy: 1e-9)
        XCTAssertEqual(u.g * 128, 28, accuracy: 1e-9)
        XCTAssertEqual(u.b * 128, 5, accuracy: 1e-9)
        // white at alpha 128 (128,128,128) → black; black at alpha 128 → white at alpha 128
        XCTAssertTrue(TileNightInversion.lightnessInvertedPremultiplied(128, 128, 128, alpha: 128) == (0, 0, 0))
        XCTAssertTrue(TileNightInversion.lightnessInvertedPremultiplied(0, 0, 0, alpha: 128) == (128, 128, 128))
        // transparent stays transparent; invalid channels above alpha are clamped to alpha first
        XCTAssertTrue(TileNightInversion.lightnessInvertedPremultiplied(0, 0, 0, alpha: 0) == (0, 0, 0))
        XCTAssertTrue(TileNightInversion.lightnessInvertedPremultiplied(9, 200, 3, alpha: 0) == (0, 0, 0))
        XCTAssertTrue(TileNightInversion.lightnessInvertedPremultiplied(255, 90, 10, alpha: 64) == (54, 54, 0)) // (64,64,10) − 10
        // every valid premultiplied input stays valid (c ≤ a), random sweep
        for _ in 0 ..< 2_000 {
            let a = UInt8.random(in: 0 ... 255)
            let c = (UInt8.random(in: 0 ... a), UInt8.random(in: 0 ... a), UInt8.random(in: 0 ... a))
            let o = TileNightInversion.lightnessInvertedPremultiplied(c.0, c.1, c.2, alpha: a, dimming: 0.9)
            XCTAssertLessThanOrEqual(o.0, a)
            XCTAssertLessThanOrEqual(o.1, a)
            XCTAssertLessThanOrEqual(o.2, a)
        }
    }

    func testLightnessInversionInPlaceKeepsAlphaAndPadding() {
        // 2×2 BGRA (alpha last) with 4 bytes of row padding: land, park @ α128, transparent, water.
        var px: [UInt8] = [
            0xE9, 0xEF, 0xF2, 255, 102, 125, 100, 128, 0xAA, 0xAA, 0xAA, 0xAA,
            0, 0, 0, 0, 0xDF, 0xD3, 0xAA, 255, 0xBB, 0xBB, 0xBB, 0xBB,
        ]
        px.withUnsafeMutableBytes { TileNightInversion.lightnessInvertPremultiplied($0, width: 2, height: 2, bytesPerRow: 12) }
        XCTAssertEqual(Array(px[0 ..< 4]), [0x0D, 0x13, 0x16, 255], "land → #16130D (BGRA)")
        XCTAssertEqual(Array(px[4 ..< 8]), [5, 28, 3, 128], "premultiplied park")
        XCTAssertEqual(Array(px[8 ..< 12]), [0xAA, 0xAA, 0xAA, 0xAA], "padding untouched")
        XCTAssertEqual(Array(px[12 ..< 16]), [0, 0, 0, 0], "transparent")
        XCTAssertEqual(Array(px[16 ..< 20]), [0x55, 0x49, 0x20, 255], "water → #204955 (BGRA)")
        XCTAssertEqual(Array(px[20 ..< 24]), [0xBB, 0xBB, 0xBB, 0xBB])
        // alpha first (ARGB): the colour bytes are the three others
        var argb: [UInt8] = [255, 0xC8, 0xFA, 0xCC]
        argb.withUnsafeMutableBytes {
            TileNightInversion.lightnessInvertPremultiplied($0, width: 1, height: 1, bytesPerRow: 4, alphaIndex: 0)
        }
        XCTAssertEqual(argb, [255, 5, 55, 9])
        // dimming through the lookup table equals the scalar maths
        var dim: [UInt8] = [0xE9, 0xEF, 0xF2, 255, 0, 0, 0, 255]
        dim.withUnsafeMutableBytes {
            TileNightInversion.lightnessInvertPremultiplied($0, width: 2, height: 1, bytesPerRow: 8, dimming: 0.9)
        }
        XCTAssertEqual(Array(dim[0 ..< 4]), [12, 17, 20, 255])
        XCTAssertEqual(Array(dim[4 ..< 8]), [230, 230, 230, 255])
    }

    func testNightFilterIdentityAndStyles() {
        XCTAssertEqual(TileNightStyle.allCases, [.lightnessInvert, .rgbInvert])
        XCTAssertEqual(TileNightFilter(style: .lightnessInvert, dimming: 0.9), TileNightFilter(style: .lightnessInvert, dimming: 0.9))
        XCTAssertNotEqual(TileNightFilter(style: .lightnessInvert, dimming: 0.9), TileNightFilter(style: .lightnessInvert, dimming: 1))
        XCTAssertNotEqual(TileNightFilter(style: .lightnessInvert, dimming: 1), TileNightFilter(style: .rgbInvert))
        // the parity style is never dimmed: its identity ignores the dimming
        XCTAssertEqual(TileNightFilter(style: .rgbInvert, dimming: 0.5), TileNightFilter(style: .rgbInvert, dimming: 1))
        XCTAssertEqual(TileNightFilter(style: .lightnessInvert, dimming: 3).dimming, 1)
        let park: [UInt8] = [0xCC, 0xFA, 0xC8, 255] // BGRA
        var a = park, b = park
        a.withUnsafeMutableBytes { TileNightFilter(style: .rgbInvert).apply(to: $0, width: 1, height: 1, bytesPerRow: 4) }
        XCTAssertEqual(a, [0x33, 0x05, 0x37, 255], "osmdroid: magenta park")
        b.withUnsafeMutableBytes { TileNightFilter(style: .lightnessInvert).apply(to: $0, width: 1, height: 1, bytesPerRow: 4) }
        XCTAssertEqual(b, [9, 55, 5, 255], "iOS: dark green park")
    }
}
