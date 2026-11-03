// SPDX-License-Identifier: AGPL-3.0-or-later
// CONTRACT FILE — shared by the link (OpenCfMotoCore/Link), the dash projection engine and the
// ReplayKit mirror (OpenCfMotoApple). See docs/spec/media-video.md.

import Foundation

/// The video canvas negotiated by REQ_RV_CONFIG_CAPTURE (16) → RLY 17.
/// `width`/`height` are the encoded size = requested size rounded DOWN to a multiple of 16
/// (`& 0xFFF0`, never overridden by any profile): 800×386 → 800×384 (CFDL16), 800×951 → 800×944
/// (CFDL26), 1280×576 (800MT). The encoder must produce exactly this size.
public struct VideoCanvas: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
    public var width: Int
    public var height: Int
    /// deviceWidth/deviceHeight exactly as requested by the dash.
    public var requestedWidth: Int
    public var requestedHeight: Int
    /// wantFps from REQ 16 (informational; Android only logs it).
    public var requestedFps: Int?

    public init(width: Int, height: Int, requestedWidth: Int? = nil, requestedHeight: Int? = nil, requestedFps: Int? = nil) {
        self.width = width
        self.height = height
        self.requestedWidth = requestedWidth ?? width
        self.requestedHeight = requestedHeight ?? height
        self.requestedFps = requestedFps
    }

    /// Canvas for a dash request, applying the `& 0xFFF0` rounding.
    public static func rounded(requestedWidth w: Int, requestedHeight h: Int, requestedFps: Int? = nil) -> VideoCanvas {
        VideoCanvas(width: w & 0xFFF0, height: h & 0xFFF0, requestedWidth: w, requestedHeight: h, requestedFps: requestedFps)
    }

    /// Android's default before any REQ 16 arrives.
    public static let defaultLandscape = VideoCanvas(width: 800, height: 384, requestedWidth: 800, requestedHeight: 386)

    public var isPortrait: Bool { height > width }
    public var aspect: Double { height == 0 ? 1 : Double(width) / Double(height) }
    public var description: String { "\(width)x\(height) (req \(requestedWidth)x\(requestedHeight))" }
}

/// One H.264 access unit ready for the wire (see media-video.md "frame wire format").
public struct EncodedFrame: Sendable, Equatable {
    /// Annex-B access unit with 4-byte start codes. Keyframes carry SPS + PPS in front of the IDR
    /// slice (SPS/PPS are prepended to EVERY keyframe). No AUD/SEI/filler required.
    public var accessUnit: Data
    public var isKeyframe: Bool
    /// Seconds (monotonic), informational.
    public var presentationTime: TimeInterval
    /// Monotonic per-encoder sequence number.
    public var sequence: UInt64
    /// ADDITION (locked iPhone, Phase 0, P0-6): which encoder instance produced this access unit,
    /// stamped by the dash projection engine: 0 = not stamped (every other producer), 1 = the
    /// pre-encoded hold IDRs, then 2, 3, … one per live encoder instance of the engine (never reused).
    /// Diagnostics only: never written to the wire (`wireBytes`) or to the wire dump.
    public var encoderTag: UInt32

    public init(accessUnit: Data, isKeyframe: Bool, presentationTime: TimeInterval = 0, sequence: UInt64 = 0,
                encoderTag: UInt32 = 0) {
        self.accessUnit = accessUnit
        self.isKeyframe = isKeyframe
        self.presentationTime = presentationTime
        self.sequence = sequence
        self.encoderTag = encoderTag
    }

    /// Exact bytes for one REQ_RV_DATA_NEXT (114) answer on :10920:
    /// `[size: Int32 LE][Annex-B access unit]` — no ReqBase header, no terminator.
    public var wireBytes: Data {
        var w = ByteWriter(capacity: 4 + accessUnit.count)
        w.i32le(Int32(accessUnit.count))
        w.append(accessUnit)
        return w.data
    }
}

/// Encoder settings derived from the bike profile + power mode + adaptive policy.
public struct EncoderParameters: Sendable, Equatable, Codable {
    /// Average (CBR target) bitrate in bits/s.
    public var bitrate: Int
    /// Frame-rate cap (frames rendered/encoded per second).
    public var frameRate: Int
    /// IDR interval in seconds (1 s default, Morini 2 s).
    public var keyframeIntervalSeconds: Double
    /// Force H.264 Baseline@3.1 (all profiles except Morini).
    public var forceBaseline: Bool
    /// Re-submit the last picture if nothing was encoded for this long (VT has no
    /// KEY_REPEAT_PREVIOUS_FRAME_AFTER; Android uses 0.9 s).
    public var repeatLastFrameAfter: TimeInterval

    public init(bitrate: Int = 2_500_000, frameRate: Int = 24, keyframeIntervalSeconds: Double = 1,
                forceBaseline: Bool = true, repeatLastFrameAfter: TimeInterval = 0.9) {
        self.bitrate = bitrate
        self.frameRate = frameRate
        self.keyframeIntervalSeconds = keyframeIntervalSeconds
        self.forceBaseline = forceBaseline
        self.repeatLastFrameAfter = repeatLastFrameAfter
    }

    public static let `default` = EncoderParameters()
}

/// Supplies encoded frames to the media plane. Implemented by the dash projection engine
/// (own CoreGraphics UI) and the ReplayKit mirror. All methods may be called from any task.
public protocol VideoFrameSource: AnyObject, Sendable {
    /// REQ 16 negotiated (or re-negotiated) the canvas. Create/recreate the encoder at exactly
    /// `canvas.width × canvas.height`.
    func prepare(canvas: VideoCanvas, parameters: EncoderParameters)
    /// REQ_RV_DATA_START (112), called BEFORE the 113 reply: set the keyframe gate, flush queued
    /// frames, force an IDR and encode the current picture immediately.
    func resynchronize()
    /// REQ_RV_DATA_NEXT (114): the next access unit to send. Should return quickly; must return
    /// within `timeout`. Returns nil only if nothing at all could be produced (the link then logs
    /// and sends nothing for this pull — never a zero-size or repeated P-frame).
    func nextFrame(timeout: TimeInterval) async -> EncodedFrame?
    /// The media sockets closed (the dash will re-open them and send 16/112 again).
    func mediaStopped()
}

/// Device thermal level (Android PowerManager thermal status names) — input of AdaptivePolicy.
/// iOS mapping: nominal → none, fair → moderate, serious → severe, critical → critical.
public enum ThermalLevel: Int, Sendable, Codable, Comparable, CaseIterable {
    case none = 0, light, moderate, severe, critical, emergency, shutdown
    public static func < (a: ThermalLevel, b: ThermalLevel) -> Bool { a.rawValue < b.rawValue }
}
