// SPDX-License-Identifier: AGPL-3.0-or-later
// Geometry vectors from navigation-dash.md §11.3 (landscape 800×384) and §11.4 (portrait 800×944).
import XCTest
@testable import OpenCfMotoCore

final class DashLayoutTests: XCTestCase {
    let m = ApproximateTextMeasurer()
    func ctx(_ w: Double, _ h: Double, margins: ScreenMargins = .zero) -> DashLayoutContext {
        DashLayoutContext(canvas: DashSize(width: w, height: h), margins: margins, measurer: m)
    }

    private func assertRect(_ r: DashRect?, _ x: Double, _ y: Double, _ w: Double, _ h: Double, accuracy: Double = 1e-6,
                            file: StaticString = #filePath, line: UInt = #line) {
        guard let r else { return XCTFail("nil rect", file: file, line: line) }
        XCTAssertEqual(r.x, x, accuracy: accuracy, "x", file: file, line: line)
        XCTAssertEqual(r.y, y, accuracy: accuracy, "y", file: file, line: line)
        XCTAssertEqual(r.width, w, accuracy: accuracy, "w", file: file, line: line)
        XCTAssertEqual(r.height, h, accuracy: accuracy, "h", file: file, line: line)
    }

    func testFabColumnLandscape() {
        // right margin 6 (x = 748…794), y = 8, 60, 112, 164, 216 (bottom 262)
        let fabs = DashLayout.fabColumn(ctx(800, 384))
        XCTAssertEqual(fabs.count, 5)
        for (i, y) in [8.0, 60, 112, 164, 216].enumerated() { assertRect(fabs[i], 748, y, 46, 46) }
        XCTAssertEqual(fabs[4].maxY, 262)
    }

    func testFabColumnPortraitCentred() {
        // right margin 8, vertically centred: 254 tall ⇒ y = 345…599
        let fabs = DashLayout.fabColumn(ctx(800, 944))
        assertRect(fabs[0], 746, 345, 46, 46)
        XCTAssertEqual(fabs[4].maxY, 599)
    }

    func testFabColumnScalesWithDensity() {
        let fabs = DashLayout.fabColumn(ctx(1280, 576))
        XCTAssertEqual(fabs[0].width, 46 * 1.425, accuracy: 1e-9)
        XCTAssertEqual(fabs[0].maxX, 1280 - 6 * 1.425, accuracy: 1e-9)
        XCTAssertEqual(fabs[1].minY - fabs[0].maxY, 6 * 1.425, accuracy: 1e-9)
    }

    func testSearchPillGeometry() {
        let c = ctx(800, 384)
        let pill = DashLayout.searchPill(c, circuitLabel: "Circuit", lapLabel: "Lap")
        XCTAssertEqual(pill.frame.x, 12)
        XCTAssertEqual(pill.frame.y, 8)
        XCTAssertEqual(pill.frame.height, 48)
        assertRect(pill.iconRect, 16, 22, 20, 20)
        assertRect(pill.textRect, 44, 8, 300, 48)
        XCTAssertEqual(pill.circuitRect.height, 36)
        XCTAssertEqual(pill.circuitRect.minY, 14)
        XCTAssertEqual(pill.circuitRect.minX, 344)
        XCTAssertEqual(pill.lapRect.minX, pill.circuitRect.maxX)
        XCTAssertEqual(pill.frame.maxX, pill.lapRect.maxX + 14, accuracy: 1e-9)
        // spec ≈ 453 px wide (Roboto); the approximate measurer gives the same order
        XCTAssertEqual(pill.frame.width, 453, accuracy: 20)
        XCTAssertEqual(pill.textFont.size, 16)
        XCTAssertEqual(pill.labelFont, DashFont(size: 14, weight: .bold))
    }

    func testSearchPillShrinksBeforeFabLane() {
        // 544×512 (CL-C450): the pill must end before W − 88 = 456.
        let pill = DashLayout.searchPill(ctx(544, 512), circuitLabel: "Circuit", lapLabel: "Lap")
        XCTAssertLessThanOrEqual(pill.frame.maxX, 456 + 1e-9)
        XCTAssertLessThan(pill.textRect.width, 300)
    }

    func testSearchPillRespectsMargins() {
        // 800NK Advanced: top margin 22 → pill at y = 30 (iOS: margins are an unsafe area)
        let pill = DashLayout.searchPill(ctx(720, 704, margins: ScreenMargins(top: 22)), circuitLabel: "Circuit", lapLabel: "Lap")
        XCTAssertEqual(pill.frame.y, 30)
        let fabs = DashLayout.fabColumn(ctx(720, 704, margins: ScreenMargins(top: 22, right: 10)))
        XCTAssertEqual(fabs[0].minY, 30)
        XCTAssertEqual(fabs[0].maxX, 720 - 10 - 6)
    }

