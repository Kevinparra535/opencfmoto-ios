// SPDX-License-Identifier: AGPL-3.0-or-later
// Command-line arguments of linkrunner.

import Foundation
import OpenCfMotoCore

struct RunnerArguments {
    enum KeyChoice: String { case generate, fixture }
    enum InterfaceChoice: String { case real, loopback, loopbackAsWifi = "loopback-as-wifi", none }

    var dashHost: String? = "127.0.0.1"
    var gateway: String?
    var localHost: String?
    var wifiInterface: String?
    var interfaces: InterfaceChoice = .real
    var bindHost: String?
    var seconds: Double = 30
    var profile: BikeProfileID?
    var qrText: String? = RunnerArguments.defaultQR
    var learnedCanvas: VideoCanvas?
    var forceTouch = false
    var forceNonTouch = false
    var timeSyncForcePhone = false
    var fast = false
    var eventsOnly = false
    var netTrace = false
    var key: KeyChoice = .generate
    var phoneUUID: String?
    var clip: String?
    var clipDirectory: String?
    var clipCache: String?
    var sourceFPS: Double = 0
    var framePullTimeout: Double = 3
    var connectBackTimeout: Double = 10
    var stallTimeout: Double = 8
    var stallCooldown: Double = 20
    var maxReconnects = 20
    var bonjour: DiscoveredDash?
    var bonjourDelay: Double = 0.5
    var eventsJSONL: String?
    var summaryJSON: String?
    var exitOnFatal = true

    /// A Carbit format-A pairing QR (session-network.md §2.3). modelid 37416 = CFDL16 → the early
    /// profile guess is Legacy, exactly like an Android run without a QR.
    static let defaultQR = "http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37416&sn=FAKE&action=9&ssid=FAKEDASH-0001&pwd=fakedash1&auth=wpa2-psk&name=FakeDash"

    static let usage = """
    linkrunner — runs the real OpenCfMotoCore EasyConnLink over POSIX sockets against a PXC dash.

    usage: linkrunner [--dash IP] [--gateway IP] [--seconds N] [--profile auto|<id>] [--qr TEXT | --no-qr]
                      [--events] [--fast] [options]

    Session:
      --dash IP               dash IPv4 (LinkConfiguration.dashHost; default 127.0.0.1; 'none' = resolve)
      --gateway IP            injected Wi-Fi gateway (EasyConnLink `gateway:`)
      --seconds N             run time, then print the summary and exit (default 30)
      --profile auto|ID       profile override: \(BikeProfileID.allCases.map { $0.rawValue }.joined(separator: ", "))
      --qr TEXT               pairing QR text (parsed with BikeQR.parse; default: a CFDL16 Carbit QR)
      --no-qr                 no QR at all (LinkConfiguration.qr = nil)
      --learned WxH           learned canvas (DashMemory) as requested by the dash, e.g. 800x386
      --force-touch           LinkConfiguration.forceTouchscreen
      --force-non-touch       LinkOptions.forceNonTouch
      --time-sync-phone       LinkOptions.timeSyncForcePhone (0x10601 with phone time)
      --key generate|fixture  RSA identity: fresh PureSwiftHuidSigner.generate() (default) or the fixed
                              control-plane.md §9.5 test key (reproducible pubkey/encryptedHUID)
      --phone-uuid UUID       PhoneIdentity.phoneUUID (default: random per run)
      --fast                  short discovery/reconnect/watchdog timers (heartbeat stays 2 s)
      --frame-pull-timeout S  LinkConfiguration.framePullTimeout (default 3)
      --connect-back-timeout S (default 10)   --stall-timeout S (default 8)
      --stall-cooldown S (default 20)          --max-reconnects N (default 20)
      --bonjour IP[:PORT]     add a static DashDiscovery returning this endpoint (Bonjour race path)
      --bonjour-delay S       its browse delay (default 0.5)

    Addressing (the dash connects back to the probe's source address):
      --local-host IP         LinkConfiguration.localHost
      --interface NAME        LinkOptions.wifiInterfaceName
      --ifaces real|loopback|loopback-as-wifi|none
                              LinkOptions.interfaceProvider: real getifaddrs (default); only lo flagged as
                              loopback; lo presented as a Wi-Fi interface (isLoopback=false); empty list
      --bind IP               listener bind address (default 0.0.0.0, all interfaces)

    Video (SyntheticFrameSource):
      --clip FILE             Annex-B file to serve for every canvas
      --clip-dir DIR          directory with clip_<w>x<h>.h264 (default: tools/fakedash/clips)
      --clip-cache DIR        where missing clips are generated with ffmpeg (default: $TMPDIR/linkrunner-clips)
      --source-fps N          emulate an encoder producing N frames/s (default 0 = serve every pull at once)

    Output:
      --events                print LinkEvents only (no engine log lines)
      --net-trace             also print stream close lines (connect/accept lines are D/NET log lines)
      --events-jsonl FILE     LinkEvents as JSON lines
      --summary-json FILE     final summary as JSON
      --keep-going            do not exit early on a fatal state (port in use, no address)

    Exit codes: 0 frames were streamed, 3 no frame streamed, 2 fatal link state, 64 usage error.
    """

