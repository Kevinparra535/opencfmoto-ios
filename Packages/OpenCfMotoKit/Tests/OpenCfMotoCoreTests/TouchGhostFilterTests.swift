// SPDX-License-Identifier: AGPL-3.0-or-later
// Vectors: docs/spec/input-controls.md §2.4 (wire decode), §4.5(a) (test/GhostTouchTest.kt) and
// §4.5(b) scenario traces S1–S9 (Android reference + the F1–F3 variants); media-video.md §11.
import XCTest
@testable import OpenCfMotoCore

final class TouchFrameTests: XCTestCase {
    func testDecodeVectors() throws {
        let down = try XCTUnwrap(PxcTouchFrame.decode(linkHex("02 00 80 02 20 01 00 00 40 E2 01 00 00 00 00 00 00 00")))
        XCTAssertEqual(down, PxcTouchFrame(rawAction: 2, x: 640, y: 288, pointerId: 0, timestamp: 123_456))
        XCTAssertEqual(down.action, .down)
        let move = try XCTUnwrap(PxcTouchFrame.decode(linkHex("03 00 BC 02 2C 01 00 00 50 E2 01 00 00 00 00 00 00 00")))
        XCTAssertEqual([Int(move.rawAction), move.x, move.y, move.pointerId], [3, 700, 300, 0])
        XCTAssertEqual(move.action, .move)
        XCTAssertEqual(move.timestamp, 123_472)
        let up = try XCTUnwrap(PxcTouchFrame.decode(linkHex("01 00 BC 02 2C 01 00 00 60 E2 01 00 00 00 00 00 00 00")))
        XCTAssertEqual([Int(up.rawAction), up.x, up.y, up.pointerId], [1, 700, 300, 0])
        XCTAssertEqual(up.action, .up)
        let second = try XCTUnwrap(PxcTouchFrame.decode(linkHex("02 00 E8 03 C8 00 01 00 6C E2 01 00 00 00 00 00 00 00")))
        XCTAssertEqual([Int(second.rawAction), second.x, second.y, second.pointerId], [2, 1000, 200, 1])
        // y is u16 @4 (not u32): pointer 1 does not leak into y.
        XCTAssertEqual(second.y, 200)
    }

    func testRejectsShortBodiesAndFlagsUnknownActions() {
        XCTAssertNil(PxcTouchFrame.decode(linkHex("02 00 80 02 20 01 00")))
        let unknown = PxcTouchFrame.decode(linkHex("09 00 01 00 01 00 00 00"))
        XCTAssertNotNil(unknown)
        XCTAssertNil(unknown?.action)
        XCTAssertNil(unknown?.timestamp) // < 12 bytes
    }

    func testFullMediaFrameExample() throws {
        // media-video.md §11: DOWN at (400,200), pointer 0, ts 0x12345678.
        let wire = linkHex("20 00 12 00 00 00 00 00 02 00 90 01 c8 00 00 00 78 56 34 12 00 00 00 00 00 00")
        let msg = try XCTUnwrap(try MediaMessage.decode(wire)).message
        XCTAssertEqual(msg.cmdType, MediaCmd.touch)
        let t = try XCTUnwrap(PxcTouchFrame.decode(msg.body))
        XCTAssertEqual(t, PxcTouchFrame(rawAction: 2, x: 400, y: 200, pointerId: 0, timestamp: 0x1234_5678))
        XCTAssertEqual(t.encodedBody(), msg.body)
    }

    func testNormalization() {
        XCTAssertEqual(PxcTouchFrame.normalize(2), .down)
        XCTAssertEqual(PxcTouchFrame.normalize(1), .up)
        XCTAssertEqual(PxcTouchFrame.normalize(3), .move)
        XCTAssertNil(PxcTouchFrame.normalize(0))
        XCTAssertNil(PxcTouchFrame.normalize(9))
        XCTAssertEqual(DashTouch.Action.down.rawValue, 0)
        XCTAssertEqual(DashTouch.Action.up.rawValue, 1)
        XCTAssertEqual(DashTouch.Action.move.rawValue, 2)
        for a in [DashTouch.Action.down, .up, .move] {
            XCTAssertEqual(PxcTouchFrame.normalize(PxcTouchFrame.rawAction(for: a)), a)
        }
    }
}