    func testNavCardLandscapeOneAndTwoLines() {
        let c = ctx(800, 384)
        let one = DashLayout.navCard(c, cue: HudCue(dir: .right, distanceText: "350 m", text: "Calle 80"))
        XCTAssertFalse(one.isBanner)
        XCTAssertEqual(one.frame.minX, 8)
        XCTAssertEqual(one.frame.minY, 8)
        // P0 (D11): distance 30 → 48 sp, road 18 → 26 sp; the column (48 + 2 + 26 sp lines) is taller than
        // the 64-dp icon, which is centred on it
        let col = 1.2 * 48 + 2 + 1.2 * 26
        assertRect(one.iconRect, 26, 22 + (col - 64) / 2, 64, 64) // padding L18 T14, icon 64
        XCTAssertEqual(one.distanceRect.minX, 26 + 64 + 14)
        XCTAssertEqual(one.distanceFont, DashFont(size: 48, weight: .bold))
        XCTAssertEqual(one.roadFont, DashFont(size: 26, weight: .bold))
        XCTAssertEqual(one.roadLineCount, 1)
        XCTAssertEqual(one.frame.height, 14 + col + 14, accuracy: 1e-9)
        // width = 18 + 64 + 14 + column + 22
        XCTAssertEqual(one.frame.width, 18 + 64 + 14 + one.distanceRect.width + 22, accuracy: 1e-9)
        let long = DashLayout.navCard(c, cue: HudCue(dir: .left, distanceText: "1.2 km",
                                                     text: "Bulevardul Regele Mihai I colț cu Strada Ion Brătianu și Piața Unirii nord", lanes: "↑ ↑ →"))
        XCTAssertEqual(long.roadLineCount, 2)
        XCTAssertNotNil(long.lanesRect)
        XCTAssertGreaterThan(long.frame.height, one.frame.height)
        XCTAssertLessThanOrEqual(long.frame.maxX, 800 - 88 + 1e-9) // right margin 88
        // max road width = 24 × line height (maxEms 24)
        XCTAssertLessThanOrEqual(long.roadRect.width, 24 * DashTextLayout.lineHeight(font: long.roadFont, measurer: m) + 1e-9)
        XCTAssertEqual(long.lanesRect!.minY - long.roadRect.maxY, 4, accuracy: 1e-9)
    }

    func testNavBannerPortrait() {
        let c = ctx(800, 944)
        let b = DashLayout.navCard(c, cue: HudCue(dir: .right, distanceText: "350 m", text: "Strada Republicii", lanes: "↑ ↑ →"))
        XCTAssertTrue(b.isBanner)
        XCTAssertEqual(b.frame.minX, 0)
        XCTAssertEqual(b.frame.minY, 0)
        XCTAssertEqual(b.frame.width, 800)
        XCTAssertEqual(b.distanceFont.size, 52) // P0 (D11): 32 → 52
        XCTAssertEqual(b.roadFont.size, 28)     // 20 → 28
        XCTAssertEqual(b.lanesFont.size, 18)
        XCTAssertEqual(b.iconRect.minY, 10 + (b.frame.height - 22 - 64) / 2, accuracy: 1e-9)
        // content centred horizontally
        let rowW = b.distanceRect.maxX - b.iconRect.minX
        XCTAssertEqual(b.iconRect.minX + rowW / 2, 400, accuracy: 1e-6)
        // top margin pads the content, banner still starts at y 0
        let withMargin = DashLayout.navCard(ctx(800, 944, margins: ScreenMargins(top: 22)), cue: HudCue(dir: .left, distanceText: "1 km", text: "x"))
        XCTAssertEqual(withMargin.frame.minY, 0)
        // margin + T10 + the text column (52-sp distance + 28-sp road, taller than the 64-dp icon) + B12
        let col = 1.2 * 52 + 1.2 * 28
        XCTAssertEqual(withMargin.frame.height, 22 + 10 + col + 12, accuracy: 1e-9)
        XCTAssertEqual(withMargin.iconRect.minY, 32 + (col - 64) / 2, accuracy: 1e-9)
    }

    private let labels3 = ["TIME", "ARRIVE", "LEFT"]

    func testMetricsCardLandscapeNatural() {
        // P0 (D12, D01): TIME / ARRIVE / LEFT — no ALT column, no End button
        let c = ctx(800, 384)
        let l = DashLayout.metricsCard(c, labels: labels3, values: ["—", "—", "—"])
        XCTAssertFalse(l.isBar)
        XCTAssertEqual(l.frame.minX, 8)
        XCTAssertEqual(l.frame.maxY, 376) // bottom = H − 8
        XCTAssertNil(l.statusRect) // status hidden in landscape
        // minimum column widths 80 / 80 / 90 with "—"
        XCTAssertEqual(l.columns.map(\.labelRect.width), [80, 80, 90])
        XCTAssertEqual(l.columns[1].labelRect.minX - l.columns[0].labelRect.maxX, 20) // gap 20
        XCTAssertEqual(l.columns[2].labelRect.minX - l.columns[1].labelRect.maxX, 20)
        XCTAssertEqual(l.columns[2].valueFont.size, 30)
        XCTAssertEqual(l.columns[0].valueFont.size, 26)
        XCTAssertEqual(l.columns[0].labelFont.size, 13)
        XCTAssertEqual(l.columns[0].valueRect.minY - l.columns[0].labelRect.maxY, 4) // value top margin 4
        XCTAssertEqual(l.frame.width, 22 + 80 + 20 + 80 + 20 + 90 + 22, accuracy: 1e-9)
    }

    func testMetricsCardCompressesBeforeSpeedChip() {
        // Long values: the chip (limit room always reserved, P0) starts at x 560 → the card must end at ≤ 552.
        let c = ctx(800, 384)
        let chip = DashLayout.speedChip(c, hasLimit: false, navigating: true)
        XCTAssertEqual(chip.gaugeRect.minX, 560)
        let l = DashLayout.metricsCard(c, labels: labels3, values: ["1h05m", "14:20", "123.4 km"], maxRight: chip.frame.minX - 8)
        XCTAssertLessThanOrEqual(l.frame.maxX, 552 + 1e-9)
        XCTAssertFalse(l.frame.intersects(chip.frame))
        // values fully shown (no ellipsis) on 800 px
        XCTAssertEqual(l.columns.map(\.value), ["1h05m", "14:20", "123.4 km"])
    }

