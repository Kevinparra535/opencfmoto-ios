// SPDX-License-Identifier: AGPL-3.0-or-later
// Locked iPhone, Phase 0 (design §6.2): a `DashVideoEncoder` that needs no VideoToolbox, so the
// engine's background ladder is tested on every macOS machine (VMs included). It emits synthetic access
// units built from the known-good byte vectors (SPS + PPS + IDR slice, P slices), synchronously from
// `encode` (like a CPU encoder) or later on its own queue (like VideoToolbox), and can be told to fail
// creation, refuse encodes, stall, report hardware, or write a wrong-size SPS.
#if canImport(CoreVideo)
import CoreVideo
import Foundation
import OpenCfMotoCore
@testable import OpenCfMotoApple

/// The byte vectors of the Phase 0 contract §10.
enum FakeAU {
    /// The CI simulator's VideoToolbox SPS: 800×384, Baseline, constraint 0xE0, level 3.1.
    static let sps800x384 = Data([0x27, 0x42, 0xE0, 0x1F, 0xA9, 0x18, 0x19, 0x06, 0x36, 0x02, 0xD4, 0x08, 0x08, 0x08,
                                  0xC2, 0xB5, 0xEF, 0x7C, 0x04])
    /// 1280×576 (VUI truncated): the right SPS for a 1280×576 canvas, the WRONG one for 800×384.
    static let sps1280x576 = Data([0x67, 0x42, 0x00, 0x1F, 0xDA, 0x01, 0x40, 0x12, 0x69, 0xA8])
    /// CAVLC, ids 0.
    static let pps = Data([0x28, 0xDE, 0x09, 0xC8])

    /// Payload bytes that never contain 0x00 (no start-code emulation), different per frame.
    private static func payload(_ n: Int, marker: UInt8) -> [UInt8] {
        (0 ..< 12).map { i in marker | UInt8((n + i) & 0x3F) }
    }

    /// IDR slice header prefix (first_mb 0, slice_type 7 = I, pps 0) + payload.
    static func idrSlice(_ n: Int, marker: UInt8 = 0x80) -> Data { Data([0x65, 0x88, 0x84] + payload(n, marker: marker)) }
    /// P slice header prefix (first_mb 0, slice_type 5 = P, pps 0) + payload.
    static func pSlice(_ n: Int) -> Data { Data([0x41, 0x9A] + payload(n, marker: 0x80)) }

    static func idr(sps: Data = sps800x384, _ n: Int, marker: UInt8 = 0x80) -> Data {
        AnnexB.join([sps, pps, idrSlice(n, marker: marker)])
    }

    static func p(_ n: Int) -> Data { AnnexB.join([pSlice(n)]) }

    /// The two pre-encoded "Phone locked" IDRs the tests' hold seam returns (marker 0xC0 in the payload).
    static func holdFrames(sps: Data = sps800x384) -> [EncodedFrame] {
        (0 ..< 2).map { EncodedFrame(accessUnit: idr(sps: sps, $0, marker: 0xC0), isKeyframe: true, sequence: UInt64($0 + 1)) }
    }

    /// A hold IDR (tests tell them from live frames by the payload marker as well as by the tag).
    static func isHoldPicture(_ f: EncodedFrame) -> Bool {
        AnnexB.nalUnits(annexB: f.accessUnit).contains { $0.count > 3 && $0[$0.startIndex] == 0x65 && $0[$0.startIndex + 3] & 0xC0 == 0xC0 }
    }
}

final class FakeDashVideoEncoder: DashVideoEncoder, @unchecked Sendable {
    struct Behavior: Sendable {
        /// `configure` throws this (the session cannot be created).
        var configureFailure: DashEncoderFailure?
        /// What `usesHardware` answers (nil = "VideoToolbox did not say").
        var usesHardware: Bool? = false
        /// nil: output synchronously from `encode` (a CPU encoder); else this long after it, on a queue.
        var outputDelay: TimeInterval?
        /// Per-output delays (output 0, 1, …); outputs past the end use `outputDelay`.
        var outputDelays: [TimeInterval] = []
        /// Accept frames but never output anything.
        var stall = false
        /// Refuse every encode, reporting this failure first (synchronously, like VideoToolbox).
        var refusal: DashEncoderFailure?
        /// The SPS written in front of every IDR (nil: the right one for the configured size).
        var sps: Data?
        var averageEncodeMs = 1.0
        /// `invalidate()` still lets one P-frame out 50 ms later (a VideoToolbox output racing the
        /// invalidation): the engine must drop it.
        var lateFrameAfterInvalidate = false
    }

