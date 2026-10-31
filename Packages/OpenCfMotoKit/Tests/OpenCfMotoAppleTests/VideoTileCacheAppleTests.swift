// SPDX-License-Identifier: AGPL-3.0-or-later
// TileImageCache with a fake HTTP server (macOS CI): download → decode → memory/disk, night
// inversion, dedupe, 2-download limit, negative caching, stale serving, ancestors, prefetch.
#if canImport(CoreGraphics) && canImport(ImageIO) && canImport(CoreVideo) && canImport(CoreText)
import CoreGraphics
import CoreVideo
import ImageIO
import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoApple

private func pollUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}

/// 256×256 PNG: top half red, bottom half blue.
private func makePNG() -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(colorSpace: space, components: [1, 0, 0, 1])!)
    ctx.fill(CGRect(x: 0, y: 128, width: 256, height: 128)) // CG y-up: the top half
    ctx.setFillColor(CGColor(colorSpace: space, components: [0, 0, 1, 1])!)
    ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 128))
    let image = ctx.makeImage()!
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(dest))
    return data as Data
}

private final class FakeTileServer: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [HTTPRequest] = []
    private var inFlight = 0
    private var _maxInFlight = 0
    var status = 200
    var delay: TimeInterval = 0
    var offline = false
    let png = makePNG()

    var requests: [HTTPRequest] { lock.withLock { _requests } }
    var maxInFlight: Int { lock.withLock { _maxInFlight } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let (status, delay, offline) = lock.withLock { () -> (Int, TimeInterval, Bool) in
            _requests.append(request)
            inFlight += 1
            _maxInFlight = max(_maxInFlight, inFlight)
            return (self.status, self.delay, self.offline)
        }
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        lock.withLock { inFlight -= 1 }
        if offline { throw HTTPClientError.noNetwork }
        return HTTPResponse(status: status, headers: ["content-type": "image/png"], body: status == 200 ? png : Data())
    }
}

