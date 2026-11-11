// SPDX-License-Identifier: AGPL-3.0-or-later
// The map's tile credit (navigation-dash.md §10.4): "© OpenStreetMap" drawn small in the map's free
// bottom-left corner while the tiles come from the OSMF servers — in the map layer (under every piece of
// chrome, overlay and sheet), never a control, clear of the chrome on every supported canvas.
import XCTest
@testable import OpenCfMotoCore

final class DashMapAttributionTests: XCTestCase {
    static let credit = MapTileSource.openStreetMapCredit

    /// The credit plates drawn in `list` (the rect of the credit's text command is its plate).
    static func credits(_ list: DashDisplayList) -> [DashRect] {
        list.commands.compactMap { cmd -> DashRect? in
            if case let .text(s, r, _) = cmd, s == credit { return r }
            return nil
        }
    }

    /// Index of the first command drawing `text` (or a `.fill` of `color` when `text` is nil).
    private func index(_ list: DashDisplayList, text: String? = nil, fill color: DashColor? = nil) -> Int? {
        list.commands.firstIndex { cmd in
            switch cmd {
            case let .text(s, _, _): return s == text
            case let .fill(_, c, _): return text == nil && c == color
            default: return false
            }
        }
    }

    private func frame(_ m: DashModel, now: TimeInterval = 100, setup: (DashUIController) -> Void = { _ in }) -> DashDisplayList {
        let ui = DashUIController()
        ui.update(m)
        setup(ui)
        return ui.displayList(now: now)
    }

    func testNoCreditForACustomTileServer() {
        var m = DashFixtures.navigating()
        m.mapAttribution = MapTileSource.attribution(template: "https://tiles.example.com/{z}/{x}/{y}.png")
        XCTAssertNil(m.mapAttribution)
        let list = frame(m)
        XCTAssertEqual(Self.credits(list), [])
        XCTAssertNil(index(list, fill: DashPalette.attributionFill), "no plate either")
        XCTAssertEqual(Self.credits(frame(DashFixtures.navigating())).count, 1, "the default tiles carry it")
    }

    /// Free ride on 800×384: the bottom-left corner, 8 dp from the safe edges; 11 sp medium on a plate of
    /// text + 2 × 8 by line + 2 × 2 dp.
    func testBottomLeftCornerOfTheFreeMap() throws {
        let list = frame(DashFixtures.freeRide())
        let r = try XCTUnwrap(Self.credits(list).first)
        let font = DashFont(size: 11, weight: .medium)
        let m = ApproximateTextMeasurer().measure(Self.credit, font: font)
        XCTAssertEqual(r.minX, 8, accuracy: 1e-9)
        XCTAssertEqual(r.maxY, 384 - 8, accuracy: 1e-9)
        XCTAssertEqual(r.width, m.width + 16, accuracy: 1e-9)
        XCTAssertEqual(r.height, m.lineHeight + 4, accuracy: 1e-9)
        guard case let .text(_, _, style)? = list.commands.first(where: { if case let .text(s, _, _) = $0 { return s == Self.credit }; return false })
        else { return XCTFail("no credit text") }
        XCTAssertEqual(style.font, font)
        XCTAssertEqual(style.alignment, .center)
        XCTAssertEqual(style.color, DashPalette.attributionText)
        // the plate is filled just before the text
        let at = try XCTUnwrap(index(list, text: Self.credit))
        guard case let .fill(_, plate, _) = list.commands[at - 1] else { return XCTFail("no plate") }
        XCTAssertEqual(plate, DashPalette.attributionFill)
        // margins move it with the safe area
        var margins = DashFixtures.freeRide()
        margins.margins = ScreenMargins(top: 22, bottom: 10, left: 12, right: 14)
        let inset = try XCTUnwrap(Self.credits(frame(margins)).first)
        XCTAssertEqual(inset.minX, 12 + 8, accuracy: 1e-9)
        XCTAssertEqual(inset.maxY, 384 - 10 - 8, accuracy: 1e-9)
    }

