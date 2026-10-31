// SPDX-License-Identifier: AGPL-3.0-or-later
// Narrow testing hook for end-to-end runs against a fake dash on the loopback interface (the iOS
// app's `-e2eFakeDash` launch mode driven by the CI simulator job, tools/ci/e2e/): lets the
// composition root replace the link's local-address source and engine timers, which
// `ConnectionModel` otherwise keeps internal (`ConnectionTuning`). The shipping app never calls it.
//
// Why a loopback run needs it: the link derives the phone address from the Wi-Fi port's
// `phoneIPv4` (+ `getifaddrs`) and never probes its OWN address as the dash
// (`InterfaceAddresses.gatewayCandidates`). A fake dash on 127.0.0.1 therefore needs the phone side
// presented under a different loopback address (127.0.0.2 by default); the probe still leaves from
// 127.0.0.1, so the fake dash calls back to 127.0.0.1 and the listeners (bound to every
// interface) accept it.

import Foundation
import OpenCfMotoCore

/// Overrides applied to every link `ConnectionModel` starts after `applyTestingOverrides(_:)`.
public struct ConnectionTestingOverrides: Sendable {
    /// Local IPv4 addresses the link picks the phone address from (replaces `getifaddrs`).
    public var interfaceProvider: (@Sendable () -> [InterfaceAddress])?
    /// Engine timers (probe / heartbeat / reconnect / watchdog); nil keeps the Android values.
    public var linkTimings: LinkTimings?
    /// Connect-back timeout after an accepted probe; nil keeps the default (10 s).
    public var connectBackTimeout: TimeInterval?
    /// Delay between the launch auto-connect decision and Connect; nil keeps 1.2 s.
    public var autoConnectDelay: TimeInterval?

    public init(interfaceProvider: (@Sendable () -> [InterfaceAddress])? = nil, linkTimings: LinkTimings? = nil,
                connectBackTimeout: TimeInterval? = nil, autoConnectDelay: TimeInterval? = nil) {
        self.interfaceProvider = interfaceProvider
        self.linkTimings = linkTimings
        self.connectBackTimeout = connectBackTimeout
        self.autoConnectDelay = autoConnectDelay
    }

    /// The default loopback phone address (the fake dash listens on 127.0.0.1).
    public static let loopbackPhoneIPv4 = "127.0.0.2"

    /// A fake dash on the loopback interface: the phone side is `phoneIPv4` on `lo0` (/8). The
    /// address is flagged as a regular interface so the bike-address picker accepts it even when the
    /// Wi-Fi port reports no phone address. The Wi-Fi port should report the same `phoneIPv4` and the
    /// fake dash address (127.0.0.1) as its gateway.
    public static func loopback(phoneIPv4: String = loopbackPhoneIPv4) -> ConnectionTestingOverrides {
        let address = InterfaceAddress(name: "lo0", ipv4: phoneIPv4, netmask: "255.0.0.0", isUp: true, isLoopback: false)
        return ConnectionTestingOverrides(interfaceProvider: { [address] })
    }
}

public extension ConnectionModel {
    /// Testing only (loopback / end-to-end runs): replaces the link's local-address source and
    /// timers for every session started afterwards. Call it once, right after creating the model.
    func applyTestingOverrides(_ overrides: ConnectionTestingOverrides) {
        var applied: [String] = []
        if let provider = overrides.interfaceProvider {
            tuning.interfaceProvider = provider
            applied.append("interfaces=\(provider().map(\.description).joined(separator: ","))")
        }
        if let timings = overrides.linkTimings {
            tuning.linkTimings = timings
            applied.append("timings")
        }
        if let timeout = overrides.connectBackTimeout {
            tuning.connectBackTimeout = timeout
            applied.append("connectBack=\(timeout)s")
        }
        if let delay = overrides.autoConnectDelay {
            tuning.autoConnectDelay = delay
            applied.append("autoConnectDelay=\(delay)s")
        }
        Log.i("APP", "testing overrides: \(applied.isEmpty ? "none" : applied.joined(separator: " "))")
    }
}
