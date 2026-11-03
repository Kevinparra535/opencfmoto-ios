// SPDX-License-Identifier: AGPL-3.0-or-later
// Locked iPhone, Phase 0 (design §3.2, P0-3): the encoder seam of `DashProjectionEngine`. The engine
// talks to every H.264 encoder through `DashVideoEncoder`: the VideoToolbox hardware session in the
// foreground, a VideoToolbox software session (rung 1) and, in Phase 1, a bundled CPU encoder (rung 2,
// injected through `DashProjectionEngine.cpuEncoderFactory`) in the background. `H264Encoder` conforms.
//
// The kind and failure types are platform-neutral (compiled and unit-tested on Linux); the protocol
// itself needs CoreVideo.

import Foundation
import OpenCfMotoCore

/// Which encoder a `DashVideoEncoder` is. `description` is the encoder name used in every log line
/// (`[switch] vt-hw → vt-sw`, `enc=vt-sw`, `(encoder vt-sw, …)`) and in the stats (`encoder`).
public enum DashEncoderKind: Sendable, Equatable, Hashable, CustomStringConvertible {
    /// VideoToolbox, hardware accelerated: the foreground encoder (`vt-hw`).
    case videoToolboxHardware
    /// VideoToolbox with `EnableHardwareAcceleratedVideoEncoder = false`, or a non-hardware
    /// `kVTVideoEncoderSpecification_EncoderID` (`vt-sw`).
    case videoToolboxSoftware
    /// A CPU encoder in the app (`cpu-<backend>`: `cpu-minih264`, `cpu-openh264`, `cpu-swift`).
    case cpu(backend: String)

    public var description: String {
        switch self {
        case .videoToolboxHardware: return "vt-hw"
        case .videoToolboxSoftware: return "vt-sw"
        case let .cpu(backend): return backend.isEmpty ? "cpu" : "cpu-\(backend)"
        }
    }

    /// The background rung this kind serves (nil for the foreground hardware encoder).
    public var backgroundRung: BackgroundRung? {
        switch self {
        case .videoToolboxHardware: return nil
        case .videoToolboxSoftware: return .videoToolboxSoftware
        case .cpu: return .cpu
        }
    }
}

/// A failure reported through `DashVideoEncoder.onFailure` (VideoToolbox: the same events as
/// `H264Encoder.onError`).
public struct DashEncoderFailure: Error, Sendable, Equatable, CustomStringConvertible {
    /// OSStatus (VideoToolbox) or backend error code; nil when there is none.
    public var status: Int32?
    /// The session / encoder is gone (VideoToolbox: `H264EncoderStatus.requiresSessionRecreation`).
    /// VideoToolbox re-creates it by itself; for a CPU encoder it means demote at once.
    public var requiresRecreation: Bool
    /// Human-readable, e.g. `VTCompressionSessionEncodeFrame failed: kVTInvalidSessionErr`.
    public var message: String

    public init(status: Int32? = nil, requiresRecreation: Bool = false, message: String) {
        self.status = status
        self.requiresRecreation = requiresRecreation
        self.message = message
    }

    public var description: String { message }
}

#if canImport(CoreVideo)
import CoreVideo

/// Every member `DashProjectionEngine` uses. Called on the engine's serial render queue, except the
/// read-only properties (any thread). `onFrame` may be called synchronously from inside `encode`
/// (a CPU encoder), or later on another thread (VideoToolbox); it is never called with an empty access
/// unit, and the first output after `configure` is an IDR with SPS + PPS in front.
public protocol DashVideoEncoder: AnyObject, Sendable {
    var kind: DashEncoderKind { get }
    /// Log label, e.g. `own`, `own-sw-pre`, `own-sw`, `own-sw-id`, `mirror`.
    var label: String { get }
    /// Every encoded access unit (Annex-B, 4-byte start codes, SPS + PPS before every IDR).
    var onFrame: (@Sendable (EncodedFrame) -> Void)? { get set }
    /// Every failure (encode refused, output error, session lost).
    var onFailure: (@Sendable (DashEncoderFailure) -> Void)? { get set }
    /// Creates (or re-creates) the encoder at exactly `width × height` (the RLY 17 canvas). Throws when
    /// it cannot be created now; VideoToolbox keeps the configuration and retries on the next encode.
    func configure(width: Int, height: Int, parameters: EncoderParameters) throws
    /// A configuration exists (the session may still be pending re-creation).
    var isConfigured: Bool { get }
    /// A live session exists and is not marked invalid.
    var isSessionValid: Bool { get }
    /// Frames submitted whose output has not come out yet (always 0 for a synchronous encoder).
    var framesInFlight: Int { get }
    var parameters: EncoderParameters? { get }
    /// Submits one 32BGRA picture at monotonic `pts` seconds; `forceKeyframe` asks for an IDR.
    /// Returns false when the frame was not accepted.
    @discardableResult func encode(pixelBuffer: CVPixelBuffer, pts: TimeInterval, forceKeyframe: Bool) -> Bool
    /// Live bitrate / frame-rate change (no new session, so no new SPS).
    func update(parameters: EncoderParameters)
    /// Tears the encoder down; nothing is output after it returns.
    func invalidate()
    /// The encoder runs on hardware: nil = unknown (VideoToolbox did not answer).
    var usesHardware: Bool? { get }
    /// Average submit → output time in milliseconds.
    var averageEncodeMs: Double { get }
    /// The latest SPS / PPS this encoder put in front of an IDR.
    var lastParameterSets: (sps: [Data], pps: [Data]) { get }
}
#endif
