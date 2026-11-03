// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) VideoPipeline.kt (createEncoder / drainLoop / requestKeyframe /
// setEncoderBitrate), mapped to VideoToolbox per docs/spec/media-video.md §7.1, §15.3 and
// docs/spec/ios-platform-facts.md §d.
//
// The dash decodes a timestamp-less H.264 stream: Baseline@3.1, no frame reordering, CAVLC,
// SPS + PPS in front of EVERY IDR (Annex-B, 4-byte start codes), IDR every 1 s (Morini 2 s).

import Foundation
import OpenCfMotoCore

// MARK: - Platform-neutral settings (unit-tested on Linux)

/// VideoToolbox H.264 session settings derived from the canvas and `EncoderParameters`.
public struct H264EncoderSettings: Sendable, Equatable {
    public enum ProfileLevel: String, Sendable, Equatable {
        /// `kVTProfileLevel_H264_Baseline_3_1` — the known-good dash setting.
        case baseline31 = "H264_Baseline_3_1"
        /// `kVTProfileLevel_H264_Baseline_AutoLevel` — Baseline canvases beyond level 3.1 limits.
        case baselineAutoLevel = "H264_Baseline_AutoLevel"
        /// `kVTProfileLevel_H264_Main_AutoLevel` — profiles without `forceBaseline` (Morini).
        case mainAutoLevel = "H264_Main_AutoLevel"
    }

    /// Level 3.1 MaxFS (macroblocks per frame).
    public static let level31MaxFrameMacroblocks = 3_600
    /// Level 3.1 MaxMBPS (macroblocks per second).
    public static let level31MaxMacroblocksPerSecond = 108_000
    /// `DataRateLimits` byte budget = bitrate × this / 8 per `dataRateLimitSeconds`.
    public static let dataRatePeakFactor = 1.5

    public var width: Int
    public var height: Int
    public var profileLevel: ProfileLevel
    /// `kVTCompressionPropertyKey_AverageBitRate` (bits/s).
    public var averageBitRate: Int
    /// `kVTCompressionPropertyKey_DataRateLimits` = [bytes, seconds].
    public var dataRateLimitBytes: Int
    public var dataRateLimitSeconds: Double
    /// `kVTCompressionPropertyKey_ExpectedFrameRate`.
    public var expectedFrameRate: Int
    /// `kVTCompressionPropertyKey_MaxKeyFrameInterval` (frames) = fps × IDR seconds.
    public var maxKeyFrameInterval: Int
    /// `kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration` (seconds).
    public var maxKeyFrameIntervalDuration: Double
    /// CAVLC entropy coding (Baseline has no CABAC).
    public var usesCAVLC: Bool
    public var macroblocksPerFrame: Int
    public var macroblocksPerSecond: Int

    public init(width: Int, height: Int, parameters p: EncoderParameters) {
        self.width = width
        self.height = height
        let fps = max(1, p.frameRate)
        let mbs = ((max(0, width) + 15) / 16) * ((max(0, height) + 15) / 16)
        macroblocksPerFrame = mbs
        macroblocksPerSecond = mbs * fps
        if p.forceBaseline {
            let exceeds = mbs > Self.level31MaxFrameMacroblocks || mbs * fps > Self.level31MaxMacroblocksPerSecond
            profileLevel = exceeds ? .baselineAutoLevel : .baseline31
        } else {
            profileLevel = .mainAutoLevel
        }
        usesCAVLC = p.forceBaseline
        averageBitRate = max(1, p.bitrate)
        dataRateLimitBytes = max(1, Int((Double(max(1, p.bitrate)) * Self.dataRatePeakFactor / 8).rounded()))
        dataRateLimitSeconds = 1
        expectedFrameRate = fps
        let idr = p.keyframeIntervalSeconds.isFinite && p.keyframeIntervalSeconds > 0 ? p.keyframeIntervalSeconds : 1
        maxKeyFrameInterval = max(1, Int((Double(fps) * idr).rounded()))
        maxKeyFrameIntervalDuration = idr
    }
}

/// VideoToolbox status codes the encoder reacts to (docs/spec/ios-platform-facts.md §d).
public enum H264EncoderStatus {
    public static let propertyNotSupported: Int32 = -12900   // kVTPropertyNotSupportedErr
    public static let parameterError: Int32 = -12902         // kVTParameterErr
    public static let invalidSession: Int32 = -12903         // kVTInvalidSessionErr
    public static let allocationFailed: Int32 = -12904       // kVTAllocationFailedErr
    public static let couldNotFindEncoder: Int32 = -12908    // kVTCouldNotFindVideoEncoderErr
    public static let encoderMalfunction: Int32 = -12912     // kVTVideoEncoderMalfunctionErr
    public static let encoderNotAvailableNow: Int32 = -12915 // kVTVideoEncoderNotAvailableNowErr
    public static let sessionMalfunction: Int32 = -17691     // kVTSessionMalfunctionErr

