// SPDX-License-Identifier: AGPL-3.0-or-later
// iOS Local Network privacy: trigger the system alert during onboarding and detect denial.
// docs/spec/ios-platform-facts.md (c) and design recommendation 9 (TN3179).
//
// iOS offers no API to read the Local Network permission state (FB8711182). The supported technique
// (TN3179) is to perform a local network operation and observe the result: a UDP "connection" to a
// local address on the Wi-Fi interface either becomes `.ready` (allowed) or `.waiting` with
// `NWPath.UnsatisfiedReason.localNetworkDenied` (denied / not yet answered — Network.framework
// retries automatically once the user allows it). Do this in the FOREGROUND: in the background an
// undetermined state is silently denied without showing the alert.

#if canImport(Foundation)
import Foundation
import OpenCfMotoCore

/// What the Local Network check observed.
public enum LocalNetworkAccess: String, Sendable, Equatable, CustomStringConvertible {
    /// A local connection became ready: access is granted.
    case granted
    /// The connection is blocked by Local Network privacy (denied, or the alert is still unanswered
    /// when the check gave up).
    case denied
    /// No decisive answer within the time allowed.
    case undetermined
    /// Nothing to test against (no Wi-Fi path / no local address).
    case unavailable

    public var description: String { rawValue }

    /// Local Network privacy itself answered the probe: the system alert has been shown and answered
    /// (or was answered earlier), so later quiet checks may probe again without popping the alert
    /// out of context. `.unavailable` / `.undetermined` prove nothing — off Wi-Fi the probe never
    /// touches the local network, so no alert was shown (review finding IOS-5).
    public var isDecisive: Bool { self == .granted || self == .denied }
}
#endif

#if canImport(Network)
import Network

/// Triggers and detects iOS Local Network permission (no state API exists, see file header).
public enum LocalNetworkPermission {
    /// UDP discard port: nothing listens there, and a datagram to it is harmless.
    static let probePort: UInt16 = 9

    /// Quick check (≤ `timeout`): returns `.denied` as soon as the denial is observed.
    /// - Parameter host: a local IPv4 to test against; default = the Wi-Fi gateway (or subnet `.1`).
    public static func check(host: String? = nil, timeout: TimeInterval = 2) async -> LocalNetworkAccess {
        await probe(host: host, timeout: timeout, waitForDecision: false)
    }

    /// Onboarding: triggers the alert (if undetermined) and waits up to `timeout` for the user's
    /// answer — returns `.granted` as soon as the connection is allowed, else `.denied` /
    /// `.undetermined` at the deadline.
    public static func request(host: String? = nil, timeout: TimeInterval = 30) async -> LocalNetworkAccess {
        await probe(host: host, timeout: timeout, waitForDecision: true)
    }

    static func probe(host: String?, timeout: TimeInterval, waitForDecision: Bool) async -> LocalNetworkAccess {
        var target = host
        if target == nil {
            let s = await WiFiInfo.currentSnapshot(timeout: 1.0)
            if s.isLocalNetworkDenied { return .denied }
            guard s.isSatisfied else { return .unavailable }
            target = s.usableGateways.first ?? s.subnetGateway
        }
        guard let target, let port = NWEndpoint.Port(rawValue: probePort) else { return .unavailable }

        let params = NWParameters(dtls: nil, udp: NWProtocolUDP.Options())
        params.requiredInterfaceType = .wifi
        let conn = NWConnection(host: NWEndpoint.Host(target), port: port, using: params)
        let queue = DispatchQueue(label: "ocm.localnetwork")
        let gate = OCMReadyGate(stopOnWaiting: { _, reason in
            // Denied while the user may still answer the alert: keep waiting when asked to
            // (Network.framework retries by itself once access is granted).
            if reason == .localNetworkDenied { return !waitForDecision }
            // Any other waiting reason (no route, no Wi-Fi): nothing to learn here.
            return true
        })
        conn.stateUpdateHandler = { state in
            if let ev = OCMNWSupport.event(for: state, path: conn.currentPath) { gate.observe(ev) }
        }
        conn.start(queue: queue)
        let outcome = await gate.wait(timeout: timeout, queue: queue)
        let access: LocalNetworkAccess
        switch outcome {
        case .ready:
            // Also send one datagram so the alert is triggered even if readiness alone did not.
            conn.send(content: Data([0]), completion: .idempotent)
            access = .granted
        case let .waiting(_, reason), let .failed(_, reason):
            access = reason == .localNetworkDenied ? .denied : .unavailable
        case let .timedOut(_, reason):
            access = reason == .localNetworkDenied ? .denied : .undetermined
        case .cancelled:
            access = .undetermined
        }
        queue.asyncAfter(deadline: .now() + 0.2) {
            conn.stateUpdateHandler = nil  // break the connection ↔ handler cycle
            conn.cancel()
        }
        Log.i("NET", "[LAN] local network access via \(target): \(access)")
        return access
    }
}
#endif