final class VideoTileCacheAppleTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ocm-tiles-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makeCache(_ server: FakeTileServer, dir: URL) -> (TileImageCache, Locked<[TileCacheKey]>) {
        let cache = TileImageCache(httpClient: server, configuration: .init(directory: dir))
        let loaded = Locked<[TileCacheKey]>([])
        cache.onTileLoaded = { k in loaded.withLock { $0.append(k) } }
        return (cache, loaded)
    }

    private func rgb(_ pb: CVPixelBuffer, _ x: Int, _ y: Int) -> [Int] {
        guard let p = PixelBufferFactory.pixel(pb, x: x, y: y) else { return [] }
        return [Int(p.r), Int(p.g), Int(p.b)]
    }

    func testDownloadDecodeAndDrawUprightDayAndNight() throws {
        let server = FakeTileServer()
        let (cache, loaded) = makeCache(server, dir: tempDir())
        XCTAssertNil(cache.image(z: 16, x: 100, y: 200, night: false))
        cache.request(z: 16, x: 100, y: 200)
        XCTAssertTrue(pollUntil { loaded.current.contains(TileCacheKey(z: 16, x: 100, y: 200)) })
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.url.absoluteString, "https://tile.openstreetmap.org/16/100/200.png")
        XCTAssertEqual(request.headers["User-Agent"], AppHTTPIdentity.userAgent)
        let image = try XCTUnwrap(cache.image(z: 16, x: 100, y: 200, night: false))
        XCTAssertEqual(image.width, 256)

        let renderer = DashRenderer(tileCache: cache)
        let pb = try XCTUnwrap(PixelBufferFactory.makeStandaloneBuffer(width: 128, height: 64))
        renderer.render(DashDisplayList(size: DashSize(width: 128, height: 64), background: .black, commands: [
            .tile(z: 16, x: 100, y: 200, rect: DashRect(x: 0, y: 0, width: 64, height: 64), invert: false),
            .tile(z: 16, x: 100, y: 200, rect: DashRect(x: 64, y: 0, width: 64, height: 64), invert: true),
        ]), into: pb)
        XCTAssertEqual(rgb(pb, 32, 10), [255, 0, 0], "day tile upright: red on top")
        XCTAssertEqual(rgb(pb, 32, 54), [0, 0, 255])
        XCTAssertEqual(rgb(pb, 96, 10), [0, 255, 255], "night: 255 − c")
        XCTAssertEqual(rgb(pb, 96, 54), [255, 255, 0])
        XCTAssertEqual(renderer.stats.tilesDrawn, 2)
        XCTAssertEqual(cache.stats.nightVariantsBuilt, 1)
        XCTAssertEqual(server.requests.count, 1)
    }

    func testRequestsAreDeduplicatedAndAtMostTwoRunConcurrently() throws {
        let server = FakeTileServer()
        server.delay = 0.1
        let (cache, loaded) = makeCache(server, dir: tempDir())
        for _ in 0 ..< 10 { cache.request(z: 15, x: 1, y: 1) }
        for x in 2 ..< 8 { cache.request(z: 15, x: x, y: 1) }
        XCTAssertTrue(pollUntil(10) { Set(loaded.current).count == 7 })
        XCTAssertEqual(server.requests.count, 7)
        XCTAssertLessThanOrEqual(server.maxInFlight, 2)
        XCTAssertGreaterThanOrEqual(server.maxInFlight, 1)
    }

    func testDiskCacheServesANewInstanceOffline() throws {
        let dir = tempDir()
        let server = FakeTileServer()
        let (cache, loaded) = makeCache(server, dir: dir)
        cache.request(z: 14, x: 3, y: 4)
        XCTAssertTrue(pollUntil { !loaded.current.isEmpty })
        let file = dir.appendingPathComponent(TileDiskLayout.sourceKey(for: cache.urlTemplate)).appendingPathComponent("14/3/4.png")
        XCTAssertTrue(pollUntil { FileManager.default.fileExists(atPath: file.path) })

        let offline = FakeTileServer()
        offline.offline = true
        let (second, loaded2) = makeCache(offline, dir: dir)
        second.request(z: 14, x: 3, y: 4)
        XCTAssertTrue(pollUntil { !loaded2.current.isEmpty })
        XCTAssertNotNil(second.image(z: 14, x: 3, y: 4, night: false))
        XCTAssertEqual(second.stats.diskHits, 1)
        XCTAssertEqual(offline.requests.count, 0, "fresh disk tile: no network")
    }

    func testStaleDiskTileIsServedAndRefreshed() throws {
        let dir = tempDir()
        let server = FakeTileServer()
        let (cache, loaded) = makeCache(server, dir: dir)
        let file = dir.appendingPathComponent(TileDiskLayout.sourceKey(for: cache.urlTemplate)).appendingPathComponent("13/5/6.png")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try server.png.write(to: file)
        let old = Date().addingTimeInterval(-100 * 24 * 3600)
        try FileManager.default.setAttributes([.creationDate: old, .modificationDate: old], ofItemAtPath: file.path)
        cache.request(z: 13, x: 5, y: 6)
        XCTAssertTrue(pollUntil { !loaded.current.isEmpty })
        XCTAssertEqual(cache.stats.staleServed, 1)
        XCTAssertTrue(pollUntil { server.requests.count == 1 }, "expired tile refreshed in the background")
        XCTAssertTrue(pollUntil { cache.stats.downloads == 1 })
    }

    func testMissingTileIsNotHammered() throws {
        let server = FakeTileServer()
        server.status = 404
        let (cache, _) = makeCache(server, dir: tempDir())
        cache.request(z: 19, x: 10, y: 10)
        XCTAssertTrue(pollUntil { cache.stats.downloadFailures == 1 })
        for _ in 0 ..< 5 { cache.request(z: 19, x: 10, y: 10) }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertNil(cache.image(z: 19, x: 10, y: 10, night: false))
    }

    func testTilesBeyondTheServerZoomAreNeverFetched() throws {
        let server = FakeTileServer()
        let (cache, _) = makeCache(server, dir: tempDir())
        cache.request(z: 20, x: 10, y: 10) // OSM serves 0…19
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(server.requests.count, 0)
    }

    func testAncestorFallbackCropsTheRightQuadrant() throws {
        let server = FakeTileServer()
        let (cache, loaded) = makeCache(server, dir: tempDir())
        cache.request(z: 15, x: 50, y: 100)
        XCTAssertTrue(pollUntil { !loaded.current.isEmpty })
        // Children of 15/50/100 at z16: (100,200) top-left, (100,201) bottom-left.
        let topLeft = try XCTUnwrap(cache.fallbackImage(z: 16, x: 100, y: 200, night: false))
        XCTAssertEqual(topLeft.width, 128)
        let pb = try XCTUnwrap(PixelBufferFactory.makeStandaloneBuffer(width: 64, height: 64))
        let renderer = DashRenderer(tileCache: cache)
        renderer.render(DashDisplayList(size: DashSize(width: 64, height: 64), background: .black, commands: [
            .tile(z: 16, x: 100, y: 200, rect: DashRect(x: 0, y: 0, width: 32, height: 64), invert: false),
            .tile(z: 16, x: 100, y: 201, rect: DashRect(x: 32, y: 0, width: 32, height: 64), invert: false),
        ]), into: pb)
        XCTAssertEqual(rgb(pb, 16, 32), [255, 0, 0], "top-left child is entirely in the red half")
        XCTAssertEqual(rgb(pb, 48, 32), [0, 0, 255], "bottom-left child is entirely in the blue half")
        XCTAssertEqual(renderer.stats.tilesFromParent, 2)
    }

    func testPrefetchDownloadsTheCorridor() throws {
        let server = FakeTileServer()
        let (cache, _) = makeCache(server, dir: tempDir())
        let n = cache.prefetch(corridor: [GeoPoint(lat: 45.0, lon: 25.0), GeoPoint(lat: 45.01, lon: 25.02)],
                               zooms: 14 ... 15, radiusMeters: 150)
        XCTAssertGreaterThan(n, 0)
        XCTAssertLessThanOrEqual(n, cache.configuration.maxPrefetchTiles)
        XCTAssertTrue(pollUntil(10) { server.requests.count == n }, "\(server.requests.count) of \(n)")
        XCTAssertTrue(pollUntil { cache.stats.downloads == n })
    }

    func testTemplateChangeDropsMemory() throws {
        let server = FakeTileServer()
        let (cache, loaded) = makeCache(server, dir: tempDir())
        cache.request(z: 12, x: 1, y: 2)
        XCTAssertTrue(pollUntil { !loaded.current.isEmpty })
        XCTAssertNotNil(cache.image(z: 12, x: 1, y: 2, night: false))
        cache.urlTemplate = "https://tiles.example.com/{z}/{x}/{y}.png"
        XCTAssertNil(cache.image(z: 12, x: 1, y: 2, night: false))
        cache.request(z: 12, x: 1, y: 2)
        XCTAssertTrue(pollUntil { server.requests.contains { $0.url.host == "tiles.example.com" } })
    }
}
#endif
