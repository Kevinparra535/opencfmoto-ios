// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) AaCompositor.kt (mirror fit math) + VideoPipeline.kt (mirror mode)
// Screen mirroring source (ReplayKit Broadcast Upload Extension today; in-process ScreenCaptureKit
// on iOS 27+): phone screen CMSampleBuffers → fit into the dash canvas (FIT by default, screen
// margins, any CGImagePropertyOrientation) → 32BGRA canvas buffer → H264Encoder → access units.
// Ported from OpenCfMoto (Android) AaCompositor.kt (computeViewport / mapCanvasToSource, used by
// VideoPipeline.setupProjectionDisplay for MediaProjection mirroring) — docs/spec/media-video.md
// §10.3, §10.6, §15.7; ios-platform-facts.md §f and design recommendation 14.
//
// Memory (the extension has ~50 MB, ~25 MB for our code): tiny pools (≤ 3 canvas buffers, ≤ 2
// scaled intermediates), one VT session, no caches. ReplayKit stops delivering frames on a static
// screen, so the last canvas picture is re-encoded every 0.9 s (keep-alive).

import Foundation
import OpenCfMotoCore

// MARK: - Platform-neutral fit math (unit-tested on Linux)

/// The mirror fit math of Android `AaCompositor.computeViewport` / `mapCanvasToSource`, with the
/// same Float32 arithmetic and Java `Math.round` (= floor(x + 0.5)) rounding.
public enum MirrorFitMath {
    /// Draw rectangle in canvas pixels (top-left origin); may exceed the canvas for FILL.
    public struct Viewport: Equatable, Sendable, CustomStringConvertible {
        public var x: Int
        public var y: Int
        public var width: Int
        public var height: Int
        public init(x: Int, y: Int, width: Int, height: Int) { self.x = x; self.y = y; self.width = width; self.height = height }
        public var description: String { "\(x),\(y) \(width)x\(height)" }
    }

    /// Area left after the margins (clamped like Android): (x, y, width, height).
    public static func insetArea(canvasWidth w: Int, canvasHeight h: Int, margins: ScreenMargins) -> Viewport {
        let mT = clamp(margins.top, 0, h)
        let mB = clamp(margins.bottom, 0, h - mT)
        let mL = clamp(margins.left, 0, w)
        let mR = clamp(margins.right, 0, w - mL)
        return Viewport(x: mL, y: mT, width: max(w - mL - mR, 1), height: max(h - mT - mB, 1))
    }

    /// Where a `sourceWidth × sourceHeight` picture is drawn in the canvas (AaCompositor.kt:298-330).
    public static func viewport(canvasWidth w: Int, canvasHeight h: Int, sourceWidth sw: Int, sourceHeight sh: Int,
                                fit: ScreenFit, margins: ScreenMargins) -> Viewport? {
        guard w > 0, h > 0, sw > 0, sh > 0 else { return nil }
        let area = insetArea(canvasWidth: w, canvasHeight: h, margins: margins)
        let srcAspect = Float(sw) / Float(sh)
        let areaAspect = Float(area.width) / Float(area.height)
        var vw = area.width, vh = area.height
        switch fit {
        case .stretch:
            break
        case .fit:
            if srcAspect < areaAspect {
                vh = area.height; vw = javaRound(Float(area.height) * srcAspect)
            } else {
                vw = area.width; vh = javaRound(Float(area.width) / srcAspect)
            }
        case .fill:
            if srcAspect < areaAspect {
                vw = area.width; vh = javaRound(Float(area.width) / srcAspect)
            } else {
                vh = area.height; vw = javaRound(Float(area.height) * srcAspect)
            }
        }
        // Int division truncates toward zero, like Kotlin.
        return Viewport(x: area.x + (area.width - vw) / 2, y: area.y + (area.height - vh) / 2, width: vw, height: vh)
    }

    /// Inverse map of a canvas point into source pixels; nil inside a black bar
    /// (AaCompositor.kt:281-289, 64-bit integer math).
    public static func mapCanvasToSource(x cx: Int, y cy: Int, viewport v: Viewport, sourceWidth sw: Int,
                                         sourceHeight sh: Int) -> (x: Int, y: Int)? {
        guard v.width > 0, v.height > 0, sw > 0, sh > 0 else { return nil }
        let rx = cx - v.x, ry = cy - v.y
        guard rx >= 0, ry >= 0, rx < v.width, ry < v.height else { return nil }
        let sx = Int(Int64(rx) * Int64(sw) / Int64(v.width))
        let sy = Int(Int64(ry) * Int64(sh) / Int64(v.height))
        return (clamp(sx, 0, sw - 1), clamp(sy, 0, sh - 1))
    }

