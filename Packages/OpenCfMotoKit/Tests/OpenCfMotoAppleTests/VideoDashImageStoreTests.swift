// SPDX-License-Identifier: AGPL-3.0-or-later
// DashImageStore (macOS CI): the album artwork the dash draws — PNG / JPEG decode, invalid bytes
// rejected, aspect-fill variants with a centred crop, never upscaled past the decode, LRU eviction,
// variant cache, memory-warning purge + re-decode, concurrent access.
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoApple

final class VideoDashImageStoreTests: XCTestCase {
    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    /// `width` × `height`: left half `left`, right half `right` (0xRRGGBB), encoded as PNG or JPEG.
    private func encoded(_ width: Int, _ height: Int, left: UInt32, right: UInt32? = nil, jpeg: Bool = false) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: Self.space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func color(_ rgb: UInt32) -> CGColor {
            CGColor(colorSpace: Self.space, components: [CGFloat((rgb >> 16) & 0xFF) / 255, CGFloat((rgb >> 8) & 0xFF) / 255,
                                                         CGFloat(rgb & 0xFF) / 255, 1])!
        }
        ctx.setFillColor(color(left))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let right {
            ctx.setFillColor(color(right))
            ctx.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        }
        let image = ctx.makeImage()!
        let data = NSMutableData()
        let type = (jpeg ? "public.jpeg" : "public.png") as CFString
        let dest = CGImageDestinationCreateWithData(data as CFMutableData, type, 1, nil)!
        let options = jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary : nil
        CGImageDestinationAddImage(dest, image, options)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    /// RGBA of pixel (x, y), y from the TOP.
    private func rgba(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
        let w = image.width, h = image.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: Self.space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let i = y * w * 4 + x * 4
        return [Int(p[i]), Int(p[i + 1]), Int(p[i + 2]), Int(p[i + 3])]
    }

