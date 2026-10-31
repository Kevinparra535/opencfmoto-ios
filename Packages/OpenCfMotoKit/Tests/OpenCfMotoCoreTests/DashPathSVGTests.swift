// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import OpenCfMotoCore

final class DashPathSVGTests: XCTestCase {
    private func p(_ x: Double, _ y: Double) -> DashPoint { DashPoint(x, y) }

    private func cubicPoint(_ p0: DashPoint, _ c1: DashPoint, _ c2: DashPoint, _ p1: DashPoint, _ t: Double) -> DashPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return DashPoint(a * p0.x + b * c1.x + c * c2.x + d * p1.x, a * p0.y + b * c1.y + c * c2.y + d * p1.y)
    }

    private func assertPoint(_ a: DashPoint, _ b: DashPoint, accuracy: Double = 1e-9, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, "x", file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, "y", file: file, line: line)
    }

    func testAbsoluteMoveLineClose() throws {
        let path = try DashPath(svg: "M12,3 L19,12 L14,12 Z")
        XCTAssertEqual(path.elements, [.move(p(12, 3)), .line(p(19, 12)), .line(p(14, 12)), .close])
    }

    func testBaseArrowParsesToSevenVerticesAndClose() throws {
        let path = try DashPath(svg: DashIcons.baseArrowPathData)
        XCTAssertEqual(path.elements, [.move(p(12, 3)), .line(p(19, 12)), .line(p(14, 12)), .line(p(14, 21)),
                                       .line(p(10, 21)), .line(p(10, 12)), .line(p(5, 12)), .close])
    }

    func testRelativeCommandsAndHV() throws {
        let path = try DashPath(svg: "m10,10 l5,0 h5 v5 H0 V0 z")
        XCTAssertEqual(path.elements, [.move(p(10, 10)), .line(p(15, 10)), .line(p(20, 10)), .line(p(20, 15)),
                                       .line(p(0, 15)), .line(p(0, 0)), .close])
    }

    func testImplicitLineToAfterMoveTo() throws {
        XCTAssertEqual(try DashPath(svg: "M0,0 10,0 10,10").elements, [.move(p(0, 0)), .line(p(10, 0)), .line(p(10, 10))])
        // relative: pairs after m are relative line-tos
        XCTAssertEqual(try DashPath(svg: "m1,1 2,0 0,2").elements, [.move(p(1, 1)), .line(p(3, 1)), .line(p(3, 3))])
    }

    func testImplicitRepeatOfOtherCommands() throws {
        // "h-6v6h-2" style and repeated L pairs
        XCTAssertEqual(try DashPath(svg: "M0 0 L1 1 2 2 3 3").elements,
                       [.move(p(0, 0)), .line(p(1, 1)), .line(p(2, 2)), .line(p(3, 3))])
        XCTAssertEqual(try DashPath(svg: "M0 0 h1 2 3").elements,
                       [.move(p(0, 0)), .line(p(1, 0)), .line(p(3, 0)), .line(p(6, 0))])
    }

    func testPackedNumbers() throws {
        // "0.5.5" = 0.5, .5 ; "1-2" = 1, -2 ; exponents
        XCTAssertEqual(try DashPath(svg: "M0.5.5L1-2").elements, [.move(p(0.5, 0.5)), .line(p(1, -2))])
        XCTAssertEqual(try DashPath(svg: "M1e1,2E-1 L-.5,+3").elements, [.move(p(10, 0.2)), .line(p(-0.5, 3))])
        // compass needle sub-path from ic_fab_compass
        let needle = try DashPath(svg: "M14.14,14.14L9,15l0.86,-5.14L15,9l-0.86,5.14z")
        XCTAssertEqual(needle.elements.count, 6)
        assertPoint({ if case let .line(q) = needle.elements[2] { return q }; return .zero }(), p(9.86, 9.86), accuracy: 1e-12)
        assertPoint({ if case let .line(q) = needle.elements[4] { return q }; return .zero }(), p(14.14, 14.14), accuracy: 1e-12)
    }

    func testCubicAndSmoothCubicReflection() throws {
        let path = try DashPath(svg: "M0,0 C0,10 10,10 10,0 S20,-10 20,0")
        XCTAssertEqual(path.elements.count, 3)
        XCTAssertEqual(path.elements[1], .cubic(p(0, 10), p(10, 10), p(10, 0)))
        // S: first control = reflection of (10,10) about (10,0) = (10,-10)
        XCTAssertEqual(path.elements[2], .cubic(p(10, -10), p(20, -10), p(20, 0)))
    }

    func testSmoothCubicWithoutPreviousCubicUsesCurrentPoint() throws {
        let path = try DashPath(svg: "M5,5 S10,0 15,5")
        XCTAssertEqual(path.elements[1], .cubic(p(5, 5), p(10, 0), p(15, 5)))
    }

    func testRelativeSmoothCubicImplicitRepeat() throws {
        // From ic_fab_gps: "s1.79,4 4,4 4,-1.79 4,-4" → two smooth segments
        let path = try DashPath(svg: "M12,8c-2.21,0 -4,1.79 -4,4s1.79,4 4,4 4,-1.79 4,-4")
        XCTAssertEqual(path.elements.count, 4)
        assertCubic(path.elements[1], p(9.79, 8), p(8, 9.79), p(8, 12))
        assertCubic(path.elements[2], p(8, 14.21), p(9.79, 16), p(12, 16))
        assertCubic(path.elements[3], p(14.21, 16), p(16, 14.21), p(16, 12))
    }

    private func assertCubic(_ e: DashPathElement, _ c1: DashPoint, _ c2: DashPoint, _ end: DashPoint,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard case let .cubic(a, b, c) = e else { return XCTFail("expected cubic, got \(e)", file: file, line: line) }
        assertPoint(a, c1, accuracy: 1e-9, file: file, line: line)
        assertPoint(b, c2, accuracy: 1e-9, file: file, line: line)
        assertPoint(c, end, accuracy: 1e-9, file: file, line: line)
    }

    func testQuadAndSmoothQuad() throws {
        let path = try DashPath(svg: "M0,0 Q5,10 10,0 T20,0")
        XCTAssertEqual(path.elements[1], .quad(p(5, 10), p(10, 0)))
        XCTAssertEqual(path.elements[2], .quad(p(15, -10), p(20, 0)))
        let rel = try DashPath(svg: "M7,14 q0,-3 3,-4 t3,-1")
        XCTAssertEqual(rel.elements[1], .quad(p(7, 11), p(10, 10)))
        XCTAssertEqual(rel.elements[2], .quad(p(13, 9), p(13, 9)))
    }

    func testMergeIconQuadratic() throws {
        let path = try DashPath(svg: "M7,21 L7,14 Q7,11 10,10 L13,8.5 M13,8.5 L13,21")
        XCTAssertEqual(path.elements, [.move(p(7, 21)), .line(p(7, 14)), .quad(p(7, 11), p(10, 10)), .line(p(13, 8.5)),
                                       .move(p(13, 8.5)), .line(p(13, 21))])
    }

    func testArcSweepOneGoesOverTheTop() throws {
        // U-turn arc: from (8,11) to (16,11), r 4, sweep 1 → clockwise on screen over the top (12,7).
        let path = try DashPath(svg: "M8,11 A4,4 0 0 1 16,11")
        let cubics = path.elements.compactMap { e -> (DashPoint, DashPoint, DashPoint)? in
            if case let .cubic(a, b, c) = e { return (a, b, c) }
            return nil
        }
        XCTAssertEqual(cubics.count, 2) // 180° → two ≤90° segments
        assertPoint(cubics[0].2, p(12, 7), accuracy: 1e-9)
        assertPoint(cubics[1].2, p(16, 11), accuracy: 0)
        // Every sampled point lies on the circle (12,11) r 4 within the Bézier approximation error.
        var start = p(8, 11)
        for c in cubics {
            for k in 0 ... 10 {
                let q = cubicPoint(start, c.0, c.1, c.2, Double(k) / 10)
                let r = ((q.x - 12) * (q.x - 12) + (q.y - 11) * (q.y - 11)).squareRoot()
                XCTAssertEqual(r, 4, accuracy: 4 * 3e-4)
                XCTAssertLessThanOrEqual(q.y, 11 + 1e-9) // upper half only
            }
            start = c.2
        }
    }

    func testArcSweepZeroGoesUnderneath() throws {
        let path = try DashPath(svg: "M0,0 A1,1 0 0 0 2,0")
        guard case let .cubic(_, _, mid) = path.elements[1] else { return XCTFail("expected cubic") }
        assertPoint(mid, p(1, 1), accuracy: 1e-9)
    }

    func testArcLargeFlagSelectsLongWay() throws {
        // 90° chord on a circle r 1: small arc = 1 segment, large arc = 3 segments (270°).
        let small = try DashPath(svg: "M1,0 A1,1 0 0 1 0,1")
        let large = try DashPath(svg: "M1,0 A1,1 0 1 1 0,1")
        XCTAssertEqual(small.elements.count, 2)
        XCTAssertEqual(large.elements.count, 4)
    }

    func testFullCircleFromTwoRelativeArcs() throws {
        // Puck shadow disc: centre (24,24) r 15.
        let path = try DashPath(svg: "M24,24m-15,0a15,15 0,1 1,30 0a15,15 0,1 1,-30 0")
        let b = try XCTUnwrap(path.controlPointBounds)
        XCTAssertEqual(b.minX, 9, accuracy: 1e-9)
        XCTAssertEqual(b.maxX, 39, accuracy: 1e-9)
        // control points of a circle approximation slightly exceed the circle vertically (k = 0.5523)
        XCTAssertEqual(b.minY, 9, accuracy: 1e-6)
        XCTAssertEqual(b.maxY, 39, accuracy: 1e-6)
        XCTAssertEqual(path.elements.filter { if case .cubic = $0 { return true }; return false }.count, 4)
    }

    func testPackedArcFlags() throws {
        let path = try DashPath(svg: "M0,0a1,1 0 012,0")
        guard case let .cubic(_, _, end) = path.elements.last else { return XCTFail("expected cubic") }
        assertPoint(end, p(2, 0), accuracy: 0)
    }

    func testOutOfRangeRadiiAreScaledUp() throws {
        // r 0.5 between points 2 apart → scaled to r 1 (semicircle)
        let path = try DashPath(svg: "M0,0 A0.5,0.5 0 0 1 2,0")
        guard case let .cubic(_, _, mid) = path.elements[1] else { return XCTFail("expected cubic") }
        assertPoint(mid, p(1, -1), accuracy: 1e-9)
    }

    func testZeroRadiusArcIsStraight() throws {
        let path = try DashPath(svg: "M0,0 A0,5 0 0 1 3,0")
        XCTAssertEqual(path.elements[1], .cubic(p(1, 0), p(2, 0), p(3, 0)))
        XCTAssertEqual(try DashPath(svg: "M1,1 A3,3 0 0 1 1,1").elements, [.move(p(1, 1))]) // coincident endpoints
    }

    func testRotatedEllipseArcEndpoint() throws {
        let path = try DashPath(svg: "M10,10 A20,10 30 0 1 30,25")
        guard case let .cubic(_, _, end) = path.elements.last else { return XCTFail("expected cubic") }
        assertPoint(end, p(30, 25), accuracy: 0)
    }

    func testDrawingAfterCloseStartsNewSubpathAtStart() throws {
        let path = try DashPath(svg: "M5,5 L10,5 Z L5,10")
        XCTAssertEqual(path.elements, [.move(p(5, 5)), .line(p(10, 5)), .close, .move(p(5, 5)), .line(p(5, 10))])
        // relative after close is relative to the subpath start
        let rel = try DashPath(svg: "M5,5 L10,5 z l1,1")
        XCTAssertEqual(rel.elements.last, .line(p(6, 6)))
    }

    func testMultipleSubpathsInOnePathData() throws {
        let menu = try DashPath(svg: DashIcons.pathData[.fabMenu]![0])
        XCTAssertEqual(menu.elements.filter { if case .move = $0 { return true }; return false }.count, 3)
        XCTAssertEqual(menu.elements.filter { $0 == .close }.count, 3)
        let b = try XCTUnwrap(menu.controlPointBounds)
        XCTAssertEqual(b.minY, 4, accuracy: 1e-9)
        XCTAssertEqual(b.maxY, 20, accuracy: 1e-9)
    }

    func testErrors() {
        XCTAssertThrowsError(try DashPath(svg: "L1,2")) { XCTAssertEqual($0 as? DashSVGPathError, .missingMoveTo(offset: 0)) }
        XCTAssertThrowsError(try DashPath(svg: "1,2")) { XCTAssertEqual($0 as? DashSVGPathError, .missingMoveTo(offset: 0)) }
        XCTAssertThrowsError(try DashPath(svg: "M1")) { XCTAssertEqual($0 as? DashSVGPathError, .expectedNumber(offset: 2)) }
        XCTAssertThrowsError(try DashPath(svg: "M1,2 X3")) { error in
            XCTAssertEqual(error as? DashSVGPathError, .unexpectedCharacter("X", offset: 5))
        }
        XCTAssertThrowsError(try DashPath(svg: "M0 0 A1 1 0 2 0 1 1")) { XCTAssertEqual($0 as? DashSVGPathError, .expectedFlag(offset: 12)) }
        XCTAssertThrowsError(try DashPath(svg: "M0 0 Z 1 2")) // numbers after Z
        XCTAssertThrowsError(try DashPath(svg: "M0 0 L . 2")) { XCTAssertEqual($0 as? DashSVGPathError, .expectedNumber(offset: 7)) }
        XCTAssertEqual(try DashPath(svg: "").elements, [])
        XCTAssertEqual(try DashPath(svg: "  \n ").elements, [])
    }

    func testSvgPathDataRoundTrip() throws {
        for icon in DashIcon.allCases {
            for layer in DashIcons.drawing(icon).layers {
                let data = layer.path.svgPathData
                let reparsed = try DashPath(svg: data)
                XCTAssertEqual(reparsed.elements.count, layer.path.elements.count, "\(icon)")
                for (a, b) in zip(reparsed.elements, layer.path.elements) {
                    switch (a, b) {
                    case let (.move(x), .move(y)), let (.line(x), .line(y)): assertPoint(x, y, accuracy: 0.0006)
                    case let (.quad(x1, x2), .quad(y1, y2)): assertPoint(x1, y1, accuracy: 0.0006); assertPoint(x2, y2, accuracy: 0.0006)
                    case let (.cubic(x1, x2, x3), .cubic(y1, y2, y3)):
                        assertPoint(x1, y1, accuracy: 0.0006); assertPoint(x2, y2, accuracy: 0.0006); assertPoint(x3, y3, accuracy: 0.0006)
                    case (.close, .close): break
                    default: XCTFail("element kind mismatch in \(icon)")
                    }
                }
            }
        }
    }

    func testNumberFormatting() {
        XCTAssertEqual(DashSVGNumber.format(1), "1")
        XCTAssertEqual(DashSVGNumber.format(1.5), "1.5")
        XCTAssertEqual(DashSVGNumber.format(-0.0001), "0")
        XCTAssertEqual(DashSVGNumber.format(2.66667), "2.667")
        XCTAssertEqual(DashSVGNumber.format(-12.1), "-12.1")
        XCTAssertEqual(DashSVGNumber.format(.nan), "0")
    }
}
