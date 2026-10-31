// SPDX-License-Identifier: AGPL-3.0-or-later
// Vectors: docs/spec/control-plane.md §2.3 (byte-exact output of the Kotlin encoder).
import XCTest
@testable import OpenCfMotoCore

final class ProtocolPxcFrameTests: XCTestCase {
    // MARK: §2.3 vectors

    private let vectors: [(cmd: UInt32, payload: String, hex: String)] = [
        (0x7000_0011, "{\"status\":true}",
         "11 00 00 70 1f 00 00 00 0e 00 00 70 00 00 00 00 7b 22 73 74 61 74 75 73 22 3a 74 72 75 65 7d"),
        (0x10000, "", "00 00 01 00 10 00 00 00 10 00 01 00 00 00 00 00"),
        (0x10001, "", "01 00 01 00 10 00 00 00 11 00 01 00 00 00 00 00"),
        (0x20000, "", "00 00 02 00 10 00 00 00 10 00 02 00 00 00 00 00"),
        (0x20001, "", "01 00 02 00 10 00 00 00 11 00 02 00 00 00 00 00"),
        (0x7000_0000, "", "00 00 00 70 10 00 00 00 10 00 00 70 00 00 00 00"),
        (0x7000_0001, "", "01 00 00 70 10 00 00 00 11 00 00 70 00 00 00 00"),
        (0x10690, "{\"usbSpeed\":0,\"wifiSpeed\":0}",
         "90 06 01 00 2c 00 00 00 bc 06 01 00 00 00 00 00 7b 22 75 73 62 53 70 65 65 64 22 3a 30 2c 22 77 69 66 69 53 70 65 65 64 22 3a 30 7d"),
        (0x10691, "", "91 06 01 00 10 00 00 00 81 06 01 00 00 00 00 00"),
        (0x103E0, "{\"client_set\":\"easy_conn\",\"sn\":\"DSXXZMHNFV3DEXEBB3PZ2\"}",
         "e0 03 01 00 47 00 00 00 a7 03 01 00 00 00 00 00 7b 22 63 6c 69 65 6e 74 5f 73 65 74 22 3a 22 65 61 73 79 5f 63 6f 6e 6e 22 2c 22 73 6e 22 3a 22 44 53 58 58 5a 4d 48 4e 46 56 33 44 45 58 45 42 42 33 50 5a 32 22 7d"),
        (0x103E1, "", "e1 03 01 00 10 00 00 00 f1 03 01 00 00 00 00 00"),
        (0x201C0, "{\"isOk\":true,\"errCode\":0,\"errMsg\":\"\",\"id\":\"DSXXZMHNFV3DEXEBB3PZ2\",\"client_set\":\"easy_conn\"}",
         "c0 01 02 00 6b 00 00 00 ab 01 02 00 00 00 00 00 7b 22 69 73 4f 6b 22 3a 74 72 75 65 2c 22 65 72 72 43 6f 64 65 22 3a 30 2c 22 65 72 72 4d 73 67 22 3a 22 22 2c 22 69 64 22 3a 22 44 53 58 58 5a 4d 48 4e 46 56 33 44 45 58 45 42 42 33 50 5a 32 22 2c 22 63 6c 69 65 6e 74 5f 73 65 74 22 3a 22 65 61 73 79 5f 63 6f 6e 6e 22 7d"),
        (0x201C1, "", "c1 01 02 00 10 00 00 00 d1 01 02 00 00 00 00 00"),
        (0x10450, "", "50 04 01 00 10 00 00 00 40 04 01 00 00 00 00 00"),
        (0x10451, "", "51 04 01 00 10 00 00 00 41 04 01 00 00 00 00 00"),
        (0x103A1, "", "a1 03 01 00 10 00 00 00 b1 03 01 00 00 00 00 00"),
        (0x10781, "", "81 07 01 00 10 00 00 00 91 07 01 00 00 00 00 00"),
    ]

