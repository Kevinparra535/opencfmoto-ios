// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import OpenCfMotoCore

final class MirrorRelayProtocolTests: XCTestCase {
    private func hex(_ s: String) -> Data { Data(hexString: s)! }

    private let sampleConfig = MirrorRelayConfig(
        canvas: VideoCanvas(width: 800, height: 384, requestedWidth: 800, requestedHeight: 386),
        parameters: .default,
        fit: .fit,
        margins: ScreenMargins(customised: false, top: 22, bottom: 0, left: 0, right: 0))

    // MARK: golden bytes

    func testGoldenKeyframeRequest() {
        XCTAssertEqual(MirrorRelayMessage.keyframeRequest.encoded(), hex("04 00000000"))
    }

    func testGoldenStop() {
        XCTAssertEqual(MirrorRelayMessage.stop(reason: "bye").encoded(), hex("05 03000000 627965"))
    }

    func testGoldenHello() {
        XCTAssertEqual(MirrorRelayMessage.hello(version: 1, agent: "ext").encoded(), hex("01 04000000 01 657874"))
    }

    func testGoldenLog() {
        XCTAssertEqual(MirrorRelayMessage.log(level: .warn, tag: "VT", message: "é").encoded(),
                       hex("06 06000000 02 02 5654 c3a9"))
    }

    func testGoldenFrame() {
        let f = EncodedFrame(accessUnit: hex("00000001 6588"), isKeyframe: true, presentationTime: 0.5, sequence: 1)
        XCTAssertEqual(MirrorRelayMessage.frame(f).encoded(),
                       hex("03 17000000 01 0100000000000000 20a1070000000000 000000016588"))
    }

    func testGoldenConfig() {
        let expectedPayload = hex("""
            01 2003 8001 2003 8201 0000 a0252600 1800 e8030000 84030000 01 01 00 1600 0000 0000 0000
            """)
        XCTAssertEqual(sampleConfig.encoded(), expectedPayload)
        XCTAssertEqual(expectedPayload.count, MirrorRelayConfig.encodedLength)
        XCTAssertEqual(MirrorRelayMessage.config(sampleConfig).encoded(), hex("02 24000000") + expectedPayload)
    }

    // MARK: round trips

    func testRoundTripEveryMessageType() throws {
        let messages: [MirrorRelayMessage] = [
            .hello(version: MirrorRelayProtocol.version, agent: "OpenCfMotoMirror/0.1"),
            .config(sampleConfig),
            .frame(EncodedFrame(accessUnit: Data([0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x68, 0xCE, 0, 0, 0, 1, 0x65, 0x88]),
                                isKeyframe: true, presentationTime: 12.25, sequence: 42)),
            .frame(EncodedFrame(accessUnit: Data([0, 0, 0, 1, 0x41, 0x9A]), isKeyframe: false,
                                presentationTime: 12.291667, sequence: 43)),
            .keyframeRequest,
            .stop(reason: "broadcast finished"),
            .log(level: .error, tag: "MIRROR", message: "VT error -12903 ✓"),
        ]
        for m in messages {
            var d = MirrorRelayDecoder()
            let out = try d.decode(m.encoded())
            XCTAssertEqual(out, [m], "round trip of \(m.type)")
            XCTAssertEqual(d.bufferedByteCount, 0)
        }
    }

    func testConfigRoundTripPreservesAllFields() throws {
        let cfg = MirrorRelayConfig(
            canvas: VideoCanvas(width: 1280, height: 576, requestedWidth: 1280, requestedHeight: 576, requestedFps: 30),
            parameters: EncoderParameters(bitrate: 2_000_000, frameRate: 10, keyframeIntervalSeconds: 2,
                                          forceBaseline: false, repeatLastFrameAfter: 0.9),
            fit: .stretch,
            margins: ScreenMargins(customised: true, top: 1, bottom: 2, left: 3, right: 200))
        XCTAssertEqual(try MirrorRelayConfig(decoding: cfg.encoded()), cfg)
    }

