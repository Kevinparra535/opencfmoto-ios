// SPDX-License-Identifier: AGPL-3.0-or-later
// Apple Music (iOS addition): geometry of the now-playing tile and the Music sheet on every
// supported canvas (tables of the music contract §3.2 / §3.3, ApproximateTextMeasurer; the tables
// print whole px, so edges are checked within ±0.5 px).
import XCTest
@testable import OpenCfMotoCore

final class DashMusicLayoutTests: XCTestCase {
    private let measurer = ApproximateTextMeasurer()

    private func ctx(_ w: Double, _ h: Double, margins: ScreenMargins = .zero) -> DashLayoutContext {
        DashLayoutContext(canvas: DashSize(width: w, height: h), margins: margins, measurer: measurer)
    }

    /// x0…x1 × y0…y1 within ±0.5 px.
    private func assertEdges(_ r: DashRect?, _ e: [Double], _ tag: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let r else { return XCTFail("\(tag): nil rect", file: file, line: line) }
        let tol = 0.5 + 1e-9
        XCTAssertEqual(r.minX, e[0], accuracy: tol, "\(tag) minX \(r)", file: file, line: line)
        XCTAssertEqual(r.maxX, e[1], accuracy: tol, "\(tag) maxX \(r)", file: file, line: line)
        XCTAssertEqual(r.minY, e[2], accuracy: tol, "\(tag) minY \(r)", file: file, line: line)
        XCTAssertEqual(r.maxY, e[3], accuracy: tol, "\(tag) maxY \(r)", file: file, line: line)
    }

    private func clock(_ c: DashLayoutContext, _ fabs: [DashRect]) -> DashRect {
        DashLayout.clockChip(c, text: "14:05", font: c.font(15, .bold, digits: true), fabs: fabs)
    }

    private func inside(_ r: DashRect, _ outer: DashRect) -> Bool {
        r.minX >= outer.minX - 1e-6 && r.maxX <= outer.maxX + 1e-6 && r.minY >= outer.minY - 1e-6 && r.maxY <= outer.maxY + 1e-6
    }

    // MARK: Tile (§3.2)

    func testTileOnEveryCanvas() {
        struct Row {
            var w: Double, h: Double, top: Double
            var tile: [Double], bar: [Double], badge: [Double], clock: [Double]
        }
        let rows = [
            Row(w: 800, h: 384, top: 0, tile: [730, 794, 270, 334], bar: [736, 788, 325, 328], badge: [770, 790, 274, 294],
                clock: [733, 794, 348, 376]),
            Row(w: 800, h: 400, top: 0, tile: [730, 794, 270, 334], bar: [736, 788, 325, 328], badge: [770, 790, 274, 294],
                clock: [733, 794, 364, 392]),
            Row(w: 800, h: 944, top: 0, tile: [728, 792, 645, 709], bar: [734, 786, 700, 703], badge: [768, 788, 649, 669],
                clock: [731, 792, 609, 637]),
            Row(w: 720, h: 704, top: 22, tile: [650, 714, 292, 356], bar: [656, 708, 347, 350], badge: [690, 710, 296, 316],
                clock: [653, 714, 668, 696]),
            Row(w: 544, h: 512, top: 0, tile: [474, 538, 270, 334], bar: [480, 532, 325, 328], badge: [514, 534, 274, 294],
                clock: [477, 538, 476, 504]),
            Row(w: 1024, h: 464, top: 0, tile: [944, 1017, 307, 380], bar: [951, 1010, 370, 373], badge: [990, 1013, 312, 334],
                clock: [948, 1017, 423, 455]),
            Row(w: 1280, h: 576, top: 0, tile: [1180, 1271, 385, 476], bar: [1189, 1263, 463, 467], badge: [1237, 1266, 390, 419],
                clock: [1185, 1271, 525, 565]),
        ]
        for row in rows {
            let tag = "\(Int(row.w))×\(Int(row.h))"
            let c = ctx(row.w, row.h, margins: ScreenMargins(customised: false, top: Int(row.top)))
            let fabs = DashLayout.fabColumn(c)
            let clk = clock(c, fabs)
            assertEdges(clk, row.clock, "\(tag) clock")
            guard let t = DashLayout.musicTile(c, fabs: fabs, clock: clk) else {
                XCTFail("\(tag): no tile")
                continue
            }
            assertEdges(t.frame, row.tile, "\(tag) tile")
            assertEdges(t.progressRect, row.bar, "\(tag) bar")
            assertEdges(t.badgeRect, row.badge, "\(tag) badge")
            XCTAssertFalse(t.hidesClock, tag)
            XCTAssertEqual(t.frame.width, t.frame.height, accuracy: 1e-9, "\(tag) square")
            XCTAssertEqual(t.frame.maxX, fabs[4].maxX, accuracy: 1e-9, "\(tag) right-aligned with the FABs")
            XCTAssertEqual(t.cornerRadius, c.dp(10), accuracy: 1e-9, tag)
            XCTAssertGreaterThanOrEqual(t.frame.width, c.dp(DashDimens.fabSize) - 1e-9, tag)
            XCTAssertFalse(t.frame.intersects(clk), "\(tag) tile vs clock")
            for f in fabs { XCTAssertFalse(t.frame.intersects(f), "\(tag) tile vs FAB") }
            XCTAssertTrue(inside(t.frame, c.safe), "\(tag) inside the safe area")
        }
    }

