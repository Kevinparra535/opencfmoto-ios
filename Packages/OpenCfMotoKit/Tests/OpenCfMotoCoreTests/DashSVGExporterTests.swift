// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import OpenCfMotoCore

final class DashSVGExporterTests: XCTestCase {
    private let size = DashSize(width: 100, height: 50)

    private func count(_ s: String, _ needle: String) -> Int { s.components(separatedBy: needle).count - 1 }

    func testDocumentFrameAndBackground() {
        let svg = DashSVGExporter().svg(DashDisplayList(size: size, background: DashColor(argb: 0xFF10_1418)))
        XCTAssertTrue(svg.hasPrefix("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"50\" viewBox=\"0 0 100 50\">"))
        XCTAssertTrue(svg.contains("<rect x=\"0\" y=\"0\" width=\"100\" height=\"50\" fill=\"#101418\"/>"))
        XCTAssertTrue(svg.hasSuffix("</svg>"))
    }

    func testFillStrokeAttributes() {
        var list = DashDisplayList(size: size, background: .black)
        list.commands = [
            .fill(DashPath.rect(DashRect(x: 1, y: 2, width: 3, height: 4)), DashColor(argb: 0x66FF_9800), .evenOdd),
            .stroke(DashPath.polyline([DashPoint(0, 0), DashPoint(10, 5)]),
                    DashStroke(width: 3.5, color: DashColor(argb: 0xFFFB_BC04), cap: .round, join: .bevel, dash: [8, 6])),
            .fill(DashPath(), .white, .nonZero), // empty paths are skipped
        ]
        let svg = DashSVGExporter().svg(list)
        XCTAssertTrue(svg.contains("<path d=\"M1 2 L4 2 L4 6 L1 6 Z\" fill=\"#FF9800\" fill-opacity=\"0.4\" fill-rule=\"evenodd\"/>"))
        XCTAssertTrue(svg.contains("fill=\"none\" stroke=\"#FBBC04\" stroke-width=\"3.5\" stroke-linecap=\"round\" stroke-linejoin=\"bevel\" stroke-dasharray=\"8 6\""))
        XCTAssertEqual(count(svg, "<path"), 2)
    }

    func testGroupsAreBalancedForSaveTransformClipRestore() {
        var list = DashDisplayList(size: size, background: .black)
        list.commands = [
            .save, .transform(.rotation(.pi / 2)), .clip(DashPath.rect(DashRect(x: 0, y: 0, width: 10, height: 10))),
            .fill(DashPath.rect(DashRect(x: 0, y: 0, width: 5, height: 5)), .white, .nonZero),
            .save, .transform(.translation(3, 4)), .restore,
            .restore,
            .restore, // extra restore must not unbalance the document
            .save, .transform(.scale(2, 2)), // unterminated save is closed at the end
        ]
        let svg = DashSVGExporter().svg(list)
        XCTAssertEqual(count(svg, "<g"), count(svg, "</g>"))
        XCTAssertTrue(svg.contains("<clipPath id=\"c1\" clipPathUnits=\"userSpaceOnUse\">"))
        XCTAssertTrue(svg.contains("<g clip-path=\"url(#c1)\">"))
        XCTAssertTrue(svg.contains("matrix(0 1 -1 0 0 0)"))
        XCTAssertTrue(svg.contains("matrix(1 0 0 1 3 4)"))
    }

