// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import OpenCfMotoCore

final class DashFocusTests: XCTestCase {
    func testEnsureDefaultKeepsListedFocusElseFirst() {
        var f = DashFocusEngine()
        f.ensure([])
        XCTAssertNil(f.focusedId)
        f.ensure(["a", "b", "c"])
        XCTAssertEqual(f.focusedId, "a")
        f.move(["a", "b", "c"], by: 1)
        XCTAssertEqual(f.focusedId, "b")
        f.ensure(["x", "b", "y"]) // still listed (at a different index) → kept by id
        XCTAssertEqual(f.focusedId, "b")
        f.ensure(["x", "y"])
        XCTAssertEqual(f.focusedId, "x")
        f.ensure([])
        XCTAssertNil(f.focusedId)
    }

    func testPreferGoAndEnd() {
        var f = DashFocusEngine(focusedId: "preview.save")
        f.ensure(["preview.go", "preview.circuit", "preview.cancel", "preview.save"], prefer: .go)
        XCTAssertEqual(f.focusedId, "preview.go")
        // pin setup: Go hidden → behaves like default (keeps Save)
        f = DashFocusEngine(focusedId: "preview.save")
        f.ensure(["preview.cancel", "preview.save", "preview.home", "preview.marker"], prefer: .go)
        XCTAssertEqual(f.focusedId, "preview.save")
        f.ensure(["metrics.end", "fab.recenter"], prefer: .end)
        XCTAssertEqual(f.focusedId, "metrics.end")
        f.ensure(["fab.recenter", "fab.zoomIn"], prefer: .end) // End absent → first
        XCTAssertEqual(f.focusedId, "fab.recenter")
    }

    func testMoveWrapsBothWays() {
        let list = ["a", "b", "c"]
        var f = DashFocusEngine()
        f.move(list, by: 1) // nothing focused → first
        XCTAssertEqual(f.focusedId, "a")
        f.move(list, by: -1)
        XCTAssertEqual(f.focusedId, "c")
        f.move(list, by: 1)
        XCTAssertEqual(f.focusedId, "a")
        f.move(list, by: 5) // (0 + 5) mod 3 = 2
        XCTAssertEqual(f.focusedId, "c")
        f.move(list, by: -7) // (2 − 7) mod 3 = 1
        XCTAssertEqual(f.focusedId, "b")
        f = DashFocusEngine(focusedId: "gone")
        f.move(list, by: 1)
        XCTAssertEqual(f.focusedId, "a")
        f.move([], by: 1)
        XCTAssertNil(f.focusedId)
    }

    func testTouchFocusAndDefaultPreference() {
        var f = DashFocusEngine(focusedId: "a")
        f.focus("c", in: ["a", "b", "c"])
        XCTAssertEqual(f.focusedId, "c")
        f.focus("zzz", in: ["a", "b", "c"])
        XCTAssertEqual(f.focusedId, "c")
        XCTAssertEqual(DashFocusEngine.defaultPreference(inPreview: true, navigating: true), .go)
        XCTAssertEqual(DashFocusEngine.defaultPreference(inPreview: false, navigating: true), .end)
        XCTAssertEqual(DashFocusEngine.defaultPreference(inPreview: false, navigating: false), .default)
    }
}

final class DashGestureTests: XCTestCase {
    private var rec = DashGestureRecognizer()
    private let button = DashRect(x: 90, y: 90, width: 40, height: 40)

    override func setUp() {
        super.setUp()
        rec = DashGestureRecognizer()
    }

    private func hit(_ p: DashPoint) -> DashTouchTarget {
        if button.contains(p) { return .control(id: "btn", rect: button) }
        if p.x >= 500, p.x < 600 { return .controlInScroll(id: "row", rect: DashRect(x: 500, y: 0, width: 100, height: 50), container: "list") }
        if p.x >= 600, p.x < 700 { return .scrollArea(container: "list") }
        if p.x >= 700, p.x < 750 { return .blocker }
        if p.y < 10 { return .ignored }
        return .map
    }