    func testEncodeMatchesKotlinVectors() {
        for v in vectors {
            XCTAssertEqual(PxcFrame(cmd: v.cmd, text: v.payload).encoded(), linkHex(v.hex), PxcCmd.hex(v.cmd))
        }
    }

    func testDecodeRoundTripsVectors() throws {
        for v in vectors {
            let bytes = linkHex(v.hex)
            let decoded = try XCTUnwrap(try PxcFrame.decode(bytes))
            XCTAssertEqual(decoded.consumed, bytes.count)
            XCTAssertEqual(decoded.frame.cmd, v.cmd)
            XCTAssertEqual(decoded.frame.payloadText, v.payload)
        }
    }

    func testProbeFrameIs86BytesWithMagic0x70000046() {
        let bytes = PxcProbe.frameBytes
        XCTAssertEqual(bytes.count, 86)
        XCTAssertEqual(bytes, linkHex("""
            10 00 00 70 56 00 00 00 46 00 00 70 00 00 00 00
            7b 22 70 68 6f 6e 65 54 79 70 65 22 3a 22 41 6e
            64 72 6f 69 64 22 2c 22 70 61 63 6b 61 67 65 4e
            61 6d 65 22 3a 22 63 6f 6d 2e 63 66 6d 6f 74 6f
            2e 63 66 6d 6f 74 6f 69 6e 74 65 72 6e 61 74 69
            6f 6e 61 6c 22 7d
            """))
        XCTAssertEqual(PxcProbe.frame.magic, 0x7000_0046)
        XCTAssertEqual(PxcProbe.frame.totalLength, 86)
        XCTAssertEqual(PxcProbe.payloadJSON.utf8.count, 70)
    }

    func testHeaderFields() {
        let f = PxcFrame(cmd: 0x10690, text: "{\"usbSpeed\":0,\"wifiSpeed\":0}")
        XCTAssertEqual(f.totalLength, 44)
        XCTAssertEqual(f.magic, 0x106BC)
        XCTAssertEqual(f.cmdHex, "0x10690")
    }

    // MARK: Rejections

    func testBadMagicIsRejected() {
        // control-plane.md §2.3 NEGATIVE: 0x10000 ^ 0x10 = 0x10010, magic says 0x10011.
        let bad = linkHex("00 00 01 00 10 00 00 00 11 00 01 00 00 00 00 00")
        XCTAssertThrowsError(try PxcFrame.decode(bad)) { e in
            XCTAssertEqual(e as? PxcFrameError, .badMagic(cmd: 0x10000, totalLength: 0x10, magic: 0x10011))
        }
        XCTAssertEqual(PxcFrameError.badMagic(cmd: 0x10000, totalLength: 16, magic: 0x10011).description,
                       "bad magic: cmd=65536 len=16 magic=65553")
    }

    func testPayloadAboveOneMiBIsRejected() {
        let total = UInt32(16 + PxcFrame.maxPayloadSize + 1)
        var w = ByteWriter()
        w.u32le(0x10010)
        w.u32le(total)
        w.u32le(0x10010 ^ total)
        w.u32le(0)
        XCTAssertThrowsError(try PxcFrame.parseHeader(w.bytes)) { e in
            XCTAssertEqual(e as? PxcFrameError, .payloadTooLarge(PxcFrame.maxPayloadSize + 1))
        }
        // Exactly 1 MiB is still accepted.
        var ok = ByteWriter()
        let total2 = UInt32(16 + PxcFrame.maxPayloadSize)
        ok.u32le(0x10010)
        ok.u32le(total2)
        ok.u32le(0x10010 ^ total2)
        ok.u32le(0)
        XCTAssertEqual(try PxcFrame.parseHeader(ok.bytes).payloadLength, PxcFrame.maxPayloadSize)
    }