final class TouchGhostFilterTests: XCTestCase {
    typealias Input = (t: Int64, raw: UInt16, x: Int, y: Int, id: Int)

    /// Runs a trace under virtual time; returns "t ACTION outId (x,y)" lines.
    private func run(_ inputs: [Input], compat: Bool) -> [String] {
        let clock = LinkManualClock()
        let scheduler = LinkVirtualScheduler(clock: clock)
        let out = Locked<[DashTouch]>([])
        let filter = GhostTouchFilter(configuration: compat ? .androidCompatible : .default, clock: clock,
                                      scheduler: scheduler) { t in out.withLock { $0.append(t) } }
        for i in inputs {
            scheduler.runDue(beforeMs: i.t)
            clock.setMs(i.t)
            filter.handle(rawAction: i.raw, x: i.x, y: i.y, pointerId: i.id)
        }
        scheduler.runAll()
        return out.current.map { t in
            let name = t.action == .down ? "DOWN" : (t.action == .up ? "UP" : "MOVE")
            return "\(Int64((t.time * 1000).rounded())) \(name) \(t.pointerId) (\(t.x),\(t.y))"
        }
    }

    // MARK: §4.5(a) GhostTouchTest

    func testNearVectors() {
        XCTAssertTrue(GhostTouchFilter.near(100, 200, 100, 200))
        XCTAssertTrue(GhostTouchFilter.near(100, 200, 130, 230))
        XCTAssertTrue(GhostTouchFilter.near(100, 200, 52, 200))   // dx = 48, inclusive
        XCTAssertFalse(GhostTouchFilter.near(100, 200, 149, 200)) // dx = 49
        XCTAssertFalse(GhostTouchFilter.near(100, 200, 100, 249)) // dy = 49
        XCTAssertTrue(GhostTouchFilter.near(0, 0, 150, 150, tolerance: 150))
        XCTAssertFalse(GhostTouchFilter.near(0, 0, 151, 0, tolerance: 150))
    }

    // MARK: §4.5(b) traces

    static let s1: [Input] = [(0, 2, 100, 100, 0), (60, 1, 100, 100, 0)]
    static let s2: [Input] = [(0, 2, 100, 100, 0), (16, 3, 140, 100, 0), (32, 1, 160, 100, 0), (40, 2, 175, 100, 0),
                              (56, 3, 200, 100, 0), (200, 1, 300, 100, 0)]
    static let s3: [Input] = [(0, 2, 100, 100, 0), (30, 3, 118, 100, 0), (34, 1, 120, 100, 0), (40, 2, 125, 100, 1),
                              (56, 3, 130, 100, 1), (72, 3, 150, 100, 1), (88, 3, 170, 100, 1), (400, 3, 200, 100, 1),
                              (420, 1, 210, 100, 1)]
    static let s4: [Input] = [(0, 2, 300, 200, 0), (5, 2, 320, 210, 1), (20, 3, 325, 212, 1), (40, 1, 325, 212, 1),
                              (60, 1, 300, 200, 0)]
    static let s5: [Input] = [(0, 2, 200, 200, 0), (10, 2, 400, 200, 1), (30, 3, 190, 200, 0), (31, 3, 410, 200, 1),
                              (60, 3, 180, 200, 0), (61, 3, 420, 200, 1), (100, 1, 180, 200, 0), (140, 1, 420, 200, 1)]
    static let s6: [Input] = [(0, 2, 100, 100, 0), (50, 1, 100, 100, 0), (190, 2, 105, 100, 0), (240, 1, 105, 100, 0)]
    static let s7: [Input] = [(0, 2, 100, 100, 0), (50, 1, 100, 100, 0), (70, 2, 400, 100, 0), (120, 1, 400, 100, 0)]
    static let s8: [Input] = [(0, 2, 200, 200, 0), (5, 2, 400, 200, 1), (100, 1, 200, 200, 0), (130, 1, 400, 200, 1)]
    static let s9: [Input] = [(0, 9, 1, 1, 0)]

