// SPDX-License-Identifier: AGPL-3.0-or-later
// Test doubles for the link: a scripted frame source, a manual clock, a virtual scheduler for the
// ghost filter, an event recorder and small async helpers.

import Foundation
import XCTest
@testable import OpenCfMotoCore

/// Manual monotonic clock (seconds).
final class LinkManualClock: MonotonicClock, @unchecked Sendable {
    private let t: Locked<TimeInterval>
    init(_ start: TimeInterval = 0) { t = Locked(start) }
    func now() -> TimeInterval { t.current }
    func set(_ v: TimeInterval) { t.set(v) }
    func setMs(_ ms: Int64) { t.set(Double(ms) / 1000) }
}

/// Virtual-time scheduler for `GhostTouchFilter`: nothing runs until the test advances time.
final class LinkVirtualScheduler: TouchStitchScheduler, @unchecked Sendable {
    private final class Item: TouchStitchCancellable, @unchecked Sendable {
        let due: TimeInterval
        let seq: Int
        let work: @Sendable () -> Void
        let cancelled = Locked(false)
        init(due: TimeInterval, seq: Int, work: @escaping @Sendable () -> Void) {
            self.due = due
            self.seq = seq
            self.work = work
        }
        func cancel() { cancelled.set(true) }
    }

    let clock: LinkManualClock
    private let items = Locked<[Item]>([])
    private let seq = Locked(0)

    init(clock: LinkManualClock) { self.clock = clock }

    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> TouchStitchCancellable {
        let n = seq.withLock { s -> Int in
            s += 1
            return s
        }
        let item = Item(due: clock.now() + delay, seq: n, work: work)
        items.withLock { $0.append(item) }
        return item
    }

    /// Runs every pending item due strictly before `t` (ms), earliest first, moving the clock to each
    /// item's due time (Android trace semantics: a timer due exactly at an input fires after it).
    func runDue(beforeMs t: Int64) {
        let limit = Double(t) / 1000 - 1e-9
        while let next = popEarliest(dueBefore: limit) {
            clock.set(next.due)
            next.work()
        }
    }

    func runAll() { runDue(beforeMs: Int64.max / 2) }

    var pendingCount: Int { items.withLock { $0.filter { !$0.cancelled.current }.count } }

    private func popEarliest(dueBefore limit: TimeInterval) -> Item? {
        items.withLock { list -> Item? in
            list.removeAll { $0.cancelled.current }
            guard let idx = list.indices.filter({ list[$0].due <= limit })
                .min(by: { (list[$0].due, list[$0].seq) < (list[$1].due, list[$1].seq) }) else { return nil }
            return list.remove(at: idx)
        }
    }
}

/// Scripted `VideoFrameSource`: after every `resynchronize()` the next frame is a keyframe
/// (SPS + PPS + IDR toy AU), then P-frames. Records every call in order.
final class LinkFakeFrameSource: VideoFrameSource, @unchecked Sendable {
    enum Call: Equatable {
        case prepare(VideoCanvas, EncoderParameters)
        case resynchronize
        case nextFrame
        case mediaStopped
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var needKeyframe = true
    private var sequence: UInt64 = 0
    /// When true, `nextFrame` returns nil after the timeout.
    var starve: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _starve }
        set { lock.lock(); _starve = newValue; lock.unlock() }
    }

    private var _starve = false

    static let sps: [UInt8] = [0x67, 0x42, 0x00, 0x1F, 0xDA, 0x01, 0x40, 0x12, 0x69, 0xA8]
    static let pps: [UInt8] = [0x68, 0xCE, 0x0D, 0x88]

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }

    /// The frame number `seq` this source produces (keyframe or P).
    static func frame(seq: UInt64, key: Bool) -> EncodedFrame {
        let au: Data
        if key {
            au = AnnexB.join([Data(sps), Data(pps), Data([0x65, 0x88, 0x84, UInt8(seq & 0xFF)])])
        } else {
            au = AnnexB.join([Data([0x41, 0x9A, UInt8(seq & 0xFF)])])
        }
        return EncodedFrame(accessUnit: au, isKeyframe: key, presentationTime: 0, sequence: seq)
    }

    func prepare(canvas: VideoCanvas, parameters: EncoderParameters) {
        lock.lock(); _calls.append(.prepare(canvas, parameters)); lock.unlock()
    }

    func resynchronize() {
        lock.lock()
        _calls.append(.resynchronize)
        needKeyframe = true
        lock.unlock()
    }

    func nextFrame(timeout: TimeInterval) async -> EncodedFrame? {
        if beginPull() {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            return nil
        }
        return produce()
    }

    /// Records the pull; true when starving.
    private func beginPull() -> Bool {
        lock.lock(); defer { lock.unlock() }
        _calls.append(.nextFrame)
        return _starve
    }

    private func produce() -> EncodedFrame {
        lock.lock()
        defer { lock.unlock() }
        sequence += 1
        let key = needKeyframe
        needKeyframe = false
        return LinkFakeFrameSource.frame(seq: sequence, key: key)
    }

    func mediaStopped() {
        lock.lock(); _calls.append(.mediaStopped); lock.unlock()
    }
}

