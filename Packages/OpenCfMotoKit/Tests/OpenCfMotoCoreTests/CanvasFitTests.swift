// SPDX-License-Identifier: AGPL-3.0-or-later
// computeViewport / mapCanvasToSource vectors (media-video.md §10.3) and margins helpers (§10.4).

import XCTest
@testable import OpenCfMotoCore

final class CanvasFitTests: XCTestCase {

    private func vp(_ cw: Int, _ ch: Int, _ sw: Int, _ sh: Int, _ mode: ScreenFit, top: Int = 0) -> CanvasViewport? {
        CanvasFit.viewport(canvasWidth: cw, canvasHeight: ch, sourceWidth: sw, sourceHeight: sh, mode: mode,
                           margins: ScreenMargins(customised: true, top: top))
    }

    private func v(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> CanvasViewport { CanvasViewport(x: x, y: y, width: w, height: h) }

    func testWorkedExamples() {
        let cases: [(Int, Int, Int, Int, Int, CanvasViewport, CanvasViewport, CanvasViewport)] = [
            // canvas, source, top margin, FIT, FILL, STRETCH
            (800, 384, 800, 480, 0, v(80, 0, 640, 384), v(0, -48, 800, 480), v(0, 0, 800, 384)),
            (800, 944, 720, 1280, 0, v(134, 0, 531, 944), v(0, -239, 800, 1422), v(0, 0, 800, 944)),
            (1280, 576, 800, 480, 0, v(160, 0, 960, 576), v(0, -96, 1280, 768), v(0, 0, 1280, 576)),
            (720, 704, 720, 712, 22, v(15, 22, 690, 682), v(0, 7, 720, 712), v(0, 22, 720, 682)),
            (800, 384, 1080, 2400, 0, v(313, 0, 173, 384), v(0, -697, 800, 1778), v(0, 0, 800, 384)),
            (800, 384, 2400, 1080, 0, v(0, 12, 800, 360), v(-26, 0, 853, 384), v(0, 0, 800, 384)),
            (800, 944, 1080, 2400, 0, v(187, 0, 425, 944), v(0, -417, 800, 1778), v(0, 0, 800, 944)),
        ]
        for c in cases {
            XCTAssertEqual(vp(c.0, c.1, c.2, c.3, .fit, top: c.4), c.5, "FIT \(c)")
            XCTAssertEqual(vp(c.0, c.1, c.2, c.3, .fill, top: c.4), c.6, "FILL \(c)")
            XCTAssertEqual(vp(c.0, c.1, c.2, c.3, .stretch, top: c.4), c.7, "STRETCH \(c)")
        }
    }

    func testInverseMap() {
        let fit = CanvasViewport(x: 160, y: 0, width: 960, height: 576)
        func map(_ x: Int, _ y: Int) -> [Int]? {
            CanvasFit.mapCanvasToSource(x: x, y: y, viewport: fit, sourceWidth: 800, sourceHeight: 480).map { [$0.x, $0.y] }
        }
        XCTAssertNil(map(0, 0))                 // black bar
        XCTAssertEqual(map(160, 0), [0, 0])
        XCTAssertEqual(map(640, 288), [400, 240])
        XCTAssertEqual(map(1119, 575), [799, 479])
        XCTAssertNil(map(1200, 10))
        XCTAssertNil(map(1120, 0))              // right edge is exclusive
        XCTAssertNil(CanvasFit.mapCanvasToSource(x: 1, y: 1, viewport: v(0, 0, 0, 10), sourceWidth: 10, sourceHeight: 10))
        // FILL viewports extend beyond the canvas: canvas (0,0) maps inside the source
        let fill = CanvasViewport(x: 0, y: -48, width: 800, height: 480)
        XCTAssertEqual(CanvasFit.mapCanvasToSource(x: 0, y: 0, viewport: fill, sourceWidth: 800, sourceHeight: 480).map { [$0.x, $0.y] }, [0, 48])
    }

    func testMarginClamping() {
        // margins larger than the canvas are clamped; the area never collapses below 1×1
        let c = CanvasFit.clampedInsets(canvasWidth: 100, canvasHeight: 50, margins: ScreenMargins(customised: true, top: 40, bottom: 40, left: 90, right: 90))
        XCTAssertEqual([c.top, c.bottom, c.left, c.right], [40, 10, 90, 10])
        XCTAssertEqual(CanvasFit.contentRect(canvasWidth: 100, canvasHeight: 50, margins: ScreenMargins(customised: true, top: 40, bottom: 40, left: 90, right: 90)),
                       v(90, 40, 1, 1))
        XCTAssertEqual(CanvasFit.contentRect(canvasWidth: 800, canvasHeight: 384, margins: .zero), v(0, 0, 800, 384))
        XCTAssertTrue(CanvasFit.isInsideContent(x: 0, y: 22, canvasWidth: 720, canvasHeight: 704, margins: ScreenMargins(top: 22)))
        XCTAssertFalse(CanvasFit.isInsideContent(x: 0, y: 21, canvasWidth: 720, canvasHeight: 704, margins: ScreenMargins(top: 22)))
        XCTAssertNil(CanvasFit.viewport(canvasWidth: 0, canvasHeight: 10, sourceWidth: 1, sourceHeight: 1, mode: .fit))
        XCTAssertEqual(CanvasFit.viewport(canvas: .rounded(requestedWidth: 800, requestedHeight: 386), sourceWidth: 800, sourceHeight: 480, mode: .fit),
                       v(80, 0, 640, 384))
    }

    func testEffectiveMarginsAndSummary() {
        let nkDefault = CanvasFit.profileDefaultMargins(.nkAdvanced)
        XCTAssertEqual([nkDefault.top, nkDefault.bottom, nkDefault.left, nkDefault.right], [22, 0, 0, 0])
        XCTAssertEqual(CanvasFit.profileDefaultMargins(.legacy), ScreenMargins())
        XCTAssertEqual(CanvasFit.profileDefaultMargins(nil), ScreenMargins())
        let notCustom = ScreenMargins(customised: false, top: 5, bottom: 5, left: 5, right: 5)
        let eff = CanvasFit.effectiveMargins(notCustom, profileDefault: nkDefault)
        XCTAssertEqual([eff.top, eff.bottom, eff.left, eff.right], [22, 0, 0, 0])
        XCTAssertEqual(CanvasFit.marginsSummary(notCustom, profileDefault: nkDefault),
                       "Top 22 \u{00B7} bottom 0 \u{00B7} left 0 \u{00B7} right 0 px (profile default)")
        XCTAssertEqual(CanvasFit.marginsSummary(ScreenMargins(customised: true, top: 12, left: 4, right: 4), profileDefault: nkDefault),
                       "Top 12 \u{00B7} bottom 0 \u{00B7} left 4 \u{00B7} right 4 px")
        XCTAssertEqual(CanvasFit.marginsSummary(ScreenMargins(), profileDefault: ScreenMargins()),
                       "None \u{2014} Android Auto uses the whole dash")
        XCTAssertEqual(CanvasFit.marginsSummary(ScreenMargins(customised: true), profileDefault: nkDefault),
                       "None \u{2014} Android Auto uses the whole dash")
    }

    func testDescriptionAndRect() {
        XCTAssertEqual(v(-26, 0, 853, 384).description, "-26, 0, 853, 384")
        XCTAssertEqual(v(1, 2, 3, 4).dashRect, DashRect(x: 1, y: 2, width: 3, height: 4))
    }
}