    static let s1Out = ["0 DOWN 0 (100,100)", "140 UP 0 (100,100)"]
    static let s2Out = ["0 DOWN 0 (100,100)", "16 MOVE 0 (140,100)", "40 MOVE 0 (175,100)", "56 MOVE 0 (200,100)", "280 UP 0 (300,100)"]
    static let s4Out = ["0 DOWN 0 (300,200)", "140 UP 0 (300,200)"]
    static let s6Out = ["0 DOWN 0 (100,100)", "130 UP 0 (100,100)", "190 DOWN 0 (105,100)", "320 UP 0 (105,100)"]
    static let s7Out = ["0 DOWN 0 (100,100)", "70 UP 0 (100,100)", "70 DOWN 0 (400,100)", "200 UP 0 (400,100)"]

    func testS1TapAndroid() { XCTAssertEqual(run(Self.s1, compat: true), Self.s1Out) }
    func testS2DragReacquiredSameIdAndroid() { XCTAssertEqual(run(Self.s2, compat: true), Self.s2Out) }

    func testS3ReacquiredWithNewIdAndroidDropsSelfGhosts() {
        XCTAssertEqual(run(Self.s3, compat: true), [
            "0 DOWN 0 (100,100)", "30 MOVE 0 (118,100)", "40 MOVE 0 (125,100)", "88 MOVE 0 (170,100)",
            "400 MOVE 0 (200,100)", "500 UP 0 (210,100)",
        ])
    }

    func testS4GhostSecondContact() { XCTAssertEqual(run(Self.s4, compat: true), Self.s4Out) }

    func testS5PinchAndroidLosesPointer0Up() {
        XCTAssertEqual(run(Self.s5, compat: true), [
            "0 DOWN 0 (200,200)", "10 DOWN 1 (400,200)", "30 MOVE 0 (190,200)", "31 MOVE 1 (410,200)",
            "60 MOVE 0 (180,200)", "61 MOVE 1 (420,200)", "220 UP 1 (420,200)",
        ])
    }

    func testS6LateReacquireIsTwoTaps() { XCTAssertEqual(run(Self.s6, compat: true), Self.s6Out) }
    func testS7FarReacquireCommitsUp() { XCTAssertEqual(run(Self.s7, compat: true), Self.s7Out) }

    func testS8TwoFingersLiftAndroidLosesFirstUp() {
        XCTAssertEqual(run(Self.s8, compat: true), ["0 DOWN 0 (200,200)", "5 DOWN 1 (400,200)", "210 UP 1 (400,200)"])
    }

    func testS9UnknownActionDropped() {
        XCTAssertEqual(run(Self.s9, compat: true), [])
        XCTAssertEqual(run(Self.s9, compat: false), [])
    }

    // MARK: Fixed variants (default configuration): only S3, S5, S8 differ

    func testFixedModeUnchangedTraces() {
        XCTAssertEqual(run(Self.s1, compat: false), Self.s1Out)
        XCTAssertEqual(run(Self.s2, compat: false), Self.s2Out)
        XCTAssertEqual(run(Self.s4, compat: false), Self.s4Out)
        XCTAssertEqual(run(Self.s6, compat: false), Self.s6Out)
        XCTAssertEqual(run(Self.s7, compat: false), Self.s7Out)
    }

    func testS3WithF3TransfersIdentity() {
        XCTAssertEqual(run(Self.s3, compat: false), [
            "0 DOWN 0 (100,100)", "30 MOVE 0 (118,100)", "40 MOVE 0 (125,100)", "56 MOVE 0 (130,100)",
            "72 MOVE 0 (150,100)", "88 MOVE 0 (170,100)", "400 MOVE 0 (200,100)", "500 UP 0 (210,100)",
        ])
    }

    func testS5WithF1CommitsPointer0Up() {
        XCTAssertEqual(run(Self.s5, compat: false), [
            "0 DOWN 0 (200,200)", "10 DOWN 1 (400,200)", "30 MOVE 0 (190,200)", "31 MOVE 1 (410,200)",
            "60 MOVE 0 (180,200)", "61 MOVE 1 (420,200)", "140 UP 0 (180,200)", "220 UP 1 (420,200)",
        ])
    }

    func testS8WithF1() {
        XCTAssertEqual(run(Self.s8, compat: false),
                       ["0 DOWN 0 (200,200)", "5 DOWN 1 (400,200)", "130 UP 0 (200,200)", "210 UP 1 (400,200)"])
    }

