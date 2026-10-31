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
    }
}
