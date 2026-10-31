// SPDX-License-Identifier: AGPL-3.0-or-later
// DashMemory.kt port (session-network.md §8.2, media-video.md §10.2).

import XCTest
@testable import OpenCfMotoCore

final class DashMemoryTests: XCTestCase {

    func testObserveStoresUnroundedSize() {
        let kv = InMemoryKeyValueStore()
        let m = DashMemory(store: kv)
        XCTAssertTrue(m.observe(ssid: "CFMOTO-f46457", width: 800, height: 386))
        XCTAssertEqual(kv.string(forKey: "dash_geo_CFMOTO-f46457"), "800x386")
        XCTAssertFalse(m.observe(ssid: "CFMOTO-f46457", width: 800, height: 386)) // unchanged
        XCTAssertEqual(m.learnedSize(forSSID: "CFMOTO-f46457"), LearnedDashSize(width: 800, height: 386))
        XCTAssertEqual(m.learnedCanvas(forSSID: "CFMOTO-f46457"),
                       VideoCanvas(width: 800, height: 384, requestedWidth: 800, requestedHeight: 386))
        XCTAssertTrue(m.observe(ssid: "CFMOTO-f46457", canvas: .rounded(requestedWidth: 800, requestedHeight: 951)))
        XCTAssertEqual(kv.string(forKey: "dash_geo_CFMOTO-f46457"), "800x951")
        XCTAssertEqual(m.learnedCanvas(forSSID: "CFMOTO-f46457")?.height, 944)
    }

    func testObserveIgnoresBadInput() {
        let kv = InMemoryKeyValueStore()
        let m = DashMemory(store: kv)
        XCTAssertFalse(m.observe(ssid: nil, width: 800, height: 386))
        XCTAssertFalse(m.observe(ssid: "  ", width: 800, height: 386))
        XCTAssertFalse(m.observe(ssid: "A", width: 0, height: 386))
        XCTAssertFalse(m.observe(ssid: "A", width: 800, height: -1))
        XCTAssertTrue(kv.allKeys().isEmpty)
        XCTAssertNil(m.learnedSize(forSSID: nil))
        XCTAssertNil(m.learnedSize(forSSID: "A"))
    }

    func testSsidIsCaseSensitive() {
        let m = DashMemory(store: InMemoryKeyValueStore())
        m.observe(ssid: "Bike", width: 1280, height: 576)
        XCTAssertNil(m.learnedSize(forSSID: "bike"))
        XCTAssertEqual(m.learnedSize(forSSID: "Bike")?.description, "1280x576")
        m.forget(ssid: "Bike")
        XCTAssertNil(m.learnedSize(forSSID: "Bike"))
    }

    func testParse() {
        XCTAssertEqual(DashMemory.parse("800x951"), LearnedDashSize(width: 800, height: 951))
        XCTAssertEqual(DashMemory.parse("800x951x7"), LearnedDashSize(width: 800, height: 951)) // extra parts ignored
        XCTAssertEqual(DashMemory.parse("+800x+951"), LearnedDashSize(width: 800, height: 951)) // Kotlin toIntOrNull
        XCTAssertEqual(DashMemory.parse("8192x1"), LearnedDashSize(width: 8192, height: 1))
        XCTAssertNil(DashMemory.parse("8193x100"))
        XCTAssertNil(DashMemory.parse("0x100"))
        XCTAssertNil(DashMemory.parse("800X951"))
        XCTAssertNil(DashMemory.parse("800"))
        XCTAssertNil(DashMemory.parse(" 800x951"))
        XCTAssertNil(DashMemory.parse(""))
    }

    func testLastDashTouch() {
        let m = DashMemory(store: InMemoryKeyValueStore())
        XCTAssertNil(m.lastDashTouch())
        m.setLastDashTouch(true)
        XCTAssertEqual(m.lastDashTouch(), true)
    }

    func testBestFit() {
        // 800×951 → rounded 800×944: no AA size has w == 800 & h ≥ 944 or h == 944 → nil
        XCTAssertNil(DashMemory.bestFit(width: 800, height: 951))
        // 800×386 → 800×384: LANDSCAPE_800x480 (w == 800, 480 ≥ 384)
        XCTAssertEqual(DashMemory.bestFit(width: 800, height: 386), .landscape800x480)
        // 1280×576 → LANDSCAPE_1280x720
        XCTAssertEqual(DashMemory.bestFit(width: 1280, height: 576), .landscape1280x720)
        // 720×712 → 720×704: PORTRAIT_720x1280 (w == 720, h 1280 ≥ 704); 1280x720 has h == 720 ≠ 704
        XCTAssertEqual(DashMemory.bestFit(width: 720, height: 712), .portrait720x1280)
        // 800×480 exact
        XCTAssertEqual(DashMemory.bestFit(width: 800, height: 480), .landscape800x480)
        // 1080×1920 exact
        XCTAssertEqual(DashMemory.bestFit(width: 1080, height: 1920), .portrait1080x1920)
        // 640×480 → h == 480 & w 800 ≥ 640 → 800x480
        XCTAssertEqual(DashMemory.bestFit(width: 640, height: 480), .landscape800x480)
        XCTAssertEqual(DashMemory.AAResolution.landscape1280x720.width, 1280)
    }
}
