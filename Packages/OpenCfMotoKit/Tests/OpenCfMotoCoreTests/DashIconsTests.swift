// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import OpenCfMotoCore

final class DashIconsTests: XCTestCase {
    private func firstPoint(_ path: DashPath) -> DashPoint? {
        if case let .move(p)? = path.elements.first { return p }
        return nil
    }

    func testEveryIconHasLayersInsideItsViewport() throws {
        for icon in DashIcon.allCases {
            let d = DashIcons.drawing(icon)
            XCTAssertFalse(d.layers.isEmpty, "\(icon)")
            for layer in d.layers {
                XCTAssertFalse(layer.path.isEmpty, "\(icon)")
                let b = try XCTUnwrap(layer.path.controlPointBounds)
                XCTAssertGreaterThanOrEqual(b.minX, -1e-9, "\(icon)")
                XCTAssertGreaterThanOrEqual(b.minY, -1e-9, "\(icon)")
                XCTAssertLessThanOrEqual(b.maxX, d.viewport.width + 1e-9, "\(icon)")
                XCTAssertLessThanOrEqual(b.maxY, d.viewport.height + 1e-9, "\(icon)")
            }
        }
    }

    func testViewports() {
        XCTAssertEqual(DashIcons.drawing(.manLeft).viewport, DashSize(width: 24, height: 24))
        XCTAssertEqual(DashIcons.drawing(.fabGps).viewport, DashSize(width: 24, height: 24))
        XCTAssertEqual(DashIcons.drawing(.navArrow).viewport, DashSize(width: 48, height: 48))
        XCTAssertEqual(DashIcons.drawing(.destPin).viewport, DashSize(width: 40, height: 48))
    }

    func testArrowRotationsMoveTheTip() throws {
        // Base arrow tip (12,3), rotated clockwise about (12,12) (Android group rotation, y-down).
        let cases: [(DashIcon, Double, Double)] = [
            (.manStraight, 12, 3),
            (.manRight, 21, 12),
            (.manLeft, 3, 12),
            (.manSlightRight, 12 + 9 * sin(.pi / 4), 12 - 9 * cos(.pi / 4)),
            (.manSlightLeft, 12 - 9 * sin(.pi / 4), 12 - 9 * cos(.pi / 4)),
            (.manSharpRight, 12 + 9 * sin(.pi / 4), 12 + 9 * cos(.pi / 4)),
            (.manSharpLeft, 12 - 9 * sin(.pi / 4), 12 + 9 * cos(.pi / 4)),
        ]
        for (icon, x, y) in cases {
            let tip = try XCTUnwrap(firstPoint(DashIcons.drawing(icon).layers[0].path))
            XCTAssertEqual(tip.x, x, accuracy: 1e-9, "\(icon)")
            XCTAssertEqual(tip.y, y, accuracy: 1e-9, "\(icon)")
        }
        XCTAssertEqual(DashIcons.arrowRotationDeg(.manSharpLeft), -135)
        XCTAssertNil(DashIcons.arrowRotationDeg(.manUturn))
    }

    func testTurnDirMapping() {
        XCTAssertEqual(DashIcons.icon(for: .left), .manLeft)
        XCTAssertEqual(DashIcons.icon(for: .right), .manRight)
        XCTAssertEqual(DashIcons.icon(for: .sharpLeft), .manSharpLeft)
        XCTAssertEqual(DashIcons.icon(for: .sharpRight), .manSharpRight)
        XCTAssertEqual(DashIcons.icon(for: .slightLeft), .manSlightLeft)
        XCTAssertEqual(DashIcons.icon(for: .slightRight), .manSlightRight)
        XCTAssertEqual(DashIcons.icon(for: .uturn), .manUturn)
        XCTAssertEqual(DashIcons.icon(for: .roundabout), .manRoundabout)
        XCTAssertEqual(DashIcons.icon(for: .mergeLeft), .manMerge)
        XCTAssertEqual(DashIcons.icon(for: .mergeRight), .manMerge)
        XCTAssertEqual(DashIcons.icon(for: .forkLeft), .manFork)
        XCTAssertEqual(DashIcons.icon(for: .forkRight), .manFork)
        XCTAssertEqual(DashIcons.icon(for: .straight), .manStraight)
        XCTAssertEqual(DashIcons.icon(for: .continue), .manStraight)
        XCTAssertEqual(DashIcons.icon(for: .arrive), .manArrive)
    }