    // MARK: F2 (eviction / trim deliver an UP)

    func testStaleEvictionIsSilentOnAndroidAndDeliveredWithF2() {
        let trace: [Input] = [(0, 2, 100, 100, 0), (10, 2, 400, 100, 1), (400, 3, 410, 100, 1)]
        XCTAssertEqual(run(trace, compat: true), ["0 DOWN 0 (100,100)", "10 DOWN 1 (400,100)", "400 MOVE 1 (410,100)"])
        XCTAssertEqual(run(trace, compat: false),
                       ["0 DOWN 0 (100,100)", "10 DOWN 1 (400,100)", "400 UP 0 (100,100)", "400 MOVE 1 (410,100)"])
    }

    func testMaxPointersTrimKeepsCurrentAndMostRecent() {
        let trace: [Input] = [(0, 2, 100, 100, 0), (10, 2, 300, 100, 1), (20, 2, 500, 100, 2)]
        XCTAssertEqual(run(trace, compat: true), ["0 DOWN 0 (100,100)", "10 DOWN 1 (300,100)", "20 DOWN 2 (500,100)"])
        XCTAssertEqual(run(trace, compat: false),
                       ["0 DOWN 0 (100,100)", "10 DOWN 1 (300,100)", "20 UP 0 (100,100)", "20 DOWN 2 (500,100)"])
    }

    func testQ6GhostThatMovesAwayBecomesAPointer() {
        // A ghost DOWN is dropped, but its later MOVE > 48 px away from the other finger is accepted.
        let trace: [Input] = [(0, 2, 300, 200, 0), (5, 2, 320, 210, 1), (40, 3, 420, 210, 1)]
        XCTAssertEqual(run(trace, compat: true), ["0 DOWN 0 (300,200)", "40 MOVE 1 (420,210)"])
        XCTAssertEqual(run(trace, compat: false), ["0 DOWN 0 (300,200)", "40 MOVE 1 (420,210)"])
    }

    func testStitchWindowBoundaryIsInclusive() {
        // DOWN exactly 80 ms after the UP and exactly 150 px away still stitches (<=).
        // The drag stays open: no UP is delivered.
        let trace: [Input] = [(0, 2, 100, 100, 0), (20, 1, 100, 100, 0), (100, 2, 250, 250, 0)]
        XCTAssertEqual(run(trace, compat: true), ["0 DOWN 0 (100,100)", "100 MOVE 0 (250,250)"])
        // 81 ms later is a new touch.
        let late: [Input] = [(0, 2, 100, 100, 0), (20, 1, 100, 100, 0), (101, 2, 100, 100, 0)]
        XCTAssertEqual(run(late, compat: true), ["0 DOWN 0 (100,100)", "100 UP 0 (100,100)", "101 DOWN 0 (100,100)"])
    }

    func testResetCancelsHeldUp() {
        let clock = LinkManualClock()
        let scheduler = LinkVirtualScheduler(clock: clock)
        let out = Locked<[DashTouch]>([])
        let filter = GhostTouchFilter(clock: clock, scheduler: scheduler) { t in out.withLock { $0.append(t) } }
        filter.handle(rawAction: 2, x: 1, y: 1, pointerId: 0)
        clock.setMs(10)
        filter.handle(rawAction: 1, x: 1, y: 1, pointerId: 0)
        XCTAssertEqual(filter.trackedPointerIds, [0])
        filter.reset()
        scheduler.runAll()
        XCTAssertEqual(out.current.count, 1) // only the DOWN
        XCTAssertEqual(filter.trackedPointerIds, [])
    }

    func testDispatchSchedulerDeliversHeldUpAfterAbout80ms() async {
        let out = Locked<[DashTouch]>([])
        let filter = GhostTouchFilter { t in out.withLock { $0.append(t) } }
        filter.handle(rawAction: 2, x: 10, y: 20, pointerId: 0)
        let start = Date()
        filter.handle(rawAction: 1, x: 10, y: 20, pointerId: 0)
        XCTAssertEqual(out.current.count, 1)
        let delivered = await linkEventually(timeout: 2) { out.current.count == 2 }
        XCTAssertTrue(delivered)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.07)
        XCTAssertEqual(out.current.last?.action, .up)
    }
}
