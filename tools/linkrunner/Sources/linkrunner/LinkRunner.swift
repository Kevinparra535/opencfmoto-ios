// SPDX-License-Identifier: AGPL-3.0-or-later
// linkrunner: drives the real OpenCfMotoCore `EasyConnLink` over `POSIXNetworkProvider` (the app's
// transport) against a PXC dash (tools/fakedash/fakedash.py, or a real dash from a computer on its
// Wi-Fi), with a synthetic H.264 source, and prints every LinkEvent (and the engine log) with
// timestamps, then a run summary.

import Foundation
import OpenCfMotoCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@main
struct LinkRunnerMain {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        setvbuf(stdout, nil, _IOLBF, 0)
        let args: RunnerArguments
        do {
            args = try RunnerArguments.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("linkrunner: \(error)\n".utf8))
            exit(64)
        }
        let code = await LinkRunner(args).run()
        exit(code)
    }
}

// MARK: - Output

/// Thread-safe, timestamped console output plus an optional JSON-lines event file.
final class RunnerOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let startNanos = DispatchTime.now().uptimeNanoseconds
    private let wallFormatter: DateFormatter
    private var jsonl: FileHandle?

    init(jsonlPath: String?) {
        wallFormatter = DateFormatter()
        wallFormatter.locale = Locale(identifier: "en_US_POSIX")
        wallFormatter.dateFormat = "HH:mm:ss.SSS"
        if let jsonlPath {
            _ = FileManager.default.createFile(atPath: jsonlPath, contents: nil)
            jsonl = FileHandle(forWritingAtPath: jsonlPath)
        }
    }

    /// Seconds since the runner started (monotonic).
    var elapsed: Double { Double(DispatchTime.now().uptimeNanoseconds - startNanos) / 1e9 }

    func line(_ kind: String, _ text: String) {
        lock.lock()
        defer { lock.unlock() }
        let stamp = String(format: "[+%8.3fs %@]", elapsed, wallFormatter.string(from: Date()))
        print("\(stamp) \(kind) \(text)")
    }

    func json(_ object: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        guard let jsonl else { return }
        var o = object
        o["t"] = (elapsed * 1000).rounded() / 1000
        o["wall_ms"] = Int64(Date().timeIntervalSince1970 * 1000)
        guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return }
        jsonl.write(data)
        jsonl.write(Data("\n".utf8))
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? jsonl?.close()
        jsonl = nil
    }
}

// MARK: - Run tracking

/// What the summary needs from the event stream.
final class RunTracker: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var states: [(t: Double, state: LinkState)] = []
    private(set) var dashInfos: [DashInfo] = []
    private(set) var canvases: [VideoCanvas] = []
    private(set) var mediaStarts: [Double] = []
    private(set) var touches: [DashTouch] = []
    private(set) var lastStats: LinkStats?
    private(set) var firstStreamingAt: Double?
    private(set) var firstFailure: LinkFailure?

    func record(_ event: LinkEvent, at t: Double) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case let .state(s):
            states.append((t, s))
            if s == .streaming, firstStreamingAt == nil { firstStreamingAt = t }
            if case let .failed(f) = s, firstFailure == nil { firstFailure = f }
        case let .dashIdentified(info): dashInfos.append(info)
        case let .canvas(c): canvases.append(c)
        case .mediaStarted: mediaStarts.append(t)
        case let .touch(touch): touches.append(touch)
        case let .stats(s): lastStats = s
        }
    }

    func snapshot<R>(_ body: (RunTracker) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(self)
    }
}

/// A `DashDiscovery` that "finds" one fixed endpoint after a delay (exercises the Bonjour race).
struct StaticDashDiscovery: DashDiscovery {
    let endpoint: DiscoveredDash
    let delay: TimeInterval
    func discover(timeout: TimeInterval) async -> [DiscoveredDash] {
        let wait = min(delay, timeout)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        return delay <= timeout ? [endpoint] : []
    }
}

// MARK: - Runner

