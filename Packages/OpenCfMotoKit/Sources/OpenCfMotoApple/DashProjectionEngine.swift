// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) VideoPipeline.kt
// The own-UI video source (the iOS main path): DashDisplayList → DashRenderer (CoreGraphics, CPU)
// → 32BGRA CVPixelBuffer at exactly the negotiated canvas → H264Encoder (VideoToolbox) →
// FrameQueue → REQ_RV_DATA_NEXT (114) pulls. Android counterparts: the own Map/GPX Presentation
// mode, onBikeDataStart, pollFrame, IDLE_ENCODER_REPEAT_US — here with the iOS fixes of
// docs/spec/media-video.md §15.2–§15.5 (pull-paced rendering, GOP-safe queue, never a repeated
// P-frame, never an unanswered pull when a picture exists) and the background plan of
// docs/spec/ios-platform-facts.md design recommendations 1–4 (software encoder at 5–10 fps on
// iOS 17.4+, otherwise a pre-encoded "hold" IDR).

import Foundation
import OpenCfMotoCore

// MARK: - Platform-neutral pieces (unit-tested on Linux)

/// Per-tick decision of the render loop.
///
/// - A new picture is rendered when the content changed and it can be encoded right away (no
///   encoded frame is waiting in the queue and none is inside the encoder) — rendering is paced
///   by the dash's pulls (media-video.md §15.4) — or when a phone preview is due.
/// - The latest picture is encoded when it is new, when an IDR is requested (REQ 112 resync,
///   queue overflow, new session), or as a keep-alive repeat when nothing was encoded for
///   `repeatAfter` (0.9 s; VideoToolbox has no KEY_REPEAT_PREVIOUS_FRAME_AFTER).
struct ProjectionPacer {
    struct Input: Equatable {
        var now: TimeInterval
        var encoderReady: Bool
        var contentChanged: Bool
        var keyframeRequested: Bool
        var queuedFrames: Int
        var framesInFlight: Int
        var lastEncodeAt: TimeInterval?
        var hasPicture: Bool
        var pictureNotEncoded: Bool
        var repeatAfter: TimeInterval
        var previewDue: Bool
    }

    struct Decision: Equatable {
        var render: Bool
        var encode: Bool
        var forceKeyframe: Bool
        var isRepeat: Bool
        static let idle = Decision(render: false, encode: false, forceKeyframe: false, isRepeat: false)
    }

    static func decide(_ i: Input) -> Decision {
        let canEncode = i.encoderReady
            && (i.keyframeRequested || (i.queuedFrames == 0 && i.framesInFlight == 0))
        let render = (i.contentChanged || !i.hasPicture) && (canEncode || i.previewDue)
        let hasPicture = i.hasPicture || render
        guard canEncode, hasPicture else {
            return Decision(render: render, encode: false, forceKeyframe: false, isRepeat: false)
        }
        if i.keyframeRequested {
            return Decision(render: render, encode: true, forceKeyframe: true, isRepeat: false)
        }
        if render || i.pictureNotEncoded {
            return Decision(render: render, encode: true, forceKeyframe: false, isRepeat: false)
        }
        guard let last = i.lastEncodeAt else {
            return Decision(render: false, encode: true, forceKeyframe: false, isRepeat: true)
        }
        if i.now - last >= i.repeatAfter {
            return Decision(render: false, encode: true, forceKeyframe: false, isRepeat: true)
        }
        return .idle
    }
}

/// The REQ 114 pull policy shared by every frame source: wait for the next queued access unit;
/// if none arrives in time, answer with a cached keyframe (never a P-frame) and re-close the
/// keyframe gate so the next live frame is an IDR again (the decoder's reference changed).
enum FramePull {
    /// Time kept back from the caller's timeout so the answer is never late.
    static let safetyMargin: TimeInterval = 0.15

    static func next(from queue: FrameQueue, timeout: TimeInterval,
                     fallbackKeyframe: () -> EncodedFrame?) async -> (frame: EncodedFrame?, usedFallback: Bool) {
        let wait = max(0.01, timeout - safetyMargin)
        if let f = await queue.next(timeout: wait) { return (f, false) }
        guard let key = fallbackKeyframe(), key.isKeyframe, !key.accessUnit.isEmpty else { return (nil, false) }
        queue.resynchronize()
        return (key, true)
    }
}

/// Coalesces keyframe requests (E2E: a session used to start with 3–4 IDRs in its first 200 ms —
/// the prepare-time IDR, the 112 resync asking twice, a second IDR 200 ms later). A request is
/// satisfied by ANY keyframe the encoder outputs after it (a forced or a periodic IDR pushed after
/// a resync's flush opens the queue's gate all the same), and while a forced IDR is in flight
/// (submitted, not output yet) no second one is forced. A forced IDR that never comes out (dropped
/// by VideoToolbox, session lost) is retried after `inFlightTimeout`.
struct KeyframeCoalescer: Equatable {
    var inFlightTimeout: TimeInterval = 0.5
    /// An IDR is still needed.
    private(set) var pending = false
    /// Keyframes output when the newest request was made (only later outputs satisfy it).
    private var pendingMark: UInt64 = 0
    private var forcedAt: TimeInterval?
    private var forcedMark: UInt64 = 0

    /// A keyframe is needed; `outputs` = keyframes the encoder had output at that moment.
    mutating func request(outputs: UInt64) {
        pendingMark = pending ? max(pendingMark, outputs) : outputs
        pending = true
    }

    /// Whether to force an IDR now (`outputs` = keyframes output so far).
    mutating func shouldForce(now: TimeInterval, outputs: UInt64) -> Bool {
        if pending, outputs > pendingMark {
            pending = false // a keyframe came out after the request: satisfied (coalesced)
            forcedAt = nil
        }
        guard pending else { return false }
        if let at = forcedAt, outputs <= forcedMark, now - at < inFlightTimeout { return false }
        return true
    }

    /// A forced IDR was submitted to the encoder.
    mutating func forced(now: TimeInterval, outputs: UInt64) {
        forcedAt = now
        forcedMark = outputs
    }

    /// The encoder session was replaced: nothing is in flight any more.
    mutating func encoderReset() { forcedAt = nil }
}

/// Which cached IDR a 114 falls back to when the encoder produced nothing in time (CL-5): in the
/// foreground only the last live keyframe — never the pre-encoded "Phone locked" hold picture,
/// which may linger after an inactive blip (Control Center, a banner) — and in the background
/// modes the hold picture first, then the last live keyframe.
enum ProjectionFallback {
    static func keyframe(foreground: Bool, hold: () -> EncodedFrame?, live: () -> EncodedFrame?) -> EncodedFrame? {
        foreground ? live() : (hold() ?? live())
    }

    /// ADDITION (locked iPhone, Phase 0, P0-5): where the engine is when a pull times out.
    enum Context: Sendable, Equatable {
        /// The hardware encoder feeds the dash.
        case foreground
        /// A background encoder (vt-sw, cpu) feeds the dash (`.backgroundSoftware`).
        case backgroundEncoder
        /// No encoder: the hold IDRs feed the dash (`.hold`, also idle).
        case hold
    }

    /// ADDITION (locked iPhone, Phase 0, P0-5): the fallback order with a background encoder.
    /// - `.foreground`: the last live IDR only (CL-5, as above);
    /// - `.backgroundEncoder`: that encoder's own last IDR first — the "Phone locked" card would be
    ///   wrong while the map is live, and every extra encoder change on the wire is a risk — then the
    ///   hold picture, then any live IDR of the canvas;
    /// - `.hold`: the hold picture, then the live IDR.
    /// Each source is asked only when the previous one had nothing (`hold` advances a round-robin).
    static func keyframe(_ context: Context, backgroundEncoder: () -> EncodedFrame?, hold: () -> EncodedFrame?,
                         live: () -> EncodedFrame?) -> EncodedFrame? {
        switch context {
        case .foreground: return live()
        case .backgroundEncoder: return backgroundEncoder() ?? hold() ?? live()
        case .hold: return hold() ?? live()
        }
    }
}

/// Records the exact access units sent to the dash as a raw Annex-B `.h264` file (Android
/// DUMP_H264, 600-AU cap; media-video.md §7.7, §15.8) — open it with ffprobe / ffplay.
public final class H264WireDump: @unchecked Sendable {
    public let url: URL
    public let maxFrames: Int
    private let lock = NSLock()
    private var handle: FileHandle?
    private var _framesWritten = 0

    /// Creates / truncates the file.
    public init(url: URL, maxFrames: Int = 600) throws {
        self.url = url
        self.maxFrames = max(1, maxFrames)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
    }

    deinit { close() }

    public var framesWritten: Int { lock.lock(); defer { lock.unlock() }; return _framesWritten }
    public var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return handle == nil }

    /// Appends one access unit; returns false once the cap is reached or the file is closed.
    @discardableResult
    public func write(_ frame: EncodedFrame) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let h = handle else { return false }
        do {
            try h.write(contentsOf: frame.accessUnit)
        } catch {
            try? h.close()
            handle = nil
            return false
        }
        _framesWritten += 1
        if _framesWritten >= maxFrames {
            try? h.close()
            handle = nil
            Log.i("DUMP", "complete: \(url.lastPathComponent) (\(_framesWritten) frames)")
        }
        return true
    }

    public func close() {
        lock.lock()
        let h = handle
        handle = nil
        lock.unlock()
        try? h?.close()
    }
}

/// Counts events in a sliding window (frames per second).
struct RateMeter {
    let window: TimeInterval
    private var stamps: [TimeInterval] = []
    init(window: TimeInterval = 2) { self.window = window }
    mutating func add(_ t: TimeInterval) {
        stamps.append(t)
        trim(t)
    }
    mutating func rate(now: TimeInterval) -> Double {
        trim(now)
        return Double(stamps.count) / window
    }
    private mutating func trim(_ now: TimeInterval) {
        let cut = now - window
        if let i = stamps.firstIndex(where: { $0 > cut }) {
            if i > 0 { stamps.removeFirst(i) }
        } else {
            stamps.removeAll()
        }
    }
}

// MARK: - Engine (Apple platforms)

#if canImport(VideoToolbox) && canImport(CoreGraphics) && canImport(CoreText)
import CoreGraphics
import CoreVideo
import VideoToolbox

/// Snapshot of the projection engine state (phone UI / logs).
public struct DashProjectionStats: Sendable, Equatable {
    public var mode: DashProjectionEngine.Mode = .idle
    public var canvas: VideoCanvas?
    /// Parameters after thermal / power / background caps.
    public var effectiveParameters = EncoderParameters()
    public var renderedFrames = 0
    public var encodeSubmissions = 0
    public var repeatedFrames = 0
    public var outputFrames = 0
    public var outputKeyframes = 0
    public var outputFPS: Double = 0
    /// REQ 114 pulls per second (the dash's demand).
    public var pullRate: Double = 0
    public var pullsServed = 0
    public var pullsUnanswered = 0
    public var fallbackKeyframesServed = 0
    public var holdFramesServed = 0
    public var lastRenderMs: Double = 0
    public var averageRenderMs: Double = 0
    public var averageEncodeMs: Double = 0
    public var queueOverflows = 0
    public var gatedDrops = 0
    public var poolExhausted = 0
    public var encoderErrors = 0
    public var usingHardwareEncoder: Bool?
    public var thermalLevel: ThermalLevel = .none
    public var lowPowerMode = false
    // ADDITION (locked iPhone, Phase 0).
    /// The encoder now feeding the dash (`DashEncoderKind.description`): `vt-hw` in the foreground,
    /// `vt-sw` / `cpu-<backend>` in backgroundSoftware, `hold` in hold; nil when idle / stopped.
    public var encoder: String?
    /// Seconds since the current background period began; 0 in the foreground.
    public var backgroundSeconds: Double = 0
    /// The background frame-rate cap in effect while backgroundSoftware (Phase 0: `backgroundFrameRate`;
    /// Phase 1: the budget); nil otherwise.
    public var backgroundFpsCap: Int?
    /// Background encoders demoted since the engine was created.
    public var demotions = 0
    /// Process CPU % of one core (100 = one core busy), latest background measurement; nil until measured.
    public var cpuPercent: Double?
    public init() {}
}