    let kind: DashEncoderKind
    let label: String
    let encoderID: String?
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "fake.dash.encoder")
    private var behavior: Behavior
    private var _onFrame: (@Sendable (EncodedFrame) -> Void)?
    private var _onFailure: (@Sendable (DashEncoderFailure) -> Void)?
    private var size: (width: Int, height: Int)?
    private var _parameters: EncoderParameters?
    private var valid = false
    private var outputs = 0
    private var inFlight = 0
    private var generation = 0
    private var _configureCount = 0
    private var _encodeCount = 0
    private var _invalidateCount = 0
    private var _forcedCount = 0
    private var lastSPS: [Data] = []
    private var lastPPS: [Data] = []

    init(label: String, kind: DashEncoderKind, encoderID: String? = nil, behavior: Behavior = Behavior()) {
        self.label = label
        self.kind = kind
        self.encoderID = encoderID
        self.behavior = behavior
    }

    func setBehavior(_ change: (inout Behavior) -> Void) {
        lock.lock()
        change(&behavior)
        lock.unlock()
    }

    var configureCount: Int { lock.lock(); defer { lock.unlock() }; return _configureCount }
    var encodeCount: Int { lock.lock(); defer { lock.unlock() }; return _encodeCount }
    var invalidateCount: Int { lock.lock(); defer { lock.unlock() }; return _invalidateCount }
    var forcedCount: Int { lock.lock(); defer { lock.unlock() }; return _forcedCount }
    var configuredSize: (width: Int, height: Int)? { lock.lock(); defer { lock.unlock() }; return size }

    var onFrame: (@Sendable (EncodedFrame) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onFrame }
        set { lock.lock(); _onFrame = newValue; lock.unlock() }
    }

    var onFailure: (@Sendable (DashEncoderFailure) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onFailure }
        set { lock.lock(); _onFailure = newValue; lock.unlock() }
    }

    func configure(width: Int, height: Int, parameters: EncoderParameters) throws {
        lock.lock()
        _configureCount += 1
        if let failure = behavior.configureFailure {
            lock.unlock()
            throw failure
        }
        size = (width, height)
        _parameters = parameters
        valid = true
        outputs = 0
        inFlight = 0
        generation += 1
        lock.unlock()
    }

    var isConfigured: Bool { lock.lock(); defer { lock.unlock() }; return size != nil }
    var isSessionValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    var framesInFlight: Int { lock.lock(); defer { lock.unlock() }; return inFlight }
    var parameters: EncoderParameters? { lock.lock(); defer { lock.unlock() }; return _parameters }

    @discardableResult
    func encode(pixelBuffer: CVPixelBuffer, pts: TimeInterval, forceKeyframe: Bool) -> Bool {
        lock.lock()
        guard let size, valid else { lock.unlock(); return false }
        _encodeCount += 1
        if let refusal = behavior.refusal {
            let handler = _onFailure
            lock.unlock()
            handler?(refusal)
            return false
        }
        if behavior.stall {
            inFlight += 1
            lock.unlock()
            return true
        }
        let n = outputs
        outputs += 1
        let key = forceKeyframe || n == 0
        if forceKeyframe { _forcedCount += 1 }
        let defaultSPS = size.width == 1280 && size.height == 576 ? FakeAU.sps1280x576 : FakeAU.sps800x384
        let sps = behavior.sps ?? defaultSPS
        if key {
            lastSPS = [sps]
            lastPPS = [FakeAU.pps]
        }
        let au = key ? FakeAU.idr(sps: sps, n) : FakeAU.p(n)
        let frame = EncodedFrame(accessUnit: au, isKeyframe: key, presentationTime: pts, sequence: UInt64(n + 1))
        let handler = _onFrame
        let delay = n < behavior.outputDelays.count ? behavior.outputDelays[n] : behavior.outputDelay
        let gen = generation
        if delay != nil { inFlight += 1 }
        lock.unlock()
        if let delay {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.emitLate(frame, generation: gen) }
        } else {
            handler?(frame)
        }
        return true
    }

    private func emitLate(_ frame: EncodedFrame, generation gen: Int) {
        lock.lock()
        guard gen == generation else { lock.unlock(); return } // invalidated / re-configured meanwhile
        inFlight = max(0, inFlight - 1)
        let handler = _onFrame
        lock.unlock()
        handler?(frame)
    }

    func update(parameters: EncoderParameters) {
        lock.lock()
        if _parameters != nil { _parameters = parameters }
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        valid = false
        size = nil
        generation += 1
        inFlight = 0
        _invalidateCount += 1
        let late = behavior.lateFrameAfterInvalidate ? _onFrame : nil
        let n = outputs
        lock.unlock()
        if let late {
            let frame = EncodedFrame(accessUnit: FakeAU.p(n), isKeyframe: false, sequence: UInt64(n + 1))
            queue.asyncAfter(deadline: .now() + 0.05) { late(frame) }
        }
    }

    var usesHardware: Bool? { lock.lock(); defer { lock.unlock() }; return behavior.usesHardware }
    var averageEncodeMs: Double { lock.lock(); defer { lock.unlock() }; return behavior.averageEncodeMs }
    var lastParameterSets: (sps: [Data], pps: [Data]) { lock.lock(); defer { lock.unlock() }; return (lastSPS, lastPPS) }
}

/// Makes the engine's VideoToolbox encoders (`DashProjectionEngine.encoderFactory`) as fakes and
/// remembers every request.
final class FakeEncoderFactory: @unchecked Sendable {
    typealias Request = DashProjectionEngine.EncoderRequest
    private let lock = NSLock()
    private var behaviorFor: @Sendable (Request) -> FakeDashVideoEncoder.Behavior
    private var _made: [(request: Request, encoder: FakeDashVideoEncoder)] = []

    init(_ behaviorFor: @escaping @Sendable (Request) -> FakeDashVideoEncoder.Behavior = { _ in .init() }) {
        self.behaviorFor = behaviorFor
    }

    /// Behaviour of the encoders made from now on.
    func setBehavior(_ behaviorFor: @escaping @Sendable (Request) -> FakeDashVideoEncoder.Behavior) {
        lock.lock()
        self.behaviorFor = behaviorFor
        lock.unlock()
    }

    func make(_ request: Request) -> any DashVideoEncoder {
        lock.lock()
        let behavior = behaviorFor(request)
        let encoder = FakeDashVideoEncoder(label: request.label,
                                           kind: request.software ? .videoToolboxSoftware : .videoToolboxHardware,
                                           encoderID: request.encoderID, behavior: behavior)
        _made.append((request, encoder))
        lock.unlock()
        return encoder
    }

    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return _made.map(\.request) }
    var encoders: [FakeDashVideoEncoder] { lock.lock(); defer { lock.unlock() }; return _made.map(\.encoder) }
    func encoders(label: String) -> [FakeDashVideoEncoder] { encoders.filter { $0.label == label } }
}
#endif