    /// The session is gone (backgrounding, media-services reset): drop it and recreate it on the
    /// next encode, then start with an IDR.
    public static func requiresSessionRecreation(_ status: Int32) -> Bool {
        status == invalidSession || status == encoderNotAvailableNow || status == encoderMalfunction
            || status == sessionMalfunction
    }

    public static func describe(_ status: Int32) -> String {
        knownName(status) ?? "OSStatus \(status)"
    }

    /// ADDITION (locked iPhone, Phase 0): the constant name of a status this encoder knows
    /// (`kVTCouldNotFindVideoEncoderErr`, `noErr` for 0), nil for any other status — the `name` of
    /// `BackgroundLog.osStatus(_:name:)` in the `create=` field of the `[bg]` lines.
    public static func knownName(_ status: Int32) -> String? {
        switch status {
        case 0: return "noErr"
        case propertyNotSupported: return "kVTPropertyNotSupportedErr"
        case parameterError: return "kVTParameterErr"
        case invalidSession: return "kVTInvalidSessionErr"
        case allocationFailed: return "kVTAllocationFailedErr"
        case couldNotFindEncoder: return "kVTCouldNotFindVideoEncoderErr"
        case encoderMalfunction: return "kVTVideoEncoderMalfunctionErr"
        case encoderNotAvailableNow: return "kVTVideoEncoderNotAvailableNowErr"
        case sessionMalfunction: return "kVTSessionMalfunctionErr"
        default: return nil
        }
    }

    /// ADDITION (locked iPhone, Phase 0): the `DashEncoderFailure` an encoder error is reported as
    /// through `DashVideoEncoder.onFailure`: the status, whether the session must be re-created
    /// (`requiresSessionRecreation`), and the error text.
    public static func failure(status: Int32?, message: String) -> DashEncoderFailure {
        DashEncoderFailure(status: status, requiresRecreation: status.map(requiresSessionRecreation) ?? false, message: message)
    }
}

/// Counters exposed by `H264Encoder.stats`.
public struct H264EncoderStats: Sendable, Equatable {
    public var sessionsCreated = 0
    public var framesSubmitted = 0
    public var framesOutput = 0
    public var keyframesOutput = 0
    public var framesDropped = 0
    public var errors = 0
    public var lastError: Int32?
    /// Submit → output latency of the last frame (ms).
    public var lastEncodeMs: Double = 0
    /// Exponential moving average of the submit → output latency (ms).
    public var averageEncodeMs: Double = 0
    public var lastFrameBytes = 0
    /// `UsingHardwareAcceleratedVideoEncoder` as reported by the session (nil = unknown).
    public var usingHardware: Bool?
    /// The session was created with hardware acceleration disabled (`allowSoftware`).
    public var softwareRequested = false
    public init() {}
}

// MARK: - VideoToolbox encoder (Apple platforms)

#if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo)
import CoreMedia
import CoreVideo
import VideoToolbox

public enum H264EncoderError: Error, CustomStringConvertible {
    case notConfigured
    case invalidSize(width: Int, height: Int)
    case sessionCreationFailed(OSStatus)
    case encodeFailed(OSStatus)
    case outputFailed(OSStatus)

    public var status: OSStatus? {
        switch self {
        case let .sessionCreationFailed(s), let .encodeFailed(s), let .outputFailed(s): return s
        case .notConfigured, .invalidSize: return nil
        }
    }

    public var description: String {
        switch self {
        case .notConfigured: return "H.264 encoder not configured"
        case let .invalidSize(w, h): return "invalid encoder size \(w)x\(h)"
        case let .sessionCreationFailed(s): return "VTCompressionSessionCreate failed: \(H264EncoderStatus.describe(s))"
        case let .encodeFailed(s): return "VTCompressionSessionEncodeFrame failed: \(H264EncoderStatus.describe(s))"
        case let .outputFailed(s): return "VT output error: \(H264EncoderStatus.describe(s))"
        }
    }

    /// ADDITION (locked iPhone, Phase 0): this error as reported through `DashVideoEncoder.onFailure`.
    public var dashFailure: DashEncoderFailure { H264EncoderStatus.failure(status: status, message: description) }
}