    func testStrokedIconsUseSpecWidthsAndCaps() {
        func strokes(_ icon: DashIcon) -> [(Double, DashLineCap, DashLineJoin)] {
            DashIcons.drawing(icon).layers.compactMap {
                if case let .stroke(_, w, c, j) = $0.paint { return (w, c, j) }
                return nil
            }
        }
        XCTAssertEqual(strokes(.manUturn).map(\.0), [2.4])
        XCTAssertEqual(strokes(.manUturn).first?.1, .round)
        XCTAssertEqual(strokes(.manUturn).first?.2, .round)
        XCTAssertEqual(strokes(.manRoundabout).map(\.0), [2.2, 2.2])
        XCTAssertEqual(strokes(.manRoundabout).first?.2, .miter)
        XCTAssertEqual(strokes(.manMerge).map(\.0), [2.2])
        XCTAssertEqual(strokes(.manFork).map(\.0), [2.2])
        XCTAssertEqual(DashIcons.drawing(.manFork).layers.count, 3) // stems + two heads
    }

    func testEvenOddIcons() {
        if case let .fill(_, rule) = DashIcons.drawing(.manArrive).layers[0].paint { XCTAssertEqual(rule, .evenOdd) } else { XCTFail() }
        if case let .fill(_, rule) = DashIcons.drawing(.fabCompass).layers[0].paint { XCTAssertEqual(rule, .evenOdd) } else { XCTFail() }
        if case let .fill(_, rule) = DashIcons.drawing(.fabGps).layers[0].paint { XCTAssertEqual(rule, .nonZero) } else { XCTFail() }
        // arrive = outer pin + inner hole (two sub-paths)
        let moves = DashIcons.drawing(.manArrive).layers[0].path.elements.filter { if case .move = $0 { return true }; return false }
        XCTAssertEqual(moves.count, 2)
    }

    func testPuckAndPinColours() {
        let puck = DashIcons.drawing(.navArrow).layers.map(\.paint)
        XCTAssertEqual(puck, [.fill(DashColor(argb: 0x6600_0000), .nonZero), .fill(DashColor(argb: 0xFF1A_73E8), .nonZero),
                              .fill(.white, .nonZero)])
        let pin = DashIcons.drawing(.destPin).layers.map(\.paint)
        XCTAssertEqual(pin, [.fill(DashColor(argb: 0xFFE5_3935), .nonZero), .fill(.white, .nonZero)])
    }

    func testAspectFitIntoManeuverSlot() throws {
        // 24-unit icon into the 64×64 slot: scale 64/24.
        let (t, s) = DashIcons.fitTransform(viewport: DashSize(width: 24, height: 24), into: DashRect(x: 26, y: 22, width: 64, height: 64))
        XCTAssertEqual(s, 64.0 / 24.0, accuracy: 1e-12)
        let o = t.apply(DashPoint(0, 0)), e = t.apply(DashPoint(24, 24))
        XCTAssertEqual(o.x, 26, accuracy: 1e-9); XCTAssertEqual(o.y, 22, accuracy: 1e-9)
        XCTAssertEqual(e.x, 90, accuracy: 1e-9); XCTAssertEqual(e.y, 86, accuracy: 1e-9)
        // stroke widths scale with the icon
        let cmds = DashIcons.commands(.manUturn, in: DashRect(x: 0, y: 0, width: 64, height: 64))
        guard case let .stroke(_, st) = cmds[0] else { return XCTFail("stroke first") }
        XCTAssertEqual(st.width, 2.4 * 64 / 24, accuracy: 1e-9)
    }

