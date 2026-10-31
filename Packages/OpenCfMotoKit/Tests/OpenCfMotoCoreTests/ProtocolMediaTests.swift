// SPDX-License-Identifier: AGPL-3.0-or-later
// Vectors: docs/spec/media-video.md §3.3, §4.2–§4.8, §5.3, §14.2.
import XCTest
@testable import OpenCfMotoCore

final class ProtocolMediaTests: XCTestCase {
    func testRequestHeaderVectors() throws {
        XCTAssertEqual(MediaMessage(cmdType: MediaCmd.reqHeartbeat).encoded(), linkHex("40 00 00 00 00 00 00 00"))
        XCTAssertEqual(MediaMessage(cmdType: MediaCmd.reqDataNext).encoded(), linkHex("72 00 00 00 00 00 00 00"))
        XCTAssertEqual(MediaMessage(cmdType: MediaCmd.reqDataStart).encoded(), linkHex("70 00 00 00 00 00 00 00"))
        XCTAssertEqual(MediaMessage(cmdType: MediaCmd.reqGetVersion).encoded(), linkHex("30 00 00 00 00 00 00 00"))
        XCTAssertEqual(MediaMessage(cmdType: MediaCmd.reqStartH264).encoded(), linkHex("80 00 00 00 00 00 00 00"))
        // REQ 16 header with a CFDL26 204-byte body and a bike token.
        let h = try MediaMessage.parseHeader([0x10, 0x00, 0xCC, 0x00, 0x78, 0x56, 0x34, 0x12])
        XCTAssertEqual(h, MediaMessage.Header(cmdType: 16, cmdLen: 204, token: 0x1234_5678))
    }

