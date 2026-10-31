// SPDX-License-Identifier: AGPL-3.0-or-later
// Timer constants and engine options of the PXC session (docs/spec/session-network.md §6.10,
// control-plane.md §4–§5). Values that already live in the frozen `LinkConfiguration`
// (connect-back timeout, stall threshold/cooldown, reconnect budget, frame-pull timeout) are not
// duplicated here.

import Foundation

/// Every timer of the session engine as a named constant (Android values by default). Tests use
/// `scaled(by:)` or explicit short values so the suite runs in seconds.
public struct LinkTimings: Sendable, Equatable {
    /// :10930 probe TCP connect timeout (Android 3000 ms).
    public var probeConnectTimeout: TimeInterval = 3
    /// :10930 probe reply read timeout (Android 5000 ms).
    public var probeReadTimeout: TimeInterval = 5
    /// Sleep after a failed probe attempt = unit × attempt number (Android 750 ms × n, also after
    /// the last attempt).
    public var probeRetryUnit: TimeInterval = 0.75
    /// Attempts on the primary gateway :10930 (Android 5).
    public var gatewayProbeAttempts: Int = 5
    /// Attempts on each additional guessed gateway candidate (iOS address ladder).
    public var fallbackGatewayProbeAttempts: Int = 2
    /// Attempts on a Bonjour result (Android 3, plus 3 after one re-browse).
    public var bonjourProbeAttempts: Int = 3
    /// Attempts per re-probe in the reconnect loop (Android 2 on :10930, 2 on Bonjour).
    public var reconnectProbeAttempts: Int = 2
    /// Attempts on each port found by the scan (Android 2).
    public var scannedPortProbeAttempts: Int = 2
    /// Bonjour `_EasyConn._tcp` browse window (Android 12 000 ms).
    public var bonjourBrowseTimeout: TimeInterval = 12
    /// Last-resort TCP connect scan range (Android 10915…10935).
    public var portScanRange: ClosedRange<UInt16> = 10915 ... 10935
    /// Connect timeout per scanned port (Android 350 ms).
    public var portScanConnectTimeout: TimeInterval = 0.35
    /// Phone heartbeat 0x70000000 on every channel-selected :10922 socket (Android 2000 ms; first
    /// beat one interval after the select).
    public var heartbeatInterval: TimeInterval = 2
    /// Reconnect backoff `min(base + step × n, cap)` (Android 500 + 500 n ms, cap 4000 ms).
    public var reconnectBackoffBase: TimeInterval = 0.5
    public var reconnectBackoffStep: TimeInterval = 0.5
    public var reconnectBackoffCap: TimeInterval = 4
    /// Wait for the dash to call back after each re-probe (Android 2500 ms).
    public var reconnectSettle: TimeInterval = 2.5
    /// Watchdog / stats / `hb#` tick (Android 5000 ms).
    public var watchdogTick: TimeInterval = 5
    /// Re-arm discovery/reconnect this long after entering `.failed(.lostLink/.dashNotFound/
    /// .localNetworkDenied)` (Android watchdog 20 000 ms; nil disables).
    public var errorRearmInterval: TimeInterval? = 20
    /// Window for `LinkStats.pullRate`.
    public var statsWindow: TimeInterval = 5

    public init() {}

    /// Android defaults.
    public static let standard = LinkTimings()

    /// Backoff before reconnect attempt `n` (1-based): 1000, 1500, …, 4000 ms by default.
    public func reconnectBackoff(attempt n: Int) -> TimeInterval {
        min(reconnectBackoffBase + reconnectBackoffStep * Double(n), reconnectBackoffCap)
    }

    /// Every duration multiplied by `factor` (attempt counts and port range unchanged).
    public func scaled(by factor: Double) -> LinkTimings {
        var t = self
        t.probeConnectTimeout *= factor
        t.probeReadTimeout *= factor
        t.probeRetryUnit *= factor
        t.bonjourBrowseTimeout *= factor
        t.portScanConnectTimeout *= factor
        t.heartbeatInterval *= factor
        t.reconnectBackoffBase *= factor
        t.reconnectBackoffStep *= factor
        t.reconnectBackoffCap *= factor
        t.reconnectSettle *= factor
        t.watchdogTick *= factor
        t.errorRearmInterval = errorRearmInterval.map { $0 * factor }
        t.statsWindow *= factor
        return t
    }
}

/// Engine options that are not part of the frozen `LinkConfiguration` contract.
public struct LinkOptions: Sendable {
    public var timings: LinkTimings = .standard
    /// Setup "Disable touchscreen": never advertise `supportScreenTouch` (wins over
    /// `LinkConfiguration.forceTouchscreen`). Not in `LinkConfiguration` (contract change requested).
    public var forceNonTouch: Bool = false
    /// Clock-lab "phone" knob: always write phone time into 0x10601 (default: echo).
    public var timeSyncForcePhone: Bool = false
    /// Ghost-touch filter settings (fixes F1–F3 on by default).
    public var ghostFilter: GhostTouchFilter.Configuration = .default
    /// Scheduler for the 80 ms held-UP timers (nil = a private Dispatch queue).
    public var touchScheduler: TouchStitchScheduler?
    /// Clamp dash touches to `[0, w-1] × [0, h-1]` of the negotiated canvas.
    public var clampTouchesToCanvas: Bool = true
    /// Also run the 112 sequence (resynchronize) on REQ_START_H264 128 before replying 129
    /// (media-video.md §16.6; Android only replies).
    public var resynchronizeOnStartH264: Bool = true
    /// NWPath Wi-Fi interface name, used to pick the local IPv4 (never assume "en0").
    public var wifiInterfaceName: String?
    /// Source of local IPv4 addresses (`getifaddrs` by default; injected in tests).
    public var interfaceProvider: @Sendable () -> [InterfaceAddress] = { InterfaceAddresses.current() }
    /// Encoder parameters passed to `VideoFrameSource.prepare` (default: the profile's encoder
    /// defaults). The app plugs its EncoderPlanner (quality, power mode, adaptive policy) here.
    public var encoderParameters: (@Sendable (BikeProfile, VideoCanvas) -> EncoderParameters)?
    /// Wall clock in epoch ms for 0x10601 phone stamps (tests inject a fixed value).
    public var wallClockMillis: @Sendable () -> Int64 = { HuTimeSync.currentMillis() }
    /// Device time zone for 0x10601 phone stamps (re-read on every frame).
    public var timeZone: @Sendable () -> TimeZone = { TimeZone.current }

    public init() {}
}
