// SPDX-License-Identifier: AGPL-3.0-or-later
// Test harness for the session models: an AppModel over the in-memory preview services with typed
// handles to every fake, short timers, a fixed RSA identity and helpers (bikes, waiting, frames).
// NOTE (Linux): swift-corelibs-xctest cannot call synchronous @MainActor test methods; every
// main-actor test must be `async`.

import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

@MainActor
final class AppTestHarness {
    let model: AppModel
    let system: PreviewSystem
    let wifi: PreviewWifi
    let location: PreviewLocation
    let speech: PreviewSpeech
    let handlebar: PreviewHandlebar
    let projection: PreviewProjection
    let mirror: MirrorHosting
    /// Every `setPreferCellular` call, in order.
    let cellular: Locked<[Bool]>

    var core: AppCore { model.core }
    var connection: ConnectionModel { model.connection }
    var ride: RideModel { model.ride }
    var controls: ControlsModel { model.controls }

    /// - Parameters:
    ///   - network: sockets for the link (default: `PreviewNetwork`, nothing ever answers).
    ///   - frameSource: the own-UI frame source behind `PreviewProjection`.
    ///   - mirror: the mirror host (default `PreviewMirror`).
    init(flavor: BuildFlavor = .full, network: NetworkProvider? = nil, frameSource: VideoFrameSource? = nil,
         mirror: MirrorHosting? = nil, configure: (inout AppServices) -> Void = { _ in }) {
        var services = AppServices.preview(flavor: flavor)
        let system = PreviewSystem()
        system.flavor = flavor
        let wifi = PreviewWifi(supportsAutomaticJoin: flavor == .full)
        let location = PreviewLocation()
        let speech = PreviewSpeech()
        let handlebar = PreviewHandlebar()
        let projection = frameSource.map { PreviewProjection(frameSource: $0) } ?? PreviewProjection()
        let mirrorHost = mirror ?? PreviewMirror()
        let cellular = Locked<[Bool]>([])
        services.system = system
        services.wifi = wifi
        services.location = location
        services.speech = speech
        services.handlebar = handlebar
        services.projection = projection
        services.mirror = mirrorHost
        services.makeSigner = { AppTestKeys.fixtureSigner }
        services.setPreferCellular = { on in cellular.withLock { $0.append(on) } }
        if let network { services.network = network }
        configure(&services)
        self.system = system
        self.wifi = wifi
        self.location = location
        self.speech = speech
        self.handlebar = handlebar
        self.projection = projection
        self.mirror = mirrorHost
        self.cellular = cellular
        model = AppModel(services: services)
        model.connection.tuning.autoConnectDelay = 0.05
        model.connection.tuning.wifiParkGrace = 0.3
        model.connection.tuning.linkTimings = Self.fastTimings
        model.connection.tuning.connectBackTimeout = 2
        model.connection.tuning.framePullTimeout = 0.3
        model.connection.tuning.interfaceProvider = { [] }
        model.ride.tuning.uiTickInterval = 0.02
        model.bannerDuration = 0.2
    }

    /// Link timers shortened so a session runs in well under a second (LinkEndToEndTests values).
    static var fastTimings: LinkTimings {
        var t = LinkTimings()
        t.probeConnectTimeout = 0.3
        t.probeReadTimeout = 0.5
        t.probeRetryUnit = 0.01
        t.bonjourBrowseTimeout = 0.2
        t.portScanConnectTimeout = 0.02
        t.heartbeatInterval = 0.2
        t.reconnectBackoffBase = 0.02
        t.reconnectBackoffStep = 0.02
        t.reconnectBackoffCap = 0.1
        t.reconnectSettle = 0.4
        t.watchdogTick = 0.1
        t.errorRearmInterval = 0.4
        t.statsWindow = 1
        return t
    }

    nonisolated static let sampleRaw = "http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37416&sn=peTz&action=9&ssid=CFMOTO-f46457&pwd=59a9cddc94&auth=wpa2-psk&name=CFMOTO-f46457"

    /// Saves + selects a bike straight in the garage (GarageModel.pair belongs to logic-data).
    @discardableResult
    func addBike(raw: String = AppTestHarness.sampleRaw) -> (bike: GarageBike, qr: BikeQR) {
        guard let qr = BikeQR.parse(raw) else { fatalError("test QR does not parse: \(raw)") }
        let bike = core.garage.save(qr)
        core.garage.select(bike.id)
        model.garage.reload()
        return (bike, qr)
    }

    /// The Wi-Fi the PreviewWifi fake reports after a join (192.168.0.2 → gateway 192.168.0.1).
    nonisolated static func bikeNetwork(ssid: String?) -> WifiNetworkInfo {
        WifiNetworkInfo(isWifiAvailable: true, ssid: ssid, interfaceName: "en0", phoneIPv4: "192.168.0.2",
                        gateway: "192.168.0.1", dashHostCandidates: ["192.168.0.1"])
    }

    var language: NavLanguage { core.language }
}

/// Polls `condition` on the main actor every 5 ms until true or `timeout` seconds elapsed.
@MainActor
func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

/// Lets queued main-actor work (coalesced model updates, stream deliveries) run.
@MainActor
func settle(_ seconds: TimeInterval = 0.05) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

// MARK: - Link test helpers (LinkTestDoubles.swift of the core tests)