    func testAspectFitNonSquarePin() {
        // ic_dest_pin 40×48 into the 36×44 destination slot → scale 0.9, centred horizontally.
        let rect = DashRect(x: 100, y: 200, width: 36, height: 44)
        let (t, s) = DashIcons.fitTransform(viewport: DashSize(width: 40, height: 48), into: rect)
        XCTAssertEqual(s, 0.9, accuracy: 1e-12)
        let anchor = t.apply(DashPoint(20, 48)) // bottom centre
        XCTAssertEqual(anchor.x, 118, accuracy: 1e-9)
        XCTAssertEqual(anchor.y, 200 + 22 + 0.9 * 24, accuracy: 1e-9)
    }

    func testRotationAboutRectCentre() throws {
        // Compass rotated by 90°: needle-free check on the disc top point (12,2) → right (22,12).
        let rect = DashRect(x: 0, y: 0, width: 24, height: 24)
        let path = DashIcons.path(.fabCompass, in: rect, rotation: .pi / 2)
        let p0 = try XCTUnwrap(firstPoint(path))
        XCTAssertEqual(p0.x, 22, accuracy: 1e-9)
        XCTAssertEqual(p0.y, 12, accuracy: 1e-9)
    }

    func testTintAndAlpha() {
        let cmds = DashIcons.commands(.search, in: DashRect(x: 0, y: 0, width: 20, height: 20), tint: DashColor(argb: 0xFF5F_6368))
        guard case let .fill(_, c, _) = cmds[0] else { return XCTFail() }
        XCTAssertEqual(c, DashColor(argb: 0xFF5F_6368))
        let faded = DashIcons.commands(.fabCompass, in: DashRect(x: 0, y: 0, width: 24, height: 24), alpha: 0.55)
        guard case let .fill(_, c2, _) = faded[0] else { return XCTFail() }
        XCTAssertEqual(c2, DashColor(rgb: 0xFFFFFF, alpha: 0.55))
        // tint keeps per-layer alpha (puck shadow 0x66 × tint alpha 1)
        let puck = DashIcons.commands(.navArrow, in: DashRect(x: 0, y: 0, width: 48, height: 48), tint: .white)
        guard case let .fill(_, c3, _) = puck[0] else { return XCTFail() }
        XCTAssertEqual(c3, DashColor(argb: 0x66FF_FFFF))
    }

    func testFabGpsDescribesCrosshairExtents() throws {
        let b = try XCTUnwrap(DashIcons.drawing(.fabGps).layers[0].path.controlPointBounds)
        XCTAssertEqual(b.minX, 1, accuracy: 1e-9)
        XCTAssertEqual(b.maxX, 23, accuracy: 1e-9)
        XCTAssertEqual(b.minY, 1, accuracy: 1e-9)
        XCTAssertEqual(b.maxY, 23, accuracy: 1e-9)
    }

    func testPlusMinusExactGeometry() throws {
        let minus = DashIcons.drawing(.fabMinus).layers[0].path
        XCTAssertEqual(minus.elements, [.move(DashPoint(19, 13)), .line(DashPoint(5, 13)), .line(DashPoint(5, 11)),
                                        .line(DashPoint(19, 11)), .line(DashPoint(19, 13)), .close])
        let plus = try XCTUnwrap(DashIcons.drawing(.fabPlus).layers[0].path.controlPointBounds)
        XCTAssertEqual(plus, DashRect(x: 5, y: 5, width: 14, height: 14))
    }
}