    /// Java `Math.round(float)`: floor(x + 0.5), ties toward +∞.
    static func javaRound(_ f: Float) -> Int {
        guard f.isFinite else { return 0 }
        return Int((Double(f) + 0.5).rounded(.down))
    }

    static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { max(lo, min(hi, v)) }

    // Orientation (CGImagePropertyOrientation raw values: 1 up, 2 upMirrored, 3 down,
    // 4 downMirrored, 5 leftMirrored, 6 right, 7 rightMirrored, 8 left; EXIF semantics).

    static func normalizedOrientation(_ raw: UInt32) -> UInt32 { (1 ... 8).contains(raw) ? raw : 1 }

    /// The stored picture is displayed rotated by 90° (width and height swap).
    public static func isQuarterTurn(orientation raw: UInt32) -> Bool { normalizedOrientation(raw) >= 5 }

    /// Size of the picture once displayed upright.
    public static func orientedSize(width: Int, height: Int, orientation raw: UInt32) -> (width: Int, height: Int) {
        isQuarterTurn(orientation: raw) ? (height, width) : (width, height)
    }

    /// Linear part (a, b, c, d — CGAffineTransform semantics, y-down, about the picture centre)
    /// mapping stored-picture coordinates to upright display coordinates.
    static func displayMatrix(orientation raw: UInt32) -> (a: Double, b: Double, c: Double, d: Double) {
        switch normalizedOrientation(raw) {
        case 2: return (-1, 0, 0, 1)   // upMirrored: flip horizontally
        case 3: return (-1, 0, 0, -1)  // down: 180°
        case 4: return (1, 0, 0, -1)   // downMirrored: flip vertically
        case 5: return (0, 1, 1, 0)    // leftMirrored: transpose
        case 6: return (0, 1, -1, 0)   // right: rotate 90° clockwise
        case 7: return (0, -1, -1, 0)  // rightMirrored: transverse
        case 8: return (0, -1, 1, 0)   // left: rotate 90° counter-clockwise
        default: return (1, 0, 0, 1)   // up
        }
    }

    /// Size of the scaled, still un-rotated intermediate picture for `viewport`, at most
    /// `maxPixels` (FILL viewports can be much larger than the canvas; the rest is scaled up).
    static func intermediateSize(viewport v: Viewport, orientation raw: UInt32, maxPixels: Int) -> (width: Int, height: Int) {
        var w = max(2, v.width), h = max(2, v.height)
        if isQuarterTurn(orientation: raw) { swap(&w, &h) }
        let pixels = Double(w) * Double(h)
        if maxPixels > 0, pixels > Double(maxPixels) {
            let s = (Double(maxPixels) / pixels).squareRoot()
            w = max(2, Int(Double(w) * s))
            h = max(2, Int(Double(h) * s))
        }
        return (w, h)
    }
}

// MARK: - Mirror source (Apple platforms)

#if canImport(VideoToolbox) && canImport(CoreGraphics) && canImport(CoreMedia) && canImport(ImageIO)
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import VideoToolbox

public struct MirrorFrameSourceStats: Sendable, Equatable {
    public var framesIn = 0
    /// Screen frames replaced by a newer one before being processed (frame-rate cap).
    public var framesCoalesced = 0
    public var framesProcessed = 0
    public var repeats = 0
    public var transferErrors = 0
    public var framesOut = 0
    public var keyframesOut = 0
    public var lastProcessMs: Double = 0
    public var sourceWidth = 0
    public var sourceHeight = 0
    public var orientation: UInt32 = 1
    public var viewport: MirrorFitMath.Viewport?
    public init() {}
}