    func testPresentationTimeIsCarriedInMicroseconds() throws {
        let f = EncodedFrame(accessUnit: Data([1]), isKeyframe: false, presentationTime: 1.2345675, sequence: 7)
        var d = MirrorRelayDecoder()
        guard case let .frame(back)? = try d.decode(MirrorRelayMessage.frame(f).encoded()).first else {
            return XCTFail("no frame")
        }
        XCTAssertEqual(back.presentationTime, 1.234568, accuracy: 1e-9)
        XCTAssertEqual(back.sequence, 7)
        XCTAssertEqual(MirrorRelayMessage.micros(-0.25), -250_000)
        XCTAssertEqual(MirrorRelayMessage.micros(.nan), 0)
    }

    func testEmptyAccessUnitRoundTrips() throws {
        let f = EncodedFrame(accessUnit: Data(), isKeyframe: false, presentationTime: 0, sequence: 0)
        var d = MirrorRelayDecoder()
        XCTAssertEqual(try d.decode(MirrorRelayMessage.frame(f).encoded()), [.frame(f)])
    }

    // MARK: streaming

    private var stream: [MirrorRelayMessage] {
        [.hello(version: 1, agent: "x"), .config(sampleConfig),
         .frame(EncodedFrame(accessUnit: Data(repeating: 0xAB, count: 300), isKeyframe: true, presentationTime: 1, sequence: 1)),
         .keyframeRequest,
         .frame(EncodedFrame(accessUnit: Data([0, 0, 0, 1, 0x41]), isKeyframe: false, presentationTime: 1.04, sequence: 2)),
         .stop(reason: "")]
    }

    func testDecodesByteByByte() throws {
        let all = stream.reduce(Data()) { $0 + $1.encoded() }
        var d = MirrorRelayDecoder()
        var out: [MirrorRelayMessage] = []
        for b in all { out += try d.decode(Data([b])) }
        XCTAssertEqual(out, stream)
        XCTAssertEqual(d.bufferedByteCount, 0)
    }

    func testDecodesArbitraryChunks() throws {
        let all = [UInt8](stream.reduce(Data()) { $0 + $1.encoded() })
        for chunk in [2, 3, 5, 7, 16, 64, 1000] {
            var d = MirrorRelayDecoder()
            var out: [MirrorRelayMessage] = []
            var i = 0
            while i < all.count {
                let end = min(all.count, i + chunk)
                out += try d.decode(Data(all[i ..< end]))
                i = end
            }
            XCTAssertEqual(out, stream, "chunk \(chunk)")
        }
    }

    func testPartialMessageStaysBuffered() throws {
        let enc = MirrorRelayMessage.stop(reason: "partial").encoded()
        var d = MirrorRelayDecoder()
        XCTAssertEqual(try d.decode(enc.prefix(3)), [])
        XCTAssertEqual(d.bufferedByteCount, 3)
        XCTAssertEqual(try d.decode(enc.dropFirst(3)), [.stop(reason: "partial")])
        XCTAssertEqual(d.bufferedByteCount, 0)
    }

    func testCompactionWithManyLargeMessages() throws {
        var frames: [MirrorRelayMessage] = []
        var joined = Data()
        for i in 0 ..< 40 {
            let au = Data(repeating: UInt8(i), count: 10_000)
            let pts = Double(i) * 0.125 // exact in µs (the relay carries microseconds)
            let f = EncodedFrame(accessUnit: au, isKeyframe: i % 10 == 0, presentationTime: pts, sequence: UInt64(i))
            let m = MirrorRelayMessage.frame(f)
            frames.append(m)
            joined.append(m.encoded())
        }
        let all = [UInt8](joined)
        var d = MirrorRelayDecoder()
        var out: [MirrorRelayMessage] = []
        var i = 0
        while i < all.count { // uneven chunks so messages straddle reads
            let end = min(all.count, i + 7_919)
            out += try d.decode(Data(all[i ..< end]))
            i = end
        }
        XCTAssertEqual(out.count, 40)
        XCTAssertEqual(out, frames)
        XCTAssertEqual(d.bufferedByteCount, 0)
    }

    // MARK: errors and forward compatibility

    func testOversizedPayloadThrows() {
        var d = MirrorRelayDecoder(maxPayloadLength: 1024)
        XCTAssertThrowsError(try d.decode(hex("03 01040000"))) { err in
            XCTAssertEqual(err as? MirrorRelayProtocolError, .payloadTooLarge(type: 3, length: 1025))
        }
    }