    func testMarginsMakeTheClockGiveWay() {
        // 800×384 with margins 22 / 10 / 12 / 14: 8 dp above the clock leaves < 46 dp.
        let c = ctx(800, 384, margins: ScreenMargins(top: 22, bottom: 10, left: 12, right: 14))
        let fabs = DashLayout.fabColumn(c)
        assertEdges(fabs[0].union(fabs[4]), [734, 780, 30, 284], "FAB column")
        let t = DashLayout.musicTile(c, fabs: fabs, clock: clock(c, fabs))
        assertEdges(t?.frame, [716, 780, 292, 356], "tile")
        XCTAssertEqual(t?.hidesClock, true)
        // without a clock chip there is nothing to hide
        let noClock = DashLayout.musicTile(c, fabs: fabs, clock: nil)
        assertEdges(noClock?.frame, [716, 780, 292, 356], "tile without clock")
        XCTAssertEqual(noClock?.hidesClock, false)
    }

    func testNoRoomNoTile() {
        let c = ctx(300, 200)
        let fabs = DashLayout.fabColumn(c)
        XCTAssertNil(DashLayout.musicTile(c, fabs: fabs, clock: clock(c, fabs)))
        XCTAssertNil(DashLayout.musicTile(c, fabs: fabs, clock: nil))
        XCTAssertNil(DashLayout.musicTile(ctx(800, 384), fabs: [], clock: nil))
        // portrait: the tile needs 46 dp between the clock and 12 dp above the safe bottom
        let p = ctx(400, 720)
        let pf = DashLayout.fabColumn(p)
        XCTAssertNotNil(DashLayout.musicTile(p, fabs: pf, clock: clock(p, pf)))
        XCTAssertNil(DashLayout.musicTile(p, fabs: pf, clock: DashRect(x: 300, y: 650, width: 50, height: 28)))
    }

    func testPortraitTileShrinksOrDropsForABottomCard() {
        let c = ctx(800, 944)
        let fabs = DashLayout.fabColumn(c)
        let clk = clock(c, fabs)
        let full = try! XCTUnwrap(DashLayout.musicTile(c, fabs: fabs, clock: clk))
        assertEdges(full.frame, [728, 792, 645, 709], "free")
        // a card whose top is at 705 leaves 705 − 8 − 645 = 52 px: the tile shrinks (still right-aligned)
        let card = DashRect(x: 0, y: 705, width: 800, height: 239)
        let small = try! XCTUnwrap(DashLayout.musicTile(c, fabs: fabs, clock: clk, avoiding: [card]))
        XCTAssertEqual(small.frame.height, 52, accuracy: 1e-9)
        XCTAssertEqual(small.frame.maxY, card.minY - 8, accuracy: 1e-9)
        XCTAssertEqual(small.frame.maxX, full.frame.maxX, accuracy: 1e-9)
        XCTAssertEqual(small.progressRect.maxY, small.frame.maxY - 6, accuracy: 1e-9)
        // 690 leaves 37 px < 46: no tile (the menu entry remains)
        XCTAssertNil(DashLayout.musicTile(c, fabs: fabs, clock: clk, avoiding: [DashRect(x: 0, y: 690, width: 800, height: 254)]))
        // a card that does not touch the tile changes nothing
        XCTAssertEqual(DashLayout.musicTile(c, fabs: fabs, clock: clk, avoiding: [DashRect(x: 0, y: 836, width: 800, height: 108)]), full)
        XCTAssertEqual(DashLayout.musicTile(c, fabs: fabs, clock: clk, avoiding: [DashRect(x: 0, y: 650, width: 700, height: 60)]), full)
    }

