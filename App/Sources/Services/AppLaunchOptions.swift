// SPDX-License-Identifier: AGPL-3.0-or-later
// Test / demo switches read from the launch arguments. iOS never passes any of them, so they are
// harmless in normal use; the CI simulator job (tools/ci/e2e/) and developers pass them with
// `xcrun simctl launch <device> <bundle id> -demo -demoSeed -uiScreen settings` or in the Xcode
// scheme:
//
// | Argument                         | Effect                                                              |
// |----------------------------------|---------------------------------------------------------------------|
// | `-demo`                          | simulated bike side (always on in the Simulator, except e2e)        |
// | `-demoSeed`                      | demo content: a bike, saved trips, home + favourites, onboarding done |
// | `-e2eFakeDash`                   | REAL link stack against tools/fakedash/fakedash.py on 127.0.0.1     |
// | `-e2eDash cfdl16\|cfdl26\|mt800`  | which fake dash model the seeded bike matches (default cfdl16)      |
// | `-e2eHost <ipv4>`                | fake dash address (default 127.0.0.1)                               |
// | `-e2eMusic`                      | e2e: a fake Apple Music (3 songs with covers) + the dash music script |
// | `-e2eBackgroundCycle <s>:<d>`    | e2e: simulated lock `s` s after the first STREAMING, for `d` s (scene inactive → background → inactive → active) |
// | `-e2eBackgroundEncoder <policy>` | the locked-phone policy: `auto`, `vtsw`, `cpu`, `hold`, `cpu-always` (overrides the build default and any stored value) |
// | `-uiScreen <name>`               | open that screen after launch (RootLaunchScreen names; `gpx` = a demo GPX preview; `pocketOffer` = Home with the «Modo bolsillo» countdown card held at 5 s) |
// | `-uiOrientation landscape`       | rotate the interface to landscape after launch                      |
// | `-uiDashSheet music`             | with `-uiScreen dash`: open the dash's Music sheet once it shows music |
// | `-uiSettingsAnchor music`        | with `-uiScreen settings`: scroll to "Apple Music on the dash"      |
//
// An invalid `-e2eBackgroundCycle` / `-e2eBackgroundEncoder` value is ignored with a warning in the log.
// `-e2eFakeDash` and `-uiScreen` turn the automatic «Modo bolsillo» countdown after Connect / Go off,
// so the launched screen stays on screen (`-uiScreen ride` still shows the pocket screen itself).

import Foundation
import OpenCfMotoCore

struct AppLaunchOptions: Equatable {
    /// `-e2eBackgroundCycle <startSec>:<durationSec>`.
    struct BackgroundCycle: Equatable {
        /// Seconds after the session first reaches STREAMING.
        var start: TimeInterval
        /// Seconds the phone stays "locked" (from the lock to the unlock).
        var duration: TimeInterval
    }

    /// `-demo`: fake bike / Wi-Fi / GPS services (the Simulator default).
    var demo = false
    /// `-demoSeed`: seed demo content (bike, trips, places) and skip the onboarding.
    var demoSeed = false
    /// `-e2eFakeDash`: real sockets + projection against a fake dash on `e2eHost`.
    var e2eFakeDash = false
    /// `-e2eDash <model>`: the fakedash model the seeded bike's pairing QR matches.
    var e2eDash = "cfdl16"
    /// `-e2eHost <ipv4>`: where the fake dash listens for the :10930 probe.
    var e2eHost = "127.0.0.1"
    /// `-uiScreen <name>`: screen to open after launch (nil = home).
    var uiScreen: String?
    /// `-uiOrientation landscape`.
    var landscape = false
    /// `-e2eMusic`: the e2e run gets a seeded fake Music app and drives the dash's Music sheet.
    var e2eMusic = false
    /// `-uiDashSheet <name>`: a dash sheet to open on the phone's Dash view ("music").
    var uiDashSheet: String?
    /// `-uiSettingsAnchor <name>`: the Settings section to scroll to ("music"; the CI screenshot of
    /// the Apple Music section, review fix F10).
    var uiSettingsAnchor: String?
    /// `-e2eBackgroundCycle <start>:<duration>` (locked iPhone, Phase 0): the e2e harness simulates a lock.
    var e2eBackgroundCycle: BackgroundCycle?
    /// `-e2eBackgroundEncoder <policy>` (locked iPhone, Phase 0): the locked-phone policy of this run.
    var e2eBackgroundEncoder: LockedStreamPolicy?
    /// Launch arguments that were given but not understood (logged as warnings at launch).
    var warnings: [String] = []