    private func send(_ a: DashTouch.Action, _ x: Double, _ y: Double, t: TimeInterval, id: Int = 0) -> [DashGestureEvent] {
        rec.process(DashTouch(action: a, pointerId: id, x: Int(x), y: Int(y), time: t), point: DashPoint(x, y), now: t, hitTest: hit)
    }

    func testTapOnControl() {
        XCTAssertEqual(send(.down, 100, 100, t: 0), [])
        XCTAssertEqual(send(.up, 103, 102, t: 0.08), [.tap(id: "btn")])
        // moved within the control (beyond slop) is still a tap
        XCTAssertEqual(send(.down, 95, 95, t: 1), [])
        XCTAssertEqual(send(.move, 125, 125, t: 1.05), [])
        XCTAssertEqual(send(.up, 125, 125, t: 1.1), [.tap(id: "btn")])
        // released outside rect + slop → no tap
        XCTAssertEqual(send(.down, 100, 100, t: 2), [])
        XCTAssertEqual(send(.move, 160, 100, t: 2.05), [])
        XCTAssertEqual(send(.up, 160, 100, t: 2.1), [])
        // released just inside the slop band → tap
        XCTAssertEqual(send(.down, 100, 100, t: 3), [])
        XCTAssertEqual(send(.up, 137, 100, t: 3.1), [.tap(id: "btn")])
    }

    func testLongPressViaTickAndFallbackAtUp() {
        XCTAssertEqual(send(.down, 300, 200, t: 10), [])
        XCTAssertEqual(rec.tick(now: 10.44), [])
        XCTAssertEqual(rec.tick(now: 10.45), [.longPress(DashPoint(300, 200))])
        XCTAssertEqual(rec.tick(now: 11), [])
        XCTAssertEqual(send(.up, 300, 200, t: 11.2), []) // consumed
        // no tick: fires at UP
        XCTAssertEqual(send(.down, 300, 200, t: 20), [])
        XCTAssertEqual(send(.move, 303, 204, t: 20.3), []) // within slop (5 px)
        XCTAssertEqual(send(.up, 303, 204, t: 20.5), [.longPress(DashPoint(300, 200))])
        // a MOVE after 450 ms also fires it
        XCTAssertEqual(send(.down, 300, 200, t: 30), [])
        XCTAssertEqual(send(.move, 301, 200, t: 30.46), [.longPress(DashPoint(300, 200))])
    }

    func testMapTapThenPanAndPanEnd() {
        XCTAssertEqual(send(.down, 300, 200, t: 0), [])
        XCTAssertEqual(send(.up, 300, 200, t: 0.1), [.mapTap(DashPoint(300, 200))])
        XCTAssertEqual(send(.down, 300, 200, t: 5), [])
        XCTAssertEqual(send(.move, 305, 200, t: 5.05), []) // within slop
        XCTAssertEqual(send(.move, 320, 190, t: 5.1), [.panBegan, .pan(delta: DashPoint(20, -10))])
        XCTAssertEqual(send(.move, 330, 190, t: 5.15), [.pan(delta: DashPoint(10, 0))])
        XCTAssertEqual(rec.tick(now: 6), []) // no long-press once panning
        XCTAssertEqual(send(.up, 330, 190, t: 6.1), [.panEnded])
    }

    func testDoubleTapWindowAndSlop() {
        // first tap: up at 0.05
        _ = send(.down, 300, 200, t: 0)
        _ = send(.up, 300, 200, t: 0.05)
        XCTAssertEqual(send(.down, 340, 230, t: 0.30), [.doubleTap(DashPoint(340, 230))]) // 250 ms, 50 px
        XCTAssertEqual(send(.up, 340, 230, t: 0.35), [])
        // too slow (> 300 ms between UP and DOWN)
        _ = send(.down, 300, 200, t: 10)
        _ = send(.up, 300, 200, t: 10.05)
        XCTAssertEqual(send(.down, 300, 200, t: 10.36), [])
        _ = send(.up, 300, 200, t: 10.4)
        // too far (> 100 px)
        _ = send(.down, 300, 200, t: 20)
        _ = send(.up, 300, 200, t: 20.05)
        XCTAssertEqual(send(.down, 300, 310, t: 20.2), [])
        _ = send(.up, 300, 310, t: 20.25)
        // too fast (< 40 ms)
        _ = send(.down, 300, 200, t: 30)
        _ = send(.up, 300, 200, t: 30.05)
        XCTAssertEqual(send(.down, 300, 200, t: 30.07), [])
    }