    func testHeaderFieldSignedness() throws {
        // cmdType is signed 16-bit, cmdLen unsigned 16-bit (Android getShort & 0xFFFF).
        let h = try MediaMessage.parseHeader([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertEqual(h.cmdType, -1)
        XCTAssertEqual(h.cmdLen, 65535)
        XCTAssertEqual(h.token, -1)
    }

    func testFixedRepliesAreTokenZeroAndExact() {
        XCTAssertEqual(MediaReplies.heartbeat.encoded(), linkHex("41 00 00 00 00 00 00 00"))
        XCTAssertEqual(MediaReplies.getVersion.encoded(), linkHex("31 00 08 00 00 00 00 00 03 00 00 00 01 00 00 00"))
        XCTAssertEqual(MediaReplies.configCaptureExtend.encoded(),
                       linkHex("61 00 0b 00 00 00 00 00 7b 22 73 74 61 74 65 22 3a 30 7d"))
        XCTAssertEqual(MediaReplies.dataStart.encoded(), linkHex("71 00 00 00 00 00 00 00"))
        XCTAssertEqual(MediaReplies.startH264.encoded(), linkHex("81 00 00 00 00 00 00 00"))
    }

    func testConfigCaptureReplyVectors() {
        let cfdl16 = ConfigCaptureRequest(body: LinkDashSamples.configCaptureBody(width: 800, height: 386))
        XCTAssertEqual(cfdl16.reply().encoded(), linkHex("11 00 09 00 00 00 00 00 02 00 00 00 20 03 80 01 00"))
        XCTAssertEqual(cfdl16.canvas, VideoCanvas(width: 800, height: 384, requestedWidth: 800, requestedHeight: 386, requestedFps: 30))

        let cfdl16ext = ConfigCaptureRequest(body: LinkDashSamples.configCaptureBody(width: 800, height: 386, ext: 1))
        XCTAssertEqual(cfdl16ext.reply().encoded(), linkHex("11 00 09 00 00 00 00 00 02 00 00 00 20 03 80 01 01"))

        let huid = String(repeating: "A", count: 171) + "="
        let cfdl26 = ConfigCaptureRequest(body: LinkDashSamples.configCaptureBody(width: 800, height: 951, huid: huid))
        XCTAssertEqual(cfdl26.bodyLength, 204)
        XCTAssertEqual(cfdl26.encryptedHUID, huid)
        XCTAssertEqual(cfdl26.reply().encoded(), linkHex("11 00 09 00 00 00 00 00 02 00 00 00 20 03 b0 03 00"))

        let mt800 = ConfigCaptureRequest(body: LinkDashSamples.configCaptureBody(width: 1280, height: 576))
        XCTAssertEqual(mt800.reply().encoded(), linkHex("11 00 09 00 00 00 00 00 02 00 00 00 00 05 40 02 00"))
        XCTAssertEqual(mt800.canvas.width, 1280)
        XCTAssertEqual(mt800.canvas.height, 576)
    }

    func testWantEncoderZeroIsForcedToH264AndOtherValuesAreEchoed() {
        let zero = ConfigCaptureRequest(body: LinkDashSamples.configCaptureBody(width: 800, height: 386, encoder: 0))
        XCTAssertEqual(zero.replyEncoder, 2)
        XCTAssertEqual(zero.reply().body.prefix(4), linkHex("02 00 00 00"))
        let five = ConfigCaptureRequest(body: LinkDashSamples.configCaptureBody(width: 800, height: 386, encoder: 5))
        XCTAssertEqual(five.reply().body.prefix(4), linkHex("05 00 00 00"))
    }

    func testSyntheticCFDL16RequestParsesEveryField() {
        // media-video.md §4.2 synthetic CFDL16-like body.
        let body = linkHex("20 03 82 01 1e 00 00 00 02 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00")
        let r = ConfigCaptureRequest(body: body)
        XCTAssertEqual(r.deviceWidth, 800)
        XCTAssertEqual(r.deviceHeight, 386)
        XCTAssertEqual(r.wantFps, 30)
        XCTAssertEqual(r.wantEncoder, 2)
        XCTAssertEqual(r.supportCodec, 0)
        XCTAssertEqual(r.minQuality, 0)
        XCTAssertEqual(r.maxQuality, 0)
        XCTAssertEqual(r.bitRate, 0)
        XCTAssertEqual(r.capScreenMode, 0)
        XCTAssertEqual(r.touchMode, 0)
        XCTAssertEqual(r.orientation, 0)
        XCTAssertEqual(r.displayId, 0)
        XCTAssertEqual(r.videoType, 0)
        XCTAssertEqual(r.supportExtendProtocol, 0)
        XCTAssertEqual(r.reserved, 0)
        XCTAssertNil(r.encryptedHUID)
        XCTAssertEqual(r.description, "REQ_CONFIG_CAPTURE w=800 h=386 fps=30 wantEncoder=2 ext=0 len=32")
    }

    func testFieldOffsets() {
        var w = ByteWriter()
        w.u16le(1280); w.u16le(576); w.i32le(25); w.i32le(2); w.i32le(7)
        w.u16le(10); w.u16le(90); w.i32le(2_500_000)
        w.u8(1); w.u8(3); w.u8(4); w.u8(5); w.u8(6); w.u8(0xFF); w.u16le(0xABCD)
        w.append(Data("SIG\0\0".utf8))
        let r = ConfigCaptureRequest(body: w.data)
        XCTAssertEqual(r.supportCodec, 7)
        XCTAssertEqual(r.minQuality, 10)
        XCTAssertEqual(r.maxQuality, 90)
        XCTAssertEqual(r.bitRate, 2_500_000)
        XCTAssertEqual(r.capScreenMode, 1)
        XCTAssertEqual(r.touchMode, 3)
        XCTAssertEqual(r.orientation, 4)
        XCTAssertEqual(r.displayId, 5)
        XCTAssertEqual(r.videoType, 6)
        XCTAssertEqual(r.supportExtendProtocol, 0xFF)
        XCTAssertEqual(r.reserved, 0xABCD)
        XCTAssertEqual(r.encryptedHUID, "SIG")
        XCTAssertTrue(r.description.contains("ext=-1")) // Android logs the signed byte
        XCTAssertEqual(r.reply().body.last, 0xFF)
    }

    func testShortBodiesUseAndroidDefaults() {
        let empty = ConfigCaptureRequest(body: Data())
        XCTAssertEqual(empty.deviceWidth, 0)
        XCTAssertEqual(empty.deviceHeight, 0)
        XCTAssertEqual(empty.wantFps, 0)
        XCTAssertEqual(empty.wantEncoder, 2)
        XCTAssertEqual(empty.supportExtendProtocol, 0)
        XCTAssertFalse(empty.hasUsableSize)
        let widthOnly = ConfigCaptureRequest(body: linkHex("20 03"))
        XCTAssertEqual(widthOnly.deviceWidth, 800)
        XCTAssertEqual(widthOnly.deviceHeight, 0)
        XCTAssertFalse(widthOnly.hasUsableSize)
        let elevenBytes = ConfigCaptureRequest(body: linkHex("20 03 82 01 1e 00 00 00 05 00 00"))
        XCTAssertEqual(elevenBytes.wantEncoder, 2) // < 12 bytes → 2
        XCTAssertEqual(ConfigCaptureRequest(body: linkHex("0f 00 0f 00")).hasUsableSize, false) // 15 & 0xFFF0 = 0
    }

    func testRoundingTable() {
        let table = [386: 384, 951: 944, 576: 576, 400: 400, 460: 448, 750: 736, 712: 704, 544: 544, 512: 512,
                     1024: 1024, 464: 464, 720: 720, 480: 480]
        for (input, expected) in table {
            XCTAssertEqual(VideoCanvas.rounded(requestedWidth: input, requestedHeight: input).width, expected)
            XCTAssertEqual(BikeProfile.legacy.roundCaptureDimensions(width: input, height: input).height, expected)
        }
    }

    func testFrameWireFormatToyAU() {
        // media-video.md §14.2 frame write (toy AU of 30 bytes) and §5.3 P-frame.
        let au = linkHex("00 00 00 01 67 42 00 1f da 01 40 12 69 a8 00 00 00 01 68 ce 0d 88 00 00 00 01 65 88 84 00")
        XCTAssertEqual(EncodedFrame(accessUnit: au, isKeyframe: true).wireBytes,
                       linkHex("1e 00 00 00") + au)
        let p = linkHex("00 00 00 01 41 9a 00 21")
        XCTAssertEqual(EncodedFrame(accessUnit: p, isKeyframe: false).wireBytes, linkHex("08 00 00 00 00 00 00 01 41 9a 00 21"))
    }

    func testDecodeAndReadFromStream() async throws {
        let msg = MediaMessage(cmdType: 16, token: 99, body: LinkDashSamples.configCaptureBody(width: 800, height: 386))
        let wire = msg.encoded()
        XCTAssertNil(try MediaMessage.decode(wire.prefix(7)))
        XCTAssertNil(try MediaMessage.decode(wire.prefix(20)))
        let decoded = try XCTUnwrap(try MediaMessage.decode(wire))
        XCTAssertEqual(decoded.message, msg)
        XCTAssertEqual(decoded.consumed, 40)

        let (a, b) = LinkMemoryStream.pair(aHost: "p", aPort: 10921, bHost: "d", bPort: 1)
        try await b.write(wire + MediaMessage(cmdType: 114).encoded())
        let m1 = try await MediaMessage.read(from: a)
        let m2 = try await MediaMessage.read(from: a)
        XCTAssertEqual(m1, msg)
        XCTAssertEqual(m2.cmdType, 114)
        XCTAssertTrue(m2.body.isEmpty)
        try await b.write(wire.prefix(12))
        b.close()
        do {
            _ = try await MediaMessage.read(from: a)
            XCTFail("expected short body")
        } catch {
            XCTAssertEqual(error as? MediaMessageError, .shortBody(expected: 32))
        }
    }

    func testCommandNames() {
        XCTAssertEqual(MediaCmd.name(of: 16), "REQ_RV_CONFIG_CAPTURE")
        XCTAssertEqual(MediaCmd.name(of: 114), "REQ_RV_DATA_NEXT")
        XCTAssertEqual(MediaCmd.name(of: 7), "?")
    }
}