    func testMetricsCardLastResortEllipsis() {
        let c = ctx(800, 384)
        let l = DashLayout.metricsCard(c, labels: labels3, values: ["12h05m", "14:20", "1234.5 km"], maxRight: 200)
        XCTAssertLessThanOrEqual(l.frame.maxX, 200 + 1e-6)
        XCTAssertLessThan(l.columns[2].valueFont.size, 30)
    }

    func testMetricsWarningRowInLandscape() {
        let c = ctx(800, 384)
        let plain = DashLayout.metricsCard(c, labels: labels3, values: ["—", "—", "—"])
        let warn = DashLayout.metricsCard(c, labels: labels3, values: ["—", "—", "—"], landscapeStatus: "Route · 12.3 km · OFF 95 m")
        XCTAssertNotNil(warn.statusRect)
        XCTAssertGreaterThan(warn.frame.height, plain.frame.height)
        XCTAssertEqual(warn.frame.maxY, 376)
        XCTAssertEqual(warn.statusFont.size, 14)
        XCTAssertGreaterThanOrEqual(warn.statusRect!.width, DashTextLayout.width("Route · 12.3 km · OFF 95 m", font: warn.statusFont, measurer: m) - 1e-6)
    }

    func testSpeedChipStacksOnNarrowCanvases() {
        XCTAssertFalse(DashLayout.speedChipStacksAboveMetrics(ctx(800, 384), labels: labels3))
        XCTAssertFalse(DashLayout.speedChipStacksAboveMetrics(ctx(1280, 576), labels: labels3))
        XCTAssertFalse(DashLayout.speedChipStacksAboveMetrics(ctx(1024, 464), labels: labels3))
        // without ALT and End the 3-column card fits beside the chip on 720×704 (it stacked before P0)
        XCTAssertFalse(DashLayout.speedChipStacksAboveMetrics(ctx(720, 704), labels: labels3))
        XCTAssertTrue(DashLayout.speedChipStacksAboveMetrics(ctx(544, 512), labels: labels3))
        XCTAssertFalse(DashLayout.speedChipStacksAboveMetrics(ctx(800, 944), labels: labels3)) // portrait
    }

    func testMetricsBarPortrait() {
        let c = ctx(800, 944)
        let l = DashLayout.metricsCard(c, labels: labels3, values: ["18m", "14:23", "12.3 km"])
        XCTAssertTrue(l.isBar)
        XCTAssertEqual(l.frame.minX, 0)
        XCTAssertEqual(l.frame.width, 800)
        XCTAssertEqual(l.frame.maxY, 944)
        // 3 weighted columns over 776 px: 242.5 / 242.5 / 291
        let widths = l.columns.map(\.valueRect.width)
        XCTAssertEqual(widths[0], 776 / 3.2, accuracy: 1e-9)
        XCTAssertEqual(widths[2], 776 * 1.2 / 3.2, accuracy: 1e-9)
        XCTAssertEqual(widths.reduce(0, +), 776, accuracy: 1e-9)
        XCTAssertEqual(l.columns[0].labelFont.size, 11)
        XCTAssertEqual(l.columns[0].valueFont.size, 22)
        XCTAssertEqual(l.columns[2].valueFont.size, 24)
        let status = try! XCTUnwrap(l.statusRect)
        XCTAssertEqual(status.width, 776, accuracy: 1e-9) // the whole row: End left the bar
        XCTAssertEqual(l.statusFont.size, 13)
    }

    func testSpeedChipLandscape() {
        // P0 (D03, D19): the limit room is always reserved — the gauge sits at x 560 with or without a sign
        let c = ctx(800, 384)
        let none = DashLayout.speedChip(c, hasLimit: false, navigating: false)
        assertRect(none.gaugeRect, 560, 292, 84, 84)
        assertRect(none.frame, 560, 292, 152, 84)
        XCTAssertNil(none.limitRect)
        let lim = DashLayout.speedChip(c, hasLimit: true, navigating: true)
        assertRect(lim.gaugeRect, 560, 292, 84, 84)
        assertRect(lim.limitRect, 656, 306, 56, 56) // 12 gap, vertically centred
        XCTAssertEqual(lim.frame, none.frame)
        XCTAssertEqual(lim.speedFont, DashFont(size: 44, weight: .bold, monospacedDigits: true)) // D11: 32 → 44
        XCTAssertEqual(lim.unitFont, DashFont(size: 13, weight: .bold))
        XCTAssertEqual(lim.limitFont.size, 20)
    }

    func testSpeedChipPortrait() {
        let c = ctx(800, 944)
        // navigating: top-right, right edge 792, x = 628 with or without a limit (its room is reserved)
        let navLim = DashLayout.speedChip(c, hasLimit: true, navigating: true, belowY: 92)
        XCTAssertEqual(navLim.gaugeRect.minX, 628)
        XCTAssertEqual(navLim.frame.maxX, 792)
        XCTAssertEqual(navLim.gaugeRect.minY, 100) // 8 under the banner
        let nav = DashLayout.speedChip(c, hasLimit: false, navigating: true, belowY: 92)
        XCTAssertEqual(nav.gaugeRect.minX, 628)
        XCTAssertEqual(nav.gaugeRect.width, 96)
        XCTAssertEqual(nav.speedFont.size, 48)
        XCTAssertEqual(nav.unitFont.size, 14)
        // not navigating: bottom-left x 12, bottom 932
        let free = DashLayout.speedChip(c, hasLimit: true, navigating: false)
        XCTAssertEqual(free.gaugeRect.minX, 12)
        XCTAssertEqual(free.gaugeRect.maxY, 932)
        // stacked above a covering card
        let stacked = DashLayout.speedChip(c, hasLimit: true, navigating: false, stackAboveY: 700)
        XCTAssertEqual(stacked.gaugeRect.maxY, 692)
    }

