// SPDX-License-Identifier: AGPL-3.0-or-later
// `-e2eFakeDash` launch mode (CI simulator job, tools/ci/e2e/run-fakedash.sh): the REAL link stack
// against tools/fakedash/fakedash.py listening on 127.0.0.1 (the Simulator shares the Mac's network
// stack). Real: POSIXNetworkProvider (the bike-link transport; loopback destinations connect
// unbound), EasyConnLink, the RSA identity (SecKey, pure-Swift fallback), DashProjectionEngine +
// VideoToolbox + DashRenderer + TileImageCache, the internet client for tiles. Simulated: the bike
// Wi-Fi (a port that is "already joined" with the fake dash as gateway, local-only like the dash's
// access point in the field), GPS (DemoRoutePlayer), speech, handlebar, mirror. The garage holds one bike whose pairing QR matches the fakedash model
// (`-e2eDash`), the onboarding is done and auto-connect starts the session right after launch.
//
// `-e2eMusic` adds a fake Apple Music (DemoSeed.music: three songs with drawn covers, playing) and a
// script that drives the dash's Music sheet from the first own-UI frame on: +9 s open, +15 s next
// song, +21 s pause, +27 s close (`E2E music: …` log lines; `music` block in e2e-status.json; one
// `E2E frame mark` per state, decoded by the CI job as frames/music_*.png).
//
// Evidence for the CI job, in the app's Documents folder (`xcrun simctl get_app_container booted
// <bundle id> data`): `e2e-log.txt` (every Log line, appended every 2 s), `e2e-status.json`
// (connection / link / projection counters every 2 s) and `e2e-app.h264` (the first served access
// units, as sent to the dash).

import Foundation
import OpenCfMotoCore
import OpenCfMotoApple
import OpenCfMotoAppModel

/// The seeded test bike for each fakedash model (tools/fakedash/fakedash.py DASH_MODELS).
enum E2EFakeDashBike {
    struct Seed {
        let raw: String
        let ssid: String
    }

    static func seed(for dash: String) -> Seed {
        switch dash {
        case "cfdl26":
            // 1000 MT-X: modelid 37426 + Wi-Fi Direct (action 9, DIRECT- SSID) → CFDL26 portrait.
            let ssid = "DIRECT-CF-CFMOTO-E2E26"
            return Seed(raw: "http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37426&sn=E2E26&action=9&ssid=\(ssid)&pwd=e2e-fake-dash&auth=wpa2-psk&name=Fake%20dash%20CFDL26",
                        ssid: ssid)
        case "mt800":
            // 800MT: modelid 37426 over the dash SoftAP (action 1) → CFDL26 landscape.
            let ssid = "CFMOTO-E2E800"
            return Seed(raw: "http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37426&sn=E2E800&action=1&ssid=\(ssid)&pwd=e2e-fake-dash&auth=wpa2-psk&name=Fake%20dash%20800MT",
                        ssid: ssid)
        default:
            // 675 SR-R: modelid 37416 → CFDL16 / legacy.
            let ssid = "CFMOTO-E2E16"
            return Seed(raw: "http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37416&sn=E2E16&action=1&ssid=\(ssid)&pwd=e2e-fake-dash&auth=wpa2-psk&name=Fake%20dash%20CFDL16",
                        ssid: ssid)
        }
    }
}

/// A Wi-Fi port that is already on the "bike" network: the fake dash address is the gateway, the
/// phone is presented as 127.0.0.2 (`ConnectionTestingOverrides.loopback`). Local-only, as the dash's
/// access point is in the field (no internet: iOS reports the Wi-Fi path unsatisfied, field log 1).
final class E2ELoopbackWifi: WifiJoining, @unchecked Sendable {
    let supportsAutomaticJoin = true
    private let network: WifiNetworkInfo
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<WifiNetworkInfo>.Continuation] = [:]

    init(ssid: String, dashHost: String, phoneIPv4: String) {
        network = WifiNetworkInfo(isWifiAvailable: true, ssid: ssid, interfaceName: "lo0", phoneIPv4: phoneIPv4,
                                  gateway: dashHost, dashHostCandidates: [dashHost],
                                  isLocalOnly: true, pathUnsatisfiedReason: "notAvailable")
    }

    func join(ssid: String, passphrase: String?) async throws -> WifiJoinResult {
        Log.i("E2E", "fake Wi-Fi: '\(ssid)' already joined (loopback)")
        return .alreadyJoined
    }

    func forget(ssid: String) {
        Log.d("E2E", "fake Wi-Fi: forget '\(ssid)'")
    }

    func currentNetwork() async -> WifiNetworkInfo { network }

    func networkUpdates() -> AsyncStream<WifiNetworkInfo> {
        let current = network
        return AsyncStream(bufferingPolicy: .bufferingNewest(4)) { continuation in
            let id = UUID()
            lock.lock(); continuations[id] = continuation; lock.unlock()
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.continuations[id] = nil; self.lock.unlock()
            }
        }
    }
}

