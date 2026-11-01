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
/// willResignActive  → engine.prepareHoldPicture()
/// didEnterBackground → engine.enterBackground()
/// didBecomeActive   → engine.enterForeground()
/// ```
/// Thread-safe. Rendering and encoding run on one serial queue; providers are called there.
public final class DashProjectionEngine: VideoFrameSource, @unchecked Sendable {
    public enum Mode: String, Sendable, Equatable {
        /// No canvas yet.
        case idle
        /// Hardware VideoToolbox encoding at the frame-rate cap.
        case foreground
        /// Software VideoToolbox encoder (iOS 17.4+) at `backgroundFrameRate`.
        case backgroundSoftware
        /// No encoder: pulls are answered with the pre-encoded hold IDR(s).
        case hold
        /// `stop()` was called.
        case stopped
    }

    public typealias DisplayListProvider = @Sendable (TimeInterval) -> DashDisplayList

    /// Encoded size (canvas width × height) a cached IDR belongs to.
    private struct PictureSize: Equatable {
        let width: Int
        let height: Int
        init(_ c: VideoCanvas) { width = c.width; height = c.height }
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
    }

    public let renderer: DashRenderer
    /// The queue the dash pulls from (capacity 3, GOP-safe overflow, keyframe gate).
    public let frameQueue: FrameQueue
    private let clock: any MonotonicClock
    private let renderQueue = DispatchQueue(label: "ocm.dash.render", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let shared = Locked(Shared())

    // Configuration flags (set before use; read on the render queue).
    /// Apply the thermal caps of `ThermalCaps` (disable when the Auto power mode's AdaptivePolicy
    /// already reacts to the thermal level, to avoid reducing twice).
    public var appliesThermalCaps: Bool { get { flags.current.thermal } set { flags.withLock { $0.thermal = newValue } } }
    /// Cap the frame rate at 15 fps in Low Power Mode.
    public var appliesLowPowerCap: Bool { get { flags.current.lowPower } set { flags.withLock { $0.lowPower = newValue } } }
    /// Frame-rate cap of the software encoder in the background (5–10 fps recommended).
    public var backgroundFrameRate: Int { get { flags.current.backgroundFps } set { flags.withLock { $0.backgroundFps = max(1, newValue) } } }
    /// Try the software encoder (iOS 17.4+) in the background before falling back to the hold IDR.
    public var allowsSoftwareEncodingInBackground: Bool {
        get { flags.current.software } set { flags.withLock { $0.software = newValue } }
    }
    /// Second forced IDR after a resync ("after the first map paint", EasyConnProber.kt:286-292); nil = off.
    public var secondKeyframeDelay: TimeInterval? { get { flags.current.secondIDR } set { flags.withLock { $0.secondIDR = newValue } } }
    /// Maximum preview rate (frames per second).
    public var previewMaxFPS: Double { get { flags.current.previewFps } set { flags.withLock { $0.previewFps = max(0.1, newValue) } } }

    private struct Flags {
        var thermal = true
        var lowPower = true
        var backgroundFps = 8
        var software = true
        var secondIDR: TimeInterval? = 0.2
        var previewFps = 5.0
    }
    private let flags = Locked(Flags())

    // Render-queue confined state.
    private var canvas: VideoCanvas?
    private var factory: PixelBufferFactory?
    private var encoder: H264Encoder?
    private var timer: DispatchSourceTimer?
    private var timerFPS = 0
    private var lastList: DashDisplayList?
    private var lastPixelBuffer: CVPixelBuffer?
    private var pictureNotEncoded = false
    private var pendingDirty = false
    private var keyframePending = false
    private var lastEncodeAt: TimeInterval?
    private var lastPreviewAt: TimeInterval = -.greatestFiniteMagnitude
    private var renderMsAverage: Double = 0
    private var lastStatsPublish: TimeInterval = 0
    private var appliedParameters: EncoderParameters?
    /// The app is in the background (set even before any canvas exists).
    private var backgrounded = false

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
        encoder?.invalidate()
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
        // Gate closed BEFORE flushing (FrameQueue), then an IDR of the current picture.
        frameQueue.resynchronize()
        Log.d("VIDEO", "resynchronize: keyframe gate closed, queue flushed, IDR forced")
        renderQueue.async { [weak self] in
            guard let self else { return }
            self.keyframePending = true
            self.tick()
            if let delay = self.secondKeyframeDelay, delay > 0 {
                self.renderQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.isEncodingMode else { return }
                    self.keyframePending = true
                    self.tick()
                }
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
        if frameQueue.pendingCount == 0 {
            renderQueue.async { [weak self] in self?.tick() } // answer within one encode latency
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

    /// The app went to the background: stop hardware encoding; continue with the software encoder
    /// at `backgroundFrameRate` when possible (iOS 17.4+), otherwise serve the hold IDR.
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
            self.encoder?.invalidate()
            self.encoder = nil
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

    private func applyPrepare(_ newCanvas: VideoCanvas) {
        let state = shared.current.mode
        if state == .stopped || state == .idle { frameQueue.reopen() }
        let sameSize = canvas.map { $0.width == newCanvas.width && $0.height == newCanvas.height } ?? false
        canvas = newCanvas
        if !sameSize || factory == nil {
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
            encoder?.invalidate()
            encoder = nil
        }
        shared.withLock { $0.canvasSize = PictureSize(newCanvas) }
        if state == .idle || state == .stopped {
            shared.withLock { $0.mode = .foreground }
        }
        if backgrounded, shared.current.mode == .foreground {
            // The dash (re)connected while the app is in the background: never start the
            // hardware encoder there.
            encoder?.invalidate()
            encoder = nil
            switchToBackgroundMode()
        } else if shared.current.mode != .hold, encoder == nil {
            encoder = makeEncoder(software: shared.current.mode == .backgroundSoftware)
        }
        keyframePending = true
        applyEffectiveParameters()
        shared.withLock { $0.stats.canvas = newCanvas }
        Log.i("VIDEO", "own display \(newCanvas.width)x\(newCanvas.height) prepared (mode \(shared.current.mode.rawValue))")
    }

    private func makeEncoder(software: Bool) -> H264Encoder? {
        guard let c = canvas else { return nil }
        let enc = H264Encoder(label: software ? "own-sw" : "own")
        let size = PictureSize(c)
        enc.onFrame = { [weak self] f in self?.encoderOutput(f, size: size) }
        enc.onError = { [weak self] e in
            self?.shared.withLock { $0.stats.encoderErrors += 1 }
            if let s = e.status, H264EncoderStatus.requiresSessionRecreation(s) {
                self?.renderQueue.async { [weak self] in self?.keyframePending = true }
            }
        }
        do {
            try enc.configure(width: c.width, height: c.height, parameters: currentEffective(), allowSoftware: software)
        } catch {
            // Kept configured: the encoder retries creation on the next encode.
            Log.w("VIDEO", "encoder (\(software ? "software" : "hardware")) not ready: \(error)")
            if software { return nil }
        }
        appliedParameters = enc.parameters
        return enc
    }

    private func encoderOutput(_ frame: EncodedFrame, size: PictureSize) {
        let now = clock.now()
        shared.withLock {
            $0.stats.outputFrames += 1
            if frame.isKeyframe {
                $0.stats.outputKeyframes += 1
                $0.lastLiveKeyframe = (frame, size)
            }
            $0.outputMeter.add(now)
        }
        frameQueue.push(frame)
    }

    /// The last live IDR if it was encoded for the current canvas (nil otherwise).
    private func liveKeyframeForCurrentCanvas() -> EncodedFrame? {
        shared.withLock { s -> EncodedFrame? in
            guard let k = s.lastLiveKeyframe, let size = s.canvasSize, k.size == size else { return nil }
            return k.frame
        }
    }

    /// Called from FrameQueue (overflow / resync) and encoder errors.
    private func requestKeyframe() {
        shared.withLock { $0.keyframeRequested = true }
        renderQueue.async { [weak self] in self?.tick() }
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
        let (provider, keyframeFlag, invalidated, previewHandler) = shared.withLock { s -> (DisplayListProvider?, Bool, Bool, (@Sendable (CGImage) -> Void)?) in
            let r = (s.displayListProvider, s.keyframeRequested, s.invalidated, s.previewHandler)
            s.keyframeRequested = false
            s.invalidated = false
            return r
        }
        if keyframeFlag { keyframePending = true }
        if invalidated { pendingDirty = true }

        let list = provider?(now) ?? DashDisplayList(size: DashSize(width: Double(canvas.width), height: Double(canvas.height)),
                                                     background: .black)
        let changed = pendingDirty || list != lastList
        let previewFps = flags.current.previewFps
        let previewDue = previewHandler != nil && shared.current.mode == .foreground && now - lastPreviewAt >= 1 / previewFps
        let enc = encoder
        let decision = ProjectionPacer.decide(.init(
            now: now,
            encoderReady: enc?.isConfigured ?? false,
            contentChanged: changed,
            keyframeRequested: keyframePending,
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
            if enc.encode(pixelBuffer: buffer, pts: now, forceKeyframe: decision.forceKeyframe) {
                lastEncodeAt = now
                pictureNotEncoded = false
                if decision.forceKeyframe { keyframePending = false }
                shared.withLock {
                    $0.stats.encodeSubmissions += 1
                    if decision.isRepeat { $0.stats.repeatedFrames += 1 }
                }
            }
        }
        publishStatsIfDue(now)
    }

    private func publishStatsIfDue(_ now: TimeInterval) {
        guard now - lastStatsPublish >= 1 else { return }
        lastStatsPublish = now
        let encStats = encoder?.stats
        let (snapshot, handler) = shared.withLock { s -> (DashProjectionStats, (@Sendable (DashProjectionStats) -> Void)?) in
            s.stats.mode = s.mode
            s.stats.outputFPS = s.outputMeter.rate(now: now)
            s.stats.pullRate = s.pullMeter.rate(now: now)
            s.stats.averageEncodeMs = encStats?.averageEncodeMs ?? s.stats.averageEncodeMs
            s.stats.usingHardwareEncoder = encStats?.usingHardware
            s.stats.thermalLevel = s.thermalLevel
            s.stats.lowPowerMode = s.lowPowerMode
            s.stats.queueOverflows = frameQueue.overflowCount
            s.stats.gatedDrops = frameQueue.gatedDropCount
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
        let frames = H264Encoder.encodeStill(pixelBuffer: pic, width: target.width, height: target.height,
                                             parameters: currentEffective(), count: 2, timeout: 0.6)
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
        backgrounded = true
        guard canvas != nil, isEncodingMode else { return }
        encoder?.invalidate()
        encoder = nil
        switchToBackgroundMode()
    }

    /// Software encoder when possible, otherwise the hold IDR (render queue; no live encoder).
    private func switchToBackgroundMode() {
        frameQueue.resynchronize() // drop in-flight P-frames; the next live frame must be an IDR
        var nextMode = Mode.hold
        if flags.current.software, H264Encoder.isSoftwareEncodingSupported {
            shared.withLock { $0.mode = .backgroundSoftware }
            let candidate = makeEncoder(software: true)
            if let enc = candidate, enc.isSessionValid, enc.stats.usingHardware == false {
                encoder = enc
                nextMode = .backgroundSoftware
            } else {
                // No session, or VideoToolbox quietly handed back a HARDWARE session for the
                // software request (it would fail once the app is suspended): hold picture.
                if let enc = candidate, enc.isSessionValid {
                    Log.w("VIDEO", "background: no software H.264 session (hardware=\(enc.stats.usingHardware.map { String($0) } ?? "?")) — serving the hold picture")
                }
                candidate?.invalidate()
                encoder?.invalidate()
                encoder = nil
            }
        }
        let live = liveKeyframeForCurrentCanvas()
        shared.withLock { s in
            s.mode = nextMode
            if nextMode == .hold, s.holdFrames.isEmpty || s.holdCanvas != s.canvasSize, let k = live {
                s.holdFrames = [k]
                s.holdCanvas = s.canvasSize
            }
        }
        factory?.flush()
        keyframePending = true
        applyEffectiveParameters() // re-arms (or cancels) the timer for the new mode
        let holdCount = shared.current.holdFrames.count
        Log.i("VIDEO", "background → \(nextMode.rawValue)" + (nextMode == .hold ? " (\(holdCount) hold IDR(s))" : " @\(currentEffective().frameRate)fps"))
    }

    private func applyForeground() {
        backgrounded = false
        let m = shared.current.mode
        guard m == .hold || m == .backgroundSoftware, canvas != nil else { return }
        encoder?.invalidate()
        encoder = nil
        shared.withLock { $0.mode = .foreground }
        encoder = makeEncoder(software: false)
        frameQueue.resynchronize() // the dash decoder's reference is the hold / software picture
        keyframePending = true
        lastEncodeAt = nil
        pendingDirty = true
        shared.withLock { $0.holdFrames = []; $0.holdCanvas = nil }
        applyEffectiveParameters()
        tick()
        Log.i("VIDEO", "foreground → hardware encoder, IDR forced")
    }

    private func holdOrLastKeyframe() -> EncodedFrame? {
        nextHoldFrame() ?? liveKeyframeForCurrentCanvas()
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

    private func served(_ frame: EncodedFrame, hold: Bool) -> EncodedFrame {
        let dump = shared.withLock { s -> H264WireDump? in
            s.stats.pullsServed += 1
            if hold { s.stats.holdFramesServed += 1 }
            return s.dump
        }
        dump?.write(frame)
        return frame
    }
}
#endif