    func testConfirmCardLayout() {
        // P0 (D01): bottom-left, clear of the speed chip, the safe option first
        let c = ctx(800, 384)
        let chip = DashLayout.speedChip(c, hasLimit: true, navigating: true)
        let l = DashLayout.confirmCard(c, question: "End the route?", consequence: "Guidance to Câmpina stops. You keep riding in free ride.",
                                       keepLabel: "Keep going", actLabel: "End route", maxRight: chip.frame.minX - 8)
        XCTAssertEqual(l.frame.minX, 10)
        XCTAssertEqual(l.frame.maxY, 376, "the metrics card's bottom: no sliver of it below the card")
        XCTAssertEqual(l.frame.maxY, DashLayout.metricsCard(c, labels: ["TIME", "ARRIVE", "LEFT"], values: ["18m", "14:23", "12.3 km"]).frame.maxY)
        XCTAssertLessThanOrEqual(l.frame.maxX, chip.frame.minX - 8 + 1e-9)
        XCTAssertFalse(l.frame.intersects(chip.frame))
        XCTAssertLessThan(l.keepRect.maxX, l.actRect.minX)
        XCTAssertEqual(l.keepRect.height, 48)
        XCTAssertEqual(l.questionFont, DashFont(size: 24, weight: .bold))
        XCTAssertEqual(l.consequenceFont.size, 17)
        XCTAssertTrue(l.frame.contains(DashPoint(l.actRect.maxX - 1, l.actRect.maxY - 1)))
        let p = DashLayout.confirmCard(ctx(800, 944), question: "¿Terminar la ruta?", consequence: "Se detiene la guía a Câmpina.",
                                       keepLabel: "Seguir", actLabel: "Terminar")
        XCTAssertEqual(p.frame.minX, 10)
        XCTAssertEqual(p.frame.maxX, 790)
        XCTAssertEqual(p.keepRect.width, p.actRect.width, accuracy: 1e-9)
        // portrait, navigating: above the metrics bar, which stays in view
        let bar = DashLayout.metricsCard(ctx(800, 944), labels: ["TIME", "ARRIVE", "LEFT"], values: ["18m", "14:23", "12.3 km"])
        let above = DashLayout.confirmCard(ctx(800, 944), question: "¿Terminar la ruta?", consequence: "Se detiene la guía a Câmpina.",
                                           keepLabel: "Seguir", actLabel: "Terminar", bottom: bar.frame.minY - 8)
        XCTAssertEqual(above.frame.maxY, bar.frame.minY - 8, accuracy: 1e-9)
        XCTAssertFalse(above.frame.intersects(bar.frame))
    }

    func testPreviewCardLandscape() {
        let c = ctx(800, 384)
        let p = DashFixtures.preview().nav.preview!
        let l = DashLayout.previewCard(c, preview: p, language: .en)
        XCTAssertEqual(l.frame.minX, 10)
        XCTAssertEqual(l.frame.maxY, 374)
        XCTAssertLessThanOrEqual(l.frame.maxX, 800 - 96)
        XCTAssertEqual(l.nameFont, DashFont(size: 17, weight: .bold))
        XCTAssertEqual(l.metaFont.size, 13)
        XCTAssertLessThanOrEqual(l.metaRect.width, 280)
        let go = try! XCTUnwrap(l.goRect)
        XCTAssertEqual(go.height, 44)
        XCTAssertGreaterThanOrEqual(go.width, 110)
        XCTAssertEqual(go.minX - l.metaRect.maxX, 16, accuracy: 1e-9)
        XCTAssertEqual(l.chipLabels, ["★ Fast · 14:14 · 10.2 km", "Fun · 14:20 · 25.4 km"])
        XCTAssertEqual(l.chipRects.count, 2)
        XCTAssertEqual(l.chipRects[1].minX - l.chipRects[0].maxX, 16) // gap 16
        XCTAssertEqual(l.chipRects[0].height, 28 + DashTextLayout.lineHeight(font: l.chipFont, measurer: m), accuracy: 1e-9)
        XCTAssertEqual(l.actions.map(\.id), ["preview.save", "preview.circuit", "preview.cancel"])
        XCTAssertEqual(l.actions.map(\.label), ["★ Save", "Circuit", "Cancel"])
        XCTAssertEqual(l.actions[0].rect.height, 40)
        XCTAssertEqual(l.actions[0].rect.minY - l.chipRects[0].maxY, 8)
    }

    func testPreviewCardPinModeAndStarPrefix() {
        let c = ctx(800, 384)
        let pin = Place(name: "Dropped pin", lat: 1, lon: 2, category: "pin", subtitle: "1.00000, 2.00000")
        let l = DashLayout.previewCard(c, preview: RoutePreview(place: pin, meta: pin.subtitle, pinMode: true), language: .en)
        XCTAssertNil(l.goRect)
        XCTAssertNil(l.chipsViewport)
        XCTAssertEqual(l.actions.map(\.id), ["preview.save", "preview.home", "preview.marker", "preview.cancel"])
        XCTAssertEqual(l.actions.last?.label, "Done")
        XCTAssertEqual(DashLayout.chipDisplayLabel("★ Fast", selected: true), "★ Fast")
        XCTAssertEqual(DashLayout.chipDisplayLabel("Fast", selected: true), "★ Fast")
        XCTAssertEqual(DashLayout.chipDisplayLabel("Fun", selected: false), "Fun")
    }

