// SPDX-License-Identifier: AGPL-3.0-or-later
// Vectors: docs/spec/control-plane.md §13.2 (DERIVED bytes) and §16.1 (test/HuTimeSyncTest.kt),
// §13.4 (0x10450 → empty 0x10451), §2.3.
import XCTest
@testable import OpenCfMotoCore

final class ClockTimeSyncTests: XCTestCase {
    private let rome = TimeZone(identifier: "Europe/Rome")!
    private let now: Int64 = 1_786_272_219_244 // → 2026-08-09 12:43:39.244 CEST

    private func req(_ stamp: String, modelId: Int32 = 37426, seq: Int32 = 7) -> Data {
        LinkDashSamples.timeSyncRequest(stamp: stamp, modelId: modelId, seq: seq)
    }

    // MARK: §16.1 HuTimeSyncTest

    func testSaneStampEchoesBikeTime() {
        let bike = "2026-07-24 17:09:20.190000000"
        let ack = HuTimeSync.ack(request: req(bike), nowMillis: now, timeZone: rome)
        XCTAssertEqual(ack.mode, .echo)
        XCTAssertEqual(ack.stamp, bike)
        XCTAssertEqual(ack.payload.count, 45)
        XCTAssertEqual(ByteReader(ack.payload).peekI32le(at: 0), -2)
        XCTAssertEqual(String(decoding: ack.payload[16 ..< 45], as: UTF8.self), bike)
        XCTAssertEqual(ack.payload, req(bike)) // byte-identical echo
    }

    func testShortFractionalStampStillEchoesPaddedTo45() {
        let bike = "2026-08-13 14:05:20.190"
        var w = ByteWriter()
        w.i32le(-2); w.i32le(1); w.i32le(1); w.i32le(0)
        w.append(Data(bike.utf8))
        XCTAssertEqual(w.count, 39)
        let ack = HuTimeSync.ack(request: w.data, nowMillis: now, timeZone: rome)
        XCTAssertEqual(ack.mode, .echo)
        XCTAssertTrue(ack.stamp.hasPrefix("2026-08-13 14:05:20"))
        // §13.2: short 39-byte request → echo, ack padded to 45.
        XCTAssertEqual(ack.payload, linkHex("""
            fe ff ff ff 01 00 00 00 01 00 00 00 00 00 00 00
            32 30 32 36 2d 30 38 2d 31 33 20 31 34 3a 30 35 3a 32 30 2e 31 39 30 00 00 00 00 00 00
            """))
    }

    func testEpochStampWritesPhoneTimeKeepingHeader() {
        let ack = HuTimeSync.ack(request: req("1970-01-01 00:00:00.000000000"), nowMillis: now, timeZone: rome)
        XCTAssertEqual(ack.mode, .phone)
        XCTAssertTrue(HuTimeSync.isSaneStamp(ack.stamp))
        XCTAssertEqual(ack.payload.count, 45)
        XCTAssertEqual(ack.payload, Self.forcePhonePayload) // §13.2: "1970 request → phone mode, header kept"
    }