/// `VideoFrameSource` for the app's own dash UI.
///
/// Usage (app layer):
/// ```
/// let engine = DashProjectionEngine(renderer: DashRenderer(tileCache: tiles))
/// engine.displayListProvider = { now in uiController.displayList(now: now) }
/// engine.holdDisplayListProvider = { now in uiController.holdDisplayList(now: now) }
/// tiles.onTileLoaded = { [weak engine] _ in engine?.invalidate() }
/// engine.attach(thermalMonitor: thermal)
/// let link = EasyConnLink(configuration: cfg, network: provider, frameSource: engine, signer: signer)
///                                       // the link calls prepare / resynchronize / nextFrame
/// // UIApplication lifecycle:
/// willResignActive  → engine.prepareHoldPicture(); engine.prepareBackgroundEncoder()
/// didEnterBackground → engine.enterBackground()
/// didBecomeActive   → engine.enterForeground()
/// ```
/// Thread-safe. Rendering and encoding run on one serial queue; providers are called there.
///
/// Locked iPhone (Phase 0, design §3.3): every encoder is a `DashVideoEncoder`. In the foreground it
/// is the VideoToolbox hardware session (`own`). At `.background` the engine runs the BACKGROUND
/// LADDER of `lockedStreamPolicy` (Core `BackgroundEncoderLadder`): a VideoToolbox software session
/// (the one pre-warmed at `.inactive`, then fresh ones, then one per non-hardware `EncoderID`), the
/// CPU encoder of `cpuEncoderFactory` when there is one, and the pre-encoded hold picture last. A
/// candidate is accepted only after its probe IDR passed `EncoderAcceptance` and `H264StreamCheck`;
/// nothing of a rejected candidate reaches the dash. A live background encoder is demoted by
/// `EncoderHealth`; a hold reached by a demotion is retried. Every encoder instance stamps its own
/// `EncodedFrame.encoderTag`, and every change of encoder on the wire happens at an IDR.
public final class DashProjectionEngine: VideoFrameSource, @unchecked Sendable {
    public enum Mode: String, Sendable, Equatable {
        /// No canvas yet.
        case idle
        /// Hardware VideoToolbox encoding at the frame-rate cap.
        case foreground
        /// A background encoder (VideoToolbox software, iOS 17.4+; or the CPU encoder) at
        /// `backgroundFrameRate`.
        case backgroundSoftware
        /// No encoder: pulls are answered with the pre-encoded hold IDR(s).
        case hold
        /// `stop()` was called.
        case stopped
    }

    public typealias DisplayListProvider = @Sendable (TimeInterval) -> DashDisplayList

    /// What the engine asks for when it makes a VideoToolbox encoder (internal test seam
    /// `encoderFactory`; `H264Encoder(label:allowSoftware:encoderID:)` otherwise).
    struct EncoderRequest: Sendable, Equatable {
        var label: String
        var software: Bool
        var encoderID: String?
    }

    /// `EncodedFrame.encoderTag` of the pre-encoded hold IDRs; live encoders get 2, 3, … (never reused).
    static let holdTag: UInt32 = 1
    static let firstEncoderTag: UInt32 = 2
    /// The `.inactive` pre-warm probe waits this long for its IDR (the background probe:
    /// `EncoderAcceptance.videoToolboxProbeLimitMs`).
    static let preWarmProbeWaitMs: Double = 300
    /// At most this many `EncoderID` sessions are tried in the background.
    static let maxEncoderIDTries = 3

    /// Encoded size (canvas width × height) a cached IDR belongs to.
    private struct PictureSize: Equatable {
        let width: Int
        let height: Int
        init(_ c: VideoCanvas) { width = c.width; height = c.height }
    }

    /// Where the output of one encoder instance goes. The target only changes on the render queue;
    /// a VideoToolbox thread delivers under the same lock, so once a route is dropped nothing of that
    /// encoder can reach the frame queue any more (not even an output racing the switch).
    private final class EncoderRoute: @unchecked Sendable {
        enum Target {
            /// A probe encode is waiting for its IDR: never the frame queue.
            case probe(ProbeSink)
            /// The encoder feeds the dash.
            case live
            /// Rejected, replaced or not decided yet: outputs are discarded.
            case dropped
        }

        let tag: UInt32
        let size: PictureSize
        private let lock = NSLock()
        private var target: Target = .dropped

        init(tag: UInt32, size: PictureSize) {
            self.tag = tag
            self.size = size
        }

        var current: Target { lock.lock(); defer { lock.unlock() }; return target }

        func set(_ newTarget: Target) {
            lock.lock()
            target = newTarget
            lock.unlock()
        }

        func drop() { set(.dropped) }

        func deliver(_ frame: EncodedFrame, live: (EncodedFrame) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            switch target {
            case let .probe(sink): sink.deliver(frame)
            case .live: live(frame)
            case .dropped: break
            }
        }

        /// Pushes `first` (the accepted probe IDR) through `live`, then routes every later output there.
        func goLive(first: EncodedFrame, live: (EncodedFrame) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            live(first)
            target = .live
        }
    }

    /// Collects the outcome of one probe encode (a forced IDR of the last picture).
    private final class ProbeSink: @unchecked Sendable {
        enum Result {
            case frame(EncodedFrame, at: TimeInterval)
            case failure(DashEncoderFailure?)
            case timeout
        }

        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)
        /// Earliest PTS of this probe's IDR: a late output of an earlier probe of the same session (the
        /// `.inactive` pre-warm) has an older one. Producers that leave the PTS at 0 are accepted.
        private let notBefore: TimeInterval
        private var result: Result?

        init(notBefore: TimeInterval) {
            self.notBefore = notBefore
        }

        func deliver(_ frame: EncodedFrame) {
            guard frame.isKeyframe, frame.presentationTime == 0 || frame.presentationTime >= notBefore else { return }
            finish(.frame(frame, at: ProcessInfo.processInfo.systemUptime))
        }

        func fail(_ failure: DashEncoderFailure) { finish(.failure(failure)) }

        /// Waits up to `milliseconds` for the IDR (or a failure).
        func wait(milliseconds: Double) -> Result {
            _ = done.wait(timeout: .now() + .milliseconds(max(0, Int(milliseconds.rounded()))))
            lock.lock()
            defer { lock.unlock() }
            return result ?? .timeout
        }

        /// The probe encode was refused: the failure it reported, if any.
        var refusal: Result {
            lock.lock()
            defer { lock.unlock() }
            if case let .failure(f)? = result { return .failure(f) }
            return .failure(nil)
        }