    func testUndersizedTotalLenWithMatchingMagicIsAcceptedAsEmpty() throws {
        // Android: payloadLen = max(totalLen - 16, 0), even for a negative totalLen.
        for total: UInt32 in [0, 8, 15, 0xFFFF_FFF0] {
            var w = ByteWriter()
            w.u32le(0x10750)
            w.u32le(total)
            w.u32le(0x10750 ^ total)
            w.u32le(0xDEAD_BEEF) // reserved bytes are not validated
            let h = try PxcFrame.parseHeader(w.bytes)
            XCTAssertEqual(h.payloadLength, 0)
            XCTAssertTrue(h.isUndersized)
            let decoded = try XCTUnwrap(try PxcFrame.decode(w.data))
            XCTAssertEqual(decoded.frame, PxcFrame(cmd: 0x10750))
        }
    }

    func testDecodeNeedsMoreBytes() throws {
        let full = PxcFrame(cmd: 0x10010, text: "{\"a\":1}").encoded()
        XCTAssertNil(try PxcFrame.decode(full.prefix(10)))
        XCTAssertNil(try PxcFrame.decode(full.prefix(full.count - 1)))
        XCTAssertNotNil(try PxcFrame.decode(full))
    }

    // MARK: Streaming decoder

    func testStreamingDecoderHandlesByteByByteChunks() throws {
        let frames = [PxcFrame(cmd: 0x10000), PxcFrame(cmd: 0x10010, text: "{\"HUID\":\"X\"}"), PxcFrame(cmd: 0x7000_0000)]
        let wire = frames.reduce(Data()) { $0 + $1.encoded() }
        var decoder = PxcFrameDecoder()
        var out: [PxcFrame] = []
        for b in wire {
            decoder.append(Data([b]))
            out += try decoder.drain()
        }
        XCTAssertEqual(out, frames)
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testStreamingDecoderHandlesManyFramesInOneChunkAndSplitPayloads() throws {
        let a = PxcFrame(cmd: 0x10690, text: LinkDashSamples.querySpeed)
        let b = PxcFrame(cmd: 0x103E0, text: LinkDashSamples.checkSn)
        let wire = a.encoded() + b.encoded()
        var decoder = PxcFrameDecoder()
        decoder.append(wire.prefix(20)) // header of a + 4 payload bytes
        XCTAssertNil(try decoder.next())
        decoder.append(wire.dropFirst(20))
        XCTAssertEqual(try decoder.drain(), [a, b])
    }

    func testStreamingDecoderIsPoisonedByBadMagic() {
        var decoder = PxcFrameDecoder()
        decoder.append(linkHex("00 00 01 00 10 00 00 00 11 00 01 00 00 00 00 00"))
        XCTAssertThrowsError(try decoder.next())
        decoder.append(PxcFrame(cmd: 0x10000).encoded())
        XCTAssertThrowsError(try decoder.next()) // the connection must be closed
    }

    func testStreamingDecoderRejectsOversizedPayloadBeforeBuffering() {
        var decoder = PxcFrameDecoder(maxPayloadSize: 64)
        var w = ByteWriter()
        w.u32le(0x10010)
        w.u32le(16 + 65)
        w.u32le(0x10010 ^ (16 + 65))
        w.u32le(0)
        decoder.append(w.data)
        XCTAssertThrowsError(try decoder.next()) { e in XCTAssertEqual(e as? PxcFrameError, .payloadTooLarge(65)) }
    }

    // MARK: Stream reading

    func testReadFromStream() async throws {
        let (a, b) = LinkMemoryStream.pair(aHost: "p", aPort: 10922, bHost: "d", bPort: 5000)
        let frame = PxcFrame(cmd: 0x10010, text: LinkDashSamples.cfdl16ClientInfo)
        try await b.write(frame.encoded() + PxcFrame(cmd: 0x10690).encoded())
        let r1 = try await PxcFrame.read(from: a)
        let r2 = try await PxcFrame.read(from: a)
        XCTAssertEqual(r1, frame)
        XCTAssertEqual(r2.cmd, 0x10690)
    }

    func testReadFromStreamEOFIsClosedAndShortPayloadIsAFrameError() async throws {
        let (a, b) = LinkMemoryStream.pair(aHost: "p", aPort: 10922, bHost: "d", bPort: 5000)
        b.close()
        do {
            _ = try await PxcFrame.read(from: a)
            XCTFail("expected closed")
        } catch {
            XCTAssertEqual(error as? TransportError, .closed)
        }
        let (c, d) = LinkMemoryStream.pair(aHost: "p", aPort: 10922, bHost: "d", bPort: 5001)
        let full = PxcFrame(cmd: 0x10010, text: "{\"HUID\":\"6GUV\"}").encoded()
        try await d.write(full.prefix(full.count - 3))
        d.close()
        do {
            _ = try await PxcFrame.read(from: c)
            XCTFail("expected short payload")
        } catch {
            XCTAssertEqual(error as? PxcFrameError, .shortPayload(expected: full.count - 16))
        }
    }

    // MARK: Command catalogue

    func testCommandConstantsAndNames() {
        XCTAssertEqual(PxcCmd.channelCarCtrl, 65536)
        XCTAssertEqual(PxcCmd.channelCarData, 131_072)
        XCTAssertEqual(PxcCmd.clientInfo, 65552)
        XCTAssertEqual(PxcCmd.screenTouch, 196_672)
        XCTAssertEqual(PxcCmd.rvInfo, 1_610_809_424)      // Android decimal literal
        XCTAssertEqual(PxcCmd.startOverlay, 262_224)      // Android decimal literal
        XCTAssertEqual(PxcCmd.remoteAuthResult, 131_088)
        XCTAssertEqual(PxcCmd.screenEvent, 262_160)
        XCTAssertEqual(PxcCmd.name(of: 0x10780), "LOG_REPORT (CFDL26)")
        XCTAssertEqual(PxcCmd.name(of: 0x103A0), "OTA_FTP_INFO (CFDL26)")
        XCTAssertEqual(PxcCmd.name(of: 0x10020), "MEDIA_FEATURE_CFG (CFDL26)")
        XCTAssertEqual(PxcCmd.name(of: 0x104A0), "SOCK_SERVER_INFO")
        XCTAssertEqual(PxcCmd.name(of: 0x30040), "SCREEN_TOUCH")
        XCTAssertEqual(PxcCmd.name(of: 0x10010), "CLIENT_INFO (PXC)")
        XCTAssertEqual(PxcCmd.name(of: 0x0108_0001), "CHANNEL_MCULITE_CTRL_ACK")
        XCTAssertEqual(PxcCmd.name(of: 0x10750), "?")
        XCTAssertEqual(PxcCmd.reply(to: 0x10460), 0x10461)
        XCTAssertEqual(PxcCmd.reply(to: 0xFFFF_FFFF), 0) // wraps like a Java Int
        XCTAssertEqual(PxcCmd.hex(0x7000_0011), "0x70000011")
    }

    // MARK: Probe accept rule

    func testProbeAcceptRule() throws {
        let accept = try XCTUnwrap(try PxcFrame.decode(LinkFakeDash.acceptBytes)).frame
        let reject = try XCTUnwrap(try PxcFrame.decode(LinkFakeDash.rejectBytes)).frame
        XCTAssertTrue(PxcProbe.isAccepted(accept))
        XCTAssertFalse(PxcProbe.isAccepted(reject))
        XCTAssertEqual(reject.magic, 0x7000_0031)
        XCTAssertFalse(PxcProbe.isAccepted(PxcFrame(cmd: 0x7000_0010, text: "{\"status\":true}"))) // wrong cmd
        XCTAssertTrue(PxcProbe.isAccepted(PxcFrame(cmd: 0x7000_0011, text: "true"))) // substring rule
    }
}