    // MARK: Sheet (§3.3)

    private struct SheetRow {
        var w: Double, h: Double, top: Double
        var nav: Bool
        var arrangement: DashMusicSheetArrangement
        var art: [Double]
        /// ⏮ / ⏯ / ⏭ x ranges and the ⏯ y range.
        var prevX: [Double], playX: [Double], nextX: [Double], playY: [Double]
        var close: [Double]
        var titleLines = 1
    }

    private let sheetRows: [SheetRow] = [
        SheetRow(w: 800, h: 384, top: 0, nav: false, arrangement: .sideBySide, art: [432, 784, 16, 368],
                 prevX: [92, 156], playX: [176, 256], nextX: [276, 340], playY: [215, 295], close: [728, 776, 24, 72]),
        SheetRow(w: 800, h: 384, top: 0, nav: true, arrangement: .sideBySide, art: [432, 784, 16, 368],
                 prevX: [92, 156], playX: [176, 256], nextX: [276, 340], playY: [288, 368], close: [728, 776, 24, 72]),
        SheetRow(w: 800, h: 400, top: 0, nav: false, arrangement: .sideBySide, art: [416, 784, 16, 384],
                 prevX: [84, 148], playX: [168, 248], nextX: [268, 332], playY: [223, 303], close: [728, 776, 24, 72]),
        SheetRow(w: 800, h: 400, top: 0, nav: true, arrangement: .sideBySide, art: [416, 784, 16, 384],
                 prevX: [84, 148], playX: [168, 248], nextX: [268, 332], playY: [296, 376], close: [728, 776, 24, 72]),
        SheetRow(w: 800, h: 944, top: 0, nav: false, arrangement: .stacked, art: [54, 746, 16, 708],
                 prevX: [276, 340], playX: [360, 440], nextX: [460, 524], playY: [848, 928], close: [690, 738, 24, 72]),
        SheetRow(w: 800, h: 944, top: 0, nav: true, arrangement: .stacked, art: [123, 677, 154, 708],
                 prevX: [276, 340], playX: [360, 440], nextX: [460, 524], playY: [848, 928], close: [621, 669, 162, 210]),
        SheetRow(w: 720, h: 704, top: 22, nav: false, arrangement: .stacked, art: [144, 576, 38, 470],
                 prevX: [236, 300], playX: [320, 400], nextX: [420, 484], playY: [608, 688], close: [520, 568, 46, 94]),
        SheetRow(w: 720, h: 704, top: 22, nav: true, arrangement: .sideBySide, art: [332, 704, 184, 556],
                 prevX: [42, 106], playX: [126, 206], nextX: [226, 290], playY: [472, 552], close: [648, 696, 192, 240], titleLines: 2),
        SheetRow(w: 544, h: 512, top: 0, nav: false, arrangement: .stacked, art: [141, 403, 16, 278],
                 prevX: [148, 212], playX: [232, 312], nextX: [332, 396], playY: [416, 496], close: [347, 395, 24, 72]),
        SheetRow(w: 544, h: 512, top: 0, nav: true, arrangement: .sideBySide, art: [332, 528, 162, 358],
                 prevX: [42, 106], playX: [126, 206], nextX: [226, 290], playY: [365, 445], close: [472, 520, 170, 218], titleLines: 2),
        SheetRow(w: 1024, h: 464, top: 0, nav: false, arrangement: .sideBySide, art: [578, 1006, 18, 446],
                 prevX: [148, 221], playX: [244, 335], nextX: [357, 430], playY: [258, 349], close: [942, 997, 27, 82]),
        SheetRow(w: 1024, h: 464, top: 0, nav: true, arrangement: .sideBySide, art: [578, 1006, 18, 446],
                 prevX: [148, 221], playX: [244, 335], nextX: [357, 430], playY: [341, 432], close: [942, 997, 27, 82]),
        SheetRow(w: 1280, h: 576, top: 0, nav: false, arrangement: .sideBySide, art: [727, 1257, 23, 553],
                 prevX: [187, 278], playX: [306, 420], nextX: [449, 540], playY: [320, 434], close: [1177, 1246, 34, 103]),
        SheetRow(w: 1280, h: 576, top: 0, nav: true, arrangement: .sideBySide, art: [727, 1257, 23, 553],
                 prevX: [187, 278], playX: [306, 420], nextX: [449, 540], playY: [424.5, 538.5], close: [1177, 1246, 34, 103]),
    ]

