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
// | `-uiScreen <name>`               | open that screen after launch (RootLaunchScreen names)              |
// | `-uiOrientation landscape`       | rotate the interface to landscape after launch                      |

import Foundation

struct AppLaunchOptions: Equatable {
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
            case "-e2eDash":
                if let v = value(after: i) { e2eDash = v.lowercased(); i += 1 }
            case "-e2eHost":
                if let v = value(after: i) { e2eHost = v; i += 1 }
            case "-uiScreen":
                if let v = value(after: i) { uiScreen = v.lowercased(); i += 1 }
            case "-uiOrientation":
                if let v = value(after: i) { landscape = v.lowercased().hasPrefix("land"); i += 1 }
            default:
                break
            }
            i += 1
        }
    }

    /// The options this process was launched with.
    static let current = AppLaunchOptions(arguments: ProcessInfo.processInfo.arguments)

    /// One-line summary for the log ("" when nothing is set).
    var logDescription: String {
        var parts: [String] = []
        if demo { parts.append("-demo") }
        if demoSeed { parts.append("-demoSeed") }
        if e2eFakeDash { parts.append("-e2eFakeDash (\(e2eDash) @ \(e2eHost))") }
        if let uiScreen { parts.append("-uiScreen \(uiScreen)") }
        if landscape { parts.append("-uiOrientation landscape") }
        return parts.joined(separator: " ")
    }
}