    func testTextUsesLayoutAndEscapes() {
        var list = DashDisplayList(size: DashSize(width: 300, height: 100), background: .black)
        let style = DashTextStyle(font: DashFont(size: 10, weight: .bold), color: DashColor(argb: 0xFF8A_B4F8), alignment: .center, maxLines: 2)
        list.commands = [.text("Fish & <Chips> \"x\"", DashRect(x: 0, y: 0, width: 300, height: 40), style)]
        let svg = DashSVGExporter().svg(list)
        XCTAssertTrue(svg.contains("&amp; &lt;Chips&gt; &quot;x&quot;"))
        XCTAssertTrue(svg.contains("font-weight=\"700\""))
        XCTAssertTrue(svg.contains("fill=\"#8AB4F8\""))
        XCTAssertTrue(svg.contains("lengthAdjust=\"spacingAndGlyphs\""))
        let lines = DashTextLayout.layout("Fish & <Chips> \"x\"", in: DashRect(x: 0, y: 0, width: 300, height: 40), style: style,
                                          measurer: ApproximateTextMeasurer())
        // centred: anchored at the line's centre (a rasteriser drawing the natural width keeps it centred)
        XCTAssertEqual(lines[0].origin.x + lines[0].width / 2, 150, accuracy: 1e-9)
        XCTAssertTrue(svg.contains("x=\"150\" text-anchor=\"middle\" y=\"\(DashSVGNumber.format(lines[0].origin.y, decimals: 2))\""))
        // left: the line's start, no anchor; right: anchored at its end (the rect's right edge)
        for (alignment, x, anchor) in [(DashTextAlignment.left, "20", ""), (.right, "220", " text-anchor=\"end\"")] {
            var one = DashDisplayList(size: DashSize(width: 300, height: 100), background: .black)
            one.commands = [.text("Ab", DashRect(x: 20, y: 0, width: 200, height: 40),
                                  DashTextStyle(font: DashFont(size: 10), color: .white, alignment: alignment))]
            let s = DashSVGExporter().svg(one)
            XCTAssertTrue(s.contains("<text x=\"\(x)\"\(anchor) y="), "\(alignment): \(s)")
        }
        // a line with fallback-font runs keeps its start: cairosvg would anchor each run on its own
        let centred = DashTextStyle(font: DashFont(size: 10), color: .white, alignment: .center)
        var mixed = DashDisplayList(size: DashSize(width: 300, height: 100), background: .black)
        mixed.commands = [.text("＋ Marker", DashRect(x: 20, y: 0, width: 200, height: 40), centred)]
        let ms = DashSVGExporter().svg(mixed)
        let start = DashTextLayout.layout("＋ Marker", in: DashRect(x: 20, y: 0, width: 200, height: 40), style: centred,
                                          measurer: ApproximateTextMeasurer())[0].origin.x
        XCTAssertTrue(ms.contains("<text x=\"\(DashSVGNumber.format(start, decimals: 2))\" y="), ms)
        XCTAssertTrue(ms.contains("<tspan"), ms)
        XCTAssertFalse(ms.contains("text-anchor"), ms)
        // without fitting: letter-spacing is emitted instead of textLength
        var plain = DashSVGExporter()
        plain.fitTextToMeasuredWidth = false
        var spaced = DashDisplayList(size: size, background: .black)
        spaced.commands = [.text("↑ ↑", DashRect(x: 0, y: 0, width: 100, height: 20),
                                 DashTextStyle(font: DashFont(size: 16), color: .white, letterSpacingEm: 0.12))]
        let s2 = plain.svg(spaced)
        XCTAssertTrue(s2.contains("letter-spacing=\"1.92\""))
        XCTAssertFalse(s2.contains("textLength"))
    }

    func testWrappedTextBecomesSeveralLines() {
        var list = DashDisplayList(size: DashSize(width: 300, height: 100), background: .black)
        list.commands = [.text("Strada Mihai Eminescu colt cu Bulevardul Unirii", DashRect(x: 0, y: 0, width: 80, height: 40),
                               DashTextStyle(font: DashFont(size: 10), color: .white, maxLines: 2))]
        let svg = DashSVGExporter().svg(list)
        XCTAssertEqual(count(svg, "<text "), 2)
        XCTAssertTrue(svg.contains("…"))
    }