/// VideoToolbox H.264 encoder producing dash-ready `EncodedFrame`s (Annex-B, SPS + PPS before
/// every IDR). Thread-safe: every method may be called from any thread; `onFrame` / `onError` /
/// `onFailure` are invoked on a VideoToolbox thread (never while an internal lock is held), except
/// that an encode refused by VideoToolbox reports its error synchronously from `encode`.
/// It is the engine's `DashVideoEncoder` for the foreground (`own`, hardware) and for the background
/// software rung (`own-sw-pre`, `own-sw`, `own-sw-id`).
public final class H264Encoder: @unchecked Sendable {
    public typealias FrameHandler = @Sendable (EncodedFrame) -> Void
    public typealias ErrorHandler = @Sendable (H264EncoderError) -> Void
    public typealias FailureHandler = @Sendable (DashEncoderFailure) -> Void

    private struct Config {
        var width: Int
        var height: Int
        var parameters: EncoderParameters
        var allowSoftware: Bool
    }

    /// Minimum gap between two session (re)creation attempts after a failure.
    public var minimumRecreateInterval: TimeInterval = 1.0

    public let label: String
    /// ADDITION (locked iPhone, Phase 0): `kVTVideoEncoderSpecification_EncoderID` of every session
    /// (nil = let VideoToolbox choose), from `init`.
    public let encoderID: String?
    /// `allowSoftware` of `init`: what the three-argument `configure` (the `DashVideoEncoder` one) uses.
    private let initialAllowSoftware: Bool
    private let lock = NSLock()
    private var config: Config?
    private var session: VTCompressionSession?
    private var generation: UInt64 = 0
    private var needsRecreate = false
    private var lastCreateAttempt: TimeInterval = -.greatestFiniteMagnitude
    private var forceNextKeyframe = true
    /// Last submitted presentation time in integer microseconds (the CMTime timescale).
    private var lastPTSMicros: Int64?
    private var sequence: UInt64 = 0
    private var inFlight = 0
    private var submitTimes: [TimeInterval] = []
    private var lastSPS: [Data] = []
    private var lastPPS: [Data] = []
    private var _stats = H264EncoderStats()
    private var _onFrame: FrameHandler?
    private var _onError: ErrorHandler?
    private var _onFailure: FailureHandler?

    /// - Parameters:
    ///   - allowSoftware: ADDITION (locked iPhone, Phase 0): what `configure(width:height:parameters:)`
    ///     requests — `EnableHardwareAcceleratedVideoEncoder = false` (iOS 17.4+), the background
    ///     software rung. The four-argument `configure` still takes its own value.
    ///   - encoderID: ADDITION (locked iPhone, Phase 0): a `VTCopyVideoEncoderList` `EncoderID` to
    ///     request (`kVTVideoEncoderSpecification_EncoderID`); nil = VideoToolbox chooses.
    public init(label: String = "video", allowSoftware: Bool = false, encoderID: String? = nil) {
        self.label = label
        initialAllowSoftware = allowSoftware
        self.encoderID = encoderID
    }

    deinit {
        if let s = session { VTCompressionSessionInvalidate(s) }
    }

    /// Called for every encoded access unit (never empty).
    public var onFrame: FrameHandler? {
        get { lock.lock(); defer { lock.unlock() }; return _onFrame }
        set { lock.lock(); _onFrame = newValue; lock.unlock() }
    }

    /// Called for VideoToolbox errors (the encoder recreates its session by itself when needed).
    public var onError: ErrorHandler? {
        get { lock.lock(); defer { lock.unlock() }; return _onError }
        set { lock.lock(); _onError = newValue; lock.unlock() }
    }

    /// ADDITION (locked iPhone, Phase 0, `DashVideoEncoder`): called with every error `onError` gets
    /// (encode refused, output error, session creation failure), as `H264EncoderError.dashFailure`.
    public var onFailure: FailureHandler? {
        get { lock.lock(); defer { lock.unlock() }; return _onFailure }
        set { lock.lock(); _onFailure = newValue; lock.unlock() }
    }

    /// ADDITION (locked iPhone, Phase 0, `DashVideoEncoder`): `.videoToolboxSoftware` when the
    /// session is requested with `allowSoftware` (the configured value, else the `init` value),
    /// otherwise `.videoToolboxHardware`.
    public var kind: DashEncoderKind {
        lock.lock(); defer { lock.unlock() }
        return (config?.allowSoftware ?? initialAllowSoftware) ? .videoToolboxSoftware : .videoToolboxHardware
    }

