import XCTest
@testable import OpenCfMotoCore

final class AnnexBTests: XCTestCase {
    private func avcc(_ nals: [[UInt8]]) -> Data {
        var d = Data()
        for n in nals {
            let l = UInt32(n.count)
            d.append(contentsOf: [UInt8(l >> 24), UInt8((l >> 16) & 0xFF), UInt8((l >> 8) & 0xFF), UInt8(l & 0xFF)])
            d.append(contentsOf: n)
        }
        return d
    }

    func testKeyframePrependsSPSPPSAndDropsSEI() {
        let sps = Data([0x67, 0x42, 0x00, 0x1F])
        let pps = Data([0x68, 0xCE, 0x0D, 0x88])
        let slices = avcc([[0x06, 0x05, 0x01], [0x65, 0x88, 0x84]]) // SEI + IDR
        let au = AnnexB.accessUnit(avccSlices: slices, sps: [sps], pps: [pps])
        XCTAssertTrue(au.isKeyframe)
        XCTAssertEqual(au.data, Data([0, 0, 0, 1, 0x67, 0x42, 0x00, 0x1F, 0, 0, 0, 1, 0x68, 0xCE, 0x0D, 0x88, 0, 0, 0, 1, 0x65, 0x88, 0x84]))
        XCTAssertTrue(AnnexB.containsIDR(annexB: au.data))
    }

    func testPFrameHasNoParameterSets() {
        let au = AnnexB.accessUnit(avccSlices: avcc([[0x41, 0x9A, 0x00]]), sps: [Data([0x67])], pps: [Data([0x68])])
        XCTAssertFalse(au.isKeyframe)
        XCTAssertEqual(au.data, Data([0, 0, 0, 1, 0x41, 0x9A, 0x00]))
    }

    func testSplitAnnexBWithMixedStartCodes() {
        let d = Data([0, 0, 0, 1, 0x67, 0xAA, 0, 0, 1, 0x68, 0xBB, 0, 0, 0, 1, 0x65, 0xCC])
        let nals = AnnexB.nalUnits(annexB: d)
        XCTAssertEqual(nals.map { AnnexB.nalType($0)! }, [7, 8, 5])
    }

    func testWireBytesPrefixLittleEndianSize() {
        let f = EncodedFrame(accessUnit: Data([1, 2, 3]), isKeyframe: false)
        XCTAssertEqual(f.wireBytes, Data([3, 0, 0, 0, 1, 2, 3]))
    }
}

final class FrameQueueTests: XCTestCase {
    private func frame(_ seq: UInt64, key: Bool) -> EncodedFrame {
        EncodedFrame(accessUnit: Data([UInt8(seq & 0xFF)]), isKeyframe: key, sequence: seq)
    }

    func testGateDropsPFramesUntilKeyframe() async {
        let q = FrameQueue(capacity: 3)
        q.push(frame(1, key: false))
        XCTAssertEqual(q.pendingCount, 0)
        q.push(frame(2, key: true))
        q.push(frame(3, key: false))
        let a = await q.next(timeout: 0.1)
        let b = await q.next(timeout: 0.1)
        XCTAssertEqual(a?.sequence, 2)
        XCTAssertEqual(b?.sequence, 3)
        XCTAssertEqual(q.gatedDropCount, 1)
    }

    func testOverflowFlushesAndRequestsKeyframe() async {
        let q = FrameQueue(capacity: 2)
        let requested = Locked(0)
        q.onKeyframeNeeded = { requested.withLock { $0 += 1 } }
        q.push(frame(1, key: true))
        q.push(frame(2, key: false))
        q.push(frame(3, key: false)) // overflow → flush + gate
        XCTAssertEqual(q.pendingCount, 0)
        XCTAssertEqual(q.overflowCount, 1)
        XCTAssertEqual(requested.current, 1)
        q.push(frame(4, key: false)) // gated
        q.push(frame(5, key: true))
        let f = await q.next(timeout: 0.1)
        XCTAssertEqual(f?.sequence, 5)
    }

    func testWaiterReceivesPushedFrameAndTimeoutReturnsNil() async {
        let q = FrameQueue()
        q.push(frame(1, key: true))
        _ = await q.next(timeout: 0.1)
        let none = await q.next(timeout: 0.05)
        XCTAssertNil(none)
        async let waited = q.next(timeout: 2)
        try? await Task.sleep(nanoseconds: 50_000_000)
        q.push(frame(2, key: false))
        let got = await waited
        XCTAssertEqual(got?.sequence, 2)
    }

    func testResynchronizeClosesGateAndRemembersLastKeyframe() async {
        let q = FrameQueue()
        q.push(frame(1, key: true))
        q.push(frame(2, key: false))
        q.resynchronize()
        XCTAssertEqual(q.pendingCount, 0)
        XCTAssertTrue(q.isGateClosed)
        XCTAssertEqual(q.lastKeyframe?.sequence, 1)
        q.push(frame(3, key: false))
        XCTAssertEqual(q.pendingCount, 0)
    }

    /// MP-3: the cached keyframe belongs to one media session and one canvas.
    func testLastKeyframeIsForgottenOnReopenAndInvalidation() async {
        let q = FrameQueue()
        q.push(frame(1, key: true))
        q.flush()
        q.resynchronize()
        XCTAssertEqual(q.lastKeyframe?.sequence, 1, "a resync / flush keeps it (same session, same canvas)")
        q.invalidateKeyframe()
        XCTAssertNil(q.lastKeyframe, "canvas change")
        q.push(frame(2, key: true))
        q.close()
        XCTAssertEqual(q.lastKeyframe?.sequence, 2)
        q.reopen()
        XCTAssertNil(q.lastKeyframe, "a new media session never re-sends the previous one's IDR")
        XCTAssertTrue(q.isGateClosed)
        q.push(frame(3, key: true))
        XCTAssertEqual(q.lastKeyframe?.sequence, 3)
    }

    func testCloseWakesWaiters() async {
        let q = FrameQueue()
        async let w = q.next(timeout: 5)
        try? await Task.sleep(nanoseconds: 30_000_000)
        q.close()
        let r = await w
        XCTAssertNil(r)
    }
}