    func testPreviewCardPortraitGoAtRight() {
        let c = ctx(800, 944)
        let l = DashLayout.previewCard(c, preview: DashFixtures.preview(DashFixtures.port).nav.preview!, language: .en)
        XCTAssertEqual(l.frame.minX, 10)
        XCTAssertEqual(l.frame.maxX, 790)
        XCTAssertEqual(l.frame.maxY, 934)
        let go = try! XCTUnwrap(l.goRect)
        XCTAssertEqual(go.maxX, 790 - 16, accuracy: 1e-9)
        let cancel = l.actions.first { $0.id == "preview.cancel" }!
        XCTAssertEqual(go.minX - cancel.rect.maxX, 4, accuracy: 1e-9)
    }

    func testPreviewChipsScroll() {
        let c = ctx(544, 512)
        var p = DashFixtures.preview().nav.preview!
        p.chipLabels = ["Fast · 14:14 · 10.2 km", "Fun · 14:20 · 25.4 km", "Alt · 14:31 · 31.0 km", "No hwy · 14:40 · 33 km"]
        let l0 = DashLayout.previewCard(c, preview: p, language: .en, chipScroll: 0)
        let vp = try! XCTUnwrap(l0.chipsViewport)
        XCTAssertGreaterThan(l0.chipsContentWidth, vp.width)
        let l1 = DashLayout.previewCard(c, preview: p, language: .en, chipScroll: 100)
        XCTAssertEqual(l0.chipRects[0].minX - l1.chipRects[0].minX, 100, accuracy: 1e-9)
        let lMax = DashLayout.previewCard(c, preview: p, language: .en, chipScroll: 1e9)
        XCTAssertEqual(lMax.chipRects.last!.maxX + 16, vp.maxX, accuracy: 1e-6) // clamped to the content end
    }

    func testArriveCard() {
        // P0 (D22): Done first (the default focus, a real button), then Park here and Find parking
        let a = ArrivalCard(title: "Arrived · Câmpina", meta: "Mark parking, find a spot, or continue free ride")
        let l = DashLayout.arriveCard(ctx(800, 384), arrival: a, language: .en)
        XCTAssertEqual(l.frame.minX, 10)
        XCTAssertEqual(l.frame.maxY, 374)
        XCTAssertLessThanOrEqual(l.frame.maxX, 800 - 76)
        XCTAssertEqual(l.doneRect.minX, 26)
        XCTAssertEqual(l.doneRect.height, 44)
        XCTAssertGreaterThanOrEqual(l.doneRect.width, 120)
        XCTAssertGreaterThanOrEqual(l.parkRect.width, 120)
        XCTAssertGreaterThanOrEqual(l.findRect.width, 120)
        XCTAssertEqual(l.parkRect.minX - l.doneRect.maxX, 8)
        XCTAssertEqual(l.findRect.minX - l.parkRect.maxX, 8)
        XCTAssertEqual(l.titleFont.size, 17)
        XCTAssertEqual(l.doneFont, l.buttonFont)
        let p = DashLayout.arriveCard(ctx(800, 944), arrival: a, language: .en)
        XCTAssertEqual(p.titleFont.size, 18)
        XCTAssertEqual(p.doneRect.width, 800 - 20 - 32, accuracy: 1e-9) // full width, on top
        XCTAssertEqual(p.doneRect.height, 48)
        XCTAssertEqual(p.parkRect.minY - p.doneRect.maxY, 8)
        XCTAssertEqual(p.parkRect.width, p.findRect.width, accuracy: 1e-9) // equal weights
        XCTAssertEqual(p.parkRect.height, 44)
    }

    func testLapCard() {
        let lap = DashLapTimer(title: "LAP 2  0:31.20", meta: "LAST 0:30.00   BEST 0:30.00")
        let l = DashLayout.lapCard(ctx(800, 384), lap: lap)
        XCTAssertEqual(l.frame.minX, 12)
        XCTAssertEqual(l.frame.maxY, 296) // H − 88
        XCTAssertEqual(l.titleFont, DashFont(size: 22, weight: .bold))
        XCTAssertEqual(l.metaRect.minY - l.titleRect.maxY, 2)
        let above = DashLayout.lapCard(ctx(800, 384), lap: lap, aboveY: 230)
        XCTAssertEqual(above.frame.maxY, 222)
    }