    /// Bottom-left cards push it up: it ends 6 dp above the topmost one it would touch.
    func testRisesAboveTheBottomLeftCards() throws {
        func region(_ list: DashDisplayList, _ id: String) throws -> DashRect {
            try XCTUnwrap(list.hitRegions.last { $0.id == id }?.rect, id)
        }
        // landscape navigating: above the metrics card
        var list = frame(DashFixtures.navigating())
        var r = try XCTUnwrap(Self.credits(list).first)
        XCTAssertEqual(r.maxY, try region(list, "metrics.card").minY - 6, accuracy: 1e-9)
        XCTAssertEqual(r.minX, 8, accuracy: 1e-9)
        // + the lap card over the metrics card: above both
        var lap = DashFixtures.navigating()
        lap.lapTimer = DashLapTimer(title: "LAP 2  0:31.20", meta: "LAST 0:30.00   BEST 0:30.00")
        list = frame(lap)
        r = try XCTUnwrap(Self.credits(list).first)
        XCTAssertEqual(r.maxY, try region(list, "lap.card").minY - 6, accuracy: 1e-9)
        // preview / arrival cards
        for m in [DashFixtures.preview(), DashFixtures.arrival()] {
            list = frame(m)
            r = try XCTUnwrap(Self.credits(list).first)
            let card = try region(list, m.inPreview ? "preview.card" : "arrive.card")
            XCTAssertEqual(r.maxY, card.minY - 6, accuracy: 1e-9)
        }
        // portrait free ride: the speed chip holds the corner
        list = frame(DashFixtures.freeRide(DashFixtures.port))
        r = try XCTUnwrap(Self.credits(list).first)
        XCTAssertEqual(r.maxY, try region(list, "speed.chip").minY - 6, accuracy: 1e-9)
        // portrait navigating: above the full-width metrics bar
        list = frame(DashFixtures.navigating(DashFixtures.port))
        r = try XCTUnwrap(Self.credits(list).first)
        XCTAssertEqual(r.maxY, try region(list, "metrics.card").minY - 6, accuracy: 1e-9)
        // 1280 wide: everything scales (×1.425)
        list = frame(DashFixtures.navigating(DashFixtures.wide))
        r = try XCTUnwrap(Self.credits(list).first)
        XCTAssertEqual(r.minX, 8 * 1.425, accuracy: 1e-9)
        XCTAssertEqual(r.maxY, try region(list, "metrics.card").minY - 6 * 1.425, accuracy: 1e-9)
    }

    /// In the map layer (after the tiles, route and puck, before every piece of chrome) and not a control:
    /// touches on it reach the map.
    func testInTheMapLayerAndNotAControl() throws {
        for m in [DashFixtures.freeRide(), DashFixtures.navigating(), DashFixtures.preview(DashFixtures.port)] {
            let list = frame(m)
            let at = try XCTUnwrap(index(list, text: Self.credit))
            let lastTile = try XCTUnwrap(list.commands.lastIndex { if case .tile = $0 { return true }; return false })
            XCTAssertGreaterThan(at, lastTile)
            let chrome = try XCTUnwrap(index(list, text: m.navigating ? "350 m" : m.inPreview ? "Câmpina" : "Search here"))
            XCTAssertLessThan(at, chrome, "under the chrome")
            let r = try XCTUnwrap(Self.credits(list).first)
            XCTAssertNil(list.hitTest(r.center), "touches on the credit reach the map")
            XCTAssertFalse(list.hitRegions.contains { $0.id.contains("credit") || $0.id.contains("attribution") })
        }
    }

    /// Sheets and the hold picture draw over it; the opaque Music sheet hides the map and its credit.
    func testUnderSheetsAndTheHoldPictureGoneWithTheMusicSheet() throws {
        /// Index of the full-canvas fill of `color` (the dimmer, the search sheet, the hold dimmer).
        func cover(_ list: DashDisplayList, _ color: DashColor) -> Int? {
            let full = DashPath.rect(DashRect(x: 0, y: 0, width: list.size.width, height: list.size.height))
            return list.commands.firstIndex(of: .fill(full, color, .nonZero))
        }
        // menu: under the dimmer
        var list = frame(DashFixtures.navigating()) { ui in _ = ui.perform(.openMenu, now: 100) }
        XCTAssertLessThan(try XCTUnwrap(index(list, text: Self.credit)), try XCTUnwrap(cover(list, DashPalette.dimmer)))
        // search: under the sheet (white by day)
        list = frame(DashFixtures.freeRide()) { ui in _ = ui.perform(.openSearch, now: 100) }
        XCTAssertLessThan(try XCTUnwrap(index(list, text: Self.credit)), try XCTUnwrap(cover(list, DashPalette.searchDay.sheetBackground)))
        // hold picture (P0, D17): a clean card, no map — so no credit either
        let ui = DashUIController()
        ui.update(DashFixtures.navigating())
        list = ui.displayList(forHoldScreen: "Paused", now: 100)
        XCTAssertNil(index(list, text: Self.credit))
        XCTAssertFalse(list.commands.contains { if case .tile = $0 { return true }; return false })
        // Music sheet: no map, no credit
        list = frame(DashFixtures.withMusic(DashFixtures.navigating()), now: DashFixtures.musicNow) { ui in
            _ = ui.perform(.openMusic, now: DashFixtures.musicNow)
        }
        XCTAssertNotNil(list.hitRegions.first { $0.id == "music.sheet" })
        XCTAssertEqual(Self.credits(list), [])
    }