    func testEmptyRequestSynthesizesHeaderAndPhoneStamp() {
        let ack = HuTimeSync.ack(request: Data(), nowMillis: now, timeZone: rome)
        XCTAssertEqual(ack.mode, .phone)
        XCTAssertEqual(ack.payload.count, 45)
        XCTAssertNotNil(ack.stamp.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{9}$"#, options: .regularExpression))
        XCTAssertEqual(ack.payload, linkHex("""
            fe ff ff ff 00 00 00 00 01 00 00 00 00 00 00 00
            32 30 32 36 2d 30 38 2d 30 39 20 31 32 3a 34 33 3a 33 39 2e 32 34 34 30 30 30 30 30 30
            """))
    }

    func testForcePhoneOverwritesSaneBikeStamp() {
        let bike = "2026-07-24 17:09:20.190000000"
        let ack = HuTimeSync.ack(request: req(bike), forcePhone: true, nowMillis: now, timeZone: rome)
        XCTAssertEqual(ack.mode, .phone)
        XCTAssertTrue(HuTimeSync.isSaneStamp(ack.stamp))
        XCTAssertFalse(ack.stamp.hasPrefix("2026-07-24 17:09:20"))
        XCTAssertEqual(ack.stamp, "2026-08-09 12:43:39.244000000")
        XCTAssertEqual(ack.payload, Self.forcePhonePayload)
    }

    func testIsSaneStamp() {
        XCTAssertFalse(HuTimeSync.isSaneStamp(""))
        XCTAssertFalse(HuTimeSync.isSaneStamp("1970-01-01 00:00:00.000000000"))
        XCTAssertTrue(HuTimeSync.isSaneStamp("2026-01-01 00:00:00"))
        XCTAssertTrue(HuTimeSync.isSaneStamp("2026-01-01 00:00:00.000000000"))
        XCTAssertFalse(HuTimeSync.isSaneStamp("2100-01-01 00:00:00"))
    }

    /// §13.2 forcePhone payload (header kept).
    static let forcePhonePayload = linkHex("""
        fe ff ff ff 32 92 00 00 07 00 00 00 00 00 00 00
        32 30 32 36 2d 30 38 2d 30 39 20 31 32 3a 34 33 3a 33 39 2e 32 34 34 30 30 30 30 30 30
        """)

    // MARK: §13.2 frame vectors

    func testEchoFrameBytes() {
        let request = PxcFrame(cmd: PxcCmd.huTimeSync, payload: req("2026-07-24 17:09:20.190000000"))
        XCTAssertEqual(request.encoded(), linkHex("""
            00 06 01 00 3d 00 00 00 3d 06 01 00 00 00 00 00
            fe ff ff ff 32 92 00 00 07 00 00 00 00 00 00 00
            32 30 32 36 2d 30 37 2d 32 34 20 31 37 3a 30 39
            3a 32 30 2e 31 39 30 30 30 30 30 30 30
            """))
        let (reply, ack) = HuTimeSync.replyFrame(to: request, nowMillis: now, timeZone: rome)
        XCTAssertEqual(ack.mode, .echo)
        XCTAssertEqual(reply.encoded(), linkHex("""
            01 06 01 00 3d 00 00 00 3c 06 01 00 00 00 00 00
            fe ff ff ff 32 92 00 00 07 00 00 00 00 00 00 00
            32 30 32 36 2d 30 37 2d 32 34 20 31 37 3a 30 39
            3a 32 30 2e 31 39 30 30 30 30 30 30 30
            """))
    }

    // MARK: Echo rules

    func testEchoRules() {
        // 1969 and 1971 are epoch-ish too; 1972 is echoed.
        XCTAssertEqual(HuTimeSync.ack(request: req("1969-12-31 23:59:59.000000000"), nowMillis: now, timeZone: rome).mode, .phone)
        XCTAssertEqual(HuTimeSync.ack(request: req("1971-06-01 00:00:00.000000000"), nowMillis: now, timeZone: rome).mode, .phone)
        XCTAssertEqual(HuTimeSync.ack(request: req("1972-06-01 00:00:00.000000000"), nowMillis: now, timeZone: rome).mode, .echo)
        // T separator: still a stamp, year 1970 → phone; 2026 → echo.
        XCTAssertEqual(HuTimeSync.ack(request: req("1970-01-01T00:00:10.000"), nowMillis: now, timeZone: rome).mode, .phone)
        XCTAssertEqual(HuTimeSync.ack(request: req("2026-01-01T00:00:10.000"), nowMillis: now, timeZone: rome).mode, .echo)
        // Any other content — even garbage — is echoed.
        XCTAssertEqual(HuTimeSync.ack(request: req("garbage"), nowMillis: now, timeZone: rome).mode, .echo)
        // Blank / NUL / spaces → phone.
        XCTAssertEqual(HuTimeSync.ack(request: req(""), nowMillis: now, timeZone: rome).mode, .phone)
        XCTAssertEqual(HuTimeSync.ack(request: req("     "), nowMillis: now, timeZone: rome).mode, .phone)
        // Header only (16 bytes) → blank stamp → phone, header kept.
        let headerOnly = req("").prefix(16)
        let ack = HuTimeSync.ack(request: Data(headerOnly), nowMillis: now, timeZone: rome)
        XCTAssertEqual(ack.mode, .phone)
        XCTAssertEqual(ack.payload.prefix(16), Data(headerOnly))
        // < 16 bytes → synthesized header even if bytes were present.
        let short = HuTimeSync.ack(request: linkHex("01 02 03"), nowMillis: now, timeZone: rome)
        XCTAssertEqual(short.mode, .phone)
        XCTAssertEqual(short.payload.prefix(16), linkHex("fe ff ff ff 00 00 00 00 01 00 00 00 00 00 00 00"))
        // Requests longer than 45 bytes are echoed at their full length.
        let long = req("2026-07-24 17:09:20.190000000") + Data([0xAA, 0xBB])
        let longAck = HuTimeSync.ack(request: long, nowMillis: now, timeZone: rome)
        XCTAssertEqual(longAck.payload, long)
    }

    func testExtractStampTrimsTrailingNulAndSpacesOnly() {
        XCTAssertEqual(HuTimeSync.extractStamp(req("2026-08-13 14:05:20.190 \u{0}")), "2026-08-13 14:05:20.190")
        XCTAssertEqual(HuTimeSync.extractStamp(Data(count: 15)), "")
        var raw = [UInt8](req("abc"))
        raw[17] = 0xC3 // non-ASCII byte → U+FFFD (Java US_ASCII decoding)
        XCTAssertEqual(HuTimeSync.extractStamp(Data(raw)), "a\u{FFFD}c")
    }

    func testPhoneStampUsesPosixGregorianAndOneEpochValue() {
        XCTAssertEqual(HuTimeSync.phoneStamp(nowMillis: now, timeZone: rome), "2026-08-09 12:43:39.244000000")
        XCTAssertEqual(HuTimeSync.phoneStamp(nowMillis: now, timeZone: TimeZone(identifier: "UTC")!), "2026-08-09 10:43:39.244000000")
        XCTAssertEqual(HuTimeSync.phoneStamp(nowMillis: 5, timeZone: TimeZone(identifier: "UTC")!), "1970-01-01 00:00:00.005000000")
        XCTAssertEqual(HuTimeSync.phoneStamp(nowMillis: 1_000, timeZone: TimeZone(identifier: "UTC")!), "1970-01-01 00:00:01.000000000")
    }

    // MARK: §13.4 HU_QUERY_TIME

    func testQueryTimeReplyIsEmpty0x10451() {
        XCTAssertEqual(HuQueryTime.replyFrame().encoded(), linkHex("51 04 01 00 10 00 00 00 41 04 01 00 00 00 00 00"))
    }
}