    func testMenuPanelAndOrder() {
        let content = DashMenuContent(language: .en, follow: true, headingUp: true, recording: false, preferences: MapPreferences())
        let l = DashLayout.menu(ctx(800, 384), content: content)
        assertRect(l.panel, 520, 0, 280, 384)
        let ids = l.items.compactMap(\.id)
        // P0 (D01): harmless items first (the menu opens on Recenter / reroute), "End route…" last of the Ride section
        XCTAssertEqual(Array(ids.prefix(12)), ["menu.recalc", "menu.circuit", "menu.goHome", "menu.park", "menu.record", "menu.setHome",
                                               "menu.end", "menu.follow", "menu.heading", "menu.voice", "menu.zoomOut", "menu.zoomIn"])
        let noEnd = DashLayout.menu(ctx(800, 384), content: DashMenuContent(language: .en, follow: true, headingUp: true, recording: false,
                                                                            preferences: MapPreferences(), showsEnd: false))
        XCTAssertFalse(noEnd.items.compactMap(\.id).contains("menu.end"), "no End without a running route")
        XCTAssertEqual(ids.last, "menu.close")
        XCTAssertGreaterThan(l.contentHeight, 384)
        XCTAssertGreaterThan(l.maxScroll, 0)
        // first button at padding 12 + title; buttons 48 tall, 6 apart
        let buttons = l.items.filter { if case .button = $0.kind { return true }; return false }
        XCTAssertEqual(buttons[0].rect.height, 48)
        XCTAssertEqual(buttons[1].rect.minY - buttons[0].rect.maxY, 6)
        XCTAssertEqual(buttons[0].rect.minX, 532)
        XCTAssertEqual(buttons[0].rect.width, 256)
        // segments: selected state mirrors preferences
        let selected = l.items.compactMap { item -> String? in
            if case let .segment(id, _, sel) = item.kind, sel { return id }
            return nil
        }
        XCTAssertEqual(selected, ["menu.units.metric", "menu.theme.auto", "menu.voiceSeg.on", "menu.nextStop.on", "menu.autoFinish.on",
                                  "menu.chrome.dark", "menu.routeMode.fast", "menu.avoidTolls.off", "menu.avoidHighways.off"])
        let segs = l.items.filter { if case .segment = $0.kind { return true }; return false }
        XCTAssertEqual(segs[0].rect.height, 44)
        XCTAssertEqual(segs[1].rect.minX - segs[0].rect.maxX, 8)
    }

    func testMenuLabelsFollowState() {
        var prefs = MapPreferences()
        prefs.voiceOn = false
        let l = DashLayout.menu(ctx(800, 384), content: DashMenuContent(language: .en, follow: false, headingUp: false, recording: true, preferences: prefs))
        let labels = l.items.compactMap { item -> String? in
            if case let .button(_, label, _, _) = item.kind { return label }
            return nil
        }
        // P0 (D23): verb labels — what the button does, not the state
        XCTAssertTrue(labels.contains("Stop recording"))
        XCTAssertTrue(labels.contains("Follow me"))
        XCTAssertTrue(labels.contains("Put heading up"))
        XCTAssertTrue(labels.contains("Turn voice on"))
        let on = DashLayout.menu(ctx(800, 384), content: DashMenuContent(language: .es, follow: true, headingUp: true, recording: false,
                                                                         preferences: MapPreferences()))
        let es = on.items.compactMap { item -> String? in
            if case let .button(_, label, _, _) = item.kind { return label }
            return nil
        }
        for label in ["Recentrar / recalcular", "Estacionar aquí", "Guardar casa aquí", "Terminar la ruta…", "Mover el mapa",
                      "Poner norte arriba", "Silenciar voz", "Grabar viaje"] {
            XCTAssertTrue(es.contains(label), label)
        }
    }

    func testSearchSheetIdleAndResults() {
        let c = ctx(800, 384)
        let idle = DashLayout.searchSheet(c, search: DashSearchState(), places: DashFixtures.base().places, language: .en)
        XCTAssertEqual(idle.statusText, "⌨ Type on the phone — results show here")
        XCTAssertTrue(idle.statusAccent)
        XCTAssertEqual(idle.rows.first?.id, "search.typeOnPhone")
        // idle list: home, favorites, history (mode / (0,0) entries removed)
        let names = idle.rows.compactMap { row -> String? in
            if case let .place(p, nil) = row.kind { return p.name }
            return nil
        }
        XCTAssertEqual(names, ["Home", "Cafe Central", "Câmpina"])
        XCTAssertEqual(idle.chipLabels, DashSearchState.defaultPoiChips)
        XCTAssertEqual(idle.backRect.width, 44)
        XCTAssertEqual(idle.inputRect.height, 48)
        let results = DashLayout.searchSheet(c, search: DashFixtures.withSearchResults(DashFixtures.base()).search,
                                             places: DashFixtures.base().places, language: .en)
        XCTAssertEqual(results.statusText, "3 fuel nearby")
        XCTAssertFalse(results.statusAccent)
        XCTAssertEqual(results.rows.count, 4)
        if case let .place(_, idx) = results.rows[2].kind { XCTAssertEqual(idx, 1) } else { XCTFail() }
        let noStatus = DashLayout.searchSheet(c, search: DashSearchState(results: []), places: .empty, language: .es)
        XCTAssertEqual(noStatus.statusText, "Sin resultados")
        let counted = DashLayout.searchSheet(c, search: DashSearchState(results: [DashFixtures.campina]), places: .empty, language: .en)
        XCTAssertEqual(counted.statusText, "1 places")
    }

    func testIdleListRules() {
        let a = Place(name: "A", lat: 1, lon: 1)
        let places = DashPlaces(home: a, parked: Place(name: "Parked", lat: 2, lon: 2, category: "parking"),
                                favorites: [a, Place(name: "B", lat: 3, lon: 3)],
                                markers: [Place(name: "B", lat: 3.00001, lon: 3)],
                                history: [Place(name: "P", lat: 4, lon: 4, category: "parking"), Place(name: "Free ride", lat: 0, lon: 0, category: "mode"),
                                          Place(name: "Zero", lat: 0, lon: 0), Place(name: "C", lat: 5, lon: 5)])
        XCTAssertEqual(places.idleList().map(\.name), ["A", "Parked", "B", "C"])
        let many = DashPlaces(history: (0 ..< 20).map { Place(name: "H\($0)", lat: Double($0) + 1, lon: 1) })
        XCTAssertEqual(many.idleList().count, 12)
        XCTAssertTrue(places.canDelete(Place(name: "x", lat: 5, lon: 5)))
        XCTAssertTrue(places.canDelete(Place(name: "x", lat: 9, lon: 9, category: "pin")))
        XCTAssertFalse(places.canDelete(Place(name: "x", lat: 9, lon: 9)))
    }