    public var stats: H264EncoderStats { lock.lock(); defer { lock.unlock() }; return _stats }
    /// A configuration exists (the session may still be pending recreation).
    public var isConfigured: Bool { lock.lock(); defer { lock.unlock() }; return config != nil }
    /// A live session exists and is not marked invalid.
    public var isSessionValid: Bool { lock.lock(); defer { lock.unlock() }; return session != nil && !needsRecreate }
    /// Frames submitted whose output callback has not run yet.
    public var framesInFlight: Int { lock.lock(); defer { lock.unlock() }; return inFlight }
    public var parameters: EncoderParameters? { lock.lock(); defer { lock.unlock() }; return config?.parameters }
    public var size: (width: Int, height: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard let c = config else { return nil }
        return (c.width, c.height)
    }
    /// Latest SPS / PPS seen in the session's format description (diagnostics: compare with the
    /// known-good Android pair, media-video.md §7.6).
    public var lastParameterSets: (sps: [Data], pps: [Data]) {
        lock.lock(); defer { lock.unlock() }; return (lastSPS, lastPPS)
    }

    /// True when a software (non-hardware) encoder can be requested: iOS 17.4+ exposes
    /// `kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder` (always on macOS).
    /// Whether iOS actually provides a software H.264 encoder is a device question
    /// (ios-platform-facts.md "things only a real device can settle" #2).
    public static var isSoftwareEncodingSupported: Bool {
        if #available(iOS 17.4, *) { return true }
        return false
    }

    /// ADDITION (locked iPhone, Phase 0, P0-2): the H.264 (`avc1`) entries of `VTCopyVideoEncoderList`,
    /// in list order: `EncoderID`, `EncoderName` and `IsHardwareAccelerated` (nil when the entry has no
    /// such key — one report saw none even for the hardware encoder, so the list alone settles
    /// nothing). Empty when VideoToolbox returns an error. Logged once per run (L2) and used for the
    /// background `EncoderID` tries.
    public static func listAvailableEncoders() -> [BackgroundLog.EncoderListEntry] {
        var listOut: CFArray?
        let status = VTCopyVideoEncoderList(nil, &listOut)
        guard status == 0, let list = listOut as? [[String: Any]] else { return [] }
        return list.compactMap { entry -> BackgroundLog.EncoderListEntry? in
            guard let codec = entry[kVTVideoEncoderList_CodecType as String] as? NSNumber,
                  codec.uint32Value == kCMVideoCodecType_H264 else { return nil }
            let id = entry[kVTVideoEncoderList_EncoderID as String] as? String ?? "?"
            let name = entry[kVTVideoEncoderList_EncoderName as String] as? String ?? "?"
            let hardware = (entry[kVTVideoEncoderList_IsHardwareAccelerated as String] as? NSNumber)?.boolValue
            return BackgroundLog.EncoderListEntry(id: id, name: name, isHardwareAccelerated: hardware)
        }
    }

    // MARK: configuration

    /// ADDITION (locked iPhone, Phase 0, `DashVideoEncoder`): `configure(width:height:parameters:
    /// allowSoftware:)` with the `allowSoftware` given at `init` (false by default, so the existing
    /// three-argument calls — `own`, `mirror`, `hold` — keep requesting hardware).
    public func configure(width: Int, height: Int, parameters: EncoderParameters) throws {
        try configure(width: width, height: height, parameters: parameters, allowSoftware: initialAllowSoftware)
    }

    /// Creates (or recreates) the session at exactly `width × height`.
    /// - Parameter allowSoftware: disable hardware acceleration (iOS 17.4+): the background path.
    /// If creation fails the configuration is kept and creation is retried on the next `encode`
    /// (at most once per `minimumRecreateInterval`); the error is rethrown for logging.
    public func configure(width: Int, height: Int, parameters: EncoderParameters, allowSoftware: Bool = false) throws {
        guard width >= 16, height >= 16 else { throw H264EncoderError.invalidSize(width: width, height: height) }
        let cfg = Config(width: width, height: height, parameters: parameters, allowSoftware: allowSoftware)
        lock.lock()
        config = cfg
        let old = session
        session = nil
        generation &+= 1
        inFlight = 0
        submitTimes.removeAll()
        lastPTSMicros = nil
        forceNextKeyframe = true
        needsRecreate = true
        lastSPS = []
        lastPPS = []
        lock.unlock()
        if let old { VTCompressionSessionInvalidate(old) }
        try createSession(force: true)
    }

    /// Tears the session down; `encode` does nothing until `configure` is called again.
    public func invalidate() {
        lock.lock()
        let old = session
        session = nil
        config = nil
        generation &+= 1
        inFlight = 0
        submitTimes.removeAll()
        needsRecreate = false
        lock.unlock()
        if let old { VTCompressionSessionInvalidate(old) }
    }