    private func assertNear(_ a: [Int], _ b: [Int], tolerance: Int = 3, _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, message, file: file, line: line)
        for (x, y) in zip(a, b) where abs(x - y) > tolerance {
            XCTFail("\(a) is not within \(tolerance) of \(b) \(message)", file: file, line: line)
            return
        }
    }

    func testPNGAndJPEGAreReadAndInvalidBytesRejected() throws {
        let store = DashImageStore()
        XCTAssertTrue(store.set(id: "music.art.p1", data: encoded(64, 64, left: 0x20C040)))
        XCTAssertTrue(store.set(id: "music.art.p2", data: encoded(64, 64, left: 0x3060A0, jpeg: true)))
        XCTAssertEqual(store.ids, ["music.art.p1", "music.art.p2"])
        let png = try XCTUnwrap(store.image(id: "music.art.p1", pixelWidth: 32, pixelHeight: 32))
        XCTAssertEqual([png.width, png.height], [32, 32])
        assertNear(rgba(png, 16, 16), [0x20, 0xC0, 0x40, 255])
        let jpg = try XCTUnwrap(store.image(id: "music.art.p2", pixelWidth: 32, pixelHeight: 32))
        assertNear(rgba(jpg, 16, 16), [0x30, 0x60, 0xA0, 255], tolerance: 6)

        XCTAssertFalse(store.set(id: "bad", data: Data([1, 2, 3, 4, 5])))
        XCTAssertFalse(store.set(id: "bad", data: Data()))
        XCTAssertFalse(store.set(id: "bad", data: Data([0x89, 0x50, 0x4E, 0x47, 0x07])), "a PNG signature alone is no image")
        XCTAssertFalse(store.contains(id: "bad"))
        XCTAssertNil(store.image(id: "bad", pixelWidth: 10, pixelHeight: 10))
        XCTAssertFalse(store.set(id: "music.art.p1", data: Data([9, 9, 9])), "bad bytes replace nothing…")
        XCTAssertFalse(store.contains(id: "music.art.p1"), "…and the old picture under that id is gone")
        XCTAssertNil(store.image(id: "unknown", pixelWidth: 10, pixelHeight: 10))
        XCTAssertNil(store.image(id: "music.art.p2", pixelWidth: 0, pixelHeight: 10))
        XCTAssertNil(store.image(id: "music.art.p2", pixelWidth: 10, pixelHeight: 100_000))
        store.remove(id: "music.art.p2")
        XCTAssertFalse(store.contains(id: "music.art.p2"))
        XCTAssertTrue(store.set(id: "a", data: encoded(8, 8, left: 0xFFFFFF)))
        store.removeAll()
        XCTAssertEqual(store.ids, [])
    }

    func testVariantsFillTheRectWithACentredCrop() throws {
        let store = DashImageStore()
        // 200 × 100: red left half, blue right half.
        XCTAssertTrue(store.set(id: "wide", data: encoded(200, 100, left: 0xFF0000, right: 0x0000FF)))
        // Square: the centred 100 × 100 crop (x 50…150) — half red, half blue — at 50 × 50.
        let square = try XCTUnwrap(store.image(id: "wide", pixelWidth: 50, pixelHeight: 50))
        XCTAssertEqual([square.width, square.height], [50, 50])
        assertNear(rgba(square, 10, 25), [255, 0, 0, 255])
        assertNear(rgba(square, 40, 25), [0, 0, 255, 255])
        // Wider than the image: full width, the middle rows.
        let strip = try XCTUnwrap(store.image(id: "wide", pixelWidth: 100, pixelHeight: 25))
        XCTAssertEqual([strip.width, strip.height], [100, 25])
        assertNear(rgba(strip, 5, 12), [255, 0, 0, 255])
        assertNear(rgba(strip, 95, 12), [0, 0, 255, 255])
        // Tall: the middle 50 columns are all around the red / blue edge, nothing else.
        let tall = try XCTUnwrap(store.image(id: "wide", pixelWidth: 20, pixelHeight: 40))
        XCTAssertEqual([tall.width, tall.height], [20, 40])
        assertNear(rgba(tall, 2, 20), [255, 0, 0, 255])
        assertNear(rgba(tall, 17, 20), [0, 0, 255, 255])
    }

    func testNeverUpscaledPastTheDecode() throws {
        let store = DashImageStore()
        XCTAssertTrue(store.set(id: "small", data: encoded(40, 40, left: 0x808080)))
        let big = try XCTUnwrap(store.image(id: "small", pixelWidth: 80, pixelHeight: 80))
        XCTAssertEqual([big.width, big.height], [40, 40], "the cropped decode; the renderer stretches it")
        let wide = try XCTUnwrap(store.image(id: "small", pixelWidth: 160, pixelHeight: 80))
        XCTAssertEqual([wide.width, wide.height], [40, 20], "same aspect as the rect, still decode pixels")
        // Huge artwork is decoded at ≤ 640 px.
        XCTAssertTrue(store.set(id: "huge", data: encoded(1_000, 500, left: 0x404040)))
        let fit = try XCTUnwrap(store.image(id: "huge", pixelWidth: 640, pixelHeight: 640))
        XCTAssertEqual([fit.width, fit.height], [320, 320], "decode 640 × 320, centred square crop")
        var config = DashImageStore.Configuration()
        config.maxDecodePixels = 100
        let tiny = DashImageStore(configuration: config)
        XCTAssertTrue(tiny.set(id: "huge", data: encoded(1_000, 500, left: 0x404040)))
        let capped = try XCTUnwrap(tiny.image(id: "huge", pixelWidth: 500, pixelHeight: 250))
        XCTAssertEqual([capped.width, capped.height], [100, 50])
    }

    func testLeastRecentlyUsedImagesAreDropped() throws {
        var config = DashImageStore.Configuration()
        config.capacity = 2
        let store = DashImageStore(configuration: config)
        XCTAssertTrue(store.set(id: "a", data: encoded(8, 8, left: 0xFF0000)))
        XCTAssertTrue(store.set(id: "b", data: encoded(8, 8, left: 0x00FF00)))
        XCTAssertNotNil(store.image(id: "a", pixelWidth: 8, pixelHeight: 8)) // a used after b
        XCTAssertTrue(store.set(id: "c", data: encoded(8, 8, left: 0x0000FF)))
        XCTAssertEqual(store.ids, ["a", "c"])
        XCTAssertNil(store.image(id: "b", pixelWidth: 8, pixelHeight: 8))
    }

    func testVariantsAreCachedAndAPurgeKeepsTheBytes() throws {
        let store = DashImageStore()
        XCTAssertTrue(store.set(id: "a", data: encoded(64, 64, left: 0xFF0000)))
        _ = try XCTUnwrap(store.image(id: "a", pixelWidth: 32, pixelHeight: 32))
        _ = try XCTUnwrap(store.image(id: "a", pixelWidth: 32, pixelHeight: 32))
        XCTAssertEqual([store.decodeCount, store.variantCount], [1, 1], "decoded once, scaled once")
        _ = try XCTUnwrap(store.image(id: "a", pixelWidth: 64, pixelHeight: 64))
        XCTAssertEqual([store.decodeCount, store.variantCount], [1, 2], "another rect: another variant, same decode")
        // Memory warning (by notification name, as UIKit posts it).
        NotificationCenter.default.post(name: Notification.Name("UIApplicationDidReceiveMemoryWarningNotification"), object: nil)
        XCTAssertTrue(store.contains(id: "a"), "the bytes stay")
        let again = try XCTUnwrap(store.image(id: "a", pixelWidth: 32, pixelHeight: 32))
        XCTAssertEqual([store.decodeCount, store.variantCount], [2, 3], "decoded again on the next draw")
        assertNear(rgba(again, 16, 16), [255, 0, 0, 255])
        // New bytes under the same id: no stale variant.
        XCTAssertTrue(store.set(id: "a", data: encoded(64, 64, left: 0x0000FF)))
        let replaced = try XCTUnwrap(store.image(id: "a", pixelWidth: 32, pixelHeight: 32))
        assertNear(rgba(replaced, 16, 16), [0, 0, 255, 255])
        store.purgeDecoded()
        XCTAssertNotNil(store.image(id: "a", pixelWidth: 32, pixelHeight: 32))
    }

    func testConcurrentRegistrationAndDrawing() {
        let store = DashImageStore()
        let images = (0 ..< 4).map { encoded(48, 48, left: UInt32(0x202020 * ($0 + 1))) }
        DispatchQueue.concurrentPerform(iterations: 400) { i in
            let id = "img\(i % 4)"
            switch i % 5 {
            case 0: store.set(id: id, data: images[i % 4])
            case 1: store.remove(id: id)
            case 2: store.purgeDecoded()
            default: _ = store.image(id: id, pixelWidth: 16 + i % 7, pixelHeight: 16 + i % 3)
            }
        }
        for i in 0 ..< 4 { store.set(id: "img\(i)", data: images[i]) }
        for i in 0 ..< 4 { XCTAssertNotNil(store.image(id: "img\(i)", pixelWidth: 24, pixelHeight: 24)) }
    }
}
#endif