    func testUnknownTypeIsSkipped() throws {
        var d = MirrorRelayDecoder()
        let out = try d.decode(hex("7f 02000000 aabb") + MirrorRelayMessage.keyframeRequest.encoded())
        XCTAssertEqual(out, [.keyframeRequest])
        XCTAssertEqual(d.skippedUnknownMessages, 1)
    }

    func testTruncatedConfigThrows() {
        var d = MirrorRelayDecoder()
        XCTAssertThrowsError(try d.decode(MirrorRelayMessage.envelope(type: 2, payload: [1, 2, 3]))) { err in
            XCTAssertEqual(err as? MirrorRelayProtocolError, .truncatedPayload(type: 2, expected: 36, actual: 3))
        }
    }

    func testTruncatedFrameThrows() {
        var d = MirrorRelayDecoder()
        XCTAssertThrowsError(try d.decode(MirrorRelayMessage.envelope(type: 3, payload: [1, 0, 0]))) { err in
            XCTAssertEqual(err as? MirrorRelayProtocolError, .truncatedPayload(type: 3, expected: 17, actual: 3))
        }
    }

    func testTruncatedLogAndHelloThrow() {
        var d1 = MirrorRelayDecoder()
        XCTAssertThrowsError(try d1.decode(MirrorRelayMessage.envelope(type: 1, payload: [])))
        var d2 = MirrorRelayDecoder()
        XCTAssertThrowsError(try d2.decode(MirrorRelayMessage.envelope(type: 6, payload: [1, 5, 0x41])))
    }

    func testConfigAcceptsLongerPayloadOfNewerVersion() throws {
        var payload = [UInt8](sampleConfig.encoded())
        payload[0] = 2
        payload += [0xFF, 0xEE, 0xDD]
        let decoded = try MirrorRelayConfig(decoding: Data(payload))
        XCTAssertEqual(decoded, sampleConfig)
    }

    func testConfigClampsOutOfRangeValues() throws {
        var cfg = sampleConfig
        cfg.canvas.width = 70_000
        cfg.parameters.bitrate = -5
        cfg.parameters.keyframeIntervalSeconds = -1
        let back = try MirrorRelayConfig(decoding: cfg.encoded())
        XCTAssertEqual(back.canvas.width, 65_535)
        XCTAssertEqual(back.parameters.bitrate, 0)
        XCTAssertEqual(back.parameters.keyframeIntervalSeconds, 0)
    }

    func testFitCodes() {
        XCTAssertEqual(MirrorRelayConfig.fitCode(.fill), 0)
        XCTAssertEqual(MirrorRelayConfig.fitCode(.fit), 1)
        XCTAssertEqual(MirrorRelayConfig.fitCode(.stretch), 2)
        XCTAssertEqual(MirrorRelayConfig.fit(code: 0), .fill)
        XCTAssertEqual(MirrorRelayConfig.fit(code: 1), .fit)
        XCTAssertEqual(MirrorRelayConfig.fit(code: 2), .stretch)
        XCTAssertEqual(MirrorRelayConfig.fit(code: 99), .fit)
    }

    func testLogTagIsTruncatedAtCharacterBoundary() throws {
        XCTAssertEqual(MirrorRelayMessage.truncatedUTF8(String(repeating: "a", count: 300), maxBytes: 255).count, 255)
        XCTAssertEqual(MirrorRelayMessage.truncatedUTF8(String(repeating: "é", count: 200), maxBytes: 255).count, 254)
        var d = MirrorRelayDecoder()
        let out = try d.decode(MirrorRelayMessage.log(level: .debug, tag: String(repeating: "é", count: 200), message: "m").encoded())
        guard case let .log(level, tag, message)? = out.first else { return XCTFail("no log") }
        XCTAssertEqual(level, .debug)
        XCTAssertEqual(tag.count, 127)
        XCTAssertEqual(message, "m")
    }

    func testUnknownLogLevelFallsBackToInfo() throws {
        var d = MirrorRelayDecoder()
        let out = try d.decode(MirrorRelayMessage.envelope(type: 6, payload: [9, 1, 0x54, 0x6D]))
        XCTAssertEqual(out, [.log(level: .info, tag: "T", message: "m")])
    }
}