    /// Live bitrate change (AverageBitRate + DataRateLimits; no session re-creation).
    public func updateBitrate(_ bitrate: Int) {
        lock.lock()
        guard var cfg = config else { lock.unlock(); return }
        cfg.parameters.bitrate = max(1, bitrate)
        config = cfg
        let s = session
        lock.unlock()
        guard let s else { return }
        let st = H264EncoderSettings(width: cfg.width, height: cfg.height, parameters: cfg.parameters)
        _ = Self.setProperty(s, kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: st.averageBitRate), "AverageBitRate", label)
        _ = Self.setProperty(s, kVTCompressionPropertyKey_DataRateLimits, Self.dataRateLimits(st), "DataRateLimits", label)
    }

    /// Live frame-rate change (ExpectedFrameRate + MaxKeyFrameInterval).
    public func updateFrameRate(_ fps: Int) {
        lock.lock()
        guard var cfg = config else { lock.unlock(); return }
        cfg.parameters.frameRate = max(1, fps)
        config = cfg
        let s = session
        lock.unlock()
        guard let s else { return }
        let st = H264EncoderSettings(width: cfg.width, height: cfg.height, parameters: cfg.parameters)
        _ = Self.setProperty(s, kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: st.expectedFrameRate), "ExpectedFrameRate", label)
        _ = Self.setProperty(s, kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: st.maxKeyFrameInterval), "MaxKeyFrameInterval", label)
    }

    /// Applies bitrate / frame-rate changes live. Changes of `forceBaseline` or the IDR interval
    /// are stored and take effect at the next session creation.
    public func update(parameters: EncoderParameters) {
        lock.lock()
        guard let cfg = config else { lock.unlock(); return }
        let old = cfg.parameters
        config?.parameters.keyframeIntervalSeconds = parameters.keyframeIntervalSeconds
        config?.parameters.forceBaseline = parameters.forceBaseline
        config?.parameters.repeatLastFrameAfter = parameters.repeatLastFrameAfter
        lock.unlock()
        if old.bitrate != parameters.bitrate { updateBitrate(parameters.bitrate) }
        if old.frameRate != parameters.frameRate { updateFrameRate(parameters.frameRate) }
    }

    /// The next encoded frame will be an IDR (with SPS + PPS).
    public func requestKeyframe() {
        lock.lock(); forceNextKeyframe = true; lock.unlock()
    }

    /// Blocks until every submitted frame has been output (used for one-shot encodes and tests).
    public func completeFrames() {
        lock.lock(); let s = session; lock.unlock()
        if let s { _ = VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: CMTime.invalid) }
    }

    // MARK: encoding

    /// Submits one picture. `pts` is monotonic seconds; it is bumped if not strictly increasing
    /// (repeats of the same picture must still advance). Returns false if the frame was not
    /// accepted (no session, session being recreated, VideoToolbox error).
    @discardableResult
    public func encode(pixelBuffer: CVPixelBuffer, pts: TimeInterval, forceKeyframe: Bool = false) -> Bool {
        lock.lock()
        guard config != nil else { lock.unlock(); return false }
        let mustCreate = session == nil || needsRecreate
        lock.unlock()
        if mustCreate {
            do { try createSession(force: false) } catch { return false }
        }

        lock.lock()
        guard let s = session, !needsRecreate else { lock.unlock(); return false }
        let gen = generation
        let force = forceKeyframe || forceNextKeyframe
        forceNextKeyframe = false
        // Work in integer microseconds: bumping a Double by 1e-6 can round back to the same CMTime
        // value (1.0 + 1e-6 → 1_000_000.99… µs → truncated), which repeated the PTS.
        var micros: Int64 = pts.isFinite ? Int64((pts * 1_000_000).rounded()) : (lastPTSMicros ?? 0) + 1_000
        if let last = lastPTSMicros, micros <= last { micros = last + 1 }
        lastPTSMicros = micros
        inFlight += 1
        submitTimes.append(ProcessInfo.processInfo.systemUptime)
        _stats.framesSubmitted += 1
        lock.unlock()

        let props: CFDictionary? = force ? ([kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary) : nil
        var infoFlags = VTEncodeInfoFlags()
        let status = VTCompressionSessionEncodeFrame(
            s,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: CMTime(value: micros, timescale: 1_000_000),
            duration: CMTime.invalid,
            frameProperties: props,
            infoFlagsOut: &infoFlags
        ) { [weak self] outStatus, outFlags, sampleBuffer in
            self?.handleOutput(status: outStatus, flags: outFlags, sampleBuffer: sampleBuffer, generation: gen)
        }
        if status != 0 {
            lock.lock()
            if gen == generation {
                inFlight = max(0, inFlight - 1)
                if !submitTimes.isEmpty { submitTimes.removeLast() }
                if force { forceNextKeyframe = true }
                if H264EncoderStatus.requiresSessionRecreation(status) {
                    needsRecreate = true
                    forceNextKeyframe = true
                }
            }
            _stats.errors += 1
            _stats.lastError = status
            let handler = _onError
            let failureHandler = _onFailure
            lock.unlock()
            Log.shared.throttled("vt-encode-\(label)", interval: 2, .warn, "VIDEO",
                                 "[\(label)] encode failed: \(H264EncoderStatus.describe(status))")
            let error = H264EncoderError.encodeFailed(status)
            handler?(error)
            failureHandler?(error.dashFailure)
            return false
        }
        return true
    }

    // MARK: private

    private func createSession(force: Bool) throws {
        lock.lock()
        guard let cfg = config else { lock.unlock(); throw H264EncoderError.notConfigured }
        let now = ProcessInfo.processInfo.systemUptime
        if !force, now - lastCreateAttempt < minimumRecreateInterval {
            lock.unlock()
            throw H264EncoderError.sessionCreationFailed(H264EncoderStatus.encoderNotAvailableNow)
        }
        lastCreateAttempt = now
        let old = session
        session = nil
        generation &+= 1
        inFlight = 0
        submitTimes.removeAll()
        lock.unlock()
        if let old { VTCompressionSessionInvalidate(old) }

        let settings = H264EncoderSettings(width: cfg.width, height: cfg.height, parameters: cfg.parameters)
        let created: VTCompressionSession
        do {
            created = try Self.makeSession(settings: settings, allowSoftware: cfg.allowSoftware, encoderID: encoderID,
                                           label: label)
        } catch {
            lock.lock()
            needsRecreate = true
            _stats.errors += 1
            if let e = error as? H264EncoderError, let st = e.status { _stats.lastError = st }
            let handler = _onError
            let failureHandler = _onFailure
            lock.unlock()
            Log.w("VIDEO", "[\(label)] \(error)")
            if let e = error as? H264EncoderError {
                handler?(e)
                failureHandler?(e.dashFailure)
            }
            throw error
        }
        let hw = Self.readUsingHardware(created)
        lock.lock()
        session = created
        needsRecreate = false
        forceNextKeyframe = true
        lastPTSMicros = nil
        _stats.sessionsCreated += 1
        _stats.usingHardware = hw
        _stats.softwareRequested = cfg.allowSoftware
        lock.unlock()
        Log.i("VIDEO", "[\(label)] VT session \(cfg.width)x\(cfg.height) \(settings.profileLevel.rawValue) "
            + "\(settings.averageBitRate / 1000)kbps \(settings.expectedFrameRate)fps "
            + "IDR \(settings.maxKeyFrameIntervalDuration)s/\(settings.maxKeyFrameInterval)f "
            + "software=\(cfg.allowSoftware) hw=\(hw.map { String($0) } ?? "?")"
            + (encoderID.map { " id=\($0)" } ?? ""))
    }

    private static func makeSession(settings st: H264EncoderSettings, allowSoftware: Bool, encoderID: String?,
                                    label: String) throws -> VTCompressionSession {
        var spec: [CFString: Any] = [:]
        if let encoderID {
            spec[kVTVideoEncoderSpecification_EncoderID] = encoderID
        }
        if allowSoftware {
            if #available(iOS 17.4, *) {
                spec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] = false
            }
        }
        let sourceAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey: st.width,
            kCVPixelBufferHeightKey: st.height,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ]
        var out: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(st.width),
            height: Int32(st.height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec.isEmpty ? nil : (spec as CFDictionary),
            imageBufferAttributes: sourceAttributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &out)
        guard status == 0, let s = out else { throw H264EncoderError.sessionCreationFailed(status) }

        _ = setProperty(s, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue, "RealTime", label)
        let profile: CFString
        switch st.profileLevel {
        case .baseline31: profile = kVTProfileLevel_H264_Baseline_3_1
        case .baselineAutoLevel: profile = kVTProfileLevel_H264_Baseline_AutoLevel
        case .mainAutoLevel: profile = kVTProfileLevel_H264_Main_AutoLevel
        }
        _ = setProperty(s, kVTCompressionPropertyKey_ProfileLevel, profile, "ProfileLevel", label)
        // Mandatory: the wire carries no PTS, display order must equal decode order.
        _ = setProperty(s, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse, "AllowFrameReordering", label)
        if st.usesCAVLC {
            _ = setProperty(s, kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CAVLC, "H264EntropyMode", label)
        }
        _ = setProperty(s, kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: st.averageBitRate), "AverageBitRate", label)
        _ = setProperty(s, kVTCompressionPropertyKey_DataRateLimits, dataRateLimits(st), "DataRateLimits", label)
        _ = setProperty(s, kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: st.expectedFrameRate), "ExpectedFrameRate", label)
        _ = setProperty(s, kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: st.maxKeyFrameInterval), "MaxKeyFrameInterval", label)
        _ = setProperty(s, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: st.maxKeyFrameIntervalDuration),
                        "MaxKeyFrameIntervalDuration", label)
        // Emit every frame before accepting the next one (lowest latency); optional.
        _ = setProperty(s, kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: 0), "MaxFrameDelayCount", label, quiet: true)
        let prep = VTCompressionSessionPrepareToEncodeFrames(s)
        if prep != 0 { Log.w("VIDEO", "[\(label)] PrepareToEncodeFrames: \(H264EncoderStatus.describe(prep))") }
        return s
    }

    private static func dataRateLimits(_ st: H264EncoderSettings) -> CFArray {
        [NSNumber(value: st.dataRateLimitBytes), NSNumber(value: st.dataRateLimitSeconds)] as CFArray
    }

    @discardableResult
    private static func setProperty(_ s: VTCompressionSession, _ key: CFString, _ value: CFTypeRef?, _ name: String,
                                    _ label: String, quiet: Bool = false) -> OSStatus {
        let st = VTSessionSetProperty(s, key: key, value: value)
        if st != 0, !quiet {
            Log.w("VIDEO", "[\(label)] VT property \(name) not applied: \(H264EncoderStatus.describe(st))")
        }
        return st
    }

    /// Reads `UsingHardwareAcceleratedVideoEncoder` (the raw key string keeps this compiling on
    /// every SDK; the property is read-only diagnostics).
    private static func readUsingHardware(_ s: VTCompressionSession) -> Bool? {
        // Copy semantics: the value comes back retained (+1) — balanced by takeRetainedValue().
        var value: Unmanaged<CFTypeRef>?
        let st = VTSessionCopyProperty(s, key: "UsingHardwareAcceleratedVideoEncoder" as CFString,
                                       allocator: kCFAllocatorDefault, valueOut: &value)
        guard st == 0, let v = value?.takeRetainedValue() else { return nil }
        return (v as? NSNumber)?.boolValue
    }

    private func handleOutput(status: OSStatus, flags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?, generation gen: UInt64) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard gen == generation else { lock.unlock(); return } // output of a discarded session
        inFlight = max(0, inFlight - 1)
        let submittedAt = submitTimes.isEmpty ? nil : submitTimes.removeFirst()
        if status != 0 {
            _stats.errors += 1
            _stats.lastError = status
            if H264EncoderStatus.requiresSessionRecreation(status) {
                needsRecreate = true
                forceNextKeyframe = true
            }
            let handler = _onError
            let failureHandler = _onFailure
            lock.unlock()
            Log.shared.throttled("vt-output-\(label)", interval: 2, .warn, "VIDEO",
                                 "[\(label)] output error: \(H264EncoderStatus.describe(status))")
            let error = H264EncoderError.outputFailed(status)
            handler?(error)
            failureHandler?(error.dashFailure)
            return
        }
        if flags.contains(.frameDropped) {
            _stats.framesDropped += 1
            lock.unlock()
            return
        }
        let cachedSPS = lastSPS
        let cachedPPS = lastPPS
        lock.unlock()

        guard let sb = sampleBuffer, CMSampleBufferDataIsReady(sb),
              let block = CMSampleBufferGetDataBuffer(sb) else { return }
        let syncFrame = !Self.isNotSync(sb)
        var sps = cachedSPS
        var pps = cachedPPS
        var lengthSize = 4
        if let fd = CMSampleBufferGetFormatDescription(sb), let sets = Self.parameterSets(fd, includeData: syncFrame) {
            lengthSize = sets.nalLength
            if !sets.sps.isEmpty { sps = sets.sps }
            if !sets.pps.isEmpty { pps = sets.pps }
        }
        let total = CMBlockBufferGetDataLength(block)
        guard total > 0 else { return }
        var avcc = Data(count: total)
        let copyStatus = avcc.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: base)
        }
        guard copyStatus == 0 else { return }
        let au = AnnexB.accessUnit(avccSlices: avcc, lengthSize: lengthSize, sps: sps, pps: pps)
        guard !au.data.isEmpty else { return } // never hand out a zero-size frame
        if au.isKeyframe != syncFrame {
            Log.shared.throttled("vt-sync-\(label)", interval: 10, .debug, "VIDEO",
                                 "[\(label)] NotSync=\(!syncFrame) but IDR present=\(au.isKeyframe); using the bitstream")
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)

        lock.lock()
        guard gen == generation else { lock.unlock(); return }
        if au.isKeyframe {
            lastSPS = sps
            lastPPS = pps
        }
        sequence &+= 1
        let seq = sequence
        _stats.framesOutput += 1
        if au.isKeyframe { _stats.keyframesOutput += 1 }
        let isFirstKeyframe = au.isKeyframe && _stats.keyframesOutput == 1
        _stats.lastFrameBytes = au.data.count
        if let submittedAt {
            let ms = (now - submittedAt) * 1000
            _stats.lastEncodeMs = ms
            _stats.averageEncodeMs = _stats.averageEncodeMs == 0 ? ms : _stats.averageEncodeMs * 0.9 + ms * 0.1
        }
        let handler = _onFrame
        lock.unlock()

        if isFirstKeyframe {
            // media-video.md §15.8: log SPS/PPS on session creation (compare with §7.6). L1 (locked
            // iPhone, Phase 0): the FULL SPS / PPS hex and their decoded summary, every label.
            Log.i("VIDEO", BackgroundLog.firstIDR(label: label, bytes: au.data.count, sps: sps.first, pps: pps.first))
        }
        handler?(EncodedFrame(accessUnit: au.data, isKeyframe: au.isKeyframe,
                              presentationTime: pts.isValid ? pts.seconds : 0, sequence: seq))
    }

    /// `kCMSampleAttachmentKey_NotSync` of the first sample (absent = sync frame).
    private static func isNotSync(_ sb: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) else { return false }
        let array = attachments as NSArray
        guard let first = array.firstObject as? NSDictionary else { return false }
        if let v = first[kCMSampleAttachmentKey_NotSync] as? NSNumber { return v.boolValue }
        return false
    }

    /// SPS / PPS (when `includeData`) and the AVCC NAL length size from a format description.
    private static func parameterSets(_ fd: CMFormatDescription, includeData: Bool) -> (sps: [Data], pps: [Data], nalLength: Int)? {
        var count = 0
        var nalLength: Int32 = 0
        let st = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            fd, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLength)
        guard st == 0 else { return nil }
        let length = (1 ... 4).contains(Int(nalLength)) ? Int(nalLength) : 4
        guard includeData else { return ([], [], length) }
        var sps: [Data] = []
        var pps: [Data] = []
        for i in 0 ..< count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let r = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fd, parameterSetIndex: i, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            guard r == 0, let p = pointer, size > 0 else { continue }
            let nal = Data(bytes: p, count: size)
            switch AnnexB.nalType(nal) {
            case H264NALType.sps.rawValue?: sps.append(nal)
            case H264NALType.pps.rawValue?: pps.append(nal)
            default: break
            }
        }
        return (sps, pps, length)
    }
}