    func testOverlayPillAndClock() {
        let c = ctx(800, 384)
        let (r, lines) = DashLayout.overlayPill(c, text: "Parking marked", font: DashFont(size: 15, weight: .medium), topY: 108)
        XCTAssertEqual(lines, 1)
        XCTAssertEqual(r.minY, 108)
        XCTAssertEqual(r.midX, (8 + 712) / 2, accuracy: 1e-9) // centred left of the FAB lane
        let fabs = DashLayout.fabColumn(c)
        let clock = DashLayout.clockChip(c, text: "14:05", font: DashFont(size: 15, weight: .bold, monospacedDigits: true), fabs: fabs)
        XCTAssertLessThanOrEqual(clock.maxX, fabs[0].maxX + 1e-9) // never past the FAB column / canvas edge
        XCTAssertEqual(clock.maxY, 376)
        let narrow = DashLayout.clockChip(c, text: "9", font: DashFont(size: 15, weight: .bold, monospacedDigits: true), fabs: fabs)
        XCTAssertEqual(narrow.midX, fabs[0].midX, accuracy: 1e-9) // centred when it fits
        XCTAssertGreaterThan(clock.minX, 712) // inside the FAB lane, right of the speed chip
    }
}

/// Layout invariants on every canvas the spec mentions, for every UI state.
final class DashLayoutInvariantTests: XCTestCase {
    static let canvases: [DashSize] = [
        DashSize(width: 800, height: 384), DashSize(width: 800, height: 944), DashSize(width: 1280, height: 576),
        DashSize(width: 1024, height: 464), DashSize(width: 720, height: 704), DashSize(width: 544, height: 512),
    ]

    private func states(_ c: DashSize) -> [(String, DashModel)] {
        var longMetrics = DashFixtures.navigating(c)
        longMetrics.nav.metrics = HudMetrics(time: "1h05m", arrive: "14:20", left: "123.4 km", alt: "1234", altUnit: "m", status: "")
        var lap = DashFixtures.navigating(c)
        lap.lapTimer = DashLapTimer(title: "LAP 2  0:31.20", meta: "LAST 0:30.00   BEST 0:30.00")
        var margins = DashFixtures.preview(c)
        margins.margins = ScreenMargins(top: 22, bottom: 10, left: 12, right: 14)
        var musicMargins = DashFixtures.withMusic(DashFixtures.freeRide(c))
        musicMargins.margins = margins.margins
        let base: [(String, DashModel)] = [
            ("free", DashFixtures.freeRide(c)), ("preview", DashFixtures.preview(c)), ("nav", DashFixtures.navigating(c)),
            ("navLong", longMetrics), ("offRoute", DashFixtures.navigating(c, offRoute: true)), ("arrive", DashFixtures.arrival(c)),
            ("lap", lap), ("margins", margins),
        ]
        // Apple Music (iOS addition): the now-playing tile in every map state.
        let music: [(String, DashModel)] = [
            ("musicFree", DashFixtures.withMusic(DashFixtures.freeRide(c))),
            ("musicNav", DashFixtures.withMusic(DashFixtures.navigating(c))),
            ("musicNavLong", DashFixtures.withMusic(longMetrics)),
            ("musicOffRoute", DashFixtures.withMusic(DashFixtures.navigating(c, offRoute: true))),
            ("musicPreview", DashFixtures.withMusic(DashFixtures.preview(c))),
            ("musicArrive", DashFixtures.withMusic(DashFixtures.arrival(c))),
            ("musicLap", DashFixtures.withMusic(lap)),
            ("musicMargins", musicMargins),
            ("musicPaused", DashFixtures.withMusic(DashFixtures.navigating(c), DashFixtures.song(.paused))),
        ]
        return base + music
    }