    func testPinchAndContinueWithOneFinger() {
        XCTAssertEqual(send(.down, 100, 200, t: 0, id: 0), [])
        XCTAssertEqual(send(.down, 200, 200, t: 0.02, id: 1), [.panBegan])
        XCTAssertEqual(send(.move, 300, 200, t: 0.1, id: 1),
                       [.pinch(scale: 2, focal: DashPoint(200, 200), translation: DashPoint(50, 0))])
        XCTAssertEqual(send(.move, 100, 250, t: 0.15, id: 0),
                       [.pinch(scale: (200.0 * 200 + 50 * 50).squareRoot() / 200, focal: DashPoint(200, 225), translation: DashPoint(0, 25))])
        XCTAssertEqual(rec.tick(now: 2), []) // never a long-press
        XCTAssertEqual(send(.up, 300, 200, t: 0.2, id: 1), []) // one finger left → pan
        XCTAssertEqual(send(.move, 110, 250, t: 0.25, id: 0), [.pan(delta: DashPoint(10, 0))])
        XCTAssertEqual(send(.up, 110, 250, t: 0.3, id: 0), [.panEnded])
        XCTAssertFalse(rec.isActive)
    }

    func testScrollFromControlInScrollAndScrollArea() {
        XCTAssertEqual(send(.down, 550, 20, t: 0), [])
        XCTAssertEqual(send(.move, 550, 40, t: 0.05), [.scroll(container: "list", delta: DashPoint(0, 20))])
        XCTAssertEqual(send(.move, 550, 35, t: 0.1), [.scroll(container: "list", delta: DashPoint(0, -5))])
        XCTAssertEqual(send(.up, 550, 35, t: 0.2), []) // no tap after a scroll
        // tap without movement on the row → tap
        XCTAssertEqual(send(.down, 550, 20, t: 1), [])
        XCTAssertEqual(send(.up, 552, 21, t: 1.1), [.tap(id: "row")])
        // background of the list scrolls too
        XCTAssertEqual(send(.down, 650, 100, t: 2), [])
        XCTAssertEqual(send(.move, 650, 60, t: 2.1), [.scroll(container: "list", delta: DashPoint(0, -40))])
        XCTAssertEqual(send(.up, 650, 60, t: 2.2), [])
    }

    func testBlockerAndIgnoredSwallowEverything() {
        XCTAssertEqual(send(.down, 720, 100, t: 0), [])
        XCTAssertEqual(send(.move, 720, 300, t: 0.1), [])
        XCTAssertEqual(rec.tick(now: 1), [])
        XCTAssertEqual(send(.up, 720, 300, t: 1.1), [])
        XCTAssertEqual(send(.down, 300, 5, t: 2), []) // in the top margin
        XCTAssertEqual(send(.move, 300, 100, t: 2.1), [])
        XCTAssertEqual(rec.tick(now: 3), [])
        XCTAssertEqual(send(.up, 300, 100, t: 3.1), [])
    }

    func testPointerBookkeeping() {
        XCTAssertEqual(send(.up, 1, 1, t: 0, id: 7), []) // untracked UP ignored
        XCTAssertFalse(rec.isActive)
        // MOVE without DOWN is promoted to a DOWN
        XCTAssertEqual(send(.move, 100, 100, t: 1, id: 3), [])
        XCTAssertTrue(rec.isActive)
        XCTAssertEqual(send(.up, 100, 100, t: 1.05, id: 3), [.tap(id: "btn")])
        XCTAssertFalse(rec.isActive)
    }

    func testScaledThresholds() {
        let c = DashGestureConfig.scaled(1.425)
        XCTAssertEqual(c.touchSlop, 11.4, accuracy: 1e-9)
        XCTAssertEqual(c.doubleTapSlop, 142.5, accuracy: 1e-9)
        XCTAssertEqual(c.longPress, 0.45)
        XCTAssertEqual(c.doubleTapTimeout, 0.30)
    }
}