/// Builds the e2e services, seeds the stores and writes the evidence files.
@MainActor
final class E2EFakeDashHarness {
    let options: AppLaunchOptions
    let services: AppServices
    let location: PreviewLocation
    let seed: E2EFakeDashBike.Seed
    private let projection: ProjectionAdapter
    private let clock: MonotonicClock
    private let startedAt: TimeInterval
    private let logFile: E2ELogFile?
    private var player: DemoRoutePlayer?
    private var statusTask: Task<Void, Never>?
    private var musicScript: Task<Void, Never>?
    private var everStreaming = false
    private var maxFramesSent = 0

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    init(options: AppLaunchOptions, flavor: BuildFlavor, clock: MonotonicClock, http: SmartHTTPClient,
         projection: ProjectionAdapter) {
        self.options = options
        self.projection = projection
        self.clock = clock
        startedAt = clock.now()
        let docs = Self.documentsDirectory
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        for name in ["e2e-log.txt", "e2e-status.json", "e2e-app.h264"] {
            try? FileManager.default.removeItem(at: docs.appendingPathComponent(name))
        }
        logFile = E2ELogFile(url: docs.appendingPathComponent("e2e-log.txt"))
        seed = E2EFakeDashBike.seed(for: options.e2eDash)

        // Stores: in memory, seeded every launch (no Keychain / App Group needed by an unsigned build).
        let store = InMemoryKeyValueStore()
        let secrets = InMemorySecretStore()
        store.set(true, forKey: "onboarding_done") // PermissionsModel.onboardingDoneKey
        let garage = Garage(store: store, secrets: secrets)
        if let qr = BikeQR.parse(seed.raw) {
            let bike = garage.save(qr)
            garage.select(bike.id)
            Log.i("E2E", "seeded bike '\(bike.name)' (\(qr.parsedLogLine))")
        } else {
            Log.e("E2E", "test pairing QR does not parse: the session cannot start")
        }
        SettingsStore(store: store).update(forBike: nil) { s in
            s.autoConnect = true
            s.autoRecovery = true
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCfMotoE2E", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let files = AppFileLocations(tripsDirectory: root.appendingPathComponent("trips", isDirectory: true),
                                     photosDirectory: root.appendingPathComponent("photos", isDirectory: true),
                                     exportsDirectory: root.appendingPathComponent("exports", isDirectory: true))
        for dir in [files.tripsDirectory, files.photosDirectory, files.exportsDirectory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let location = PreviewLocation()
        self.location = location
        services = AppServices(
            keyValueStore: store,
            secretStore: secrets,
            http: http,
            // No real bike Wi-Fi: keep the internet (tiles) on the Mac's default route.
            setPreferCellular: { on in Log.d("E2E", "setPreferCellular(\(on)) ignored (loopback)") },
            network: POSIXNetworkProvider(),
            discovery: nil,
            makeSigner: {
                do {
                    return try await SecKeyHuidSigner.generate()
                } catch {
                    Log.w("E2E", "SecKey RSA unavailable (\(error)) \u{2014} using the pure-Swift signer")
                    return PureSwiftHuidSigner.generate()
                }
            },
            wifi: E2ELoopbackWifi(ssid: seed.ssid, dashHost: options.e2eHost,
                                  phoneIPv4: ConnectionTestingOverrides.loopbackPhoneIPv4),
            location: location,
            speech: PreviewSpeech(),
            handlebar: PreviewHandlebar(),
            projection: projection,
            mirror: PreviewMirror(),
            system: IOSSystem(flavor: flavor, store: store),
            files: files,
            clock: clock,
            music: options.e2eMusic ? DemoSeed.music(clock: clock, store: store) : nil)
        if options.e2eMusic { Log.i("E2E", "fake Apple Music: \(DemoSeed.songs.count) songs, playing") }
    }

    /// Wires the model (call right after creating it, before `AppModel.start()`).
    func attach(to model: AppModel) {
        model.connection.applyTestingOverrides(.loopback())
        let player = DemoRoutePlayer(location: location, now: services.now)
        player.start()
        self.player = player
        do {
            try projection.engine.startWireDump(to: Self.documentsDirectory.appendingPathComponent("e2e-app.h264"),
                                                maxFrames: 400)
        } catch {
            Log.w("E2E", "wire dump unavailable: \(error)")
        }
        Log.i("E2E", "fake dash mode: \(options.e2eDash) at \(options.e2eHost):10930, phone \(ConnectionTestingOverrides.loopbackPhoneIPv4) (lo0)")
        if options.e2eMusic { startMusicScript(model) }
        statusTask = Task { @MainActor [weak self, weak model] in
            var fallbackChecked = false
            while !Task.isCancelled {
                guard let self, let model else { return }
                let elapsed = self.clock.now() - self.startedAt
                if !fallbackChecked, elapsed >= 8 {
                    fallbackChecked = true
                    if model.connection.phase == .idle {
                        Log.w("E2E", "auto-connect did not start a session within 8 s \u{2014} connecting explicitly")
                        model.connection.connect()
                    }
                }
                self.writeStatus(model, elapsed: elapsed)
                self.logFile?.flush()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// `-e2eMusic`: the rider's taps on the dash's Music sheet, timed from the first own-UI frame,
    /// and the dash pictures that show each state (`frames/music_<n>_<state>.png` in the CI
    /// artifacts): the map with the playing tile just before the sheet opens, then 2 s after each
    /// step (the dash pulls 2–10 frames/s: the sheet re-renders once per second, the moving map at
    /// every pull, so the pictures are picked by time, not by a frame count).
    private func startMusicScript(_ model: AppModel) {
        enum Event: Sendable {
            case step(String, DashIntent)
            case mark(String)
        }
        let timeline: [(at: TimeInterval, event: Event)] = [
            (8.8, .mark("music_1_map_playing")), (9, .step("open", .openMusic)), (11, .mark("music_2_sheet")),
            (15, .step("next", .musicNext)), (17, .mark("music_3_sheet_next")),
            (21, .step("pause", .musicPlayPause)), (23, .mark("music_4_sheet_paused")),
            (27, .step("close", .closeSheets)), (29, .mark("music_5_map_paused")),
        ]
        musicScript = Task { @MainActor [weak self, weak model] in
            while !Task.isCancelled {
                guard let model else { return }
                if model.ride.isProjecting { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            Log.i("E2E", "music: script starts (the dash UI is live)")
            var elapsed: TimeInterval = 0
            for (at, event) in timeline {
                try? await Task.sleep(nanoseconds: UInt64((at - elapsed) * 1_000_000_000))
                elapsed = at
                guard !Task.isCancelled, let model else { return }
                switch event {
                case let .step(name, intent):
                    Log.i("E2E", "music: \(name)")
                    model.ride.performDashIntent(intent)
                case let .mark(name):
                    self?.markFrame(name)
                }
            }
        }
    }

    /// Asks the CI job for one decoded dash picture (tools/ci/e2e/run-fakedash.sh reads the
    /// `frame mark` log lines): the last frame served to the fake dash so far — its index in the
    /// stream the dash received (0-based; every served pull is one frame, one session) — saved as
    /// `frames/<name>.png`.
    private func markFrame(_ name: String) {
        let served = projection.engine.stats.pullsServed
        Log.i("E2E", "frame mark \(name) = \(max(0, served - 1))")
    }

    private func writeStatus(_ model: AppModel, elapsed: TimeInterval) {
        let c = model.connection
        let d = c.diagnostics
        if c.phase == .streaming { everStreaming = true }
        maxFramesSent = max(maxFramesSent, d.stats.framesSent)
        let e = projection.engine.stats
        let p = d.projection
        var status: [String: Any] = [
            "elapsed_s": (elapsed * 10).rounded() / 10,
            "wall": ISO8601DateFormatter().string(from: Date()),
            "dash_model": options.e2eDash,
            "phase": c.phase.rawValue,
            "detail": c.detail,
            "mode": c.mode.rawValue,
            "issue": c.issue.map { String(describing: $0) } ?? NSNull(),
            "link_state": d.state.description,
            "ever_streaming": everStreaming,
            "frames_sent": d.stats.framesSent,
            "max_frames_sent": maxFramesSent,
            "keyframes_sent": d.stats.keyframesSent,
            "bytes_sent": d.stats.bytesSent,
            "missed_pulls": d.stats.missedPulls,
            "pull_rate": (d.stats.pullRate * 10).rounded() / 10,
            "profile": d.profileName ?? NSNull(),
            "canvas": d.canvas.map { "\($0.width)x\($0.height)" } ?? NSNull(),
            "dash": d.dashInfo.map { "\($0.huName) sdk=\($0.sdkVersion)" } ?? NSNull(),
            "is_projecting": model.ride.isProjecting,
            "gps_fixes": player?.emittedFixes ?? 0,
        ]
        status["projection"] = [
            "mode": p.mode,
            "rendered_frames": p.renderedFrames,
            "encoded_frames": p.encodedFrames,
            "fps": (p.framesPerSecond * 10).rounded() / 10,
            "bitrate": p.bitrate,
            "last_error": p.lastError ?? NSNull(),
        ] as [String: Any]
        status["engine"] = [
            "mode": e.mode.rawValue,
            "canvas": e.canvas.map { "\($0.width)x\($0.height)" } ?? NSNull(),
            "rendered_frames": e.renderedFrames,
            "encode_submissions": e.encodeSubmissions,
            "output_frames": e.outputFrames,
            "output_keyframes": e.outputKeyframes,
            "repeated_frames": e.repeatedFrames,
            "pulls_served": e.pullsServed,
            "pulls_unanswered": e.pullsUnanswered,
            "fallback_keyframes_served": e.fallbackKeyframesServed,
            "encoder_errors": e.encoderErrors,
            "using_hardware_encoder": e.usingHardwareEncoder.map { $0 as Any } ?? NSNull(),
            "avg_render_ms": (e.averageRenderMs * 10).rounded() / 10,
            "avg_encode_ms": (e.averageEncodeMs * 10).rounded() / 10,
            "pool_exhausted": e.poolExhausted,
            "queue_overflows": e.queueOverflows,
            "gated_drops": e.gatedDrops,
            "hold_frames_served": e.holdFramesServed,
            "pull_rate": (e.pullRate * 10).rounded() / 10,
            "output_fps": (e.outputFPS * 10).rounded() / 10,
        ] as [String: Any]
        let music = model.music
        status["music"] = [
            "enabled": music.isEnabled,
            "authorization": music.authorization.rawValue,
            "state": music.snapshot.state.rawValue,
            "track_id": music.snapshot.track?.id ?? NSNull(),
            "artwork_source": music.lastArtworkSource ?? NSNull(),
            "on_dash": music.isShownOnDash,
            "sheet": model.ride.dashUIState.sheet.rawValue,
        ] as [String: Any]
        guard let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: Self.documentsDirectory.appendingPathComponent("e2e-status.json"), options: .atomic)
    }
}

/// Appends every `Log.shared` line to a file (flushed by the harness every 2 s), including the lines
/// logged before it subscribed.
final class E2ELogFile: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var pending: [LogLine] = []
    private var lastWrittenID: UInt64 = 0
    private var subscription: UUID?

    init?(url: URL) {
        self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return nil }
        subscription = Log.shared.subscribe { [weak self] line in
            guard let self else { return }
            self.lock.lock(); self.pending.append(line); self.lock.unlock()
        }
        let earlier = Log.shared.lines()
        lock.lock(); pending.insert(contentsOf: earlier, at: 0); lock.unlock()
        flush()
    }

    deinit {
        if let subscription { Log.shared.unsubscribe(subscription) }
    }

    func flush() {
        lock.lock()
        let lines = pending
        pending.removeAll()
        var text = ""
        for line in lines.sorted(by: { $0.id < $1.id }) where line.id > lastWrittenID {
            text += line.formatted() + "\n"
            lastWrittenID = line.id
        }
        lock.unlock()
        guard !text.isEmpty, let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }
}