    func testTilePlaceholders() {
        var list = DashDisplayList(size: size, background: .black)
        list.commands = [.tile(z: 16, x: 37452, y: 23541, rect: DashRect(x: 0, y: 0, width: 256, height: 256), treatment: .normal),
                         .tile(z: 16, x: 37453, y: 23541, rect: DashRect(x: 256, y: 0, width: 256, height: 256), treatment: .inverted),
                         .tile(z: 16, x: 37454, y: 23541, rect: DashRect(x: 0, y: 256, width: 256, height: 256), treatment: .mutedDay),
                         .tile(z: 16, x: 37455, y: 23541, rect: DashRect(x: 256, y: 256, width: 256, height: 256), treatment: .mutedNight)]
        let svg = DashSVGExporter().svg(list)
        XCTAssertTrue(svg.contains(">16/37452/23541</text>"))
        XCTAssertTrue(svg.contains(">16/37453/23541</text>"))
        XCTAssertTrue(svg.contains("fill=\"#F2EFE9\"")) // light day placeholder (classic)
        XCTAssertTrue(svg.contains("fill=\"#1B1E24\"")) // dark (inverted) placeholder
        XCTAssertTrue(svg.contains("fill=\"#E5E4E0\"")) // muted day ground (P0, D05)
        XCTAssertTrue(svg.contains("fill=\"#16191D\"")) // muted night ground
    }

    func testHitRegionOverlay() {
        var list = DashDisplayList(size: size, background: .black)
        list.hitRegions = [DashHitRegion(id: "fab.menu", rect: DashRect(x: 1, y: 1, width: 10, height: 10)),
                           DashHitRegion(id: "nav.card", rect: DashRect(x: 20, y: 1, width: 10, height: 10), focusable: false)]
        XCTAssertFalse(DashSVGExporter().svg(list).contains("stroke-dasharray=\"3 2\""))
        var exporter = DashSVGExporter()
        exporter.showHitRegions = true
        let svg = exporter.svg(list)
        XCTAssertTrue(svg.contains("stroke=\"#00C853\""))
        XCTAssertTrue(svg.contains("stroke=\"#FF1744\""))
    }

    func testSymbolFallbackRuns() {
        let e = DashSVGExporter()
        XCTAssertEqual(e.runs("＋ Marker"), "<tspan font-family=\"WenQuanYi Zen Hei\">＋</tspan> Marker")
        XCTAssertEqual(e.runs("⌨ Type"), "<tspan font-family=\"DejaVu Sans\">⌨</tspan> Type")
        XCTAssertEqual(e.runs("a<b"), "a&lt;b")
        var none = DashSVGExporter()
        none.symbolFallbacks = []
        XCTAssertEqual(none.runs("＋"), "＋")
    }

    func testFullFrameExportIsWellFormed() {
        let ui = DashUIController()
        ui.update(DashFixtures.navigating())
        let svg = DashSVGExporter().svg(ui.displayList(now: 0))
        XCTAssertEqual(count(svg, "<g"), count(svg, "</g>"))
        XCTAssertEqual(count(svg, "<text "), count(svg, "</text>"))
        XCTAssertFalse(svg.contains("nan"))
        XCTAssertFalse(svg.contains("inf"))
    }

    // MARK: Raster images (Apple Music artwork)

    private func imageList(_ id: String = "music.art.p1f") -> DashDisplayList {
        var list = DashDisplayList(size: DashSize(width: 400, height: 200), background: .black)
        list.commands = [
            .save, .clip(DashPath.rect(DashRect(x: 0, y: 0, width: 400, height: 200))),
            .image(id: id, rect: DashRect(x: 10, y: 20, width: 120, height: 120), cornerRadius: 10),
            .restore,
            .image(id: "other", rect: DashRect(x: 140, y: 20, width: 140, height: 100), cornerRadius: 0),
            .image(id: "tile", rect: DashRect(x: 300, y: 20, width: 64, height: 64), cornerRadius: 10), // no label
            .image(id: "empty", rect: DashRect(x: 0, y: 0, width: 0, height: 10), cornerRadius: 4), // skipped
        ]
        return list
    }