/// Polls `condition` every 5 ms until true or `timeout` seconds elapsed (any context).
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

/// The control-plane.md §9.5 fixed test key (PKCS#1 RSAPrivateKey DER, base64): no key generation in tests.
enum AppTestKeys {
    static let pkcs1PrivateKeyBase64 = "MIICWwIBAAKBgQCJK2qMkijMfOspHCr9UMR+djdNu6vnubHpqfJMacvtgSnbOmaMpse9gLsKp3Hd1GTK5k9W8Jk3PPU6JW3drsgdK43RdlotOlGT5PMiw7jmo0OydzXjuFrjfhLscuz6MbNPXO12IkrgoVWPsfOp3xskqWrlfQuCGNljUt/UzHJWFwIDAQABAoGAHOSYxnBZCK29aQTmZ0JWiV7ESmrgDGj4eUQTZhYY3vfIhcWY6UKOKzQM8fMQUI4XBwgZKTJ3y4NbEjrlF/9jZjaP+DySrn+U5HnVkIr4Hye3I2tOqeJaWL4LGFr0fV4qaiJVl4XxL2JMI2RlMt+S9Cw3bPkim4hIJKySXLLbjQkCQQDCzsFwYRj0ddspxVD1hVUQRaB10YTCBYoCMMKyxmWHLQqNukzWTc8EYctsz4T1u4MQnDTc3t6iWdS1of3QKKoPAkEAtEHCivoWq2bVXCViThK+BP/sHEMDyXqTgyMuv1jNkUxpwUmCoptcMNrZMBdfBowrxSe4LBersIMU1ixM/++7eQJARsTVgP3FEwm9lG8Z+hd1z3N711FF6TYZ7LHKCSgJuhGiw9nqD/A0RGNCg0TgCGUWN/KHQbW1K0V3AITYr8YWAQJAS3E+X/Y9qK0YXUGUPELh3qvSAR4XJqszs+30sccT+lz14hzHHRFS62uc/OC7N71Q0GpITcP2aqDiBqVx8KhAWQJAP3c2sgSFzB3rmQCvLG06zxM5wNmeNUiW5Vo6ZBHL8XnoFyJlMIft/pie0smdqoAZ/yCMxa4GVMUGEmc9T5THxA=="

    static let fixtureSigner: PureSwiftHuidSigner = {
        guard let der = Data(base64Encoded: pkcs1PrivateKeyBase64),
              let signer = try? PureSwiftHuidSigner(pkcs1PrivateKeyDER: der) else { fatalError("fixture key") }
        return signer
    }()
}

/// Scripted `VideoFrameSource`: after every `resynchronize()` the next frame is a keyframe
/// (SPS + PPS + IDR toy AU), then P-frames. Records every call in order.
final class TestFrameSource: VideoFrameSource, @unchecked Sendable {
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

    static let sps: [UInt8] = [0x67, 0x42, 0x00, 0x1F, 0xDA, 0x01, 0x40, 0x12, 0x69, 0xA8]
    static let pps: [UInt8] = [0x68, 0xCE, 0x0D, 0x88]

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }

    var preparedParameters: EncoderParameters? {
        calls.compactMap { if case let .prepare(_, p) = $0 { return p } else { return nil } }.last
    }

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
        produce()
    }

    private func produce() -> EncodedFrame {
        lock.lock()
        _calls.append(.nextFrame)
        sequence += 1
        let key = needKeyframe
        needKeyframe = false
        let seq = sequence
        lock.unlock()
        return TestFrameSource.frame(seq: seq, key: key)
    }

    func mediaStopped() {
        lock.lock(); _calls.append(.mediaStopped); lock.unlock()
    }
}

/// A mirror host whose relay "receives" frames from a scripted source (no sockets).
final class TestMirrorHost: MirrorHosting, @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var connected = false
    private var onChange: (@Sendable (Bool) -> Void)?
    private(set) var fits: [(ScreenFit, ScreenMargins)] = []
    let source = TestFrameSource()

    var frameSource: VideoFrameSource { source }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    var isExtensionConnected: Bool { lock.lock(); defer { lock.unlock() }; return connected }
    var onExtensionConnectionChange: (@Sendable (Bool) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return onChange }
        set { lock.lock(); onChange = newValue; lock.unlock() }
    }

    func start() throws { lock.lock(); running = true; lock.unlock() }
    func stop() { lock.lock(); running = false; connected = false; lock.unlock() }
    func setFit(_ fit: ScreenFit, margins: ScreenMargins) { lock.lock(); fits.append((fit, margins)); lock.unlock() }

    func setExtensionConnected(_ c: Bool) {
        lock.lock(); connected = c; let cb = onChange; lock.unlock()
        cb?(c)
    }
}

/// A mirror host whose relay cannot start (no App Group).
final class FailingMirrorHost: MirrorHosting, @unchecked Sendable {
    struct Unavailable: Error {}
    let frameSource: VideoFrameSource = PreviewFrameSource()
    var isRunning: Bool { false }
    var isExtensionConnected: Bool { false }
    var onExtensionConnectionChange: (@Sendable (Bool) -> Void)?
    func start() throws { throw Unavailable() }
    func stop() {}
    func setFit(_ fit: ScreenFit, margins: ScreenMargins) {}
}