final class LinkRunner: @unchecked Sendable {
    /// control-plane.md §9.5 fixed test key (PKCS#1 RSAPrivateKey DER, base64).
    static let fixtureKeyBase64 = "MIICWwIBAAKBgQCJK2qMkijMfOspHCr9UMR+djdNu6vnubHpqfJMacvtgSnbOmaMpse9gLsKp3Hd1GTK5k9W8Jk3PPU6JW3drsgdK43RdlotOlGT5PMiw7jmo0OydzXjuFrjfhLscuz6MbNPXO12IkrgoVWPsfOp3xskqWrlfQuCGNljUt/UzHJWFwIDAQABAoGAHOSYxnBZCK29aQTmZ0JWiV7ESmrgDGj4eUQTZhYY3vfIhcWY6UKOKzQM8fMQUI4XBwgZKTJ3y4NbEjrlF/9jZjaP+DySrn+U5HnVkIr4Hye3I2tOqeJaWL4LGFr0fV4qaiJVl4XxL2JMI2RlMt+S9Cw3bPkim4hIJKySXLLbjQkCQQDCzsFwYRj0ddspxVD1hVUQRaB10YTCBYoCMMKyxmWHLQqNukzWTc8EYctsz4T1u4MQnDTc3t6iWdS1of3QKKoPAkEAtEHCivoWq2bVXCViThK+BP/sHEMDyXqTgyMuv1jNkUxpwUmCoptcMNrZMBdfBowrxSe4LBersIMU1ixM/++7eQJARsTVgP3FEwm9lG8Z+hd1z3N711FF6TYZ7LHKCSgJuhGiw9nqD/A0RGNCg0TgCGUWN/KHQbW1K0V3AITYr8YWAQJAS3E+X/Y9qK0YXUGUPELh3qvSAR4XJqszs+30sccT+lz14hzHHRFS62uc/OC7N71Q0GpITcP2aqDiBqVx8KhAWQJAP3c2sgSFzB3rmQCvLG06zxM5wNmeNUiW5Vo6ZBHL8XnoFyJlMIft/pie0smdqoAZ/yCMxa4GVMUGEmc9T5THxA=="

    let args: RunnerArguments
    let out: RunnerOutput
    let tracker = RunTracker()
    private let stopRequested = Locked<String?>(nil)

    init(_ args: RunnerArguments) {
        self.args = args
        out = RunnerOutput(jsonlPath: args.eventsJSONL)
    }

    /// Short timers for local runs. Heartbeat (2 s) and the stall threshold are protocol behaviour
    /// the dash checks, so they keep their Android values.
    static var fastTimings: LinkTimings {
        var t = LinkTimings.standard
        t.probeConnectTimeout = 1
        t.probeReadTimeout = 2
        t.probeRetryUnit = 0.2
        t.bonjourBrowseTimeout = 2
        t.portScanConnectTimeout = 0.1
        t.reconnectBackoffBase = 0.1
        t.reconnectBackoffStep = 0.1
        t.reconnectBackoffCap = 1
        t.reconnectSettle = 1
        t.watchdogTick = 1
        t.errorRearmInterval = 5
        return t
    }