    /// Toasts and the link banner (top overlays) never reach it on the supported canvases.
    func testClearOfTheToastAndTheLinkBannerOnEveryCanvas() {
        for c in DashLayoutInvariantTests.canvases {
            var lap = DashFixtures.navigating(c)
            lap.lapTimer = DashLapTimer(title: "LAP 2  0:31.20", meta: "LAST 0:30.00   BEST 0:30.00")
            for (name, base) in [("free", DashFixtures.freeRide(c)), ("nav", DashFixtures.navigating(c)), ("lap", lap),
                                 ("preview", DashFixtures.preview(c)), ("arrive", DashFixtures.arrival(c))] {
                var m = base
                m.linkBanner = "Reconnecting to the dash…"
                let list = frame(m) { ui in ui.showToast("Parking marked at Câmpina", now: 99) }
                let tag = "\(Int(c.width))×\(Int(c.height)) \(name)"
                guard let credit = Self.credits(list).first else { XCTFail("\(tag): no credit"); continue }
                for text in ["Reconnecting to the dash…", "Parking marked at Câmpina"] {
                    let pills = list.commands.compactMap { cmd -> DashRect? in
                        if case let .text(s, r, _) = cmd, s == text { return r.insetBy(dx: -16 * m.scale, dy: 0) }
                        return nil
                    }
                    XCTAssertEqual(pills.count, 1, "\(tag) \(text)")
                    for p in pills { XCTAssertFalse(credit.intersects(p), "\(tag): credit \(credit) under \(text) \(p)") }
                }
            }
        }
    }

    // MARK: Layout rules

    func testLayoutEllipsisRoomAndTermination() throws {
        let c = DashLayoutContext(canvas: DashSize(width: 800, height: 384))
        // a long credit (a future custom attribution) is ellipsised to 45 % of the safe width
        let long = String(repeating: "Map tiles © Example Cartography Ltd · ", count: 4)
        let l = try XCTUnwrap(DashLayout.mapAttribution(c, text: long, avoiding: [], topLimit: 0))
        XCTAssertTrue(l.text.hasSuffix("…"), l.text)
        XCTAssertLessThanOrEqual(l.frame.width, 800 * 0.45 + 1e-9)
        // one line: line breaks and tabs become spaces
        XCTAssertEqual(DashLayout.mapAttribution(c, text: "©\tOSM\ncontributors ", avoiding: [], topLimit: 0)?.text,
                       "© OSM contributors")
        XCTAssertNil(DashLayout.mapAttribution(c, text: " \n ", avoiding: [], topLimit: 0), "nothing to draw")
        // no room left under the top chrome → no credit (never one on the chrome)
        let wall = DashRect(x: 0, y: 60, width: 400, height: 324)
        XCTAssertNil(DashLayout.mapAttribution(c, text: Self.credit, avoiding: [wall], topLimit: 56))
        XCTAssertNotNil(DashLayout.mapAttribution(c, text: Self.credit, avoiding: [], topLimit: 56))
        // a rect exactly at the clearance edge, or grazing it by a rounding error, stops the climb (no loop)
        let free = try XCTUnwrap(DashLayout.mapAttribution(c, text: Self.credit, avoiding: [], topLimit: 0)).frame
        let below = DashRect(x: 0, y: free.maxY + 6, width: 300, height: 2)
        XCTAssertEqual(DashLayout.mapAttribution(c, text: Self.credit, avoiding: [below], topLimit: 0)?.frame, free)
        let grazing = DashRect(x: 0, y: free.maxY + 6 - 1e-12, width: 300, height: 2)
        let moved = try XCTUnwrap(DashLayout.mapAttribution(c, text: Self.credit, avoiding: [grazing, grazing], topLimit: 0)).frame
        XCTAssertEqual(moved.maxY, grazing.minY - 6, accuracy: 1e-9)
        // rects to the right of it never move it
        let right = DashRect(x: 400, y: 0, width: 400, height: 384)
        XCTAssertEqual(DashLayout.mapAttribution(c, text: Self.credit, avoiding: [right], topLimit: 0)?.frame, free)
    }
}