/// Fits phone-screen frames into the dash canvas and encodes them.
/// - In the broadcast extension: create it WITHOUT a configuration (`init(configuration: nil)`),
///   set `onFrame` (forward to `MirrorRelayClient.send(frame:)`), feed
///   `append(sampleBuffer:orientation:)`, apply `MirrorRelayClient.onConfig` with
///   `update(configuration:)` and keyframe requests with `requestKeyframe()`. Nothing is encoded
///   until the host's first CONFIG: an IDR at a guessed canvas could reach a dash that negotiated
///   another size (MP-3). The newest screen frame waits and is encoded as soon as CONFIG arrives.
/// - In-process (iOS 27 ScreenCaptureKit): use it directly as the link's `VideoFrameSource`.
/// Thread-safe; `append` returns immediately (work runs on a private serial queue).
public final class MirrorFrameSource: VideoFrameSource, @unchecked Sendable {
    public typealias FrameHandler = @Sendable (EncodedFrame) -> Void

    /// Queue used when the source is pulled directly (VideoFrameSource).
    public let frameQueue: FrameQueue
    private let work = DispatchQueue(label: "ocm.mirror.work", qos: .userInteractive)
    private let lock = NSLock()

    // Guarded by `lock`.
    /// nil until the host's first CONFIG (extension use): nothing is encoded meanwhile.
    private var _configuration: MirrorRelayConfig?
    private var _onFrame: FrameHandler?
    private var deliversToQueue: Bool
    private var pending: (buffer: CVPixelBuffer, orientation: UInt32)?
    private var drainScheduled = false
    private var _stats = MirrorFrameSourceStats()
    private var stopped = false

    // `work` queue state.
    private var appliedConfig: MirrorRelayConfig?
    private var canvasFactory: PixelBufferFactory?
    private var intermediateFactory: PixelBufferFactory?
    private var transfer: VTPixelTransferSession?
    private var encoder: H264Encoder?
    private var lastCanvasBuffer: CVPixelBuffer?
    /// The last scaled (un-rotated) screen picture and what it was made from: re-composed into
    /// the canvas when the configuration changes while the screen is static.
    private var lastScaled: (buffer: CVPixelBuffer, orientation: UInt32, sourceWidth: Int, sourceHeight: Int)?
    private var lastEncodeAt: TimeInterval = 0
    private var lastProcessedAt: TimeInterval = -.greatestFiniteMagnitude
    private var keyframePending = true
    private var timer: DispatchSourceTimer?

    private static let colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private static let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    /// - Parameters:
    ///   - configuration: the canvas / encoder / fit settings, or nil to wait for the first
    ///     `update(configuration:)` (the broadcast extension waits for the host's CONFIG).
    ///   - deliversToQueue: also push frames into `frameQueue` (direct `VideoFrameSource` use;
    ///     enabled automatically by `prepare`).
    public init(configuration: MirrorRelayConfig?, deliversToQueue: Bool = false, queueCapacity: Int = 3) {
        _configuration = configuration
        self.deliversToQueue = deliversToQueue
        frameQueue = FrameQueue(capacity: queueCapacity)
        frameQueue.onKeyframeNeeded = { [weak self] in self?.requestKeyframe() }
        startTimer()
    }

    deinit {
        timer?.cancel()
        encoder?.invalidate()
        if let t = transfer { VTPixelTransferSessionInvalidate(t) }
    }

    /// The current settings (the 800×384 default while no configuration was received yet).
    public var configuration: MirrorRelayConfig {
        lock.lock(); defer { lock.unlock() }
        return _configuration ?? MirrorRelayConfig(canvas: .defaultLandscape)
    }

    /// A configuration was given (init or `update(configuration:)`): frames are being encoded.
    public var isConfigured: Bool { lock.lock(); defer { lock.unlock() }; return _configuration != nil }

    /// Receives every encoded access unit (encoder thread).
    public var onFrame: FrameHandler? {
        get { lock.lock(); defer { lock.unlock() }; return _onFrame }
        set { lock.lock(); _onFrame = newValue; lock.unlock() }
    }

    public var stats: MirrorFrameSourceStats { lock.lock(); defer { lock.unlock() }; return _stats }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    /// The last composed canvas picture (tests / diagnostics). Do not call from the work queue.
    var lastCanvasBufferForTesting: CVPixelBuffer? { work.sync { lastCanvasBuffer } }