    func testImagePlaceholderIsDeterministicAndClipped() {
        let svg = DashSVGExporter().svg(imageList())
        XCTAssertEqual(svg, DashSVGExporter().svg(imageList()), "same SVG twice")
        XCTAssertEqual(count(svg, "<g"), count(svg, "</g>"))
        // clip ids continue the c<n> counter: c1 = the explicit clip, c2…c4 = the three images
        XCTAssertTrue(svg.contains("<clipPath id=\"c2\" clipPathUnits=\"userSpaceOnUse\">"))
        XCTAssertTrue(svg.contains("<g clip-path=\"url(#c2)\">"))
        XCTAssertTrue(svg.contains("<clipPath id=\"c3\""))
        XCTAssertTrue(svg.contains("<clipPath id=\"c4\""))
        XCTAssertFalse(svg.contains("id=\"c5\""), "empty rects draw nothing")
        XCTAssertTrue(svg.contains("<linearGradient id=\"g2\""))
        XCTAssertTrue(svg.contains("fill=\"url(#g2)\""))
        XCTAssertEqual(count(svg, "<linearGradient"), 3)
        XCTAssertTrue(svg.contains(">music.art.p1f</text>"), "the id is printed on the placeholder")
        XCTAssertTrue(svg.contains(">other</text>"))
        XCTAssertFalse(svg.contains(">tile</text>"), "no label on small rects (the tile's progress bar sits there)")
        XCTAssertFalse(svg.contains("<image"))
        // the rounded clip: arcs (radius 10) in the clip path of the first image, none for radius 0
        let clip2 = svg.components(separatedBy: "<clipPath id=\"c2\"")[1].components(separatedBy: "</clipPath>")[0]
        XCTAssertTrue(clip2.contains("C") || clip2.contains("Q"), clip2)
        // two hues from the id
        let h = DashSVGExporter.fnv1a32("music.art.p1f")
        XCTAssertTrue(svg.contains("stop-color=\"\(DashSVGExporter.hslHex(hue: Double(h % 360), saturation: 0.45, lightness: 0.38))\""))
        XCTAssertTrue(svg.contains("stop-color=\"\(DashSVGExporter.hslHex(hue: Double((h >> 9) % 360), saturation: 0.45, lightness: 0.22))\""))
        XCTAssertNotEqual(DashSVGExporter().svg(imageList("music.art.s100000002")), svg, "another id, other colours")
    }

    func testImagesMapEmbedsTheRaster() {
        var e = DashSVGExporter()
        e.images = ["music.art.p1f": "data:image/png;base64,iVBORw0KGgo="]
        let svg = e.svg(imageList())
        XCTAssertEqual(count(svg, "<image "), 1)
        XCTAssertTrue(svg.contains("<image href=\"data:image/png;base64,iVBORw0KGgo=\" x=\"10\" y=\"20\" width=\"120\" height=\"120\" preserveAspectRatio=\"xMidYMid slice\"/>"))
        XCTAssertTrue(svg.contains("<g clip-path=\"url(#c2)\">"))
        XCTAssertFalse(svg.contains(">music.art.p1f</text>"))
        XCTAssertTrue(svg.contains(">other</text>"), "ids not in the map keep the placeholder")
        XCTAssertEqual(count(svg, "<g"), count(svg, "</g>"))
    }

    func testHashAndHsl() {
        XCTAssertEqual(DashSVGExporter.fnv1a32(""), 2_166_136_261)
        XCTAssertEqual(DashSVGExporter.fnv1a32("a"), 0xE40C_292C) // FNV-1a 32 reference vector
        XCTAssertEqual(DashSVGExporter.hslHex(hue: 0, saturation: 1, lightness: 0.5), "#FF0000")
        XCTAssertEqual(DashSVGExporter.hslHex(hue: 120, saturation: 1, lightness: 0.5), "#00FF00")
        XCTAssertEqual(DashSVGExporter.hslHex(hue: 240, saturation: 1, lightness: 0.25), "#000080")
        XCTAssertEqual(DashSVGExporter.hslHex(hue: 480, saturation: 0, lightness: 1), "#FFFFFF")
    }

    func testMusicFramesExportWellFormed() {
        for open in [false, true] {
            let ui = DashUIController()
            ui.update(DashFixtures.withMusic(DashFixtures.navigating()))
            if open { _ = ui.perform(.openMusic, now: DashFixtures.musicNow) }
            let svg = DashSVGExporter().svg(ui.displayList(now: DashFixtures.musicNow))
            XCTAssertEqual(count(svg, "<g"), count(svg, "</g>"))
            XCTAssertEqual(count(svg, "<text "), count(svg, "</text>"))
            XCTAssertEqual(count(svg, "<linearGradient"), 1)
            XCTAssertFalse(svg.contains("nan"))
        }
    }
}
