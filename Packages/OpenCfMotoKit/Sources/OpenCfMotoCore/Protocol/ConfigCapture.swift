// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) EasyConnProber.kt (handleMediaReq case 16)
//
// REQ_RV_CONFIG_CAPTURE (16) → RLY_RV_CONFIG_CAPTURE (17) — canvas negotiation
// (docs/spec/media-video.md §4.2). The phone replies with the requested size rounded DOWN to a
// multiple of 16 and must encode exactly that size.

import Foundation

/// Parsed REQ 16 body. Every documented field is decoded (Android only reads w, h, fps, encoder
/// and the ext byte; the rest is logged to learn what dashes send).
public struct ConfigCaptureRequest: Sendable, Equatable, CustomStringConvertible {
    /// `deviceWidth` (u16 @0), 0 if the body is shorter than 2 bytes.
    public var deviceWidth: Int
    /// `deviceHeight` (u16 @2), 0 if shorter than 4 bytes.
    public var deviceHeight: Int
    /// `wantFps` (i32 @4), 0 if shorter than 8 bytes (logged only).
    public var wantFps: Int32
    /// `wantEncoder` (i32 @8), 2 (= H.264) if shorter than 12 bytes.
    public var wantEncoder: Int32
    /// `supportCodec` (i32 @12).
    public var supportCodec: Int32?
    /// `minQuality` (u16 @16).
    public var minQuality: UInt16?
    /// `maxQuality` (u16 @18).
    public var maxQuality: UInt16?
    /// `bitRate` (i32 @20).
    public var bitRate: Int32?
    /// `capScreenMode` (u8 @24).
    public var capScreenMode: UInt8?
    /// `touchMode` (u8 @25) — undocumented; logged for research (input-controls.md §2.5).
    public var touchMode: UInt8?
    /// `orientation` (u8 @26).
    public var orientation: UInt8?
    /// `displayId` (u8 @27).
    public var displayId: UInt8?
    /// `videoType` (u8 @28).
    public var videoType: UInt8?
    /// `supportExtendProtocol` (u8 @29), echoed in RLY 17; 0 if shorter than 30 bytes.
    public var supportExtendProtocol: UInt8
    /// Reserved u16 @30.
    public var reserved: UInt16?
    /// `encryptedHUID` text @32… (CFDL26 sends 172 base64 chars); trailing NULs trimmed.
    public var encryptedHUID: String?
    /// Raw body length.
    public var bodyLength: Int

    public init(body: Data) {
        let b = [UInt8](body)
        let r = ByteReader(b)
        func u16(_ at: Int) -> UInt16? {
            guard at + 2 <= b.count else { return nil }
            return UInt16(b[at]) | (UInt16(b[at + 1]) << 8)
        }
        func i32(_ at: Int) -> Int32? { r.peekI32le(at: at) }
        func u8(_ at: Int) -> UInt8? { at < b.count ? b[at] : nil }
        deviceWidth = Int(u16(0) ?? 0)
        deviceHeight = Int(u16(2) ?? 0)
        wantFps = i32(4) ?? 0
        wantEncoder = b.count >= 12 ? (i32(8) ?? 2) : 2
        supportCodec = i32(12)
        minQuality = u16(16)
        maxQuality = u16(18)
        bitRate = i32(20)
        capScreenMode = u8(24)
        touchMode = u8(25)
        orientation = u8(26)
        displayId = u8(27)
        videoType = u8(28)
        supportExtendProtocol = b.count >= 30 ? b[29] : 0
        reserved = u16(30)
        if b.count > 32 {
            var tail = Array(b[32...])
            while let last = tail.last, last == 0 { tail.removeLast() }
            encryptedHUID = tail.isEmpty ? nil : String(decoding: tail, as: UTF8.self)
        } else {
            encryptedHUID = nil
        }
        bodyLength = b.count
    }

    /// The negotiated canvas: request rounded down to multiples of 16 (`& 0xFFF0`), raw size kept.
    public var canvas: VideoCanvas {
        VideoCanvas.rounded(requestedWidth: deviceWidth, requestedHeight: deviceHeight,
                            requestedFps: wantFps > 0 ? Int(wantFps) : nil)
    }

    /// True when both rounded dimensions are non-zero (Android would reply 0 otherwise; iOS keeps the
    /// previous canvas instead, media-video.md §15.1).
    public var hasUsableSize: Bool { (deviceWidth & 0xFFF0) > 0 && (deviceHeight & 0xFFF0) > 0 }

    /// The encoder id echoed in RLY 17 (`wantEncoder == 0 ? 2 : wantEncoder`).
    public var replyEncoder: Int32 { wantEncoder == 0 ? 2 : wantEncoder }

    /// RLY 17 for this request.
    public func reply() -> MediaMessage {
        ConfigCaptureReply(encoder: replyEncoder, width: deviceWidth & 0xFFF0, height: deviceHeight & 0xFFF0,
                           supportExtendProtocol: supportExtendProtocol).message
    }

    /// Android log line `REQ_CONFIG_CAPTURE w=… h=… fps=… wantEncoder=… ext=… len=…`.
    public var description: String {
        "REQ_CONFIG_CAPTURE w=\(deviceWidth) h=\(deviceHeight) fps=\(wantFps) wantEncoder=\(wantEncoder) " +
            "ext=\(Int8(bitPattern: supportExtendProtocol)) len=\(bodyLength)"
    }

    /// The fields Android ignores (for research logs).
    public var extraFieldsDescription: String {
        func s<T>(_ v: T?) -> String { v.map { "\($0)" } ?? "-" }
        return "codec=\(s(supportCodec)) minQ=\(s(minQuality)) maxQ=\(s(maxQuality)) bitRate=\(s(bitRate)) " +
            "capScreenMode=\(s(capScreenMode)) touchMode=\(s(touchMode)) orientation=\(s(orientation)) " +
            "displayId=\(s(displayId)) videoType=\(s(videoType)) reserved=\(s(reserved)) " +
            "encryptedHUID=\(encryptedHUID.map { "\($0.count) chars" } ?? "-")"
    }
}

/// RLY_RV_CONFIG_CAPTURE (17) body: `i32 encoder | i16 width | i16 height | u8 ext` (9 bytes).
public struct ConfigCaptureReply: Sendable, Equatable {
    public var encoder: Int32
    public var width: Int
    public var height: Int
    public var supportExtendProtocol: UInt8

    public init(encoder: Int32, width: Int, height: Int, supportExtendProtocol: UInt8) {
        self.encoder = encoder
        self.width = width
        self.height = height
        self.supportExtendProtocol = supportExtendProtocol
    }

    /// Reply for an explicit canvas (used when a request had no usable size).
    public init(canvas: VideoCanvas, encoder: Int32 = 2, supportExtendProtocol: UInt8 = 0) {
        self.init(encoder: encoder, width: canvas.width, height: canvas.height, supportExtendProtocol: supportExtendProtocol)
    }

    public var body: Data {
        var w = ByteWriter(capacity: 9)
        w.i32le(encoder)
        w.i16le(Int16(truncatingIfNeeded: width))
        w.i16le(Int16(truncatingIfNeeded: height))
        w.u8(supportExtendProtocol)
        return w.data
    }

    /// The full ReqBase message (17 wire bytes).
    public var message: MediaMessage { .reply(MediaCmd.rlyConfigCapture, body: body) }
}