    private func sheet(_ row: SheetRow, song: DashNowPlaying = DashFixtures.song(), cue: HudCue = DashFixtures.navCue,
                       language: DashLanguage = .en) -> (DashLayoutContext, DashMusicSheetLayout, DashRect?) {
        let c = ctx(row.w, row.h, margins: ScreenMargins(customised: false, top: Int(row.top)))
        let reserved = row.nav ? DashLayout.navCard(c, cue: cue).frame : nil
        return (c, DashLayout.musicSheet(c, music: song, language: language, reserved: reserved), reserved)
    }

    func testSheetOnEveryCanvasAndState() {
        for row in sheetRows {
            let (c, l, reserved) = sheet(row)
            let tag = "\(Int(row.w))×\(Int(row.h)) \(row.nav ? "nav" : "free")"
            XCTAssertEqual(l.arrangement, row.arrangement, tag)
            assertEdges(l.artworkRect, row.art, "\(tag) artwork")
            XCTAssertEqual(l.artworkRect.width, l.artworkRect.height, accuracy: 1e-9, "\(tag) square artwork")
            assertEdges(l.previousRect, row.prevX + [l.previousRect.minY, l.previousRect.maxY], "\(tag) ⏮")
            assertEdges(l.playPauseRect, row.playX + row.playY, "\(tag) ⏯")
            assertEdges(l.nextRect, row.nextX + [l.nextRect.minY, l.nextRect.maxY], "\(tag) ⏭")
            assertEdges(l.closeRect, row.close, "\(tag) ✕")
            XCTAssertEqual(l.compressionStep, 0, tag)
            XCTAssertEqual(l.titleMaxLines, row.titleLines, tag)
            XCTAssertEqual(l.sheet, DashRect(x: 0, y: 0, width: row.w, height: row.h), tag)
            XCTAssertEqual(l.artworkRadius, c.dp(12), accuracy: 1e-9, tag)
            // ⏮ ⏭ vertically centred on ⏯, 20 dp apart
            XCTAssertEqual(l.previousRect.midY, l.playPauseRect.midY, accuracy: 1e-9, tag)
            XCTAssertEqual(l.nextRect.midY, l.playPauseRect.midY, accuracy: 1e-9, tag)
            XCTAssertEqual(l.playPauseRect.minX - l.previousRect.maxX, c.dp(20), accuracy: 1e-9, tag)
            XCTAssertEqual(l.nextRect.minX - l.playPauseRect.maxX, c.dp(20), accuracy: 1e-9, tag)
            // ✕ on the artwork's top-right corner, inset 8 dp
            XCTAssertEqual(l.closeRect.maxX, l.artworkRect.maxX - c.dp(8), accuracy: 1e-9, tag)
            XCTAssertEqual(l.closeRect.minY, l.artworkRect.minY + c.dp(8), accuracy: 1e-9, tag)
            // fonts
            XCTAssertEqual(l.titleFont, c.font(row.arrangement == .stacked && row.h > row.w ? 24 : 22, .bold), tag)
            XCTAssertEqual(l.artistFont, c.font(17, .medium), tag)
            XCTAssertEqual(l.albumFont, c.font(15), tag)
            XCTAssertEqual(l.timeFont, c.font(14, digits: true), tag)
            // everything inside the safe area, never under the nav card, nothing overlaps
            let parts: [(String, DashRect?)] = [("title", l.titleRect), ("artist", l.artistRect), ("album", l.albumRect),
                                                ("bar", l.progressRect), ("elapsed", l.elapsedRect), ("remaining", l.remainingRect),
                                                ("prev", l.previousRect), ("play", l.playPauseRect), ("next", l.nextRect),
                                                ("art", l.artworkRect), ("close", l.closeRect)]
            for case let (name, r?) in parts {
                XCTAssertTrue(inside(r, c.safe), "\(tag) \(name) \(r) outside \(c.safe)")
                if let reserved { XCTAssertFalse(r.intersects(reserved), "\(tag) \(name) under the nav card") }
                if name != "art" && name != "close" { XCTAssertFalse(r.intersects(l.artworkRect), "\(tag) \(name) on the artwork") }
            }
        }
    }