final class DashPaletteTests: XCTestCase {
    func testSpecColours() {
        XCTAssertEqual(DashPalette.cardFill.argb, 0xF01A_2332)
        XCTAssertEqual(DashPalette.topBannerFill.argb, 0xFF1A_2332)
        XCTAssertEqual(DashPalette.roadText.argb, 0xFF8A_B4F8)
        XCTAssertEqual(DashPalette.laneText.argb, 0xFFFF_B74D)
        XCTAssertEqual(DashPalette.metricLabel.argb, 0xFF88_9098)
        XCTAssertEqual(DashPalette.secondaryText.argb, 0xFFB0_B8C0)
        XCTAssertEqual(DashPalette.statusText.argb, 0xFFC8_D0D8)
        XCTAssertEqual(DashPalette.statusWarning.argb, 0xFFFF_8A80)
        XCTAssertEqual(DashPalette.endPillFill.argb, 0x33FF_5A52)
        XCTAssertEqual(DashPalette.endPillStroke.argb, 0x55FF_5A52)
        XCTAssertEqual(DashPalette.blueAction.argb, 0xFF1A_73E8)
        XCTAssertEqual(DashPalette.routeChipFill.argb, 0x22FF_FFFF)
        XCTAssertEqual(DashPalette.routeChipSelectedStroke.argb, 0xFF8A_B4F8)
        XCTAssertEqual(DashPalette.fabFill.argb, 0xF01E_2430)
        XCTAssertEqual(DashPalette.gaugeStroke.argb, 0x66FF_FFFF)
        XCTAssertEqual(DashPalette.limitRed.argb, 0xFFE5_3935)
        XCTAssertEqual(DashPalette.searchPillFill.argb, 0xF2FF_FFFF)
        XCTAssertEqual(DashPalette.searchPillAccent.argb, 0xFFE6_5100)
        XCTAssertEqual(DashPalette.sheetBackground.argb, 0xF8FF_FFFF)
        XCTAssertEqual(DashPalette.sheetDelete.argb, 0xFFD9_3025)
        XCTAssertEqual(DashPalette.poiChipFill.argb, 0xFFF1_F3F4)
        XCTAssertEqual(DashPalette.dimmer.argb, 0x6600_0000)
        XCTAssertEqual(DashPalette.menuSheet.argb, 0xF014_1A20)
        XCTAssertEqual(DashPalette.segmentSelected.argb, 0xFFFF_6A2C)
        XCTAssertEqual(DashPalette.segmentUnselected.argb, 0xFF1F_242E)
        XCTAssertEqual(DashPalette.previewHome.argb, 0xFFFF_D54F)
        XCTAssertEqual(DashPalette.focusFill.argb, 0x66FF_9800)
        XCTAssertEqual(DashPalette.focusStroke.argb, 0xFFFF_9800)
        XCTAssertEqual(DashPalette.focusStrokeWidth, 5)
        XCTAssertEqual(DashPalette.focusRadius, 12)
    }

    func testRouteLineStyles() {
        XCTAssertEqual(DashPalette.routeRemain.argb, 0xFF1A_73E8)
        XCTAssertEqual(DashPalette.routeRemainWidth, 7)
        XCTAssertEqual(DashPalette.routeDone, DashColor(rgb: 0x9AA0A6, alpha: 200.0 / 255.0))
        XCTAssertEqual(DashPalette.routeDoneWidth, 5.5)
        XCTAssertEqual(DashPalette.routePreview, DashColor(rgb: 0x34A853, alpha: 220.0 / 255.0))
        XCTAssertEqual(DashPalette.routePreviewWidth, 6.5)
        XCTAssertEqual(DashPalette.routeAlternative, DashColor(rgb: 0x9AA0A6, alpha: 160.0 / 255.0))
        XCTAssertEqual(DashPalette.routeAlternativeWidth, 5)
        XCTAssertEqual(DashPalette.routeToDestination.argb, 0xFFFB_BC04)
        XCTAssertEqual(DashPalette.routeToDestinationWidth, 3.5)
        XCTAssertEqual(DashPalette.routeToDestinationDash, [8, 6])
    }

    func testChromeColours() {
        XCTAssertEqual(DashPalette.chrome(.dark).argb, 0xFF10_1418)
        XCTAssertEqual(DashPalette.chrome(.black).argb, 0xFF00_0000)
        XCTAssertEqual(DashPalette.chrome(.slate).argb, 0xFF1A_2332)
        XCTAssertEqual(DashPalette.chrome(.forest).argb, 0xFF0E_1A14)
    }

