// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoApple

/// The renderer's line breaking (DashDrawCommand.text contract) with a deterministic width model:
/// every character (including "…") is 10 px wide, so a 100 px box holds 10 characters.
final class VideoTextLayoutTests: XCTestCase {
    private let mono: (String) -> Double = { Double($0.count) * 10 }

    private func wrap(_ s: String, _ width: Double = 100, lines: Int) -> [String] {
        DashTextWrapper.wrap(s, maxWidth: width, maxLines: lines, width: mono)
    }

    func testFittingTextIsUnchanged() {
        XCTAssertEqual(wrap("Calle 80", lines: 1), ["Calle 80"])
        XCTAssertEqual(wrap("Calle 80", lines: 2), ["Calle 80"])
        XCTAssertEqual(wrap("0123456789", lines: 1), ["0123456789"]) // exactly 100 px
    }

    func testSingleLineIsEllipsised() {
        XCTAssertEqual(wrap("Hello wonderful world", lines: 1), ["Hello won…"])
        // Trailing spaces are trimmed before the ellipsis.
        XCTAssertEqual(wrap("Hello    wonderful", lines: 1), ["Hello…"])
        XCTAssertEqual(wrap("Hello", 5, lines: 1), ["…"], "only the ellipsis fits (or not even that)")
    }

    func testWordWrapAndFoldedEllipsisedLastLine() {
        XCTAssertEqual(wrap("Turn left onto Avenida Boyacá", lines: 2), ["Turn left", "onto Aven…"])
        XCTAssertEqual(wrap("Turn left onto Avenida Boyacá", lines: 5), ["Turn left", "onto", "Avenida", "Boyacá"])
        XCTAssertEqual(wrap("one two three four", lines: 3), ["one two", "three four"])
    }

    func testLongWordsBreakBetweenCharacters() {
        XCTAssertEqual(wrap("Supercalifragilistic", lines: 3), ["Supercalif", "ragilistic"])
        XCTAssertEqual(wrap("Supercalifragilisticexpialidocious", lines: 2), ["Supercalif", "ragilisti…"])
        XCTAssertEqual(wrap("ab Supercalifragilistic", lines: 3), ["ab", "Supercalif", "ragilistic"])
    }

    func testHardLineBreaks() {
        XCTAssertEqual(wrap("A\nB", lines: 2), ["A", "B"])
        XCTAssertEqual(wrap("A\n\nB", lines: 3), ["A", "", "B"], "an empty hard line keeps its slot")
        XCTAssertEqual(wrap("Line one\nLine two", lines: 1), ["Line one…"])
        // The remainder is always marked with "…" when lines were cut, even if it fits.
        XCTAssertEqual(wrap("A\nB\nC", lines: 2), ["A", "B C…"])
    }

    func testRepeatedSpacesCollapseAndEmptyText() {
        XCTAssertEqual(wrap("a  b", lines: 2), ["a b"])
        XCTAssertEqual(wrap("", lines: 1), [""])
        XCTAssertEqual(wrap("", lines: 3), [""])
        XCTAssertEqual(wrap("x", lines: 0), ["x"], "maxLines < 1 behaves like 1")
    }

    func testLetterSpacingModelChangesBreaks() {
        // width = chars × 10 + 0.12 em × 20 px × chars (core layout model) → 12.4 px per char.
        let spaced: (String) -> Double = { Double($0.count) * 10 + 0.12 * 20 * Double($0.count) }
        XCTAssertEqual(DashTextWrapper.wrap("↑ ↑ → ↑ ↑", maxWidth: 120, maxLines: 1, width: spaced), ["↑ ↑ → ↑ ↑"]) // 111.6 px
        XCTAssertEqual(DashTextWrapper.wrap("↑ ↑ → ↑ ↑ ↑", maxWidth: 120, maxLines: 1, width: spaced), ["↑ ↑ → ↑…"]) // 136.4 px
        // 9 chars = 111.6 px > 100: prefix "↑ ↑ → ↑ " trims to 7 chars + "…" = 99.2 px.
        XCTAssertEqual(DashTextWrapper.wrap("↑ ↑ → ↑ ↑", maxWidth: 100, maxLines: 1, width: spaced), ["↑ ↑ → ↑…"])
    }

    func testBlockGeometryFollowsTheContract() {
        let r = DashRect(x: 10, y: 20, width: 100, height: 50)
        // lineHeight = 15, block = 30, top = 20 + (50 − 30) / 2 = 30 → baselines 40, 55.
        XCTAssertEqual(DashTextBlockGeometry.baselines(lineCount: 2, rect: r, ascent: 10, descent: 5), [40, 55])
        XCTAssertEqual(DashTextBlockGeometry.baselines(lineCount: 1, rect: r, ascent: 10, descent: 5), [47.5])
        XCTAssertEqual(DashTextBlockGeometry.baselines(lineCount: 0, rect: r, ascent: 10, descent: 5), [])
        // A block taller than the rect overflows symmetrically.
        XCTAssertEqual(DashTextBlockGeometry.baselines(lineCount: 4, rect: r, ascent: 10, descent: 5), [25, 40, 55, 70])
        XCTAssertEqual(DashTextBlockGeometry.lineX(lineWidth: 40, rect: r, alignment: .left), 10)
        XCTAssertEqual(DashTextBlockGeometry.lineX(lineWidth: 40, rect: r, alignment: .center), 40)
        XCTAssertEqual(DashTextBlockGeometry.lineX(lineWidth: 40, rect: r, alignment: .right), 70)
    }
}