    func testBlockInternalsOn800x384() {
        // free ride: title 89–116 · artist 120–140 · album 142–160 · bar 174–180 · times 184–201
        let (_, free, _) = sheet(sheetRows[0])
        assertEdges(free.titleRect, [16, 416, 89, 116], "title")
        assertEdges(free.artistRect, [16, 416, 120, 140], "artist")
        assertEdges(free.albumRect, [16, 416, 142, 160], "album")
        assertEdges(free.progressRect, [16, 416, 174, 180], "bar")
        assertEdges(free.elapsedRect, [16, 216, 184, 201], "elapsed")
        assertEdges(free.remainingRect, [216, 416, 184, 201], "remaining")
        assertEdges(free.previousRect, [92, 156, 223, 287], "⏮")
        assertEdges(free.nextRect, [276, 340, 223, 287], "⏭")
        // navigating, under the P0 nav card (48 / 26 sp, D11) (column 16–416 × 162–368): title 162–189 · artist 193–213 ·
        // album 215–233 · bar 247–253 · times 257–274
        let (_, nav, reserved) = sheet(sheetRows[1])
        assertEdges(reserved, [8, 340, 8, 150], "nav card")
        assertEdges(nav.titleRect, [16, 416, 162, 189], "nav title")
        assertEdges(nav.artistRect, [16, 416, 193, 213], "nav artist")
        assertEdges(nav.albumRect, [16, 416, 215, 233], "nav album")
        assertEdges(nav.progressRect, [16, 416, 247, 253], "nav bar")
        assertEdges(nav.elapsedRect, [16, 216, 257, 274], "nav elapsed")
        assertEdges(nav.remainingRect, [216, 416, 257, 274], "nav remaining")
        // portrait stacked: title 24 sp, 720–749; times 817–834
        let (_, port, _) = sheet(sheetRows[5])
        assertEdges(port.titleRect, [16, 784, 720, 749], "portrait title")
        assertEdges(port.artistRect, [16, 784, 753, 773], "portrait artist")
        assertEdges(port.progressRect, [16, 784, 807, 813], "portrait bar")
        assertEdges(port.elapsedRect, [16, 400, 817, 834], "portrait elapsed")
        // 720×704 navigating: 2-line title 320–373
        let (_, nk, _) = sheet(sheetRows[7])
        assertEdges(nk.titleRect, [16, 316, 320, 373], "720 title")
    }

    func testStressTallNavCardAndLongTitle() {
        let canvases: [(Double, Double, Double)] = [(800, 384, 0), (800, 400, 0), (800, 944, 0), (720, 704, 22), (544, 512, 0),
                                                    (1024, 464, 0), (1280, 576, 0)]
        let song = DashFixtures.song(title: DashFixtures.longSongTitle)
        for (w, h, top) in canvases {
            let tag = "\(Int(w))×\(Int(h))"
            let c = ctx(w, h, margins: ScreenMargins(customised: false, top: Int(top)))
            let reserved = DashLayout.navCard(c, cue: DashFixtures.longNavCue).frame
            let l = DashLayout.musicSheet(c, music: song, language: .en, reserved: reserved)
            XCTAssertNotEqual(l.arrangement, .textOnly, tag)
            XCTAssertGreaterThanOrEqual(l.artworkRect.width, c.dp(96) - 1e-9, tag)
            for r in [l.artworkRect, l.closeRect, l.titleRect, l.previousRect, l.playPauseRect, l.nextRect]
                + [l.artistRect, l.albumRect, l.progressRect, l.elapsedRect].compactMap({ $0 }) {
                XCTAssertTrue(inside(r, c.safe), "\(tag) \(r) outside the safe area")
                XCTAssertFalse(r.intersects(reserved), "\(tag) \(r) under the nav card \(reserved)")
            }
            if w == 800 && h < 500 {
                XCTAssertGreaterThanOrEqual(l.compressionStep, 1, tag)
                XCTAssertNil(l.albumRect, "\(tag): step 1 drops the album")
            }
        }
        // 800×384: the 704-px P0 card (48 / 26 sp, D11) pushes the artwork below it: 609–784 × 193–368 (175);
        // the block left of it compresses to step 3 (1-line title, no album, 64-px ⏯)
        let c = ctx(800, 384)
        let reserved = DashLayout.navCard(c, cue: DashFixtures.longNavCue).frame
        assertEdges(reserved, [8, 712, 8, 181], "stress nav card")
        let l = DashLayout.musicSheet(c, music: song, language: .en, reserved: reserved)
        XCTAssertEqual(l.arrangement, .sideBySide)
        assertEdges(l.artworkRect, [609, 784, 193, 368], "stress artwork")
        XCTAssertEqual(l.compressionStep, 3)
        XCTAssertEqual(l.titleMaxLines, 1)
        XCTAssertEqual(l.playPauseRect.width, 64, accuracy: 1e-9)
    }