    struct UsageError: Error, CustomStringConvertible {
        let description: String
    }

    static func parse(_ argv: [String]) throws -> RunnerArguments {
        var a = RunnerArguments()
        var i = 0
        func value(_ name: String) throws -> String {
            i += 1
            guard i < argv.count else { throw UsageError(description: "\(name) needs a value") }
            return argv[i]
        }
        func double(_ name: String) throws -> Double {
            let v = try value(name)
            guard let d = Double(v), d >= 0 else { throw UsageError(description: "\(name): bad number '\(v)'") }
            return d
        }
        while i < argv.count {
            let arg = argv[i]
            switch arg {
            case "-h", "--help":
                print(usage)
                exit(0)
            case "--dash":
                let v = try value(arg)
                a.dashHost = v == "none" ? nil : v
            case "--gateway": a.gateway = try value(arg)
            case "--local-host": a.localHost = try value(arg)
            case "--interface": a.wifiInterface = try value(arg)
            case "--ifaces":
                let v = try value(arg)
                guard let c = InterfaceChoice(rawValue: v) else { throw UsageError(description: "--ifaces: \(v)?") }
                a.interfaces = c
            case "--bind": a.bindHost = try value(arg)
            case "--seconds": a.seconds = try double(arg)
            case "--profile":
                let v = try value(arg)
                if v == "auto" {
                    a.profile = nil
                } else if let p = BikeProfileID(rawValue: v) {
                    a.profile = p
                } else {
                    throw UsageError(description: "--profile: unknown '\(v)' (auto, \(BikeProfileID.allCases.map { $0.rawValue }.joined(separator: ", ")))")
                }
            case "--qr": a.qrText = try value(arg)
            case "--no-qr": a.qrText = nil
            case "--learned":
                let v = try value(arg)
                let parts = v.lowercased().split(separator: "x").compactMap { Int($0) }
                guard parts.count == 2 else { throw UsageError(description: "--learned: expected WxH, got '\(v)'") }
                a.learnedCanvas = VideoCanvas(width: parts[0], height: parts[1])
            case "--force-touch": a.forceTouch = true
            case "--force-non-touch": a.forceNonTouch = true
            case "--time-sync-phone": a.timeSyncForcePhone = true
            case "--key":
                let v = try value(arg)
                guard let k = KeyChoice(rawValue: v) else { throw UsageError(description: "--key: generate|fixture") }
                a.key = k
            case "--phone-uuid": a.phoneUUID = try value(arg)
            case "--fast": a.fast = true
            case "--frame-pull-timeout": a.framePullTimeout = try double(arg)
            case "--connect-back-timeout": a.connectBackTimeout = try double(arg)
            case "--stall-timeout": a.stallTimeout = try double(arg)
            case "--stall-cooldown": a.stallCooldown = try double(arg)
            case "--max-reconnects":
                let v = try value(arg)
                guard let n = Int(v), n >= 0 else { throw UsageError(description: "--max-reconnects: \(v)?") }
                a.maxReconnects = n
            case "--bonjour":
                let v = try value(arg)
                let parts = v.split(separator: ":", maxSplits: 1).map(String.init)
                let port = parts.count > 1 ? UInt16(parts[1]) : 10930
                guard let port else { throw UsageError(description: "--bonjour: bad port in '\(v)'") }
                a.bonjour = DiscoveredDash(host: parts[0], port: port, txt: ["source": "linkrunner"])
            case "--bonjour-delay": a.bonjourDelay = try double(arg)
            case "--clip": a.clip = try value(arg)
            case "--clip-dir": a.clipDirectory = try value(arg)
            case "--clip-cache": a.clipCache = try value(arg)
            case "--source-fps": a.sourceFPS = try double(arg)
            case "--events": a.eventsOnly = true
            case "--net-trace": a.netTrace = true
            case "--events-jsonl": a.eventsJSONL = try value(arg)
            case "--summary-json": a.summaryJSON = try value(arg)
            case "--keep-going": a.exitOnFatal = false
            default:
                throw UsageError(description: "unknown argument '\(arg)' (see --help)")
            }
            i += 1
        }
        return a
    }
}