    func testDensityVectors() {
        // navigation-dash.md §11.1, input-controls.md §3.2
        XCTAssertEqual(DashDensity.densityDpi(canvasWidth: 544), 160)
        XCTAssertEqual(DashDensity.densityDpi(canvasWidth: 720), 160)
        XCTAssertEqual(DashDensity.densityDpi(canvasWidth: 800), 160)
        XCTAssertEqual(DashDensity.densityDpi(canvasWidth: 1024), 182)
        XCTAssertEqual(DashDensity.densityDpi(canvasWidth: 1280), 228)
        XCTAssertEqual(DashDensity.scale(canvasWidth: 800), 1.0)
        XCTAssertEqual(DashDensity.scale(canvasWidth: 1024), 1.1375)
        XCTAssertEqual(DashDensity.scale(canvasWidth: 1280), 1.425)
        XCTAssertEqual(DashDensity.densityDpi(canvasWidth: 5000), 640) // clamp
        XCTAssertEqual(DashDensity.scale(canvasWidth: 5000), 4.0)
        XCTAssertEqual(DashDensity.densityDpi(canvasWidth: 1024, overrideDpi: 187), 187) // Yunmo / Ride MO
        // Math.round half-up: 160·W/900 = x.5 exactly at W = 905.625 → not an integer width; use 1001.25? check a near case
        XCTAssertEqual(DashDensity.densityDpi(canvasWidth: 1001), 178) // 177.955…
    }
}

final class DashStringsTests: XCTestCase {
    func testEnglishAndSpanishLabels() {
        XCTAssertEqual(DashText.time.localized(.en), "TIME")
        XCTAssertEqual(DashText.time.localized(.es), "TIEMPO")
        XCTAssertEqual(DashText.arrive.localized(.es), "LLEGADA") // spec fix of "LLEGAR"
        XCTAssertEqual(DashText.left.localized(.es), "RESTANTE") // spec fix of "IZQUIERDA"
        XCTAssertEqual(DashText.end.localized(.es), "Fin")
        XCTAssertEqual(DashText.searchHere.localized(.es), "Busca aquí")
        XCTAssertEqual(DashText.save.localized(.en), "★ Save")
        XCTAssertEqual(DashText.marker.localized(.es), "＋ Marcador")
        XCTAssertEqual(DashText.doneFreeRide.localized(.es), "Listo · ruta libre")
        XCTAssertEqual(DashText.recenterRecalc.localized(.en), "Recenter / Recalc")
        XCTAssertEqual(DashText.zoomOutGlyph.localized(.en), "\u{FF0D}")
        XCTAssertEqual(DashText.zoomInGlyph.localized(.en), "\u{FF0B}")
        XCTAssertEqual(DashText.typeOnPhoneStatus.localized(.en), "⌨ Type on PHONE — results show here")
        for t in DashText.allCases {
            XCTAssertFalse(t.en.isEmpty, "\(t)")
            XCTAssertFalse(t.es.isEmpty, "\(t)")
        }
    }

    func testParameterisedStrings() {
        XCTAssertEqual(DashStrings.places(3, .en), "3 places")
        XCTAssertEqual(DashStrings.places(3, .es), "3 lugares")
        XCTAssertEqual(DashStrings.altLabel(unit: "m", .en), "ALT m")
        XCTAssertEqual(DashStrings.altLabel(unit: "ft", .es), "ALT ft")
        XCTAssertEqual(DashStrings.altLabel(unit: "", .en), "ALT")
        XCTAssertEqual(DashStrings.poiChipLabel("Fuel", .en), "Fuel")
        XCTAssertEqual(DashStrings.poiChipLabel("Fuel", .es), "Gasolina")
        XCTAssertEqual(DashStrings.poiChipLabel("Custom", .es), "Custom")
        XCTAssertEqual(DashStrings.maneuverWord(.forkLeft, .en), "Keep left")
        XCTAssertEqual(DashStrings.maneuverWord(.mergeRight, .en), "Merge")
        XCTAssertEqual(DashStrings.maneuverWord(.continue, .en), "Continue")
        XCTAssertEqual(DashStrings.toDestination("Câmpina", .en), "To Câmpina")
    }

    func testPreferredLanguage() {
        XCTAssertEqual(DashLanguage.preferred(from: ["es-CO", "en-US"]), .es)
        XCTAssertEqual(DashLanguage.preferred(from: ["de-DE", "en-GB"]), .en)
        XCTAssertEqual(DashLanguage.preferred(from: ["fr-FR"]), .en)
        XCTAssertEqual(DashLanguage.preferred(from: []), .en)
    }
}