/// ADDITION (locked iPhone, Phase 0, P0-3): the engine's encoder seam. `kind`, `onFailure` and the
/// three-argument `configure` live in the class; `usesHardware` and `averageEncodeMs` read `stats`.
extension H264Encoder: DashVideoEncoder {
    /// `stats.usingHardware`: what `UsingHardwareAcceleratedVideoEncoder` said (nil = unknown).
    public var usesHardware: Bool? { stats.usingHardware }
    /// `stats.averageEncodeMs`.
    public var averageEncodeMs: Double { stats.averageEncodeMs }
}

public extension H264Encoder {
    /// Encodes `count` consecutive IDRs of one picture with a temporary session (does not disturb
    /// any live encoder) — the background "hold" picture. Blocks up to `timeout` seconds.
    /// Consecutive IDRs normally get different `idr_pic_id`s, so serving them alternately keeps
    /// repeated keyframes standards-conformant.
    static func encodeStill(pixelBuffer: CVPixelBuffer, width: Int, height: Int, parameters: EncoderParameters,
                            count: Int = 2, timeout: TimeInterval = 1.0) -> [EncodedFrame] {
        let encoder = H264Encoder(label: "hold")
        let frames = Locked<[EncodedFrame]>([])
        let done = DispatchSemaphore(value: 0)
        let wanted = max(1, count)
        encoder.onFrame = { f in
            let n = frames.withLock { (list: inout [EncodedFrame]) -> Int in
                if f.isKeyframe { list.append(f) }
                return list.count
            }
            if n == wanted { done.signal() }
        }
        do {
            try encoder.configure(width: width, height: height, parameters: parameters)
        } catch {
            return []
        }
        let base = ProcessInfo.processInfo.systemUptime
        for i in 0 ..< wanted {
            encoder.encode(pixelBuffer: pixelBuffer, pts: base + Double(i) * 0.04, forceKeyframe: true)
        }
        encoder.completeFrames()
        _ = done.wait(timeout: .now() + max(0.05, timeout))
        encoder.invalidate()
        return frames.current
    }
}
#endif