    /// tools/fakedash/clips relative to this source file (…/tools/linkrunner/Sources/linkrunner/).
    static var defaultClipDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fakedash/clips")
    }

    func runnerLine(_ text: String) { out.line("RUN  ", text) }

    func run() async -> Int32 {
        // 1. Engine log → console.
        Log.shared.echoToConsole = false
        if !args.eventsOnly {
            let o = out
            _ = Log.shared.subscribe { line in
                o.line("\(line.level.letter)/\(line.tag.padding(toLength: 4, withPad: " ", startingAt: 0))", line.message)
            }
        }

        // 2. Configuration.
        var qr: BikeQR?
        if let text = args.qrText {
            guard let parsed = BikeQR.parse(text) else {
                FileHandle.standardError.write(Data("linkrunner: --qr does not parse (\(BikeQR.failureHint(for: text) ?? "no format matched"))\n".utf8))
                return 64
            }
            qr = parsed
        }
        runnerLine(qr.map { $0.parsedLogLine } ?? "no QR")
        let signer: PureSwiftHuidSigner
        switch args.key {
        case .fixture:
            guard let der = Data(base64Encoded: LinkRunner.fixtureKeyBase64),
                  let s = try? PureSwiftHuidSigner(pkcs1PrivateKeyDER: der) else {
                runnerLine("!! fixture key does not load")
                return 70
            }
            signer = s
            runnerLine("RSA identity: control-plane.md §9.5 fixture key")
        case .generate:
            let t0 = out.elapsed
            signer = PureSwiftHuidSigner.generate()
            runnerLine(String(format: "RSA identity: fresh RSA-1024 (PureSwiftHuidSigner.generate, %.2f s)", out.elapsed - t0))
        }
        runnerLine("pubkey \(signer.publicKeyBase64.prefix(40))… (\(signer.publicKeyBase64.count) chars)")

        let phone = PhoneIdentity(phoneUUID: args.phoneUUID ?? UUID().uuidString.lowercased())
        let config = LinkConfiguration(qr: qr, profileOverride: args.profile, learnedCanvas: args.learnedCanvas,
                                       forceTouchscreen: args.forceTouch, phone: phone, localHost: args.localHost,
                                       dashHost: args.dashHost, connectBackTimeout: args.connectBackTimeout,
                                       stallTimeout: args.stallTimeout, stallReconnectCooldown: args.stallCooldown,
                                       maxReconnectAttempts: args.maxReconnects, framePullTimeout: args.framePullTimeout)
        var options = LinkOptions()
        options.timings = args.fast ? LinkRunner.fastTimings : .standard
        options.forceNonTouch = args.forceNonTouch
        options.timeSyncForcePhone = args.timeSyncForcePhone
        options.wifiInterfaceName = args.wifiInterface
        switch args.interfaces {
        case .real:
            break
        case .loopback:
            options.interfaceProvider = {
                [InterfaceAddress(name: "lo", ipv4: "127.0.0.1", netmask: "255.0.0.0", isUp: true, isLoopback: true)]
            }
        case .loopbackAsWifi:
            options.interfaceProvider = {
                [InterfaceAddress(name: "lo", ipv4: "127.0.0.1", netmask: "255.0.0.0", isUp: true, isLoopback: false)]
            }
        case .none:
            options.interfaceProvider = { [] }
        }
        preflightAddressing(config: config, options: options)

        // 3. Collaborators.
        let source = SyntheticFrameSource(
            explicitClip: args.clip.map { URL(fileURLWithPath: $0) },
            clipDirectory: URL(fileURLWithPath: args.clipDirectory ?? LinkRunner.defaultClipDirectory.path),
            cacheDirectory: URL(fileURLWithPath: args.clipCache
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("linkrunner-clips").path),
            sourceFPS: args.sourceFPS,
            log: { [out, args] text in if !args.eventsOnly { out.line("SRC  ", text) } })
        let o = out
        var trace: POSIXNetworkProvider.Trace?
        if args.netTrace { trace = { text in o.line("NET  ", text) } }
        let network = POSIXNetworkProvider(options: .init(bindHost: args.bindHost), trace: trace)
        let discovery: DashDiscovery? = args.bonjour.map { StaticDashDiscovery(endpoint: $0, delay: args.bonjourDelay) }
        let link = EasyConnLink(configuration: config, network: network, frameSource: source, signer: signer,
                                discovery: discovery, gateway: args.gateway, options: options)
        runnerLine("early profile: \(link.currentProfile.name) [\(link.currentProfile.id.rawValue)]  timings=\(args.fast ? "fast" : "standard (Android)")  framePullTimeout=\(args.framePullTimeout)s  run \(args.seconds)s")

        // 4. Events.
        let tracker = self.tracker
        let eventsTask = Task { [out] in
            var mediaStarts = 0
            for await event in link.events {
                let t = out.elapsed
                tracker.record(event, at: t)
                if case .mediaStarted = event { mediaStarts += 1 }
                let (text, json) = LinkRunner.describe(event, mediaStarts: mediaStarts)
                out.line("EVENT", text)
                out.json(json)
            }
        }

        // 5. Signals.
        let signalSources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler { [stopRequested] in stopRequested.set(sig == SIGINT ? "SIGINT" : "SIGTERM") }
            src.resume()
            return src
        }

        // 6. Run.
        link.start()
        var exitCode: Int32 = 0
        var reason = "time limit (\(args.seconds)s)"
        while out.elapsed < args.seconds {
            if let s = stopRequested.current {
                reason = s
                break
            }
            if args.exitOnFatal, case let .failed(f) = link.state, LinkRunner.isFatal(f) {
                reason = "fatal link state: \(f)"
                exitCode = 2
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        // 7. Summary, then stop.
        let finalState = link.state
        let stats = link.stats
        let summary = buildSummary(link: link, finalState: finalState, stats: stats, source: source, network: network,
                                   reason: reason, signer: signer, phone: phone)
        printSummary(summary)
        if let path = args.summaryJSON,
           let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
            _ = FileManager.default.createFile(atPath: path, contents: data)
        }
        link.stop()
        try? await Task.sleep(nanoseconds: 200_000_000) // let the last events/logs drain
        eventsTask.cancel()
        signalSources.forEach { $0.cancel() }
        out.close()
        if exitCode == 0 { exitCode = stats.framesSent > 0 ? 0 : 3 }
        return exitCode
    }

    static func isFatal(_ f: LinkFailure) -> Bool {
        switch f {
        case .portInUse, .noWifiAddress, .other: return true
        case .localNetworkDenied, .localNetworkBlocked, .dashNotFound, .lostLink: return false // the watchdog re-arms these
        }
    }

    /// Prints the addressing decision the engine is about to make (same functions, same inputs).
    private func preflightAddressing(config: LinkConfiguration, options: LinkOptions) {
        let addresses = options.interfaceProvider()
        let local: InterfaceAddress?
        if let configured = config.localHost {
            local = addresses.first { $0.ipv4 == configured }
                ?? InterfaceAddress(name: "configured", ipv4: configured, netmask: "255.255.255.0")
        } else {
            local = InterfaceAddresses.pickBikeIPv4(from: addresses, interfaceName: options.wifiInterfaceName,
                                                     subnetHint: config.dashHost ?? args.gateway)
        }
        let candidates = InterfaceAddresses.gatewayCandidates(dashHost: config.dashHost, injectedGateway: args.gateway,
                                                              local: local)
        runnerLine("interfaces (\(args.interfaces.rawValue)): \(addresses.map(\.description).joined(separator: ", "))")
        runnerLine("addressing preflight: local=\(local?.description ?? "nil") dash candidates=\(candidates)")
        for (label, host) in [("--dash", config.dashHost), ("--gateway", args.gateway)] {
            guard let host, !candidates.contains(host) else { continue }
            runnerLine("!! \(label) \(host) is NOT a probe candidate: InterfaceAddresses.gatewayCandidates drops any candidate equal to our own IPv4 (\(local?.ipv4 ?? "?")), even explicit ones")
        }
        if candidates.isEmpty {
            runnerLine("!! no probe candidate: EasyConnLink will fail with .noWifiAddress")
        }
    }

    // MARK: Event formatting

    static func describe(_ event: LinkEvent, mediaStarts: Int) -> (String, [String: Any]) {
        switch event {
        case let .state(s):
            return ("state → \(s)", ["event": "state", "state": "\(s)"])
        case let .dashIdentified(i):
            let text = "dashIdentified profile=\(i.profile.rawValue) huName=\(i.huName) huid=\(i.huid) sdk=\(i.sdkVersion) version=\(i.versionName) package=\(i.packageName) channel=\(i.channel) socketTimeout=\(i.socketTimeoutSeconds.map(String.init) ?? "-") touch=\(i.supportsScreenTouch)"
            return (text, ["event": "dashIdentified", "profile": i.profile.rawValue, "huName": i.huName, "huid": i.huid,
                           "sdkVersion": i.sdkVersion, "versionName": i.versionName, "packageName": i.packageName,
                           "channel": i.channel, "socketTimeoutSeconds": i.socketTimeoutSeconds as Any,
                           "supportsScreenTouch": i.supportsScreenTouch])
        case let .canvas(c):
            return ("canvas \(c) fps=\(c.requestedFps.map(String.init) ?? "-")",
                    ["event": "canvas", "width": c.width, "height": c.height, "requestedWidth": c.requestedWidth,
                     "requestedHeight": c.requestedHeight, "requestedFps": c.requestedFps as Any])
        case .mediaStarted:
            return ("mediaStarted #\(mediaStarts)", ["event": "mediaStarted", "n": mediaStarts])
        case let .touch(t):
            let action: String
            switch t.action {
            case .down: action = "down"
            case .up: action = "up"
            case .move: action = "move"
            }
            return ("touch \(action) pointer=\(t.pointerId) x=\(t.x) y=\(t.y)",
                    ["event": "touch", "action": action, "pointerId": t.pointerId, "x": t.x, "y": t.y])
        case let .stats(s):
            let text = String(format: "stats frames=%d key=%d bytes=%d missed=%d pulls/s=%.1f", s.framesSent, s.keyframesSent,
                              s.bytesSent, s.missedPulls, s.pullRate)
            return (text, ["event": "stats", "framesSent": s.framesSent, "keyframesSent": s.keyframesSent,
                           "bytesSent": s.bytesSent, "missedPulls": s.missedPulls, "pullRate": s.pullRate])
        }
    }

    // MARK: Summary

    private func buildSummary(link: EasyConnLink, finalState: LinkState, stats: LinkStats, source: SyntheticFrameSource,
                              network: POSIXNetworkProvider, reason: String, signer: PureSwiftHuidSigner,
                              phone: PhoneIdentity) -> [String: Any] {
        let src = source.stats
        let net = network.snapshot
        let profile = link.currentProfile
        return tracker.snapshot { t -> [String: Any] in
            var s: [String: Any] = [:]
            s["duration_s"] = (out.elapsed * 1000).rounded() / 1000
            s["stop_reason"] = reason
            s["final_state"] = "\(finalState)"
            s["states"] = t.states.map { ["t": ($0.t * 1000).rounded() / 1000, "state": "\($0.state)"] }
            s["reconnecting_entries"] = t.states.filter { if case .reconnecting = $0.state { return true } else { return false } }.count
            s["streaming_entries"] = t.states.filter { $0.state == .streaming }.count
            s["first_streaming_at_s"] = t.firstStreamingAt as Any
            s["first_failure"] = t.firstFailure.map { "\($0)" } as Any
            s["profile"] = ["id": profile.id.rawValue, "name": profile.name]
            s["dash_info"] = link.dashInfo.map { i -> [String: Any] in
                ["huid": i.huid, "huName": i.huName, "sdkVersion": i.sdkVersion, "versionName": i.versionName,
                 "packageName": i.packageName, "channel": i.channel, "supportsScreenTouch": i.supportsScreenTouch,
                 "socketTimeoutSeconds": i.socketTimeoutSeconds as Any, "profile": i.profile.rawValue]
            } as Any
            s["dash_identified_count"] = t.dashInfos.count
            s["canvas"] = link.canvas.map { ["width": $0.width, "height": $0.height, "requestedWidth": $0.requestedWidth,
                                             "requestedHeight": $0.requestedHeight, "requestedFps": $0.requestedFps as Any] } as Any
            s["canvas_events"] = t.canvases.count
            s["media_started"] = t.mediaStarts.count
            s["frames_sent"] = stats.framesSent
            s["keyframes_sent"] = stats.keyframesSent
            s["bytes_sent"] = stats.bytesSent
            s["missed_pulls"] = stats.missedPulls
            s["pull_rate"] = stats.pullRate
            var byAction: [String: Int] = [:]
            for touch in t.touches {
                let k: String
                switch touch.action {
                case .down: k = "down"
                case .up: k = "up"
                case .move: k = "move"
                }
                byAction[k, default: 0] += 1
            }
            s["touches"] = ["total": t.touches.count, "by_action": byAction,
                            "points": t.touches.prefix(200).map { ["a": $0.action.rawValue, "p": $0.pointerId, "x": $0.x, "y": $0.y] }]
            s["source"] = ["clip": src.clip as Any, "clip_size": src.clipWidth.map { "\($0)x\(src.clipHeight ?? 0)" } as Any,
                           "clip_mismatch": src.clipMismatch as Any, "prepares": src.prepares, "resyncs": src.resyncs,
                           "media_stops": src.mediaStops, "frames_served": src.framesServed,
                           "keyframes_served": src.keyframesServed, "bytes_served": src.bytesServed,
                           "nil_returns": src.nilReturns, "gate_seeks": src.gateSeeks, "loops": src.loops,
                           "contract_violations": src.contractViolations,
                           "parameters": src.parameters.map { ["bitrate": $0.bitrate, "frameRate": $0.frameRate,
                                                               "keyframeIntervalSeconds": $0.keyframeIntervalSeconds,
                                                               "forceBaseline": $0.forceBaseline] } as Any]
            s["network"] = ["listens": net.listens, "connect_attempts": net.connectAttempts, "connects_ok": net.connectsOK,
                            "connect_refused": net.connectRefused, "connect_timeouts": net.connectTimeouts,
                            "accepted": net.accepted,
                            "accepted_by_port": Dictionary(uniqueKeysWithValues: net.acceptedByPort.map { ("\($0.key)", $0.value) })]
            s["identity"] = ["phoneUUID": phone.phoneUUID, "pubkey_prefix": String(signer.publicKeyBase64.prefix(32)),
                             "key": args.key.rawValue]
            return s
        }
    }

    /// "\(value)" without Optional(...) wrappers; nil → "-".
    static func show(_ value: Any?) -> String {
        func unwrap(_ v: Any?) -> Any? {
            guard let v else { return nil }
            let m = Mirror(reflecting: v)
            if m.displayStyle == .optional {
                guard let child = m.children.first else { return nil }
                return unwrap(child.value)
            }
            if v is NSNull { return nil }
            return v
        }
        guard let v = unwrap(value) else { return "-" }
        if let d = v as? Double { return String(format: "%.3f", d) }
        if let dict = v as? [String: Any] {
            return "{" + dict.keys.sorted().map { "\($0): \(show(dict[$0]))" }.joined(separator: ", ") + "}"
        }
        return "\(v)"
    }

    private func printSummary(_ s: [String: Any]) {
        let show = LinkRunner.show
        func str(_ k: String) -> String { show(s[k]) }
        var lines: [String] = []
        lines.append("==================== linkrunner summary ====================")
        lines.append("stop reason        \(str("stop_reason")) after \(str("duration_s")) s")
        lines.append("final state        \(str("final_state"))")
        let states = (s["states"] as? [[String: Any]] ?? []).map { "+\(show($0["t"])) \(show($0["state"]))" }
        lines.append("states             \(states.joined(separator: " → "))")
        if let p = s["profile"] as? [String: Any] { lines.append("profile            \(show(p["name"])) [\(show(p["id"]))]") }
        if let d = s["dash_info"] as? [String: Any] {
            lines.append("dash               huName=\(show(d["huName"])) huid=\(show(d["huid"])) sdk=\(show(d["sdkVersion"])) channel=\(show(d["channel"])) touch=\(show(d["supportsScreenTouch"])) socketTimeout=\(show(d["socketTimeoutSeconds"]))")
        } else {
            lines.append("dash               (no CLIENT_INFO)")
        }
        if let c = s["canvas"] as? [String: Any] {
            lines.append("canvas             \(show(c["width"]))x\(show(c["height"])) (req \(show(c["requestedWidth"]))x\(show(c["requestedHeight"])), fps \(show(c["requestedFps"])))")
        } else {
            lines.append("canvas             (no REQ 16)")
        }
        lines.append("media started      \(str("media_started"))   streaming entries \(str("streaming_entries"))   reconnecting entries \(str("reconnecting_entries"))   first streaming at +\(str("first_streaming_at_s")) s   first failure \(str("first_failure"))")
        lines.append("frames sent        \(str("frames_sent")) (key \(str("keyframes_sent")), \(str("bytes_sent")) B)  missed pulls \(str("missed_pulls"))  pulls/s (last window) \(str("pull_rate"))")
        if let t = s["touches"] as? [String: Any] { lines.append("touches            \(show(t["total"])) \(show(t["by_action"]))") }
        if let src = s["source"] as? [String: Any] {
            lines.append("source             clip=\(show(src["clip"])) (\(show(src["clip_size"]))) served=\(show(src["frames_served"])) key=\(show(src["keyframes_served"])) prepares=\(show(src["prepares"])) resyncs=\(show(src["resyncs"])) mediaStops=\(show(src["media_stops"])) nil=\(show(src["nil_returns"])) gateSeeks=\(show(src["gate_seeks"])) loops=\(show(src["loops"])) violations=\((src["contract_violations"] as? [String])?.count ?? 0)")
            if let m = src["clip_mismatch"] as? String { lines.append("                   !! \(m)") }
        }
        if let n = s["network"] as? [String: Any] {
            lines.append("network            listens=\(show(n["listens"])) connects=\(show(n["connect_attempts"])) (ok \(show(n["connects_ok"])), refused \(show(n["connect_refused"])), timeouts \(show(n["connect_timeouts"]))) accepted=\(show(n["accepted"])) \(show(n["accepted_by_port"]))")
        }
        lines.append("============================================================")
        for l in lines { out.line("SUM  ", l) }
    }
}