    func testUnknownDurationDropsBarAndTimes() {
        for duration in [0.0, -3, .nan, .infinity] {
            let (_, l, _) = sheet(sheetRows[0], song: DashFixtures.song(duration: duration))
            XCTAssertNil(l.progressRect, "\(duration)")
            XCTAssertNil(l.elapsedRect, "\(duration)")
            XCTAssertNil(l.remainingRect, "\(duration)")
            XCTAssertNotNil(l.artistRect)
            // no spacing for them: album bottom + 14 → transport
            XCTAssertEqual(l.playPauseRect.minY - l.albumRect!.maxY, 14, accuracy: 1e-9)
        }
    }

    func testEmptyArtistAndAlbumDropTheirLines() {
        let (_, l, _) = sheet(sheetRows[0], song: DashFixtures.song(artist: "", album: " \n "))
        XCTAssertNil(l.artistRect)
        XCTAssertNil(l.albumRect)
        XCTAssertEqual(l.progressRect!.minY - l.titleRect.maxY, 14, accuracy: 1e-9)
        let (_, onlyAlbum, _) = sheet(sheetRows[0], song: DashFixtures.song(artist: ""))
        XCTAssertNil(onlyAlbum.artistRect)
        XCTAssertEqual(onlyAlbum.albumRect!.minY - onlyAlbum.titleRect.maxY, 2, accuracy: 1e-9)
        // the block stays vertically centred in the column (free ride: 16…368)
        let (_, radio, _) = sheet(sheetRows[0], song: DashFixtures.song(artist: "", album: "", duration: 0))
        let top = radio.titleRect.minY, bottom = radio.playPauseRect.maxY
        XCTAssertEqual((top + bottom) / 2, (16 + 368) / 2, accuracy: 1e-9)
        XCTAssertEqual(radio.compressionStep, 0)
    }

    func testEmptyTitleMeasuresTheFallback() {
        let (c, l, _) = sheet(sheetRows[7], song: DashFixtures.song(title: ""), language: .es)
        XCTAssertEqual(DashLayout.musicTitle(DashFixtures.song(title: "  "), .es), "Canción desconocida")
        XCTAssertEqual(DashLayout.musicTitle(DashFixtures.song(title: "A\nB\tC "), .en), "A B C")
        XCTAssertEqual(l.titleMaxLines, 1)
        XCTAssertEqual(l.titleRect.height, c.lineHeight(l.titleFont), accuracy: 1e-9)
    }

    func testTargetsAreLargeEnough() {
        var cases: [(DashLayoutContext, DashMusicSheetLayout)] = sheetRows.map { row in
            let (c, l, _) = sheet(row)
            return (c, l)
        }
        for (w, h) in [(800.0, 384.0), (544, 512), (720, 704)] {
            let c = ctx(w, h)
            let reserved = DashLayout.navCard(c, cue: DashFixtures.longNavCue).frame
            cases.append((c, DashLayout.musicSheet(c, music: DashFixtures.song(title: DashFixtures.longSongTitle), language: .en,
                                                   reserved: reserved)))
        }
        for (c, l) in cases {
            let side = c.dp(l.compressionStep >= 3 ? 52 : 64)
            XCTAssertEqual(l.previousRect.width, side, accuracy: 1e-9)
            XCTAssertEqual(l.nextRect.height, side, accuracy: 1e-9)
            XCTAssertEqual(l.playPauseRect.width, c.dp(l.compressionStep >= 3 ? 64 : 80), accuracy: 1e-9)
            for r in [l.previousRect, l.playPauseRect, l.nextRect, l.closeRect] {
                XCTAssertGreaterThanOrEqual(min(r.width, r.height), c.dp(48) - 1e-9)
            }
        }
    }