    init() {}

    init(arguments: [String]) {
        var i = 1 // argv[0] is the executable
        func value(after index: Int) -> String? {
            let next = index + 1
            guard next < arguments.count, !arguments[next].hasPrefix("-") else { return nil }
            return arguments[next]
        }
        while i < arguments.count {
            let arg = arguments[i]
            switch arg {
            case "-demo": demo = true
            case "-demoSeed": demoSeed = true
            case "-e2eFakeDash": e2eFakeDash = true
            case "-e2eMusic": e2eMusic = true
            case "-e2eDash":
                if let v = value(after: i) { e2eDash = v.lowercased(); i += 1 }
            case "-e2eHost":
                if let v = value(after: i) { e2eHost = v; i += 1 }
            case "-uiScreen":
                if let v = value(after: i) { uiScreen = v.lowercased(); i += 1 }
            case "-uiOrientation":
                if let v = value(after: i) { landscape = v.lowercased().hasPrefix("land"); i += 1 }
            case "-uiDashSheet":
                if let v = value(after: i) { uiDashSheet = v.lowercased(); i += 1 }
            case "-uiSettingsAnchor":
                if let v = value(after: i) { uiSettingsAnchor = v.lowercased(); i += 1 }
            case "-e2eBackgroundCycle":
                let v = value(after: i)
                if v != nil { i += 1 }
                if let cycle = v.flatMap(Self.backgroundCycle) {
                    e2eBackgroundCycle = cycle
                } else {
                    warnings.append("-e2eBackgroundCycle \(v ?? "(no value)") ignored: expected <startSec>:<durationSec>, e.g. 15:30")
                }
            case "-e2eBackgroundEncoder":
                let v = value(after: i)
                if v != nil { i += 1 }
                if let policy = v.flatMap({ LockedStreamPolicy(rawValue: $0.lowercased()) }) {
                    e2eBackgroundEncoder = policy
                } else {
                    let allowed = LockedStreamPolicy.allCases.map(\.rawValue).joined(separator: "|")
                    warnings.append("-e2eBackgroundEncoder \(v ?? "(no value)") ignored: expected \(allowed)")
                }
            default:
                break
            }
            i += 1
        }
    }

    /// `15:30` → start 15 s, duration 30 s; nil unless both are finite, start ≥ 0 and duration > 0.
    static func backgroundCycle(_ text: String) -> BackgroundCycle? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Double(parts[0]), let duration = Double(parts[1]),
              start.isFinite, duration.isFinite, start >= 0, duration > 0 else { return nil }
        return BackgroundCycle(start: start, duration: duration)
    }

    /// The options this process was launched with.
    static let current = AppLaunchOptions(arguments: ProcessInfo.processInfo.arguments)

    /// One-line summary for the log ("" when nothing is set).
    var logDescription: String {
        var parts: [String] = []
        if demo { parts.append("-demo") }
        if demoSeed { parts.append("-demoSeed") }
        if e2eFakeDash { parts.append("-e2eFakeDash (\(e2eDash) @ \(e2eHost))") }
        if e2eMusic { parts.append("-e2eMusic") }
        if let c = e2eBackgroundCycle { parts.append("-e2eBackgroundCycle \(Self.seconds(c.start)):\(Self.seconds(c.duration))") }
        if let p = e2eBackgroundEncoder { parts.append("-e2eBackgroundEncoder \(p.rawValue)") }
        if let uiScreen { parts.append("-uiScreen \(uiScreen)") }
        if landscape { parts.append("-uiOrientation landscape") }
        if let uiDashSheet { parts.append("-uiDashSheet \(uiDashSheet)") }
        if let uiSettingsAnchor { parts.append("-uiSettingsAnchor \(uiSettingsAnchor)") }
        return parts.joined(separator: " ")
    }

    /// `15`, `0.5`: whole seconds without a fraction.
    private static func seconds(_ v: TimeInterval) -> String {
        v == v.rounded() && abs(v) < 1e9 ? String(Int(v)) : String(v)
    }
}
