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
//
// On a Wi-Fi without internet (the dash's) iOS keeps the Wi-Fi path unsatisfied, so that connection
// never becomes ready (field log 1). There the check browses for the dash's `_EasyConn._tcp` instead
// (TN3179 "Check for local network access"): browsing is a local network operation (it triggers the
// alert), a result proves access, and a denial shows as kDNSServiceErr_PolicyDenied (−65570). A
// Bonjour browse worked on that network in the field.

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

    /// Quick check (≤ `timeout`; ≥ 3 s on a Wi-Fi without internet, where it browses for the dash):
    /// returns `.denied` as soon as the denial is observed.
    /// - Parameter host: a local IPv4 to test against; default = the Wi-Fi gateway (or subnet `.1`).
    public static func check(host: String? = nil, timeout: TimeInterval = 2) async -> LocalNetworkAccess {
        await probe(host: host, timeout: timeout, waitForDecision: false)
    }

    /// Onboarding: triggers the alert (if undetermined) and waits up to `timeout` for the user's
    /// answer — returns `.granted` as soon as the connection is allowed (on a Wi-Fi without internet:
    /// as soon as the browse lists the dash), else `.denied` / `.undetermined` at the deadline.
    public static func request(host: String? = nil, timeout: TimeInterval = 30) async -> LocalNetworkAccess {
        await probe(host: host, timeout: timeout, waitForDecision: true)
    }

    static func probe(host: String?, timeout: TimeInterval, waitForDecision: Bool) async -> LocalNetworkAccess {
        var target = host
        if target == nil {
            let s = await WiFiInfo.currentSnapshot(timeout: 1.0)
            if s.isLocalNetworkDenied { return .denied }
            guard s.isUp else { return .unavailable }
            if s.isLocalOnly {
                let access = await browseProbe(timeout: timeout, waitForDecision: waitForDecision)
                Log.i("NET", "[LAN] local network access via Bonjour \(EasyConnTXT.serviceType) (\(s.stateDescription)): \(access)")
                return access
            }
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

    /// The quick check browses at least this long (the dash answered within ~1.2 s in the field).
    static let minimumCheckBrowse: TimeInterval = 3
    /// `request`: one browser per slice, so a browse denied while the alert was up is retried.
    static let requestBrowseSlice: TimeInterval = 3
    /// `request`: no denial and no advertisement for this long → nothing more to learn.
    static let requestQuietLimit: TimeInterval = 15

    /// Local-only Wi-Fi: browse for `_EasyConn._tcp`. A result → granted; a policy denial → denied
    /// (`request` keeps browsing: the rider may still allow); neither → undetermined (no dash
    /// advertisement to prove access).
    static func browseProbe(timeout: TimeInterval, waitForDecision: Bool) async -> LocalNetworkAccess {
        let start = Date()
        let deadline = start.addingTimeInterval(waitForDecision ? timeout : max(timeout, minimumCheckBrowse))
        var denied = false
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let slice = waitForDecision ? min(remaining, requestBrowseSlice) : remaining
            let sliceStart = Date()
            switch await OCMLocalNetworkBrowse().run(timeout: slice, stopOnDenial: !waitForDecision) {
            case .found:
                return .granted
            case .denied:
                denied = true
                if !waitForDecision { return .denied }
            case .quiet:
                denied = false
                if !waitForDecision || Date().timeIntervalSince(start) >= requestQuietLimit { return .undetermined }
            }
            if Task.isCancelled { break }
            let rest = slice - Date().timeIntervalSince(sliceStart)
            if rest > 0 { await sleepSeconds(rest) } // a browser that failed at once: no tight loop
        }
        return denied ? .denied : .undetermined
    }
}

/// One `_EasyConn._tcp` browse for the Local Network check (internal). Resolves exactly once.
final class OCMLocalNetworkBrowse: @unchecked Sendable {
    enum Outcome: Equatable {
        /// A service was listed: Local Network access is granted.
        case found
        /// The browse is refused by Local Network privacy (denied, or the alert is unanswered).
        case denied
        /// Neither within the time allowed.
        case quiet
    }

    /// DNS-SD kDNSServiceErr_PolicyDenied.
    static let policyDeniedCode: Int32 = -65570

    private let queue = DispatchQueue(label: "ocm.localnetwork.browse")
    private let lock = NSLock()
    private var browser: NWBrowser?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var outcome: Outcome?
    private var denied = false

    static func isPolicyDenied(_ error: NWError) -> Bool {
        if case let .dns(code) = error { return Int32(code) == policyDeniedCode }
        return false
    }

    func run(timeout: TimeInterval, stopOnDenial: Bool) async -> Outcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Outcome, Never>) in
                lock.lock()
                if let outcome {
                    lock.unlock()
                    cont.resume(returning: outcome)
                    return
                }
                continuation = cont
                lock.unlock()
                start(timeout: timeout, stopOnDenial: stopOnDenial)
            }
        } onCancel: { [weak self] in
            self?.finish(.quiet)
        }
    }

    private func start(timeout: TimeInterval, stopOnDenial: Bool) {
        // The parameters of BonjourDashDiscovery, whose browse found the dash on that network.
        let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        params.includePeerToPeer = false
        params.requiredInterfaceType = .wifi
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: EasyConnTXT.serviceType, domain: nil), using: params)
        lock.lock()
        if outcome != nil {
            lock.unlock()
            return
        }
        browser = b
        lock.unlock()
        b.stateUpdateHandler = { [weak self] state in self?.handle(state, stopOnDenial: stopOnDenial) }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            if !results.isEmpty { self?.finish(.found) }
        }
        b.start(queue: queue)
        queue.asyncAfter(deadline: .now() + max(0.1, timeout)) { [weak self] in self?.finishAtDeadline() }
    }

    private func handle(_ state: NWBrowser.State, stopOnDenial: Bool) {
        switch state {
        case let .waiting(error), let .failed(error):
            let isDenied = Self.isPolicyDenied(error)
            lock.lock(); if isDenied { denied = true }; lock.unlock()
            if case .failed = state {
                finish(isDenied ? .denied : .quiet)
            } else if isDenied, stopOnDenial {
                finish(.denied)
            }
        case .ready:
            // Ready again after a denial: iOS retried the browse once access was allowed.
            lock.lock(); denied = false; lock.unlock()
        default:
            break
        }
    }

    private func finishAtDeadline() {
        lock.lock()
        let wasDenied = denied
        lock.unlock()
        finish(wasDenied ? .denied : .quiet)
    }

    private func finish(_ result: Outcome) {
        lock.lock()
        if outcome != nil {
            lock.unlock()
            return
        }
        outcome = result
        let cont = continuation
        continuation = nil
        let b = browser
        browser = nil
        lock.unlock()
        b?.cancel()
        cont?.resume(returning: result)
    }
}
#endif