/// Collects `EasyConnLink.events`.
final class LinkEventRecorder: @unchecked Sendable {
    private let events = Locked<[LinkEvent]>([])
    private var task: Task<Void, Never>?

    init(_ link: EasyConnLink) {
        task = Task { [events] in
            for await e in link.events { events.withLock { $0.append(e) } }
        }
    }

    deinit { task?.cancel() }

    var all: [LinkEvent] { events.current }

    var states: [LinkState] {
        all.compactMap { if case let .state(s) = $0 { return s } else { return nil } }
    }

    var touches: [DashTouch] {
        all.compactMap { if case let .touch(t) = $0 { return t } else { return nil } }
    }

    var canvases: [VideoCanvas] {
        all.compactMap { if case let .canvas(c) = $0 { return c } else { return nil } }
    }

    var identified: [DashInfo] {
        all.compactMap { if case let .dashIdentified(d) = $0 { return d } else { return nil } }
    }

    var mediaStartedCount: Int {
        all.filter { if case .mediaStarted = $0 { return true } else { return false } }.count
    }
}

/// Polls `condition` every 5 ms until true or `timeout` seconds elapsed.
func linkEventually(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

/// Awaits `operation`, failing with `TimeoutError` after `seconds`.
func linkWithin<T: Sendable>(_ seconds: TimeInterval = 5, _ label: String = "",
                             _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withTimeout(seconds, label: label, operation: operation)
}

/// Hex helper for byte-exact assertions.
func linkHex(_ s: String) -> Data {
    guard let d = Data(hexString: s) else { fatalError("bad hex: \(s)") }
    return d
}

/// The §9.5 fixed test key (PKCS#1 RSAPrivateKey DER, base64).
enum LinkTestKeys {
    static let pkcs1PrivateKeyBase64 = "MIICWwIBAAKBgQCJK2qMkijMfOspHCr9UMR+djdNu6vnubHpqfJMacvtgSnbOmaMpse9gLsKp3Hd1GTK5k9W8Jk3PPU6JW3drsgdK43RdlotOlGT5PMiw7jmo0OydzXjuFrjfhLscuz6MbNPXO12IkrgoVWPsfOp3xskqWrlfQuCGNljUt/UzHJWFwIDAQABAoGAHOSYxnBZCK29aQTmZ0JWiV7ESmrgDGj4eUQTZhYY3vfIhcWY6UKOKzQM8fMQUI4XBwgZKTJ3y4NbEjrlF/9jZjaP+DySrn+U5HnVkIr4Hye3I2tOqeJaWL4LGFr0fV4qaiJVl4XxL2JMI2RlMt+S9Cw3bPkim4hIJKySXLLbjQkCQQDCzsFwYRj0ddspxVD1hVUQRaB10YTCBYoCMMKyxmWHLQqNukzWTc8EYctsz4T1u4MQnDTc3t6iWdS1of3QKKoPAkEAtEHCivoWq2bVXCViThK+BP/sHEMDyXqTgyMuv1jNkUxpwUmCoptcMNrZMBdfBowrxSe4LBersIMU1ixM/++7eQJARsTVgP3FEwm9lG8Z+hd1z3N711FF6TYZ7LHKCSgJuhGiw9nqD/A0RGNCg0TgCGUWN/KHQbW1K0V3AITYr8YWAQJAS3E+X/Y9qK0YXUGUPELh3qvSAR4XJqszs+30sccT+lz14hzHHRFS62uc/OC7N71Q0GpITcP2aqDiBqVx8KhAWQJAP3c2sgSFzB3rmQCvLG06zxM5wNmeNUiW5Vo6ZBHL8XnoFyJlMIft/pie0smdqoAZ/yCMxa4GVMUGEmc9T5THxA=="

    static let fixtureSigner: PureSwiftHuidSigner = {
        try! PureSwiftHuidSigner(pkcs1PrivateKeyDER: Data(base64Encoded: pkcs1PrivateKeyBase64)!)
    }()

    /// Phone identity of the §8.4 worked example.
    static let examplePhone = PhoneIdentity(phoneUUID: "3f2b8c1e-9a47-4d2e-8b6a-0c5d7e9f1a23", phoneBrand: "samsung",
                                            phoneModel: "SM-G991B", phoneOsVersion: "35", bluetoothName: "OpenCfMoto")
}