    func testCompressionLadder() {
        // A short column forces the ladder: each step drops one thing, the transport shrinks at 3.
        let c = ctx(800, 384)
        let song = DashFixtures.song(title: DashFixtures.longSongTitle)
        var steps: [Int] = []
        for top in stride(from: 0.0, through: 240, by: 4) {
            let reserved = DashRect(x: 8, y: 8, width: 400, height: top)
            let l = DashLayout.musicSheet(c, music: song, language: .en, reserved: reserved)
            guard l.arrangement != .textOnly else { continue }
            if steps.last != l.compressionStep { steps.append(l.compressionStep) }
            XCTAssertEqual(l.albumRect == nil, l.compressionStep >= 1)
            XCTAssertEqual(l.titleMaxLines, l.compressionStep >= 2 ? 1 : 2)
            XCTAssertEqual(l.artistRect == nil, l.compressionStep >= 4)
            XCTAssertEqual(l.elapsedRect == nil, l.compressionStep >= 5)
            XCTAssertNotNil(l.progressRect)
            XCTAssertTrue(inside(l.playPauseRect, c.safe))
        }
        XCTAssertEqual(steps.first, 0)
        XCTAssertEqual(steps, steps.sorted(), "monotonic")
        XCTAssertGreaterThanOrEqual(steps.count, 4, "\(steps)")
    }

    func testTextOnlyOnATinyCanvas() {
        let c = ctx(300, 200)
        let l = DashLayout.musicSheet(c, music: DashFixtures.song(), language: .en, reserved: nil)
        XCTAssertEqual(l.arrangement, .textOnly)
        XCTAssertEqual(l.artworkRect, .zero)
        XCTAssertEqual(l.compressionStep, 5)
        XCTAssertNil(l.artistRect)
        XCTAssertNil(l.albumRect)
        XCTAssertNil(l.elapsedRect)
        XCTAssertNotNil(l.progressRect)
        // ✕ at the top-right of the free area (safe inset 16 dp)
        assertEdges(l.closeRect, [236, 284, 16, 64], "✕")
        for r in [l.titleRect, l.progressRect!, l.previousRect, l.playPauseRect, l.nextRect] {
            XCTAssertTrue(inside(r, c.safe), "\(r)")
            XCTAssertFalse(r.intersects(l.closeRect), "\(r) under ✕")
        }
        XCTAssertEqual(l.playPauseRect.width, 64, accuracy: 1e-9)
    }

    // MARK: Menu entry

    func testMenuEntryRightAfterRerouteOnlyWithMusic() {
        let c = ctx(800, 384)
        func ids(_ music: Bool, _ L: DashLanguage = .en) -> [String] {
            DashLayout.menu(c, content: DashMenuContent(language: L, follow: true, headingUp: true, recording: false,
                                                        preferences: MapPreferences(), showsMusic: music)).items.compactMap(\.id)
        }
        XCTAssertFalse(ids(false).contains("menu.music"))
        let with = ids(true)
        // P0 (D01): the menu opens on Recenter; Music is its harmless next neighbour (was after Circuit)
        XCTAssertEqual(with.firstIndex(of: "menu.music"), with.firstIndex(of: "menu.recenter").map { $0 + 1 })
        XCTAssertEqual(with.firstIndex(of: "menu.circuit"), with.firstIndex(of: "menu.music").map { $0 + 1 })
        XCTAssertEqual(with.filter { $0 != "menu.music" }, ids(false))
        let es = DashLayout.menu(c, content: DashMenuContent(language: .es, follow: true, headingUp: true, recording: false,
                                                             preferences: MapPreferences(), showsMusic: true))
        let label = es.items.compactMap { item -> String? in
            if case let .button("menu.music", label, _, _) = item.kind { return label }
            return nil
        }
        XCTAssertEqual(label, ["Música"])
        XCTAssertEqual(DashSceneBuilder.menuIntent("menu.music"), .openMusic)
    }
}