        private func finish(_ r: Result) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            result = r
            lock.unlock()
            done.signal()
        }
    }

    /// A background candidate that passed its probe.
    private struct Candidate {
        let encoder: any DashVideoEncoder
        let route: EncoderRoute
        let rung: BackgroundRung
        let probeIDR: EncodedFrame
    }

    /// The VideoToolbox software session made at `.inactive` (`own-sw-pre`).
    private struct PreWarmed {
        let encoder: any DashVideoEncoder
        let route: EncoderRoute
        let size: PictureSize
        /// Its `create=` text (`noErr`).
        let create: String
    }

    /// `EncoderHealth` of the live background encoder `tag`, and how many frames it output.
    private struct TrackedHealth {
        var tag: UInt32
        var health: EncoderHealth
        var outputs = 0
    }

    /// Counters at the start of the background period (the L9 / L13 numbers are differences).
    private struct PeriodCounters {
        var served = 0
        var hold = 0
        var fallback = 0
        var unanswered = 0
        var errors = 0
    }

    /// The background CPU dry run (Phase 0 build, P0-8).
    private struct DryRunState {
        var startedAt: TimeInterval
        var lastReportAt: TimeInterval
        var iterations = 0
        var renderMs = 0.0
        var convertMs = 0.0
        var loadMs = 0.0
        var frame: I420Frame
    }

    private enum LadderReason {
        /// `.background` (or a prepare while backgrounded).
        case entry
        /// From a retryable hold (`BackgroundEncoderLadder.shouldRetry`).
        case retry
        /// The live background encoder was demoted: continue at the next rung (no L4).
        case demotion
        /// A new canvas while backgrounded.
        case canvasChange
    }

    private struct Shared {
        var displayListProvider: DisplayListProvider?
        var holdDisplayListProvider: DisplayListProvider?
        var previewHandler: (@Sendable (CGImage) -> Void)?
        var onStats: (@Sendable (DashProjectionStats) -> Void)?
        var onPrepared: (@Sendable (VideoCanvas) -> Void)?
        var requested = EncoderParameters()
        var thermalLevel: ThermalLevel = .none
        var lowPowerMode = false
        var keyframeRequested = false
        /// `keyframesOutput` when the newest `requestKeyframe()` was made.
        var keyframeRequestMark: UInt64 = 0
        /// Keyframes output by the live encoder(s) so far (coalescing, `KeyframeCoalescer`).
        var keyframesOutput: UInt64 = 0
        var invalidated = false
        var mode: Mode = .idle
        var holdFrames: [EncodedFrame] = []
        var holdIndex = 0
        /// The canvas the hold IDRs were encoded at (only served for that canvas).
        var holdCanvas: PictureSize?
        /// The canvas of the current session (mirrors the render-queue `canvas`; nil when idle /
        /// stopped) and the last live IDR with the canvas it was encoded at (MP-3: a cached IDR is
        /// only ever re-sent for the canvas it was made for, and never across sessions).
        var canvasSize: PictureSize?
        var lastLiveKeyframe: (frame: EncodedFrame, size: PictureSize)?
        var stats = DashProjectionStats()
        var dump: H264WireDump?
        var pullMeter = RateMeter()
        var outputMeter = RateMeter()
        var cpuEncoderFactory: (@Sendable (_ label: String) -> any DashVideoEncoder)?
        var batteryProvider: (@Sendable () -> BatteryStatus?)?
        // Locked iPhone, Phase 0.
        var encoderFactory: (@Sendable (EncoderRequest) -> any DashVideoEncoder)?
        var holdFramesEncoder: (@Sendable (CVPixelBuffer, Int, Int, EncoderParameters) -> [EncodedFrame])?
        var encoderListProvider: (@Sendable () -> [BackgroundLog.EncoderListEntry])?
        var softwareEncodingAvailable: (@Sendable () -> Bool)?
        /// The `avc1` encoder list (L2), for the `EncoderID` tries.
        var encoderList: [BackgroundLog.EncoderListEntry]?
        /// The name of the encoder feeding the dash (`stats.encoder`): `vt-hw`, `vt-sw`, `hold`, …
        var feeding: String?
        /// The tag of the live background encoder (the first P0-5 fallback); nil when there is none.
        var backgroundTag: UInt32?
        /// Encoder name of every tag (L8).
        var tagNames: [UInt32: String] = [DashProjectionEngine.holdTag: "hold"]
        /// The tag of the last frame served to the dash.
        var lastServedTag: UInt32?
        /// When the last L7 `[switch]` line was logged (L8 `… after the switch`).
        var pendingSwitchAt: TimeInterval?
        var health: TrackedHealth?
        /// Start of the current background period (nil in the foreground).
        var backgroundSince: TimeInterval?
        var periodBase = PeriodCounters()
        /// The background encoders of the current period, in order (L13).
        var summaries: [BackgroundLog.EncoderSummary] = []
        var summaryIndex: [UInt32: Int] = [:]
    }

    public let renderer: DashRenderer
    /// The queue the dash pulls from (capacity 3, GOP-safe overflow, keyframe gate).
    public let frameQueue: FrameQueue
    private let clock: any MonotonicClock
    private let renderQueue = DispatchQueue(label: "ocm.dash.render", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let shared = Locked(Shared())
    /// L2 is logged once per app run (by whichever engine prepares first in the foreground).
    private static let encoderListLogged = Locked(false)

    // Configuration flags (set before use; read on the render queue).
    /// Apply the thermal caps of `ThermalCaps` (disable when the Auto power mode's AdaptivePolicy
    /// already reacts to the thermal level, to avoid reducing twice).
    public var appliesThermalCaps: Bool { get { flags.current.thermal } set { flags.withLock { $0.thermal = newValue } } }
    /// Cap the frame rate at 15 fps in Low Power Mode.
    public var appliesLowPowerCap: Bool { get { flags.current.lowPower } set { flags.withLock { $0.lowPower = newValue } } }
    /// Frame-rate cap of the software encoder in the background (5–10 fps recommended).
    public var backgroundFrameRate: Int { get { flags.current.backgroundFps } set { flags.withLock { $0.backgroundFps = max(1, newValue) } } }
    /// Try a background encoder before falling back to the hold IDR. Alias of `lockedStreamPolicy`
    /// (locked iPhone, Phase 0): true when the policy is not `.holdOnly`; setting false selects
    /// `.holdOnly`, setting true selects `.automatic` when it was `.holdOnly` (else no change).
    public var allowsSoftwareEncodingInBackground: Bool {
        get { flags.current.policy != .holdOnly }
        set {
            flags.withLock { f in
                if !newValue {
                    f.policy = .holdOnly
                } else if f.policy == .holdOnly {
                    f.policy = .automatic
                }
            }
        }
    }
    /// Second forced IDR after a resync ("after the first map paint", EasyConnProber.kt:286-292); nil
    /// = off (default). Android sends it only for the soft AA → map switch without a new 112
    /// (media-video.md §6.1); a regular 112 gets ONE IDR, and the periodic 1 s IDR covers the rest.
    public var secondKeyframeDelay: TimeInterval? { get { flags.current.secondIDR } set { flags.withLock { $0.secondIDR = newValue } } }
    /// Maximum preview rate (frames per second).
    public var previewMaxFPS: Double { get { flags.current.previewFps } set { flags.withLock { $0.previewFps = max(0.1, newValue) } } }

    // MARK: locked iPhone (Phase 0)

    /// ADDITION (locked iPhone, Phase 0): what the dash gets while the app is in the background — the
    /// rungs of the background ladder (Core `BackgroundEncoderLadder.rungs`). Default `.automatic`; the
    /// Phase 0 app sets `.videoToolboxSoftwareOnly`. Any thread; read at every ladder run (background
    /// entry, retry, canvas change while backgrounded). `allowsSoftwareEncodingInBackground` is an
    /// alias of it (false = `.holdOnly`).
    public var lockedStreamPolicy: LockedStreamPolicy {
        get { flags.current.policy } set { flags.withLock { $0.policy = newValue } }
    }

    /// ADDITION (locked iPhone, Phase 0): makes the background CPU encoder (rung 2) for a label
    /// (`own-cpu`); nil = no rung 2 (the Phase 0 app leaves it nil). Any thread; read at ladder runs.
    public var cpuEncoderFactory: (@Sendable (_ label: String) -> any DashVideoEncoder)? {
        get { shared.current.cpuEncoderFactory } set { shared.withLock { $0.cpuEncoderFactory = newValue } }
    }

    /// ADDITION (locked iPhone, Phase 0 build only): in hold, during the first 10 minutes of every
    /// background period, render the live UI at 8 fps, convert it to I420 on the CPU (vImage), burn
    /// 10 ms of synthetic load and discard the result (never sent), logging `[bg-probe]` lines.
    /// Default false.
    public var backgroundDryRun: Bool {
        get { flags.current.dryRun } set { flags.withLock { $0.dryRun = newValue } }
    }

    /// ADDITION (locked iPhone, Phase 0): the battery state for the background budget (Phase 1).
    /// Called on the render queue: it must be cheap and thread-safe. nil = unknown. The Phase 0 engine
    /// stores it (no Phase 0 engine line carries the battery).
    public var batteryProvider: (@Sendable () -> BatteryStatus?)? {
        get { shared.current.batteryProvider } set { shared.withLock { $0.batteryProvider = newValue } }
    }

    /// ADDITION (locked iPhone, Phase 0): the app is becoming `.inactive` (call right after
    /// `prepareHoldPicture`; both run on the render queue in call order): pre-warm the VideoToolbox
    /// software session (`own-sw-pre`) and probe it once with the last picture, into a probe sink —
    /// never into the frame queue, the hardware encoder is still live. The session is re-pointed and
    /// probed again at `.background`, or invalidated when the app becomes `.active` first (also at
    /// `stop()` and at a canvas change). Only in the foreground with a canvas, when the policy's rungs
    /// contain vt-sw. Logs L3.
    public func prepareBackgroundEncoder() {
        renderQueue.async { [weak self] in self?.applyPreWarm() }
    }

    // MARK: test seams (internal; set before use)

    /// Makes the VideoToolbox encoders (`own`, `own-sw-pre`, `own-sw`, `own-sw-id`); nil =
    /// `H264Encoder`. Tests inject `FakeDashVideoEncoder`.
    var encoderFactory: (@Sendable (EncoderRequest) -> any DashVideoEncoder)? {
        get { shared.current.encoderFactory } set { shared.withLock { $0.encoderFactory = newValue } }
    }

    /// Encodes the hold picture (picture, width, height, parameters → IDRs); nil =
    /// `H264Encoder.encodeStill(count: 2, timeout: 0.6)`.
    var holdFramesEncoder: (@Sendable (CVPixelBuffer, Int, Int, EncoderParameters) -> [EncodedFrame])? {
        get { shared.current.holdFramesEncoder } set { shared.withLock { $0.holdFramesEncoder = newValue } }
    }

    /// The `avc1` encoder list (L2, `EncoderID` tries); nil = `H264Encoder.listAvailableEncoders()`.
    var encoderListProvider: (@Sendable () -> [BackgroundLog.EncoderListEntry])? {
        get { shared.current.encoderListProvider } set { shared.withLock { $0.encoderListProvider = newValue } }
    }

    /// Whether the vt-sw rung is available; nil = `H264Encoder.isSoftwareEncodingSupported`.
    var softwareEncodingAvailable: (@Sendable () -> Bool)? {
        get { shared.current.softwareEncodingAvailable } set { shared.withLock { $0.softwareEncodingAvailable = newValue } }
    }

    /// The L9 status interval (10 s).
    var backgroundStatusInterval: TimeInterval {
        get { flags.current.statusInterval } set { flags.withLock { $0.statusInterval = max(0.01, newValue) } }
    }

    /// How long the dry run lasts in each background period (600 s), and its L10 interval (60 s).
    var dryRunDuration: TimeInterval {
        get { flags.current.dryRunDuration } set { flags.withLock { $0.dryRunDuration = newValue } }
    }

    var dryRunReportInterval: TimeInterval {
        get { flags.current.dryRunReportInterval } set { flags.withLock { $0.dryRunReportInterval = newValue } }
    }

    /// Lets the next foreground prepare log L2 again (L2 is once per process).
    static func resetEncoderListLogForTesting() {
        encoderListLogged.set(false)
    }

    private struct Flags {
        var thermal = true
        var lowPower = true
        var backgroundFps = 8
        var secondIDR: TimeInterval?
        var previewFps = 5.0
        var policy: LockedStreamPolicy = .automatic
        var dryRun = false
        var statusInterval: TimeInterval = 10
        var dryRunDuration: TimeInterval = 600
        var dryRunReportInterval: TimeInterval = 60
        var dryRunFps = 8
        var dryRunLoadMs = 10.0
    }
    private let flags = Locked(Flags())

    // Render-queue confined state.
    private var canvas: VideoCanvas?
    private var factory: PixelBufferFactory?
    /// The encoder feeding the dash (nil in hold).
    private var encoder: (any DashVideoEncoder)?
    /// Its route (the tag of what it outputs).
    private var liveRoute: EncoderRoute?
    /// The rung of the live background encoder (nil in the foreground and in hold).
    private var backgroundRung: BackgroundRung?
    private var timer: DispatchSourceTimer?
    private var timerFPS = 0
    private var lastList: DashDisplayList?
    private var lastPixelBuffer: CVPixelBuffer?
    private var pictureNotEncoded = false
    private var pendingDirty = false
    private var keyframes = KeyframeCoalescer()
    private var lastEncodeAt: TimeInterval?
    private var lastPreviewAt: TimeInterval = -.greatestFiniteMagnitude
    private var renderMsAverage: Double = 0
    private var lastStatsPublish: TimeInterval = 0
    private var appliedParameters: EncoderParameters?
    /// The app is in the background (set even before any canvas exists).
    private var backgrounded = false
    private var nextEncoderTag: UInt32 = DashProjectionEngine.firstEncoderTag
    private var preWarm: PreWarmed?
    /// Why the engine is in hold (nil otherwise), since when, and the retries of this background period.
    private var holdCause: HoldCause?
    private var holdSince: TimeInterval = 0
    private var retryAttempts = 0
    /// The CPU encoder's backend (`minih264`), learned from the factory's encoder.
    private var cpuBackend: String?
    private var cpuMeter = ProcessCPUMeter()
    private var statusTimer: DispatchSourceTimer?
    private var dryRun: DryRunState?
    private var dryRunTimer: DispatchSourceTimer?
#if canImport(Accelerate)
    private var converter: BGRAToI420Converter?
    private var converterUnavailable = false
#endif

    public init(renderer: DashRenderer = DashRenderer(), queueCapacity: Int = 3,
                clock: any MonotonicClock = SystemMonotonicClock()) {
        self.renderer = renderer
        frameQueue = FrameQueue(capacity: queueCapacity)
        self.clock = clock
        renderQueue.setSpecific(key: queueKey, value: 1)
        frameQueue.onKeyframeNeeded = { [weak self] in self?.requestKeyframe() }
    }

    deinit {
        timer?.cancel()
        statusTimer?.cancel()
        dryRunTimer?.cancel()
        encoder?.invalidate()
        preWarm?.encoder.invalidate()
    }

    // MARK: configuration

    /// Builds the dash UI for a given monotonic time. Called on the render queue each tick.
    public var displayListProvider: DisplayListProvider? {
        get { shared.current.displayListProvider }
        set { shared.withLock { $0.displayListProvider = newValue }; invalidate() }
    }

    /// The picture served while backgrounded without an encoder (e.g. "Phone locked — map paused").
    /// nil = the current dash UI.
    public var holdDisplayListProvider: DisplayListProvider? {
        get { shared.current.holdDisplayListProvider }
        set { shared.withLock { $0.holdDisplayListProvider = newValue } }
    }

    /// Latest rendered frame for the phone "Dash view" (≤ `previewMaxFPS`, render queue thread).
    public var previewHandler: (@Sendable (CGImage) -> Void)? {
        get { shared.current.previewHandler }
        set { shared.withLock { $0.previewHandler = newValue } }
    }

    /// Called about once per second with fresh statistics (render queue thread).
    public var onStats: (@Sendable (DashProjectionStats) -> Void)? {
        get { shared.current.onStats }
        set { shared.withLock { $0.onStats = newValue } }
    }

    /// Called (on the link's task, after `prepare` returned) with the canvas the encoder was just
    /// prepared at — REQ 16, a REQ 16 without a usable size that kept the previous canvas, or 112
    /// without 16. The app lays the dash UI out for exactly this canvas.
    public var onPrepared: (@Sendable (VideoCanvas) -> Void)? {
        get { shared.current.onPrepared }
        set { shared.withLock { $0.onPrepared = newValue } }
    }

    /// Requested encoder parameters (profile × quality × power mode / adaptive policy). Live:
    /// bitrate and frame-rate cap change without re-creating the session.
    public var parameters: EncoderParameters {
        get { shared.current.requested }
        set {
            shared.withLock { $0.requested = newValue }
            onRenderQueue { self.applyEffectiveParameters() }
        }
    }

    /// Parameters actually used (after thermal / Low Power / background caps).
    public var effectiveParameters: EncoderParameters {
        let s = shared.current
        return effective(requested: s.requested, thermal: s.thermalLevel, lowPower: s.lowPowerMode, mode: s.mode)
    }

    public var mode: Mode { shared.current.mode }

    public var stats: DashProjectionStats {
        let state = shared.current
        var s = state.stats
        s.mode = state.mode
        s.thermalLevel = state.thermalLevel
        s.lowPowerMode = state.lowPowerMode
        s.queueOverflows = frameQueue.overflowCount
        s.gatedDrops = frameQueue.gatedDropCount
        s.encoder = state.feeding
        s.backgroundSeconds = state.backgroundSince.map { max(0, clock.now() - $0) } ?? 0
        s.backgroundFpsCap = state.mode == .backgroundSoftware
            ? effective(requested: state.requested, thermal: state.thermalLevel, lowPower: state.lowPowerMode,
                        mode: .backgroundSoftware).frameRate
            : nil
        return s
    }

    /// The UI changed outside the display list (e.g. a tile finished loading): re-render soon.
    public func invalidate() {
        shared.withLock { $0.invalidated = true }
    }

    /// Feeds the thermal / power state (or use `attach(thermalMonitor:)`).
    public func setThermalState(level: ThermalLevel, lowPowerMode: Bool) {
        shared.withLock { $0.thermalLevel = level; $0.lowPowerMode = lowPowerMode }
        onRenderQueue { self.applyEffectiveParameters() }
    }

#if canImport(Darwin)
    /// Follows a `ThermalMonitor` (returns the observer id for `removeObserver`).
    @discardableResult
    public func attach(thermalMonitor: ThermalMonitor) -> UUID {
        thermalMonitor.addObserver { [weak self] state in
            self?.setThermalState(level: state.level, lowPowerMode: state.isLowPowerModeEnabled)
        }
    }
#endif

    /// Records every served access unit to `url` (raw Annex-B), up to `maxFrames`.
    public func startWireDump(to url: URL, maxFrames: Int = 600) throws {
        let dump = try H264WireDump(url: url, maxFrames: maxFrames)
        let old = shared.withLock { s -> H264WireDump? in let o = s.dump; s.dump = dump; return o }
        old?.close()
        Log.i("DUMP", "recording H.264 → \(url.lastPathComponent) (first \(maxFrames) frames)")
    }

    public func stopWireDump() {
        let old = shared.withLock { s -> H264WireDump? in let o = s.dump; s.dump = nil; return o }
        old?.close()
    }

    /// True once the recording `startWireDump` opened closed itself (`maxFrames` written, or a write
    /// failed); false while it records and after `stopWireDump()`.
    public var isWireDumpFinished: Bool {
        let dump = shared.withLock { s -> H264WireDump? in s.dump }
        return dump?.isFinished ?? false
    }

    // MARK: VideoFrameSource

    public func prepare(canvas newCanvas: VideoCanvas, parameters: EncoderParameters) {
        guard newCanvas.width >= 16, newCanvas.height >= 16 else {
            Log.w("VIDEO", "prepare: ignoring invalid canvas \(newCanvas)")
            return
        }
        shared.withLock { $0.requested = parameters }
        onRenderQueueSync { self.applyPrepare(newCanvas) }
        shared.current.onPrepared?(newCanvas)
    }

    public func resynchronize() {
        // Re-render for the resync IDR (not just re-encode the last picture): it may predate a
        // change made while the dash was away — e.g. the "Reconnecting…" banner cleared when the
        // dash identified itself again. Then gate closed BEFORE flushing (FrameQueue) and ONE IDR
        // request (FrameQueue.onKeyframeNeeded → requestKeyframe), coalesced with any in flight.
        shared.withLock { $0.invalidated = true }
        frameQueue.resynchronize()
        Log.d("VIDEO", "resynchronize: keyframe gate closed, queue flushed, IDR requested")
        if let delay = secondKeyframeDelay, delay > 0 {
            renderQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isEncodingMode else { return }
                self.markKeyframePending()
                self.tick()
            }
        }
    }

    public func nextFrame(timeout: TimeInterval) async -> EncodedFrame? {
        let now = clock.now()
        let mode = shared.withLock { s -> Mode in s.pullMeter.add(now); return s.mode }
        if mode == .hold {
            // Nothing is encoded: answer with the hold IDR(s), at the keep-alive cadence.
            let wait = min(max(0.05, timeout - FramePull.safetyMargin), effectiveParameters.repeatLastFrameAfter)
            if let f = await frameQueue.next(timeout: wait) { return served(f, hold: false) }
            if let hold = nextHoldFrame() { return served(hold, hold: true) }
            shared.withLock { $0.stats.pullsUnanswered += 1 }
            return nil
        }
        // Answer within one encode latency: render now rather than at the next timer tick. Not with a
        // background encoder (locked iPhone): there the render timer at the background cap paces the
        // stream (design §3.6, "at most the cap while the map moves"); a pull-triggered tick would render
        // and encode at the dash's pull rate (about 24/s while the map moves) instead of the cap.
        if frameQueue.pendingCount == 0, mode != .backgroundSoftware {
            renderQueue.async { [weak self] in self?.tick() }
        }
        guard mode != .stopped else { return nil }
        let result = await FramePull.next(from: frameQueue, timeout: timeout) { [weak self] in
            guard let self, self.shared.current.mode != .stopped else { return nil }
            return self.holdOrLastKeyframe()
        }
        guard let frame = result.frame else {
            shared.withLock { $0.stats.pullsUnanswered += 1 }
            Log.shared.throttled("pull-none", interval: 5, .warn, "VIDEO", "REQ_RV_DATA_NEXT(114): no frame ready")
            return nil
        }
        if result.usedFallback {
            shared.withLock { $0.stats.fallbackKeyframesServed += 1 }
            Log.shared.throttled("pull-fallback", interval: 5, .warn, "VIDEO", "114 timed out → re-sent the last IDR")
        }
        return served(frame, hold: false)
    }

    public func mediaStopped() {
        frameQueue.flush()
        Log.i("VIDEO", "media sockets closed → queue flushed")
    }

    // MARK: lifecycle

    /// Renders the hold picture (`holdDisplayListProvider`, else the current UI) and pre-encodes
    /// it as IDRs with a temporary session. Call from `willResignActive` — while the hardware
    /// encoder is still available. The negotiated canvas is used; before any REQ 16 the picture is
    /// made at `expectedCanvas` (the session's learned / default canvas) and kept for a dash that
    /// negotiates that size while the app is in the background (MP-2). `completion` (render
    /// queue) reports success.
    public func prepareHoldPicture(expectedCanvas: VideoCanvas? = nil, completion: (@Sendable (Bool) -> Void)? = nil) {
        renderQueue.async { [weak self] in
            guard let self else { completion?(false); return }
            let ok = self.buildHoldFrames(expected: expectedCanvas)
            completion?(ok)
        }
    }

    /// The app went to the background: stop hardware encoding and run the background ladder of
    /// `lockedStreamPolicy` (a background encoder at `backgroundFrameRate`, else the hold IDR).
    public func enterBackground() {
        renderQueue.async { [weak self] in self?.applyBackground() }
    }

    /// The app is active again: recreate the hardware session and start with an IDR.
    public func enterForeground() {
        renderQueue.async { [weak self] in self?.applyForeground() }
    }

    /// Stops rendering / encoding and wakes pending pulls with nil.
    public func stop() {
        onRenderQueueSync {
            self.timer?.cancel()
            self.timer = nil
            self.timerFPS = 0
            self.cancelStatusTimer()
            self.stopDryRun()
            self.invalidatePreWarm()
            self.retireLiveEncoder()
            self.backgroundRung = nil
            self.holdCause = nil
            self.factory = nil
            self.canvas = nil
            self.lastPixelBuffer = nil
            self.lastList = nil
            self.shared.withLock {
                $0.mode = .stopped
                $0.stats.mode = .stopped
                $0.canvasSize = nil
                $0.lastLiveKeyframe = nil // never seed a later session's hold with this ride's map
                // The pre-encoded hold IDRs (lock notice, tagged with their canvas) are kept: a
                // session that resumes while the phone is still locked (e.g. after the Wi-Fi park)
                // needs them; foreground use never serves them.
                $0.feeding = nil
                $0.backgroundTag = nil
                $0.health = nil
                $0.pendingSwitchAt = nil
            }
        }
        frameQueue.close()
        frameQueue.invalidateKeyframe()
        Log.i("VIDEO", "projection stopped")
    }

    // MARK: render queue

    private var isEncodingMode: Bool {
        let m = shared.current.mode
        return m == .foreground || m == .backgroundSoftware
    }

    private func onRenderQueue(_ body: @escaping @Sendable () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil { body() } else { renderQueue.async(execute: body) }
    }

    private func onRenderQueueSync(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil { body() } else { renderQueue.sync(execute: body) }
    }

    private func effective(requested: EncoderParameters, thermal: ThermalLevel, lowPower: Bool, mode: Mode) -> EncoderParameters {
        let f = flags.current
        var p = ThermalCaps.apply(to: requested, level: thermal, lowPowerMode: lowPower, thermal: f.thermal, lowPower: f.lowPower)
        if mode == .backgroundSoftware { p.frameRate = min(p.frameRate, f.backgroundFps) }
        p.frameRate = min(60, max(1, p.frameRate))
        return p
    }

    private func currentEffective() -> EncoderParameters {
        let s = shared.current
        return effective(requested: s.requested, thermal: s.thermalLevel, lowPower: s.lowPowerMode, mode: s.mode)
    }

    /// The parameters of a background encoder: the effective ones with the background frame-rate
    /// cap (Phase 0 keeps today's bitrate; `BackgroundEncoderPlan` is Phase 1).
    private func backgroundParameters() -> EncoderParameters {
        let s = shared.current
        return effective(requested: s.requested, thermal: s.thermalLevel, lowPower: s.lowPowerMode, mode: .backgroundSoftware)
    }

    private static func blankList(_ canvas: VideoCanvas) -> DashDisplayList {
        DashDisplayList(size: DashSize(width: Double(canvas.width), height: Double(canvas.height)), background: .black)
    }

    private func applyPrepare(_ newCanvas: VideoCanvas) {
        let state = shared.current.mode
        if state == .stopped || state == .idle { frameQueue.reopen() }
        let sameSize = canvas.map { $0.width == newCanvas.width && $0.height == newCanvas.height } ?? false
        canvas = newCanvas
        let reset = !sameSize || factory == nil
        if reset {
            do {
                factory = try PixelBufferFactory(width: newCanvas.width, height: newCanvas.height)
            } catch {
                Log.e("VIDEO", "pixel buffer pool \(newCanvas.width)x\(newCanvas.height): \(error)")
                factory = nil
            }
            lastPixelBuffer = nil
            lastList = nil
            pictureNotEncoded = false
            lastEncodeAt = nil
            let size = PictureSize(newCanvas)
            shared.withLock {
                // Hold IDRs pre-encoded at this very size (expected canvas, MP-2) stay usable.
                if $0.holdCanvas != size {
                    $0.holdFrames = []
                    $0.holdCanvas = nil
                }
                $0.lastLiveKeyframe = nil
            }
            frameQueue.invalidateKeyframe() // an IDR of the old size must never answer a pull (MP-3)
            invalidatePreWarm() // made for the old canvas
            retireLiveEncoder()
        }
        shared.withLock { $0.canvasSize = PictureSize(newCanvas) }
        if state == .idle || state == .stopped {
            shared.withLock { $0.mode = .foreground }
        }
        let mode = shared.current.mode
        var ladderRan = false
        if backgrounded {
            if mode == .foreground {
                // The dash (re)connected while the app is in the background: never start the
                // hardware encoder there — run the background ladder.
                runLadder(from: nil, reason: .entry)
                ladderRan = true
            } else if reset {
                // A new canvas while backgrounded: rebuild the CURRENT rung at it through the ladder
                // (never the hardware encoder), or run the whole ladder when no rung is live.
                runLadder(from: mode == .backgroundSoftware ? backgroundRung : nil, reason: .canvasChange)
                ladderRan = true
            }
        } else if mode != .hold, encoder == nil {
            encoder = makeForegroundEncoder()
        }
        if !ladderRan { markKeyframePending() } // the ladder's probe IDR already starts the stream
        applyEffectiveParameters()
        shared.withLock { $0.stats.canvas = newCanvas }
        Log.i("VIDEO", "own display \(newCanvas.width)x\(newCanvas.height) prepared (mode \(shared.current.mode.rawValue))")
        if !backgrounded { logEncoderListOnce() }
    }

    /// The VideoToolbox encoder for a request (the test seam, else `H264Encoder`).
    private func makeVideoToolboxEncoder(_ request: EncoderRequest) -> any DashVideoEncoder {
        if let make = shared.current.encoderFactory { return make(request) }
        return H264Encoder(label: request.label, allowSoftware: request.software, encoderID: request.encoderID)
    }

    /// The foreground hardware encoder (`own`) at the canvas; it feeds the dash at once.
    private func makeForegroundEncoder() -> (any DashVideoEncoder)? {
        guard let c = canvas else { return nil }
        let enc = makeVideoToolboxEncoder(EncoderRequest(label: "own", software: false, encoderID: nil))
        let route = EncoderRoute(tag: takeTag(), size: PictureSize(c))
        route.set(.live)
        install(route, on: enc)
        keyframes.encoderReset() // a forced IDR of the previous session will never come out
        do {
            try enc.configure(width: c.width, height: c.height, parameters: currentEffective())
        } catch {
            // Kept configured: the encoder retries creation on the next encode.
            Log.w("VIDEO", "encoder (hardware) not ready: \(error)")
        }
        appliedParameters = enc.parameters
        liveRoute = route
        let name = enc.kind.description
        shared.withLock { s in
            s.feeding = name
            s.backgroundTag = nil
            Self.register(tag: route.tag, name: name, in: &s)
        }
        return enc
    }

    private func takeTag() -> UInt32 {
        let tag = nextEncoderTag
        nextEncoderTag = nextEncoderTag == .max ? Self.firstEncoderTag : nextEncoderTag + 1
        return tag
    }

    private static func register(tag: UInt32, name: String, in s: inout Shared) {
        s.tagNames[tag] = name
        guard s.tagNames.count > 64 else { return }
        let keep: Set<UInt32> = [holdTag, tag, s.lastServedTag ?? holdTag, s.backgroundTag ?? holdTag]
        if let oldest = s.tagNames.keys.filter({ !keep.contains($0) }).min() { s.tagNames[oldest] = nil }
    }

    /// Points an encoder's output and failures at `route`.
    private func install(_ route: EncoderRoute, on enc: any DashVideoEncoder) {
        enc.onFrame = { [weak self] frame in self?.deliver(frame, via: route) }
        enc.onFailure = { [weak self] failure in self?.deliverFailure(failure, via: route) }
    }

    /// Any thread: an output of the encoder of `route`, stamped with its tag.
    private func deliver(_ frame: EncodedFrame, via route: EncoderRoute) {
        var stamped = frame
        stamped.encoderTag = route.tag
        route.deliver(stamped) { encoderOutput($0, route: route) }
    }

    /// Any thread (synchronously from `encode` when VideoToolbox refused the frame).
    private func deliverFailure(_ failure: DashEncoderFailure, via route: EncoderRoute) {
        switch route.current {
        case let .probe(sink): sink.fail(failure)
        case .dropped: return
        case .live: liveEncoderFailed(failure, route: route)
        }
    }

    private func liveEncoderFailed(_ failure: DashEncoderFailure, route: EncoderRoute) {
        let now = clock.now()
        let verdict = shared.withLock { s -> EncoderHealth.Verdict? in
            s.stats.encoderErrors += 1
            if let i = s.summaryIndex[route.tag] { s.summaries[i].errors += 1 }
            guard s.health?.tag == route.tag else { return nil }
            return s.health?.health.failure(failure.message, requiresRecreation: failure.requiresRecreation, now: now)
        }
        if failure.requiresRecreation {
            renderQueue.async { [weak self] in self?.markKeyframePending(sessionLost: true) }
        }
        if case let .demote(reason)? = verdict {
            let tag = route.tag
            renderQueue.async { [weak self] in self?.demote(tag: tag, reason: reason) }
        }
    }

    /// Called under the route lock (see `EncoderRoute`).
    private func encoderOutput(_ frame: EncodedFrame, route: EncoderRoute) {
        let now = clock.now()
        shared.withLock { s in
            s.stats.outputFrames += 1
            if frame.isKeyframe {
                s.stats.outputKeyframes += 1
                s.keyframesOutput &+= 1 // counted before the push: see KeyframeCoalescer
                s.lastLiveKeyframe = (frame, route.size)
            }
            s.outputMeter.add(now)
            if s.health?.tag == route.tag {
                s.health?.health.output(now: now)
                s.health?.outputs += 1
            }
            if let i = s.summaryIndex[route.tag] {
                s.summaries[i].frames += 1
                if frame.isKeyframe { s.summaries[i].keyframes += 1 }
            }
        }
        frameQueue.push(frame)
    }

    /// Invalidates the encoder feeding the dash (nothing of it is pushed any more).
    private func retireLiveEncoder() {
        let route = liveRoute
        liveRoute = nil
        route?.drop()
        guard let enc = encoder else { return }
        encoder = nil
        let average = enc.averageEncodeMs
        enc.invalidate()
        guard let tag = route?.tag else { return }
        shared.withLock { s in
            if let i = s.summaryIndex[tag] { s.summaries[i].averageEncodeMs = average > 0 ? average : nil }
            if s.health?.tag == tag { s.health = nil }
        }
    }

    /// The last live IDR if it was encoded for the current canvas (nil otherwise).
    private func liveKeyframeForCurrentCanvas() -> EncodedFrame? {
        shared.withLock { s -> EncodedFrame? in
            guard let k = s.lastLiveKeyframe, let size = s.canvasSize, k.size == size else { return nil }
            return k.frame
        }
    }

    /// The last live IDR of the current canvas when the encoder `tag` produced it.
    private func liveKeyframeForCurrentCanvas(tag: UInt32?) -> EncodedFrame? {
        guard let tag, let k = liveKeyframeForCurrentCanvas(), k.encoderTag == tag else { return nil }
        return k
    }

    /// Hold IDRs usable at the current canvas.
    private func holdFramesForCurrentCanvas() -> Int {
        shared.withLock { s in s.holdCanvas != nil && s.holdCanvas == s.canvasSize ? s.holdFrames.count : 0 }
    }

    /// Called from FrameQueue (overflow / resync) and encoder errors.
    private func requestKeyframe() {
        shared.withLock {
            $0.keyframeRequested = true
            $0.keyframeRequestMark = $0.keyframesOutput
        }
        renderQueue.async { [weak self] in self?.tick() }
    }

    /// An IDR is needed (render queue). `sessionLost`: the encoder session was invalidated, so an
    /// IDR in flight will never come out.
    private func markKeyframePending(sessionLost: Bool = false) {
        if sessionLost { keyframes.encoderReset() }
        keyframes.request(outputs: shared.current.keyframesOutput)
    }

    private func applyEffectiveParameters() {
        let p = currentEffective()
        if let enc = encoder, appliedParameters != p {
            enc.update(parameters: p)
            appliedParameters = p
        }
        shared.withLock { $0.stats.effectiveParameters = p }
        updateTimer(fps: p.frameRate)
    }

    private func updateTimer(fps: Int) {
        guard isEncodingMode, canvas != nil else {
            timer?.cancel()
            timer = nil
            timerFPS = 0
            return
        }
        guard fps != timerFPS || timer == nil else { return }
        let interval = DispatchTimeInterval.microseconds(Int(1_000_000 / Double(max(1, fps))))
        if let t = timer {
            t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        } else {
            let t = DispatchSource.makeTimerSource(flags: [], queue: renderQueue)
            t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
        timerFPS = fps
    }

    /// One render-loop step (render queue only).
    private func tick() {
        guard isEncodingMode, let canvas, let factory else { return }
        let now = clock.now()
        let (provider, keyframeFlag, requestMark, outputs, invalidated, previewHandler) = shared.withLock {
            s -> (DisplayListProvider?, Bool, UInt64, UInt64, Bool, (@Sendable (CGImage) -> Void)?) in
            let r = (s.displayListProvider, s.keyframeRequested, s.keyframeRequestMark, s.keyframesOutput, s.invalidated,
                     s.previewHandler)
            s.keyframeRequested = false
            s.invalidated = false
            return r
        }
        if keyframeFlag { keyframes.request(outputs: requestMark) }
        if invalidated { pendingDirty = true }
        let forceIDR = keyframes.shouldForce(now: now, outputs: outputs)

        let list = provider?(now) ?? Self.blankList(canvas)
        let changed = pendingDirty || list != lastList
        let previewFps = flags.current.previewFps
        let previewDue = previewHandler != nil && shared.current.mode == .foreground && now - lastPreviewAt >= 1 / previewFps
        let enc = encoder
        let decision = ProjectionPacer.decide(.init(
            now: now,
            encoderReady: enc?.isConfigured ?? false,
            contentChanged: changed,
            keyframeRequested: forceIDR,
            queuedFrames: frameQueue.pendingCount,
            framesInFlight: enc?.framesInFlight ?? 0,
            lastEncodeAt: lastEncodeAt,
            hasPicture: lastPixelBuffer != nil,
            pictureNotEncoded: pictureNotEncoded,
            repeatAfter: max(0.05, currentEffective().repeatLastFrameAfter),
            previewDue: previewDue))

        if decision.render {
            if let buffer = factory.makeBuffer() {
                let t0 = clock.now()
                renderer.render(list, into: buffer)
                let ms = (clock.now() - t0) * 1000
                renderMsAverage = renderMsAverage == 0 ? ms : renderMsAverage * 0.9 + ms * 0.1
                lastPixelBuffer = buffer
                lastList = list
                pendingDirty = false
                pictureNotEncoded = true
                shared.withLock {
                    $0.stats.renderedFrames += 1
                    $0.stats.lastRenderMs = ms
                    $0.stats.averageRenderMs = renderMsAverage
                }
                if previewDue, let handler = previewHandler, let image = DashRenderer.makeImage(from: buffer) {
                    lastPreviewAt = now
                    handler(image)
                }
            } else {
                shared.withLock { $0.stats.poolExhausted += 1 }
            }
        }

        if decision.encode, let enc, let buffer = lastPixelBuffer {
            let outputsBefore = backgroundRung != nil ? healthOutputs() : 0
            let accepted = enc.encode(pixelBuffer: buffer, pts: now, forceKeyframe: decision.forceKeyframe)
            if accepted {
                lastEncodeAt = now
                pictureNotEncoded = false
                if decision.forceKeyframe { keyframes.forced(now: now, outputs: outputs) }
                shared.withLock {
                    $0.stats.encodeSubmissions += 1
                    if decision.isRepeat { $0.stats.repeatedFrames += 1 }
                }
            }
            if backgroundRung != nil { noteSubmission(accepted: accepted, outputsBefore: outputsBefore, now: now) }
        }
        if backgroundRung != nil { checkStall(now: now) }
        publishStatsIfDue(now)
    }

    private func publishStatsIfDue(_ now: TimeInterval) {
        guard now - lastStatsPublish >= 1 else { return }
        publishStats(now: now)
    }

    private func publishStats(now: TimeInterval) {
        lastStatsPublish = now
        let average = encoder?.averageEncodeMs
        let hardware = encoder?.usesHardware
        let cap: Int? = shared.current.mode == .backgroundSoftware ? backgroundParameters().frameRate : nil
        let (snapshot, handler) = shared.withLock { s -> (DashProjectionStats, (@Sendable (DashProjectionStats) -> Void)?) in
            s.stats.mode = s.mode
            s.stats.outputFPS = s.outputMeter.rate(now: now)
            s.stats.pullRate = s.pullMeter.rate(now: now)
            s.stats.averageEncodeMs = average ?? s.stats.averageEncodeMs
            s.stats.usingHardwareEncoder = hardware
            s.stats.thermalLevel = s.thermalLevel
            s.stats.lowPowerMode = s.lowPowerMode
            s.stats.queueOverflows = frameQueue.overflowCount
            s.stats.gatedDrops = frameQueue.gatedDropCount
            s.stats.encoder = s.feeding
            s.stats.backgroundSeconds = s.backgroundSince.map { max(0, now - $0) } ?? 0
            s.stats.backgroundFpsCap = cap
            return (s.stats, s.onStats)
        }
        handler?(snapshot)
    }

    // MARK: hold / background

    @discardableResult
    private func buildHoldFrames(expected: VideoCanvas? = nil) -> Bool {
        // The negotiated canvas wins; before any REQ 16 the session's expected canvas is used.
        let target: VideoCanvas
        if let canvas {
            target = canvas
        } else if let e = expected, e.width >= 16, e.height >= 16 {
            target = e
        } else {
            return false
        }
        let now = clock.now()
        let provider = shared.withLock { $0.holdDisplayListProvider ?? $0.displayListProvider }
        var picture: CVPixelBuffer?
        let pooled = canvas != nil ? factory?.makeBuffer() : nil
        if let provider, let buffer = pooled ?? PixelBufferFactory.makeStandaloneBuffer(width: target.width, height: target.height) {
            renderer.render(provider(now), into: buffer)
            picture = buffer
        } else if canvas != nil {
            picture = lastPixelBuffer
        }
        guard let pic = picture else { return false }
        let parameters = currentEffective()
        let encoded = shared.current.holdFramesEncoder?(pic, target.width, target.height, parameters)
            ?? H264Encoder.encodeStill(pixelBuffer: pic, width: target.width, height: target.height,
                                       parameters: parameters, count: 2, timeout: 0.6)
        // Hold IDRs carry tag 1 (P0-6).
        let frames = encoded.map { frame -> EncodedFrame in
            var f = frame
            f.encoderTag = Self.holdTag
            return f
        }
        guard !frames.isEmpty else {
            Log.w("VIDEO", "hold picture: no IDR produced (encoder unavailable?)")
            return false
        }
        shared.withLock { $0.holdFrames = frames; $0.holdIndex = 0; $0.holdCanvas = PictureSize(target) }
        Log.i("VIDEO", "hold picture ready at \(target.width)x\(target.height)\(canvas == nil ? " (expected canvas)" : ""): "
            + "\(frames.count) IDR(s), \(frames.map { $0.accessUnit.count })b")
        return true
    }

    private func applyBackground() {
        guard !backgrounded else { return } // already in the background (a repeated phase change)
        backgrounded = true
        beginBackgroundPeriod()
        guard canvas != nil, shared.current.mode == .foreground else { return }
        runLadder(from: nil, reason: .entry)
    }

    private func beginBackgroundPeriod() {
        let now = clock.now()
        retryAttempts = 0
        cpuMeter = ProcessCPUMeter()
        cpuMeter.sample(now: now)
        shared.withLock { s in
            s.backgroundSince = now
            s.periodBase = PeriodCounters(served: s.stats.pullsServed, hold: s.stats.holdFramesServed,
                                          fallback: s.stats.fallbackKeyframesServed, unanswered: s.stats.pullsUnanswered,
                                          errors: s.stats.encoderErrors)
            s.summaries = []
            s.summaryIndex = [:]
        }
    }

    private func endBackgroundPeriod() {
        shared.withLock { s in
            s.backgroundSince = nil
            s.summaries = []
            s.summaryIndex = [:]
        }
    }

    private func isSoftwareEncodingAvailable() -> Bool {
        shared.current.softwareEncodingAvailable?() ?? H264Encoder.isSoftwareEncodingSupported
    }

    private func currentRungs() -> [BackgroundRung] {
        BackgroundEncoderLadder.rungs(policy: flags.current.policy, vtSoftwareAvailable: isSoftwareEncodingAvailable(),
                                      cpuAvailable: shared.current.cpuEncoderFactory != nil)
    }

    /// The background ladder (render queue; P0-4): try the rungs from `start` (nil = the top) in
    /// order and keep the first candidate whose probe IDR is accepted, else serve the hold picture.
    private func runLadder(from start: BackgroundRung?, reason: LadderReason) {
        guard let canvas else { return }
        let oldName = shared.current.feeding ?? "none"
        let previousCause = holdCause
        if reason == .canvasChange { stopDryRun() } // restarted at the new size if hold follows
        retireLiveEncoder()
        frameQueue.resynchronize() // gate closed: the next frame on the wire is an IDR
        let policy = flags.current.policy
        let cpuFactory = shared.current.cpuEncoderFactory
        let rungs = BackgroundEncoderLadder.rungs(policy: policy, vtSoftwareAvailable: isSoftwareEncodingAvailable(),
                                                  cpuAvailable: cpuFactory != nil)
        let first = start.flatMap { rungs.firstIndex(of: $0) } ?? 0
        var cpuCandidate: (any DashVideoEncoder)?
        if let make = cpuFactory, rungs[first...].contains(.cpu) {
            let candidate = make("own-cpu")
            if case let .cpu(backend) = candidate.kind { cpuBackend = backend }
            cpuCandidate = candidate
        }
        if reason != .demotion {
            Log.i("VIDEO", BackgroundLog.enter(canvas: canvas, policy: policy, rungs: rungs, cpuBackend: cpuBackend,
                                               lastLiveIDRBytes: liveKeyframeForCurrentCanvas()?.accessUnit.count,
                                               holdIDRs: holdFramesForCurrentCanvas()))
        }
        var accepted: Candidate?
        for rung in rungs[first...] {
            switch rung {
            case .videoToolboxSoftware:
                accepted = tryVideoToolboxSoftware(canvas: canvas)
            case .cpu:
                if let candidate = cpuCandidate { accepted = tryCPU(candidate, canvas: canvas) }
            case .hold:
                break
            }
            if accepted != nil { break }
        }
        if let candidate = cpuCandidate, accepted?.encoder !== candidate { candidate.invalidate() }
        invalidatePreWarm() // a pre-warmed session the ladder did not take
        if let accepted {
            goLive(accepted, from: oldName)
            return
        }
        let cause: HoldCause
        if policy == .holdOnly {
            cause = .policy
        } else if !rungs.contains(where: { $0 != .hold }) {
            cause = .noEncoderRung
        } else {
            switch reason {
            case .entry: cause = .allRungsRejected
            case .demotion: cause = .demoted
            case .retry, .canvasChange:
                if let p = previousCause, p.isRetryable {
                    cause = p
                } else {
                    cause = reason == .retry ? .demoted : .allRungsRejected
                }
            }
        }
        goHold(cause: cause, from: oldName)
    }

    /// Rung 1: the pre-warmed session, a fresh one, then one per non-hardware `EncoderID`.
    private func tryVideoToolboxSoftware(canvas: VideoCanvas) -> Candidate? {
        let parameters = backgroundParameters()
        if let pre = preWarm {
            preWarm = nil
            if pre.size == PictureSize(canvas) {
                pre.encoder.update(parameters: parameters)
                if let c = evaluateVideoToolbox(pre.encoder, route: pre.route, created: true, create: pre.create,
                                                session: .preWarmed, canvas: canvas, parameters: parameters) {
                    return c
                }
            } else {
                pre.route.drop()
                pre.encoder.invalidate()
            }
        }
        if let c = makeAndEvaluate(EncoderRequest(label: "own-sw", software: true, encoderID: nil), session: .fresh,
                                   canvas: canvas, parameters: parameters) {
            return c
        }
        let entries = encoderListForLadder().filter { $0.isHardwareAccelerated != true }.prefix(Self.maxEncoderIDTries)
        for entry in entries {
            if let c = makeAndEvaluate(EncoderRequest(label: "own-sw-id", software: true, encoderID: entry.id),
                                       session: .encoderID(entry.id), canvas: canvas, parameters: parameters) {
                return c
            }
        }
        return nil
    }

    private func makeAndEvaluate(_ request: EncoderRequest, session: BackgroundLog.SoftwareSession, canvas: VideoCanvas,
                                 parameters: EncoderParameters) -> Candidate? {
        let enc = makeVideoToolboxEncoder(request)
        let route = EncoderRoute(tag: takeTag(), size: PictureSize(canvas))
        install(route, on: enc)
        let (created, create) = configure(enc, canvas: canvas, parameters: parameters)
        return evaluateVideoToolbox(enc, route: route, created: created, create: create, session: session, canvas: canvas,
                                    parameters: parameters)
    }

    /// `configure` → (created, the `create=` text).
    private func configure(_ enc: any DashVideoEncoder, canvas: VideoCanvas,
                           parameters: EncoderParameters) -> (created: Bool, text: String) {
        do {
            try enc.configure(width: canvas.width, height: canvas.height, parameters: parameters)
            return (true, BackgroundLog.osStatus(0, name: nil))
        } catch {
            return (false, Self.creationStatus(error))
        }
    }

    /// `kVTCouldNotFindVideoEncoderErr(-12908)` for a known status, `OSStatus(-1)`, else the error text.
    private static func creationStatus(_ error: Error) -> String {
        let status: Int32?
        if let e = error as? H264EncoderError {
            status = e.status
        } else if let f = error as? DashEncoderFailure {
            status = f.status
        } else {
            status = nil
        }
        guard let status else { return String(describing: error) }
        return BackgroundLog.osStatus(status, name: H264EncoderStatus.knownName(status))
    }

    private func evaluateVideoToolbox(_ enc: any DashVideoEncoder, route: EncoderRoute, created: Bool, create: String,
                                      session: BackgroundLog.SoftwareSession, canvas: VideoCanvas,
                                      parameters: EncoderParameters) -> Candidate? {
        let result = created ? probe(enc, route: route, waitMs: EncoderAcceptance.videoToolboxProbeLimitMs) : nil
        var issues: [H264StreamIssue]?
        if let idr = result?.frame {
            issues = H264StreamCheck.check(accessUnit: idr.accessUnit, canvas: canvas, requireKeyframe: true,
                                           frameRate: parameters.frameRate)
        }
        let hardware = enc.usesHardware
        let verdict = EncoderAcceptance.decide(rung: .videoToolboxSoftware, created: created, usesHardware: hardware,
                                               probe: result?.outcome ?? .nothing(waitedMs: 0), issues: issues ?? [])
        Log.i("VIDEO", BackgroundLog.tryVideoToolbox(session, create: create, usesHardware: hardware, probe: result?.outcome,
                                                     issues: issues, verdict: verdict))
        return keepIfAccepted(enc, route: route, rung: .videoToolboxSoftware, verdict: verdict, probeIDR: result?.frame)
    }

    /// Rung 2: the CPU encoder of `cpuEncoderFactory` (one try).
    private func tryCPU(_ enc: any DashVideoEncoder, canvas: VideoCanvas) -> Candidate? {
        let parameters = backgroundParameters()
        let route = EncoderRoute(tag: takeTag(), size: PictureSize(canvas))
        install(route, on: enc)
        var created = true
        var configureText = "ok"
        do {
            try enc.configure(width: canvas.width, height: canvas.height, parameters: parameters)
        } catch {
            created = false
            configureText = String(describing: error)
        }
        let result = created ? probe(enc, route: route, waitMs: EncoderAcceptance.videoToolboxProbeLimitMs) : nil
        var issues: [H264StreamIssue]?
        if let idr = result?.frame {
            issues = H264StreamCheck.check(accessUnit: idr.accessUnit, canvas: canvas, requireKeyframe: true,
                                           frameRate: parameters.frameRate)
        }
        let verdict = EncoderAcceptance.decide(rung: .cpu, created: created, usesHardware: enc.usesHardware,
                                               probe: result?.outcome ?? .nothing(waitedMs: 0), issues: issues ?? [])
        Log.i("VIDEO", BackgroundLog.tryCPU(encoder: enc.kind.description, configure: configureText, probe: result?.outcome,
                                            issues: issues, verdict: verdict))
        return keepIfAccepted(enc, route: route, rung: .cpu, verdict: verdict, probeIDR: result?.frame)
    }

    private func keepIfAccepted(_ enc: any DashVideoEncoder, route: EncoderRoute, rung: BackgroundRung,
                                verdict: EncoderAcceptance.Verdict, probeIDR: EncodedFrame?) -> Candidate? {
        if verdict == .accept, let idr = probeIDR {
            return Candidate(encoder: enc, route: route, rung: rung, probeIDR: idr)
        }
        // Rejected: invalidated before anything of it reached the frame queue (late VideoToolbox
        // output is dropped by the route and by the encoder's generation check).
        route.drop()
        enc.invalidate()
        return nil
    }

    /// The last rendered picture; one is rendered first if there is none (`assign`: it becomes the
    /// engine's picture — not for the `.inactive` pre-warm, while the hardware encoder is live).
    private func pictureForProbe(assign: Bool) -> CVPixelBuffer? {
        if let p = lastPixelBuffer { return p }
        guard let factory, let canvas, let buffer = factory.makeBuffer() else { return nil }
        let list = shared.current.displayListProvider?(clock.now()) ?? Self.blankList(canvas)
        renderer.render(list, into: buffer)
        if assign {
            lastPixelBuffer = buffer
            lastList = list
            pictureNotEncoded = true
            shared.withLock { $0.stats.renderedFrames += 1 }
        }
        return buffer
    }

    /// A forced-IDR encode of the last picture into a probe sink (never the frame queue), waiting up
    /// to `waitMs` for the IDR.
    private func probe(_ enc: any DashVideoEncoder, route: EncoderRoute, waitMs: Double,
                       assignPicture: Bool = true) -> (outcome: ProbeOutcome, frame: EncodedFrame?) {
        guard let picture = pictureForProbe(assign: assignPicture) else { return (.failed(code: nil), nil) }
        let pts = clock.now()
        let sink = ProbeSink(notBefore: pts - 0.001)
        route.set(.probe(sink))
        defer { route.drop() } // until the engine decides: live, or invalidated
        let start = ProcessInfo.processInfo.systemUptime
        let submitted = enc.encode(pixelBuffer: picture, pts: pts, forceKeyframe: true)
        let result = submitted ? sink.wait(milliseconds: waitMs) : sink.refusal
        switch result {
        case let .frame(frame, at): return (.keyframe(bytes: frame.accessUnit.count, ms: max(0, (at - start) * 1000)), frame)
        case let .failure(failure): return (.failed(code: failure?.status), nil)
        case .timeout: return (.nothing(waitedMs: waitMs), nil)
        }
    }

    /// An accepted candidate feeds the dash: its probe IDR is the first frame on the wire.
    private func goLive(_ c: Candidate, from oldName: String) {
        let now = clock.now()
        let name = c.encoder.kind.description
        encoder = c.encoder
        liveRoute = c.route
        backgroundRung = c.rung
        holdCause = nil
        appliedParameters = c.encoder.parameters
        markKeyframePending(sessionLost: true) // before the probe IDR is pushed: it satisfies this request
        logSwitch(from: oldName, to: name, now: now)
        shared.withLock { s in
            s.mode = .backgroundSoftware
            s.feeding = name
            s.backgroundTag = c.route.tag
            Self.register(tag: c.route.tag, name: name, in: &s)
            s.health = TrackedHealth(tag: c.route.tag, health: EncoderHealth(rung: c.rung))
            s.summaryIndex[c.route.tag] = s.summaries.count
            s.summaries.append(BackgroundLog.EncoderSummary(name: name, frames: 0, keyframes: 0, errors: 0, averageEncodeMs: nil))
        }
        let p = currentEffective()
        Log.i("VIDEO", BackgroundLog.backgroundSoftware(fps: p.frameRate, encoder: name, bitrate: p.bitrate))
        c.route.goLive(first: c.probeIDR) { encoderOutput($0, route: c.route) }
        lastEncodeAt = now
        pictureNotEncoded = false
        factory?.flush()
        applyEffectiveParameters() // the render timer at the background rate
        stopDryRun()
        armStatusTimer()
    }

    /// No background encoder: the hold IDRs answer the pulls.
    private func goHold(cause: HoldCause, from oldName: String) {
        let now = clock.now()
        encoder = nil
        liveRoute = nil
        backgroundRung = nil
        holdCause = cause
        holdSince = now
        let live = liveKeyframeForCurrentCanvas()
        let holdIDRs = shared.withLock { s -> Int in
            s.mode = .hold
            s.feeding = "hold"
            s.backgroundTag = nil
            s.health = nil
            // No hold picture for this canvas: seed the hold with the last live IDR (a frozen map,
            // without the card; it keeps its tag).
            if s.holdFrames.isEmpty || s.holdCanvas != s.canvasSize, let k = live {
                s.holdFrames = [k]
                s.holdCanvas = s.canvasSize
                s.holdIndex = 0
            }
            return s.holdCanvas != nil && s.holdCanvas == s.canvasSize ? s.holdFrames.count : 0
        }
        factory?.flush()
        markKeyframePending(sessionLost: true)
        applyEffectiveParameters() // cancels the render timer
        if oldName != "hold" { logSwitch(from: oldName, to: "hold", now: now) }
        Log.i("VIDEO", BackgroundLog.backgroundHold(holdIDRs: holdIDRs, cause: cause))
        armStatusTimer()
        startDryRunIfNeeded()
    }

    /// The live background encoder `tag` failed `EncoderHealth`: continue the ladder at the next rung.
    private func demote(tag: UInt32, reason: String) {
        guard backgrounded, shared.current.mode == .backgroundSoftware, liveRoute?.tag == tag, let enc = encoder,
              let rung = backgroundRung else { return }
        let next = BackgroundEncoderLadder.next(after: rung, in: currentRungs())
        Log.w("VIDEO", BackgroundLog.demoted(encoder: enc.kind.description, reason: reason,
                                             next: BackgroundLog.rungName(next, cpuBackend: cpuBackend)))
        shared.withLock { $0.stats.demotions += 1 }
        runLadder(from: next, reason: .demotion)
    }

    /// Frames output so far by the live background encoder (0 without one).
    private func healthOutputs() -> Int {
        shared.withLock { $0.health?.outputs ?? 0 }
    }

    /// `EncoderHealth` after an `encode` call of the live background encoder. An output that came
    /// out DURING the call (a synchronous encoder, or a fast VideoToolbox callback) answered this
    /// submission: it is applied after it, so it does not leave the stall clock running.
    private func noteSubmission(accepted: Bool, outputsBefore: Int, now: TimeInterval) {
        guard let tag = liveRoute?.tag else { return }
        let verdict = shared.withLock { s -> EncoderHealth.Verdict? in
            guard s.health?.tag == tag else { return nil }
            let verdict = s.health?.health.submitted(accepted: accepted, now: now)
            if accepted, let outputs = s.health?.outputs, outputs > outputsBefore { s.health?.health.output(now: now) }
            return verdict
        }
        if case let .demote(reason)? = verdict {
            renderQueue.async { [weak self] in self?.demote(tag: tag, reason: reason) }
        }
    }

    /// The `EncoderHealth` time rule (submitted, no output for 3 s).
    private func checkStall(now: TimeInterval) {
        guard let tag = liveRoute?.tag else { return }
        let verdict = shared.withLock { s -> EncoderHealth.Verdict? in
            guard let h = s.health, h.tag == tag else { return nil }
            return h.health.check(now: now)
        }
        if case let .demote(reason)? = verdict {
            renderQueue.async { [weak self] in self?.demote(tag: tag, reason: reason) }
        }
    }

    private func applyForeground() {
        backgrounded = false
        invalidatePreWarm()
        cancelStatusTimer()
        stopDryRun()
        holdCause = nil
        retryAttempts = 0
        // Active again: a hold picture pre-encoded on the way out (Control Center, a banner, the
        // app switcher, or a real lock) is stale now — drop it even when the engine never left
        // the foreground mode, so no pull fallback can show "Phone locked" (CL-5). The next
        // `.inactive` pre-encodes a fresh one.
        shared.withLock { $0.holdFrames = []; $0.holdCanvas = nil; $0.holdIndex = 0 }
        let m = shared.current.mode
        guard m == .hold || m == .backgroundSoftware, canvas != nil else {
            endBackgroundPeriod()
            return
        }
        let now = clock.now()
        let oldName = shared.current.feeding ?? "none"
        retireLiveEncoder()
        backgroundRung = nil
        shared.withLock { $0.mode = .foreground; $0.health = nil; $0.backgroundTag = nil }
        encoder = makeForegroundEncoder()
        frameQueue.resynchronize() // the dash decoder's reference is the hold / software picture
        logSwitch(from: oldName, to: shared.current.feeding ?? DashEncoderKind.videoToolboxHardware.description, now: now)
        markKeyframePending(sessionLost: true)
        lastEncodeAt = nil
        pendingDirty = true
        shared.withLock { $0.holdFrames = []; $0.holdCanvas = nil }
        applyEffectiveParameters()
        tick()
        let (since, summaries, holdServed) = shared.withLock { s in
            (s.backgroundSince, s.summaries, s.stats.holdFramesServed - s.periodBase.hold)
        }
        Log.i("VIDEO", BackgroundLog.foreground(backgroundSeconds: since.map { now - $0 } ?? 0, encoders: summaries,
                                                holdServed: holdServed))
        endBackgroundPeriod()
    }

    /// L7: the encoder that feeds the dash changes; the keyframe gate is closed.
    private func logSwitch(from: String, to: String, now: TimeInterval) {
        let dumpFrame = shared.withLock { s -> Int? in
            s.pendingSwitchAt = now
            guard let d = s.dump, !d.isFinished else { return nil }
            return d.framesWritten + 1
        }
        Log.i("VIDEO", BackgroundLog.switchStarted(from: from, to: to, dumpFrame: dumpFrame))
    }

    // MARK: pre-warm (P0-4)

    private func applyPreWarm() {
        guard !backgrounded, shared.current.mode == .foreground, let canvas,
              currentRungs().contains(.videoToolboxSoftware) else { return }
        invalidatePreWarm()
        let parameters = backgroundParameters()
        let enc = makeVideoToolboxEncoder(EncoderRequest(label: "own-sw-pre", software: true, encoderID: nil))
        let route = EncoderRoute(tag: takeTag(), size: PictureSize(canvas))
        install(route, on: enc)
        let (created, create) = configure(enc, canvas: canvas, parameters: parameters)
        let outcome = created ? probe(enc, route: route, waitMs: Self.preWarmProbeWaitMs, assignPicture: false).outcome : nil
        Log.i("VIDEO", BackgroundLog.preWarm(create: create, usesHardware: enc.usesHardware, probe: outcome))
        if created {
            preWarm = PreWarmed(encoder: enc, route: route, size: PictureSize(canvas), create: create)
        } else {
            route.drop()
            enc.invalidate()
        }
    }

    private func invalidatePreWarm() {
        guard let p = preWarm else { return }
        preWarm = nil
        p.route.drop()
        p.encoder.invalidate()
    }

    // MARK: encoder list (P0-2, L2)

    /// L2 once per app run, at the first foreground prepare, off the render queue.
    private func logEncoderListOnce() {
        let first = Self.encoderListLogged.withLock { logged -> Bool in
            guard !logged else { return false }
            logged = true
            return true
        }
        guard first else { return }
        let provider = shared.current.encoderListProvider
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let list = provider?() ?? H264Encoder.listAvailableEncoders()
            Log.i("VIDEO", BackgroundLog.encoderList(list))
            self?.shared.withLock { $0.encoderList = list }
        }
    }

    /// The cached list (L2), fetched now when this engine has none yet.
    private func encoderListForLadder() -> [BackgroundLog.EncoderListEntry] {
        if let cached = shared.current.encoderList { return cached }
        let list = shared.current.encoderListProvider?() ?? H264Encoder.listAvailableEncoders()
        shared.withLock { $0.encoderList = list }
        return list
    }

    // MARK: background status (P0-7, L9), retry (L12)

    private func armStatusTimer() {
        guard statusTimer == nil, backgrounded, canvas != nil else { return }
        let interval = max(0.01, flags.current.statusInterval)
        let t = DispatchSource.makeTimerSource(flags: [], queue: renderQueue)
        t.schedule(deadline: .now() + interval, repeating: interval,
                   leeway: .milliseconds(max(1, min(100, Int(interval * 100)))))
        t.setEventHandler { [weak self] in self?.backgroundStatusTick() }
        t.resume()
        statusTimer = t
    }

    private func cancelStatusTimer() {
        statusTimer?.cancel()
        statusTimer = nil
    }

    private func backgroundStatusTick() {
        guard backgrounded, canvas != nil else { return }
        let now = clock.now()
        cpuMeter.sample(now: now)
        let cpu = cpuMeter.percent(window: flags.current.statusInterval, now: now)
        if let cpu { shared.withLock { $0.stats.cpuPercent = cpu } }
        switch shared.current.mode {
        case .backgroundSoftware:
            checkStall(now: now)
        case .hold:
            if let cause = holdCause, cause.isRetryable,
               BackgroundEncoderLadder.shouldRetry(after: cause, holdSince: holdSince, budgetClearSince: nil,
                                                   attempts: retryAttempts, now: now) {
                retryAttempts += 1
                Log.i("VIDEO", BackgroundLog.retryLadder(after: cause, attempt: retryAttempts))
                runLadder(from: nil, reason: .retry)
            }
        case .idle, .foreground, .stopped:
            break
        }
        let at = clock.now()
        Log.i("VIDEO", BackgroundLog.backgroundStatus(backgroundStatus(now: at, cpu: cpu)))
        publishStats(now: at)
    }

    private func backgroundStatus(now: TimeInterval, cpu: Double?) -> BackgroundLog.Status {
        let mode = shared.current.mode
        let cap: Int? = mode == .backgroundSoftware ? backgroundParameters().frameRate : nil
        let encodeMs: Double? = mode == .backgroundSoftware ? encoder?.averageEncodeMs : nil
        let render = renderMsAverage
        let queued = frameQueue.pendingCount
        return shared.withLock { s in
            let b = s.periodBase
            return BackgroundLog.Status(
                backgroundSeconds: s.backgroundSince.map { now - $0 } ?? 0, mode: s.mode.rawValue,
                encoder: s.feeding ?? "none", fpsCap: cap, outputFPS: s.outputMeter.rate(now: now),
                pullRate: s.pullMeter.rate(now: now), served: s.stats.pullsServed - b.served,
                holdServed: s.stats.holdFramesServed - b.hold, fallbackServed: s.stats.fallbackKeyframesServed - b.fallback,
                unanswered: s.stats.pullsUnanswered - b.unanswered, encoderErrors: s.stats.encoderErrors - b.errors,
                renderMs: render, encodeMs: encodeMs, cpuPercent: cpu, thermal: s.thermalLevel, lowPowerMode: s.lowPowerMode,
                queued: queued)
        }
    }

    // MARK: dry run (P0-8, L10)

    private func startDryRunIfNeeded() {
        let f = flags.current
        guard f.dryRun, dryRun == nil, backgrounded, shared.current.mode == .hold, let canvas, factory != nil,
              let since = shared.current.backgroundSince else { return }
        let now = clock.now()
        guard now - since < f.dryRunDuration, let frame = I420Frame(width: canvas.width, height: canvas.height) else { return }
        dryRun = DryRunState(startedAt: now, lastReportAt: now, frame: frame)
        let interval = 1 / Double(max(1, f.dryRunFps))
        let t = DispatchSource.makeTimerSource(flags: [], queue: renderQueue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in self?.dryRunTick() }
        t.resume()
        dryRunTimer = t
    }

    /// One dry-run iteration: render the live UI into a pool buffer, convert it to I420 (vImage), burn
    /// the synthetic load, discard everything — never the frame queue, the wire dump,
    /// `lastPixelBuffer` or the stats of served frames.
    private func dryRunTick() {
        guard dryRun != nil else { return }
        let f = flags.current
        let now = clock.now()
        guard backgrounded, shared.current.mode == .hold, let factory, let canvas,
              let since = shared.current.backgroundSince, now - since < f.dryRunDuration else {
            stopDryRun()
            return
        }
        guard var state = dryRun else { return }
        dryRun = nil // the I420 planes are written in place (no copy)
        if let buffer = factory.makeBuffer() {
            let list = shared.current.displayListProvider?(now) ?? Self.blankList(canvas)
            let t0 = ProcessInfo.processInfo.systemUptime
            renderer.render(list, into: buffer)
            let t1 = ProcessInfo.processInfo.systemUptime
            convertForDryRun(buffer, into: &state.frame)
            let t2 = ProcessInfo.processInfo.systemUptime
            Self.burnCPU(milliseconds: f.dryRunLoadMs)
            let t3 = ProcessInfo.processInfo.systemUptime
            state.iterations += 1
            state.renderMs += (t1 - t0) * 1000
            state.convertMs += (t2 - t1) * 1000
            state.loadMs += (t3 - t2) * 1000
        }
        if now - state.lastReportAt >= f.dryRunReportInterval {
            cpuMeter.sample(now: now)
            let n = Double(max(1, state.iterations))
            Log.i("VIDEO", BackgroundLog.dryRun(renderMs: state.renderMs / n, convertMs: state.convertMs / n,
                                                loadMs: state.loadMs / n, iterations: state.iterations,
                                                cpuPercent: cpuMeter.percent(window: f.dryRunReportInterval, now: now)))
            state.lastReportAt = now
        }
        dryRun = state
    }

    private func convertForDryRun(_ buffer: CVPixelBuffer, into frame: inout I420Frame) {
#if canImport(Accelerate)
        if converter == nil, !converterUnavailable {
            converter = BGRAToI420Converter()
            if converter == nil {
                converterUnavailable = true
                Log.w("VIDEO", "[bg-probe] vImage BGRA → I420 conversion unavailable")
            }
        }
        _ = converter?.convert(buffer, into: &frame)
#endif
    }

    /// Ends the dry run (L10 `dry run ended after …`, once).
    private func stopDryRun() {
        dryRunTimer?.cancel()
        dryRunTimer = nil
        guard let state = dryRun else { return }
        dryRun = nil
        Log.i("VIDEO", BackgroundLog.dryRunEnded(afterSeconds: clock.now() - state.startedAt))
    }

    /// Synthetic CPU load: a busy wait of `milliseconds`.
    private static func burnCPU(milliseconds: Double) {
        guard milliseconds > 0, milliseconds.isFinite else { return }
        let end = DispatchTime.now().uptimeNanoseconds &+ UInt64(milliseconds * 1_000_000)
        while DispatchTime.now().uptimeNanoseconds < end {}
    }

    // MARK: pulls

    /// The 114 fallback (P0-5): in the foreground the last live IDR only (never the "Phone locked"
    /// hold picture, CL-5); with a background encoder its own last IDR, then the hold picture, then
    /// any live IDR of the canvas; in hold the hold picture, then the last live IDR.
    private func holdOrLastKeyframe() -> EncodedFrame? {
        let (mode, backgroundTag) = shared.withLock { ($0.mode, $0.backgroundTag) }
        let context: ProjectionFallback.Context
        switch mode {
        case .foreground: context = .foreground
        case .backgroundSoftware: context = .backgroundEncoder
        case .hold, .idle, .stopped: context = .hold
        }
        return ProjectionFallback.keyframe(context, backgroundEncoder: { liveKeyframeForCurrentCanvas(tag: backgroundTag) },
                                           hold: { nextHoldFrame() }, live: { liveKeyframeForCurrentCanvas() })
    }

    /// Round-robin over the hold IDRs (consecutive identical IDRs share an idr_pic_id); only when
    /// they were encoded at the current canvas.
    private func nextHoldFrame() -> EncodedFrame? {
        shared.withLock { s -> EncodedFrame? in
            guard !s.holdFrames.isEmpty, let size = s.canvasSize, s.holdCanvas == size else { return nil }
            let f = s.holdFrames[s.holdIndex % s.holdFrames.count]
            s.holdIndex &+= 1
            return f
        }
    }

    /// Every frame that goes to the dash: counters, the wire dump, and L8 at the first IDR of every
    /// new encoder tag on the wire.
    private func served(_ frame: EncodedFrame, hold: Bool) -> EncodedFrame {
        let now = clock.now()
        let (dump, announce, broken) = shared.withLock { s -> (H264WireDump?, (name: String, after: Double?)?, UInt32?) in
            s.stats.pullsServed += 1
            if hold { s.stats.holdFramesServed += 1 }
            var announce: (name: String, after: Double?)?
            var broken: UInt32?
            if frame.encoderTag != s.lastServedTag {
                if frame.isKeyframe {
                    announce = (s.tagNames[frame.encoderTag] ?? "?", s.pendingSwitchAt.map { now - $0 })
                    s.pendingSwitchAt = nil
                } else {
                    broken = s.lastServedTag ?? 0
                }
                s.lastServedTag = frame.encoderTag
            }
            return (s.dump, announce, broken)
        }
        let written = dump?.write(frame) ?? false
        if let announce {
            Log.i("VIDEO", BackgroundLog.switchFirstIDR(encoder: announce.name, bytes: frame.accessUnit.count,
                                                        secondsAfterSwitch: announce.after,
                                                        dumpFrame: written ? dump?.framesWritten : nil))
        }
        if let broken {
            // Never expected: every switch closes the keyframe gate (tested).
            Log.shared.throttled("switch-not-idr", interval: 5, .warn, "VIDEO",
                                 "[switch] encoder tag \(broken) → \(frame.encoderTag) on a non-IDR frame")
        }
        return frame
    }
}
#endif