final class DashFormatTests: XCTestCase {
    func testSpeedFormatting() {
        XCTAssertEqual(DashFormat.speed(mps: nil, units: .metric), "—")
        XCTAssertEqual(DashFormat.speed(mps: 0, units: .metric), "0")
        XCTAssertEqual(DashFormat.speed(mps: 10.0 / 3.6, units: .metric), "10")
        XCTAssertEqual(DashFormat.speed(mps: 100.0 / 3.6, units: .imperial), "62") // GpxNavTest formatImperial…
        XCTAssertEqual(DashFormat.speed(mps: 12.5 / 3.6, units: .metric), "13") // HALF_UP
        XCTAssertEqual(DashFormat.speed(mps: -1, units: .metric), "0")
        XCTAssertEqual(DashFormat.speedUnit(.metric), "km/h")
        XCTAssertEqual(DashFormat.speedUnit(.imperial), "mph")
        XCTAssertEqual(DashFormat.roundHalfUp(2.5), 3)
        XCTAssertEqual(DashFormat.roundHalfUp(2.4999), 2)
    }

    func testClock() {
        let date = Date(timeIntervalSince1970: 1_793_000_000) // 2026-10-26 07:33:20 UTC
        XCTAssertEqual(DashFormat.clock(date, timeZone: TimeZone(identifier: "UTC")!), "07:33")
        XCTAssertEqual(DashFormat.clock(date, timeZone: TimeZone(secondsFromGMT: -5 * 3600)!), "02:33")
    }

    func testNightRules() {
        let utc = TimeZone(identifier: "UTC")!
        func at(_ h: Int, _ m: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(1_792_972_800 + h * 3600 + m * 60)) } // 2026-10-26 00:00 UTC
        XCTAssertTrue(DashFormat.isNight(theme: .auto, phoneDarkMode: false, date: at(6, 59), timeZone: utc))
        XCTAssertFalse(DashFormat.isNight(theme: .auto, phoneDarkMode: false, date: at(7, 0), timeZone: utc))
        XCTAssertFalse(DashFormat.isNight(theme: .auto, phoneDarkMode: false, date: at(18, 59), timeZone: utc))
        XCTAssertTrue(DashFormat.isNight(theme: .auto, phoneDarkMode: false, date: at(19, 0), timeZone: utc))
        XCTAssertTrue(DashFormat.isNight(theme: .auto, phoneDarkMode: true, date: at(12, 0), timeZone: utc))
        XCTAssertFalse(DashFormat.isNight(theme: .day, phoneDarkMode: true, date: at(23, 0), timeZone: utc))
        XCTAssertTrue(DashFormat.isNight(theme: .night, phoneDarkMode: false, date: at(12, 0), timeZone: utc))
    }
}

final class DashTextLayoutTests: XCTestCase {
    let m = ApproximateTextMeasurer()

    func testWidthWithLetterSpacing() {
        let f = DashFont(size: 16, weight: .bold)
        let plain = DashTextLayout.width("↑ ↑", font: f, measurer: m)
        let spaced = DashTextLayout.width("↑ ↑", font: f, letterSpacingEm: 0.12, measurer: m)
        XCTAssertEqual(spaced - plain, 0.12 * 16 * 3, accuracy: 1e-9)
        XCTAssertEqual(DashTextLayout.width("", font: f, measurer: m), 0)
        // "End" 17 sp bold = (0.66 + 0.54 + 0.54) × 17 × 1.06
        XCTAssertEqual(DashTextLayout.width("End", font: DashFont(size: 17, weight: .bold), measurer: m), 1.74 * 17 * 1.06, accuracy: 1e-9)
    }

    func testTruncate() {
        let f = DashFont(size: 10)
        XCTAssertEqual(DashTextLayout.truncate("abc", maxWidth: 100, font: f, measurer: m), "abc")
        let t = DashTextLayout.truncate("Bucharest Henri Coandă Airport", maxWidth: 60, font: f, measurer: m)
        XCTAssertTrue(t.hasSuffix("…"))
        XCTAssertLessThanOrEqual(DashTextLayout.width(t, font: f, measurer: m), 60.01)
        XCTAssertFalse(t.dropLast().hasSuffix(" ")) // trailing spaces trimmed before the ellipsis
        XCTAssertEqual(DashTextLayout.truncate("WWWW", maxWidth: 1, font: f, measurer: m), "…")
    }