    /// New canvas / encoder / fit settings (from the host). The next frame is an IDR: the last
    /// screen picture is re-composed for the new canvas / fit / margins at once (ReplayKit sends
    /// nothing new while the screen is static), and a frame that waited for the first CONFIG is
    /// processed now.
    public func update(configuration: MirrorRelayConfig) {
        lock.lock()
        let old = _configuration
        _configuration = configuration
        let waiting = pending != nil && !drainScheduled
        if waiting { drainScheduled = true }
        lock.unlock()
        if old.map({ $0.canvas.width != configuration.canvas.width || $0.canvas.height != configuration.canvas.height }) ?? true {
            frameQueue.invalidateKeyframe() // in-process use: never re-send an IDR of another canvas
        }
        work.async { [weak self] in
            guard let self else { return }
            self.keyframePending = true
            let changed = self.applyConfigurationIfNeeded()
            if changed { self.recomposeLastPicture() }
            self.encodeLast(force: true)
            if waiting { self.drain() }
        }
    }

    /// One screen frame (ReplayKit `processSampleBuffer(_:with: .video)`). Honour
    /// `RPVideoSampleOrientationKey` by passing it as `orientation`.
    public func append(sampleBuffer: CMSampleBuffer, orientation: CGImagePropertyOrientation) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        append(pixelBuffer: buffer, orientation: orientation)
    }

    public func append(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        _stats.framesIn += 1
        if pending != nil { _stats.framesCoalesced += 1 }
        pending = (pixelBuffer, orientation.rawValue) // keep only the newest frame
        // Without a configuration the newest frame just waits for the first CONFIG.
        let schedule = !drainScheduled && _configuration != nil
        if schedule { drainScheduled = true }
        lock.unlock()
        if schedule { work.async { [weak self] in self?.drain() } }
    }

    /// The next encoded frame will be an IDR; the current picture is re-encoded right away.
    public func requestKeyframe() {
        work.async { [weak self] in
            guard let self else { return }
            self.keyframePending = true
            self.encodeLast(force: true)
        }
    }

    /// Releases the encoder and buffers; further frames are ignored.
    public func stop() {
        lock.lock(); stopped = true; pending = nil; lock.unlock()
        work.sync {
            timer?.cancel()
            timer = nil
            encoder?.invalidate()
            encoder = nil
            if let t = transfer { VTPixelTransferSessionInvalidate(t) }
            transfer = nil
            canvasFactory = nil
            intermediateFactory = nil
            lastCanvasBuffer = nil
            lastScaled = nil
            appliedConfig = nil
        }
        frameQueue.close()
    }

    // MARK: VideoFrameSource (in-process use)

    public func prepare(canvas: VideoCanvas, parameters: EncoderParameters) {
        lock.lock()
        deliversToQueue = true
        var cfg = _configuration
        cfg.canvas = canvas
        cfg.parameters = parameters
        lock.unlock()
        update(configuration: cfg)
    }

    public func resynchronize() {
        frameQueue.resynchronize() // gate + flush + onKeyframeNeeded → requestKeyframe()
    }

    public func nextFrame(timeout: TimeInterval) async -> EncodedFrame? {
        let r = await FramePull.next(from: frameQueue, timeout: timeout) { [weak self] in
            guard let self, !self.isStopped else { return nil }
            return self.frameQueue.lastKeyframe
        }
        return r.frame
    }

    public func mediaStopped() {
        frameQueue.flush()
    }

    // MARK: work queue

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(flags: [], queue: work)
        t.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.keepAlive() }
        t.resume()
        timer = t
    }

    /// Re-encodes the last picture when nothing was encoded for `repeatLastFrameAfter` (0.9 s).
    private func keepAlive() {
        guard lastCanvasBuffer != nil else { return }
        let repeatAfter = max(0.1, configuration.parameters.repeatLastFrameAfter)
        if keyframePending || ProcessInfo.processInfo.systemUptime - lastEncodeAt >= repeatAfter {
            if encodeLast(force: keyframePending) {
                lock.lock(); _stats.repeats += 1; lock.unlock()
            }
        }
    }

    private func drain() {
        let now = ProcessInfo.processInfo.systemUptime
        let fps = max(1, configuration.parameters.frameRate)
        let minInterval = 1.0 / Double(fps)
        let wait = lastProcessedAt + minInterval - now
        if wait > 0.001 {
            work.asyncAfter(deadline: .now() + wait) { [weak self] in self?.drain() }
            return
        }
        lock.lock()
        guard _configuration != nil else {
            drainScheduled = false // keep `pending` for the first CONFIG
            lock.unlock()
            return
        }
        let item = pending
        pending = nil
        drainScheduled = false
        lock.unlock()
        guard let item else { return }
        lastProcessedAt = now
        process(item.buffer, orientation: item.orientation)
    }

    /// Applies a new configuration (work queue); true when it changed something.
    @discardableResult
    private func applyConfigurationIfNeeded() -> Bool {
        lock.lock()
        let pendingConfig = _configuration
        lock.unlock()
        guard let cfg = pendingConfig, appliedConfig != cfg else { return false }
        let old = appliedConfig
        appliedConfig = cfg
        let w = cfg.canvas.width, h = cfg.canvas.height
        guard w >= 16, h >= 16 else {
            Log.w("MIRROR", "invalid mirror canvas \(cfg.canvas)")
            canvasFactory = nil
            return true
        }
        let sizeChanged = old.map { $0.canvas.width != w || $0.canvas.height != h } ?? true
        if sizeChanged || canvasFactory == nil {
            canvasFactory = try? PixelBufferFactory(width: w, height: h, minimumBufferCount: 2, maximumBufferCount: 3)
            lastCanvasBuffer = nil
        }
        let p = cfg.parameters
        let encoderNeedsRebuild = sizeChanged || encoder == nil || old?.parameters.forceBaseline != p.forceBaseline
            || old?.parameters.keyframeIntervalSeconds != p.keyframeIntervalSeconds
        if encoderNeedsRebuild {
            encoder?.invalidate()
            let enc = H264Encoder(label: "mirror")
            enc.onFrame = { [weak self] f in self?.deliver(f) }
            do {
                try enc.configure(width: w, height: h, parameters: p)
            } catch {
                Log.w("MIRROR", "encoder not ready: \(error)")
            }
            encoder = enc
        } else {
            encoder?.update(parameters: p)
        }
        if transfer == nil {
            var t: VTPixelTransferSession?
            let st = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &t)
            if st == 0, let t {
                _ = VTSessionSetProperty(t, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
                transfer = t
            } else {
                Log.e("MIRROR", "VTPixelTransferSessionCreate failed: \(st)")
            }
        }
        keyframePending = true
        Log.i("MIRROR", "canvas \(w)x\(h) fit=\(cfg.fit.rawValue) \(p.frameRate)fps \(p.bitrate / 1000)kbps "
            + "margins T\(cfg.margins.top) B\(cfg.margins.bottom) L\(cfg.margins.left) R\(cfg.margins.right)")
        return true
    }

    /// Re-composes the last screen picture with the applied configuration (work queue): a canvas,
    /// fit or margin change takes effect at once even while ReplayKit sends no new frame.
    private func recomposeLastPicture() {
        guard let last = lastScaled, let cfg = appliedConfig, let canvasFactory else { return }
        let w = canvasFactory.width, h = canvasFactory.height
        let oriented = MirrorFitMath.orientedSize(width: last.sourceWidth, height: last.sourceHeight, orientation: last.orientation)
        guard let vp = MirrorFitMath.viewport(canvasWidth: w, canvasHeight: h, sourceWidth: oriented.width,
                                              sourceHeight: oriented.height, fit: cfg.fit, margins: cfg.margins),
              let target = canvasFactory.makeBuffer(),
              compose(last.buffer, into: target, viewport: vp, orientation: last.orientation, margins: cfg.margins)
        else { return }
        lastCanvasBuffer = target
    }

    private func process(_ source: CVPixelBuffer, orientation raw: UInt32) {
        let t0 = ProcessInfo.processInfo.systemUptime
        applyConfigurationIfNeeded()
        let cfg = configuration
        guard let canvasFactory, let transfer else { return }
        let w = canvasFactory.width, h = canvasFactory.height
        let sw = CVPixelBufferGetWidth(source), sh = CVPixelBufferGetHeight(source)
        let oriented = MirrorFitMath.orientedSize(width: sw, height: sh, orientation: raw)
        guard let vp = MirrorFitMath.viewport(canvasWidth: w, canvasHeight: h, sourceWidth: oriented.width,
                                              sourceHeight: oriented.height, fit: cfg.fit, margins: cfg.margins) else { return }
        let mid = MirrorFitMath.intermediateSize(viewport: vp, orientation: raw, maxPixels: w * h * 2)
        if intermediateFactory?.width != mid.width || intermediateFactory?.height != mid.height {
            intermediateFactory = try? PixelBufferFactory(width: mid.width, height: mid.height, minimumBufferCount: 1, maximumBufferCount: 2)
        }
        guard let scaled = intermediateFactory?.makeBuffer(), let target = canvasFactory.makeBuffer() else { return }
        let st = VTPixelTransferSessionTransferImage(transfer, from: source, to: scaled)
        guard st == 0 else {
            lock.lock(); _stats.transferErrors += 1; lock.unlock()
            Log.shared.throttled("mirror-transfer", interval: 5, .warn, "MIRROR", "pixel transfer failed: \(st)")
            return
        }
        guard compose(scaled, into: target, viewport: vp, orientation: raw, margins: cfg.margins) else { return }
        lastCanvasBuffer = target
        lastScaled = (scaled, raw, sw, sh)
        _ = encodeLast(force: keyframePending)
        let ms = (ProcessInfo.processInfo.systemUptime - t0) * 1000
        lock.lock()
        if _stats.sourceWidth != sw || _stats.sourceHeight != sh || _stats.orientation != raw {
            Log.i("MIRROR", "screen \(sw)x\(sh) orientation \(raw) → viewport \(vp) in \(w)x\(h)")
        }
        _stats.framesProcessed += 1
        _stats.lastProcessMs = ms
        _stats.sourceWidth = sw
        _stats.sourceHeight = sh
        _stats.orientation = raw
        _stats.viewport = vp
        lock.unlock()
    }

    /// Black canvas, picture drawn upright into the viewport, clipped to the margin area.
    private func compose(_ picture: CVPixelBuffer, into target: CVPixelBuffer, viewport vp: MirrorFitMath.Viewport,
                         orientation raw: UInt32, margins: ScreenMargins) -> Bool {
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(picture, options: nil, imageOut: &image) == 0, let image else { return false }
        guard CVPixelBufferLockBaseAddress(target, []) == kCVReturnSuccess else { return false }
        defer { _ = CVPixelBufferUnlockBaseAddress(target, []) }
        guard let base = CVPixelBufferGetBaseAddress(target) else { return false }
        let w = CVPixelBufferGetWidth(target), h = CVPixelBufferGetHeight(target)
        guard let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(target),
                                  space: Self.colorSpace, bitmapInfo: Self.bitmapInfo) else { return false }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1) // top-left origin, y down
        ctx.setBlendMode(.copy)
        ctx.setFillColor(CGColor(colorSpace: Self.colorSpace, components: [0, 0, 0, 1]) ?? CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let area = MirrorFitMath.insetArea(canvasWidth: w, canvasHeight: h, margins: margins)
        ctx.clip(to: CGRect(x: area.x, y: area.y, width: area.width, height: area.height))
        let quarter = MirrorFitMath.isQuarterTurn(orientation: raw)
        let drawW = CGFloat(quarter ? vp.height : vp.width)
        let drawH = CGFloat(quarter ? vp.width : vp.height)
        let m = MirrorFitMath.displayMatrix(orientation: raw)
        ctx.translateBy(x: CGFloat(vp.x) + CGFloat(vp.width) / 2, y: CGFloat(vp.y) + CGFloat(vp.height) / 2)
        ctx.concatenate(CGAffineTransform(a: CGFloat(m.a), b: CGFloat(m.b), c: CGFloat(m.c), d: CGFloat(m.d), tx: 0, ty: 0))
        ctx.translateBy(x: -drawW / 2, y: drawH / 2)
        ctx.scaleBy(x: 1, y: -1) // images are drawn y-up
        ctx.interpolationQuality = (CGFloat(image.width) == drawW && CGFloat(image.height) == drawH) ? .none : .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: drawW, height: drawH))
        return true
    }

    @discardableResult
    private func encodeLast(force: Bool) -> Bool {
        guard let buffer = lastCanvasBuffer, let encoder else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        guard encoder.encode(pixelBuffer: buffer, pts: now, forceKeyframe: force) else { return false }
        lastEncodeAt = now
        if force { keyframePending = false }
        return true
    }

    private func deliver(_ frame: EncodedFrame) {
        lock.lock()
        _stats.framesOut += 1
        if frame.isKeyframe { _stats.keyframesOut += 1 }
        let handler = _onFrame
        let toQueue = deliversToQueue
        lock.unlock()
        handler?(frame)
        if toQueue { frameQueue.push(frame) }
    }
}
#endif