    func testChromeNeverOverlapsAndStaysOnCanvas() {
        for c in Self.canvases {
            for (name, model) in states(c) {
                let ui = DashUIController()
                ui.update(model)
                let list = ui.displayList(now: 0)
                let regions = Dictionary(list.hitRegions.map { ($0.id, $0.rect) }, uniquingKeysWith: { _, b in b })
                let canvas = DashRect(x: 0, y: 0, width: c.width, height: c.height)
                let safe = model.safeRect
                let tag = "\(Int(c.width))×\(Int(c.height)) \(name)"
                for (id, r) in regions where !id.hasPrefix("search") && id != "dimmer" {
                    XCTAssertTrue(r.minX >= canvas.minX - 0.01 && r.maxX <= canvas.maxX + 0.01 && r.minY >= canvas.minY - 0.01
                                  && r.maxY <= canvas.maxY + 0.01, "\(tag): \(id) \(r) off canvas")
                    if id != "nav.card" { // the portrait banner paints under the top margin by design
                        XCTAssertTrue(r.minX >= safe.minX - 0.01 && r.maxX <= safe.maxX + 0.01 && r.minY >= safe.minY - 0.01
                                      && r.maxY <= safe.maxY + 0.01, "\(tag): \(id) \(r) outside the safe area \(safe)")
                    }
                }
                let fabs = regions.filter { $0.key.hasPrefix("fab.") }.map(\.value)
                XCTAssertEqual(fabs.count, 5, tag)
                func noOverlap(_ a: String, _ b: String) {
                    guard let ra = regions[a], let rb = regions[b] else { return }
                    XCTAssertFalse(ra.intersects(rb), "\(tag): \(a) \(ra) overlaps \(b) \(rb)")
                }
                for card in ["pill", "nav.card", "metrics.card", "preview.card", "arrive.card", "speed.chip", "lap.card", "clock"] {
                    for f in ["fab.recenter", "fab.zoomIn", "fab.zoomOut", "fab.compass", "fab.menu"] { noOverlap(card, f) }
                }
                noOverlap("metrics.card", "speed.chip")
                noOverlap("preview.card", "speed.chip")
                noOverlap("arrive.card", "speed.chip")
                noOverlap("nav.card", "speed.chip")
                noOverlap("lap.card", "metrics.card")
                noOverlap("lap.card", "preview.card")
                noOverlap("clock", "speed.chip")
                noOverlap("clock", "metrics.card")
                // Apple Music: the tile clears every card, FAB, pill label and the clock.
                for other in ["pill", "pill.circuit", "pill.lap", "nav.card", "metrics.card", "preview.card",
                              "arrive.card", "speed.chip", "lap.card", "clock", "fab.recenter", "fab.zoomIn", "fab.zoomOut",
                              "fab.compass", "fab.menu"] {
                    noOverlap("music.tile", other)
                }
                if model.music == nil {
                    XCTAssertNil(regions["music.tile"], tag)
                } else {
                    XCTAssertNotNil(regions["music.tile"], "\(tag): no tile")
                }
                // The map credit (§10.4, every fixture uses the default OSM tiles): drawn once, inside the safe
                // area, at least 6 dp clear of every control and card, the music tile, the speed chip and the
                // clock (the tile's outset focus ring is 5 dp).
                let credits = DashMapAttributionTests.credits(list)
                XCTAssertEqual(credits.count, 1, "\(tag): \(credits.count) credit(s)")
                if let credit = credits.first {
                    XCTAssertTrue(credit.minX >= safe.minX - 0.01 && credit.maxX <= safe.maxX + 0.01 && credit.minY >= safe.minY - 0.01
                                  && credit.maxY <= safe.maxY + 0.01, "\(tag): credit \(credit) outside the safe area \(safe)")
                    let gap = 6 * model.scale - 0.01
                    for (id, r) in regions {
                        XCTAssertFalse(credit.insetBy(dx: -gap, dy: -gap).intersects(r), "\(tag): credit \(credit) within 6 dp of \(id) \(r)")
                    }
                }
            }
        }
    }

    func testSheetsCoverTheirAreaOnEveryCanvas() {
        for c in Self.canvases {
            let ui = DashUIController()
            ui.update(DashFixtures.navigating(c))
            _ = ui.perform(.openMenu, now: 0)
            var list = ui.displayList(now: 0)
            let panel = list.hitRegions.first { $0.id == "menu.panel" }!.rect
            XCTAssertEqual(panel.width, 280 * DashDensity.scale(canvasWidth: c.width), accuracy: 1e-9)
            XCTAssertEqual(panel.maxX, c.width, accuracy: 1e-9)
            XCTAssertEqual(list.hitTest(DashPoint(10, 10))?.id, "dimmer")
            _ = ui.perform(.openSearch, now: 1)
            list = ui.displayList(now: 1)
            XCTAssertEqual(list.hitTest(DashPoint(c.width - 2, c.height - 2))?.id.hasPrefix("search"), true)
            XCTAssertFalse(list.hitRegions.contains { $0.id.hasPrefix("fab.") })
            // Apple Music sheet (iOS addition): opaque, the nav card stays on top while navigating
            for navigating in [true, false] {
                let tag = "\(Int(c.width))×\(Int(c.height)) music \(navigating ? "nav" : "free")"
                let mui = DashUIController()
                mui.update(DashFixtures.withMusic(navigating ? DashFixtures.navigating(c) : DashFixtures.freeRide(c)))
                XCTAssertEqual(mui.perform(.openMusic, now: 2), [.openMusic], tag)
                list = mui.displayList(now: 2)
                XCTAssertEqual(list.hitTest(DashPoint(c.width - 2, c.height - 2))?.id, "music.sheet", tag)
                XCTAssertEqual(list.hitTest(DashPoint(1, 1))?.id, navigating && c.height > c.width ? "nav.card" : "music.sheet", tag)
                XCTAssertFalse(list.hitRegions.contains { $0.id.hasPrefix("fab.") || $0.id == "music.tile" || $0.id == "clock" }, tag)
                let nav = list.hitRegions.first { $0.id == "nav.card" }
                // P0 (D03): the speed chip is the top-most layer, over the sheet; then the nav card while navigating
                XCTAssertEqual(list.hitRegions.last?.id, "speed.chip", tag)
                if navigating {
                    let card = try! XCTUnwrap(nav, tag).rect
                    XCTAssertEqual(list.hitTest(card.center)?.id, "nav.card", tag)
                    XCTAssertEqual(list.hitRegions.dropLast().last?.id, "nav.card", "\(tag): the nav card over the sheet")
                } else {
                    XCTAssertNil(nav, tag)
                }
                for id in ["music.previous", "music.playPause", "music.next", "music.close"] {
                    let r = try! XCTUnwrap(list.hitRegions.first { $0.id == id }, "\(tag) \(id)").rect
                    XCTAssertEqual(list.hitTest(r.center)?.id, id, "\(tag) \(id) reachable")
                    XCTAssertTrue(r.minX >= -0.01 && r.maxX <= c.width + 0.01 && r.minY >= -0.01 && r.maxY <= c.height + 0.01, tag)
                    XCTAssertTrue(list.hitRegions.first { $0.id == id }!.focusable, tag)
                }
            }
        }
    }
}