    func testWrapTwoLinesWithEllipsis() {
        let f = DashFont(size: 10)
        let text = "Strada Mihai Eminescu colt cu Bulevardul Unirii"
        let lines = DashTextLayout.wrap(text, maxWidth: 80, font: f, maxLines: 2, measurer: m)
        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(lines[0].hasSuffix("…"))
        XCTAssertTrue(lines[1].hasSuffix("…"))
        for l in lines { XCTAssertLessThanOrEqual(DashTextLayout.width(l, font: f, measurer: m), 80.01) }
        XCTAssertTrue(text.hasPrefix(lines[0]))
    }

    func testWrapFitsWithoutEllipsis() {
        let f = DashFont(size: 10)
        XCTAssertEqual(DashTextLayout.wrap("Calle 80", maxWidth: 200, font: f, maxLines: 2, measurer: m), ["Calle 80"])
        XCTAssertEqual(DashTextLayout.wrap("aa bb", maxWidth: 12, font: f, maxLines: 3, measurer: m), ["aa", "bb"])
        XCTAssertEqual(DashTextLayout.lineCount("aa bb", maxWidth: 12, font: f, maxLines: 3, measurer: m), 2)
    }

    func testHardBreaksAndLongWords() {
        let f = DashFont(size: 10)
        XCTAssertEqual(DashTextLayout.wrap("a\nb", maxWidth: 100, font: f, maxLines: 3, measurer: m), ["a", "b"])
        // folded hard-broken remainder still signals the cut
        XCTAssertEqual(DashTextLayout.wrap("a\nb\nc", maxWidth: 100, font: f, maxLines: 2, measurer: m), ["a", "b c…"])
        // 10 'm' at 8.6 px each = 86 px > 40 px: broken between characters
        let lines = DashTextLayout.wrap("mmmmmmmmmm", maxWidth: 40, font: f, maxLines: 5, measurer: m)
        XCTAssertEqual(lines.joined(), "mmmmmmmmmm")
        XCTAssertTrue(lines.allSatisfy { DashTextLayout.width($0, font: f, measurer: m) <= 40.01 })
    }

    func testLayoutBaselinesAndAlignment() {
        let f = DashFont(size: 10) // ascent 9.5, descent 2.5, line height 12
        let rect = DashRect(x: 10, y: 0, width: 100, height: 40)
        let left = DashTextLayout.layout("Ab", in: rect, style: DashTextStyle(font: f, color: .white), measurer: m)
        XCTAssertEqual(left.count, 1)
        XCTAssertEqual(left[0].origin.x, 10)
        XCTAssertEqual(left[0].origin.y, (40 - 12) / 2 + 9.5, accuracy: 1e-9)
        let w = DashTextLayout.width("Ab", font: f, measurer: m)
        let center = DashTextLayout.layout("Ab", in: rect, style: DashTextStyle(font: f, color: .white, alignment: .center), measurer: m)
        XCTAssertEqual(center[0].origin.x, 60 - w / 2, accuracy: 1e-9)
        let right = DashTextLayout.layout("Ab", in: rect, style: DashTextStyle(font: f, color: .white, alignment: .right), measurer: m)
        XCTAssertEqual(right[0].origin.x, 110 - w, accuracy: 1e-9)
        let two = DashTextLayout.layout("aa bb", in: DashRect(x: 0, y: 0, width: 12, height: 40),
                                        style: DashTextStyle(font: f, color: .white, maxLines: 2), measurer: m)
        XCTAssertEqual(two.map(\.text), ["aa", "bb"])
        XCTAssertEqual(two[0].origin.y, (40 - 24) / 2 + 9.5, accuracy: 1e-9)
        XCTAssertEqual(two[1].origin.y, two[0].origin.y + 12, accuracy: 1e-9)
    }
}
