// SPDX-License-Identifier: AGPL-3.0-or-later
// Locked iPhone, Phase 0 (design §3.3): the pure rules of the BACKGROUND ENCODER LADDER of the dash
// projection engine. While the app is in the background (phone locked) the engine tries, in order,
// the rungs of the policy — a VideoToolbox software session (vt-sw), a bundled CPU encoder (cpu,
// Phase 1) — and ends with the pre-encoded "Phone locked" hold picture. A rung is accepted only after
// a probe IDR passed `EncoderAcceptance`; a live one is demoted by `EncoderHealth`; hold is retried by
// `BackgroundEncoderLadder.shouldRetry`; `BackgroundBudget` caps the background frame rate (the
// Phase 1 governor) and `BackgroundEncoderPlan` sets the background bitrate (Phase 1).
//
// Foundation only, unit-tested on Linux. It lives in Core so the app model (which does not link
// OpenCfMotoApple) can carry the policy.

import Foundation

// MARK: - Policy and rungs

/// What the dash gets while the phone is locked (the app is in the background). The raw values are
/// the `-e2eBackgroundEncoder` launch-argument values and the stored value of the key
/// `ios.locked_stream_policy`.
public enum LockedStreamPolicy: String, Sendable, Codable, CaseIterable {
    /// vt-sw → cpu → hold. The engine's default.
    case automatic = "auto"
    /// cpu → hold (E2E: skips the VideoToolbox probe).
    case cpuOnly = "cpu"
    /// vt-sw → hold. The app's default in the Phase 0 build.
    case videoToolboxSoftwareOnly = "vtsw"
    /// hold only: today's behaviour with the software encoder off.
    case holdOnly = "hold"
    /// Diagnostics (Phase 1): the CPU encoder in the foreground too, so nothing switches at lock;
    /// background rungs cpu → hold.
    case cpuAlways = "cpu-always"
}

/// One rung of the background ladder. Raw values are the names used in the log lines.
public enum BackgroundRung: String, Sendable, Equatable, Hashable, CaseIterable {
    /// A VideoToolbox session created with hardware acceleration disabled.
    case videoToolboxSoftware = "vt-sw"
    /// The bundled CPU encoder (`cpuEncoderFactory`; Phase 1).
    case cpu
    /// No encoder: pulls are answered with the pre-encoded hold IDRs. Always the last rung.
    case hold
}

/// Why the engine serves the hold picture in the background: the reason of the
/// `background → hold (…; reason: <reason>)` line and the input of the retry rule.
public enum HoldCause: Sendable, Equatable, CustomStringConvertible {
    /// The policy has no encoder rung (`holdOnly`).
    case policy
    /// The policy allows encoders but none is available here (no vt-sw support, no CPU encoder).
    case noEncoderRung
    /// Every available rung was tried and rejected.
    case allRungsRejected
    /// The live background encoder was demoted and no later rung was accepted.
    case demoted
    /// The background budget asked for hold; the text is the budget's reason ("thermal critical").
    case budget(String)

    /// Exactly: `policy hold`, `no encoder rung`, `all rungs rejected`, `demoted`, `budget: <reason>`.
    public var description: String {
        switch self {
        case .policy: return "policy hold"
        case .noEncoderRung: return "no encoder rung"
        case .allRungsRejected: return "all rungs rejected"
        case .demoted: return "demoted"
        case let .budget(reason): return "budget: \(reason)"
        }
    }

    /// The engine retries the ladder from this hold (`BackgroundEncoderLadder.shouldRetry`): only after
    /// a demotion or a budget hold.
    public var isRetryable: Bool {
        switch self {
        case .demoted, .budget: return true
        case .policy, .noEncoderRung, .allRungsRejected: return false
        }
    }
}

public enum BackgroundEncoderLadder {
    /// Seconds a retryable hold must last (demotion), or the budget must stay clear (budget hold),
    /// before the ladder runs again.
    public static let retryDelay: TimeInterval = 60
    /// Ladder retries allowed per background period (the counter restarts at every `.background`).
    public static let maxRetriesPerBackgroundPeriod = 3

    /// The rungs to try, in order. Unavailable rungs are skipped; `.hold` always ends the list.
    ///
    /// | policy | rungs |
    /// |---|---|
    /// | automatic | vt-sw, cpu, hold |
    /// | cpuOnly | cpu, hold |
    /// | videoToolboxSoftwareOnly | vt-sw, hold |
    /// | holdOnly | hold |
    /// | cpuAlways | cpu, hold |
    ///
    /// `vtSoftwareAvailable`: `H264Encoder.isSoftwareEncodingSupported`; `cpuAvailable`: the engine has
    /// a `cpuEncoderFactory`.
    public static func rungs(policy: LockedStreamPolicy, vtSoftwareAvailable: Bool, cpuAvailable: Bool) -> [BackgroundRung] {
        var out: [BackgroundRung] = []
        switch policy {
        case .automatic:
            if vtSoftwareAvailable { out.append(.videoToolboxSoftware) }
            if cpuAvailable { out.append(.cpu) }
        case .cpuOnly, .cpuAlways:
            if cpuAvailable { out.append(.cpu) }
        case .videoToolboxSoftwareOnly:
            if vtSoftwareAvailable { out.append(.videoToolboxSoftware) }
        case .holdOnly:
            break
        }
        out.append(.hold)
        return out
    }

    /// The rung to try after `failed` was rejected or demoted: the next one in `rungs`; `.hold` when
    /// `failed` is the last encoder rung, is `.hold`, or is not in `rungs`.
    public static func next(after failed: BackgroundRung, in rungs: [BackgroundRung]) -> BackgroundRung {
        guard failed != .hold, let i = rungs.firstIndex(of: failed), i + 1 < rungs.count else { return .hold }
        return rungs[i + 1]
    }

    /// Whether to run the ladder again now, from a hold reached at `holdSince` because of `cause`.
    /// - `.demoted`: once `retryDelay` has passed since `holdSince`;
    /// - `.budget`: once the budget has been clear (`budgetClearSince`, nil = not clear) for `retryDelay`;
    /// - every other cause: never;
    /// - never once `attempts` (retries already made in this background period) reached
    ///   `maxRetriesPerBackgroundPeriod`.
    /// A retry whose ladder ends in hold again keeps the original retryable cause, with `holdSince` =
    /// the end of that retry.
    public static func shouldRetry(after cause: HoldCause, holdSince: TimeInterval, budgetClearSince: TimeInterval?,
                                   attempts: Int, now: TimeInterval) -> Bool {
        guard attempts < maxRetriesPerBackgroundPeriod else { return false }
        switch cause {
        case .demoted:
            return now - holdSince >= retryDelay
        case .budget:
            guard let clear = budgetClearSince else { return false }
            return now - clear >= retryDelay
        case .policy, .noEncoderRung, .allRungsRejected:
            return false
        }
    }
}

// MARK: - Acceptance

/// What the probe encode of a candidate produced. The probe is a forced-IDR encode of the last rendered
/// picture (one is rendered first if there is none).
public enum ProbeOutcome: Sendable, Equatable {
    /// An IDR access unit of `bytes` bytes came out `ms` milliseconds after the submission.
    case keyframe(bytes: Int, ms: Double)
    /// Nothing came out within `waitedMs`.
    case nothing(waitedMs: Double)
    /// The encoder refused the probe or reported an error; `code` is the OSStatus or backend code.
    case failed(code: Int32?)
}

public enum EncoderAcceptance {
    public enum Verdict: Sendable, Equatable {
        case accept
        /// The reason is logged after `→ rejected: `.
        case reject(String)
    }

    /// The vt-sw probe IDR must come out within this many milliseconds.
    public static let videoToolboxProbeLimitMs: Double = 500

    /// Accept or reject a background candidate, checked in this order (first match wins):
    /// 1. `.hold` → accept (it needs no encoder);
    /// 2. not `created` (VideoToolbox session / CPU `configure` failed) → reject `not created`;
    /// 3. vt-sw with `usesHardware == true` → reject `hw=true` (`nil`, unknown, is accepted only with
    ///    the probe IDR below);
    /// 4. probe `.failed(code)` → reject `probe failed <code>` (`probe failed` without a code);
    /// 5. probe `.nothing` → reject `probe=none`;
    /// 6. probe `.keyframe` of 0 bytes → reject `probe empty`; vt-sw probe slower than
    ///    `videoToolboxProbeLimitMs` → reject `probe slow (<ms>ms)` (ms rounded);
    /// 7. `issues` not empty → reject `sps: <issue>,<issue>…` (`H264StreamIssue.description`);
    /// 8. accept.
    public static func decide(rung: BackgroundRung, created: Bool, usesHardware: Bool?,
                              probe: ProbeOutcome, issues: [H264StreamIssue]) -> Verdict {
        if rung == .hold { return .accept }
        guard created else { return .reject("not created") }
        if rung == .videoToolboxSoftware, usesHardware == true { return .reject("hw=true") }
        switch probe {
        case let .failed(code):
            return .reject(code.map { "probe failed \($0)" } ?? "probe failed")
        case .nothing:
            return .reject("probe=none")
        case let .keyframe(bytes, ms):
            if bytes <= 0 { return .reject("probe empty") }
            if rung == .videoToolboxSoftware, ms > videoToolboxProbeLimitMs {
                return .reject("probe slow (\(ms.isFinite ? Int(ms.rounded()) : 0)ms)")
            }
        }
        if !issues.isEmpty { return .reject("sps: " + issues.map(\.description).joined(separator: ",")) }
        return .accept
    }
}

// MARK: - Demotion

/// Demotion detector of the live background encoder, fed from the engine's encoder output and the
/// encoder's `onFailure` (render queue; times are the engine clock's monotonic seconds).
///
/// | condition | verdict |
/// |---|---|
/// | `failureLimit` (3) failures within `failureWindow` (10 s) | demote `3 encode errors in 10s (last <message>)` |
/// | vt-sw: a frame submitted, no output for `outputStallLimit` (3 s) | demote `no output for 3s` |
/// | cpu: `encode()` returned false `refusalLimit` (3) times in a row | demote `3 encodes refused in a row` |
/// | cpu: a failure with `requiresRecreation` | demote at once `unrecoverable error (<message>)` |
/// | vt-sw: a failure with `requiresRecreation` | today's recreate path; counts as a failure |
public struct EncoderHealth: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        case healthy
        /// The reason is logged in `[bg] <encoder> demoted: <reason> → <next>`.
        case demote(reason: String)
    }

    public static let failureLimit = 3
    public static let failureWindow: TimeInterval = 10
    public static let outputStallLimit: TimeInterval = 3
    public static let refusalLimit = 3

    public let rung: BackgroundRung
    /// Failure times inside the window.
    public private(set) var failureTimes: [TimeInterval] = []
    /// `encode()` calls in a row that returned false (cpu).
    public private(set) var consecutiveRefusals = 0
    /// The oldest accepted submission without an output since (vt-sw stall rule); nil = none pending.
    public private(set) var pendingSince: TimeInterval?

    public init(rung: BackgroundRung) {
        self.rung = rung
    }

    /// The encoder reported a failure (`onFailure`) at `now`.
    public mutating func failure(_ message: String, requiresRecreation: Bool, now: TimeInterval) -> Verdict {
        if rung == .cpu, requiresRecreation { return .demote(reason: "unrecoverable error (\(message))") }
        failureTimes.append(now)
        failureTimes.removeAll { now - $0 > Self.failureWindow }
        if failureTimes.count >= Self.failureLimit {
            return .demote(reason: "\(Self.failureLimit) encode errors in \(Int(Self.failureWindow))s (last \(message))")
        }
        return .healthy
    }

    /// After every `encode()` call: `accepted` is its return value.
    public mutating func submitted(accepted: Bool, now: TimeInterval) -> Verdict {
        if accepted {
            consecutiveRefusals = 0
            if pendingSince == nil { pendingSince = now }
            return .healthy
        }
        guard rung == .cpu else { return .healthy } // VideoToolbox refuses while it re-creates: failures count
        consecutiveRefusals += 1
        if consecutiveRefusals >= Self.refusalLimit {
            return .demote(reason: "\(Self.refusalLimit) encodes refused in a row")
        }
        return .healthy
    }

    /// An output frame of this encoder arrived at `now`.
    public mutating func output(now: TimeInterval) {
        pendingSince = nil
    }

    /// The time rule (vt-sw only: submitted, no output for `outputStallLimit`). Call from the render
    /// tick or the background status timer.
    public func check(now: TimeInterval) -> Verdict {
        guard rung == .videoToolboxSoftware, let since = pendingSince, now - since >= Self.outputStallLimit else {
            return .healthy
        }
        return .demote(reason: "no output for \(Int(Self.outputStallLimit))s")
    }
}

// MARK: - Budget (Phase 1 governor; rules implemented and tested in Phase 0)

/// The background budget governor (design §3.9): caps the background frame rate from the process CPU
/// load, the thermal level, Low Power Mode and the battery, and asks for hold at the limits. Pure; the
/// engine would evaluate it every 5 s while backgrounded. The Phase 0 engine does NOT apply it.
///
/// | input | rule |
/// |---|---|
/// | CPU | 15-s average above `cpuStepDownPercent` (20 %): one step down 8 → 5 → 3 → 2 fps; 60-s average below `cpuStepUpPercent` (10 %): one step up, never above the start value; above `cpuHoldPercent` (40 %) for `cpuHoldSeconds` (30 s) at the lowest step: hold |
/// | thermal | `.moderate`: ≤ 5 fps; `.severe`: ≤ 2 fps; `.critical` or above: hold |
/// | Low Power Mode | ≤ 5 fps |
/// | battery, unplugged | ≤ `lowBatteryPercent` (20 %): ≤ 3 fps; ≤ `criticalBatteryPercent` (10 %): hold; no battery cap while charging or full |
/// | resume | `clearSince` = when every condition became clear; the engine retries the ladder after `BackgroundEncoderLadder.retryDelay` |
public struct BackgroundBudget: Sendable, Equatable {
    public struct Inputs: Sendable, Equatable {
        public var now: TimeInterval
        /// Process CPU % of one core, 15-s and 60-s averages (`ProcessCPUMeter`); nil = not measured.
        public var cpu15s: Double?
        public var cpu60s: Double?
        public var thermal: ThermalLevel
        public var lowPowerMode: Bool
        public var battery: BatteryStatus?

        public init(now: TimeInterval, cpu15s: Double? = nil, cpu60s: Double? = nil, thermal: ThermalLevel = .none,
                    lowPowerMode: Bool = false, battery: BatteryStatus? = nil) {
            self.now = now
            self.cpu15s = cpu15s
            self.cpu60s = cpu60s
            self.thermal = thermal
            self.lowPowerMode = lowPowerMode
            self.battery = battery
        }
    }

    public enum Limit: Sendable, Equatable {
        /// Background frame-rate cap (one of `fpsSteps`).
        case fps(Int)
        /// Serve the hold picture.
        case hold
    }

    /// A change of `limit`, logged as an L11 line (`BackgroundLog.budget`).
    public struct Change: Sendable, Equatable {
        public var from: Limit
        public var to: Limit
        /// e.g. `cpu 27% (15s)`, `cpu 6% (60s)`, `thermal critical`, `low power mode`,
        /// `battery 9% unplugged`, `clear`.
        public var reason: String
        public var inputs: Inputs

        public init(from: Limit, to: Limit, reason: String, inputs: Inputs) {
            self.from = from
            self.to = to
            self.reason = reason
            self.inputs = inputs
        }
    }

    public static let fpsSteps = [8, 5, 3, 2]
    public static let cpuStepDownPercent = 20.0
    public static let cpuStepUpPercent = 10.0
    public static let cpuHoldPercent = 40.0
    public static let cpuHoldSeconds: TimeInterval = 30
    public static let lowBatteryPercent = 20
    public static let criticalBatteryPercent = 10

    /// The highest frame rate the budget allows (the background frame-rate cap it started from).
    public let startFps: Int
    public private(set) var limit: Limit
    /// When every condition became clear (nil while one is not): the input of the retry rule.
    public private(set) var clearSince: TimeInterval?

    public init(startFps: Int = 8) {
        self.startFps = startFps
        limit = .fps(startFps)
    }

    /// Evaluates the rules at `inputs.now`; returns the change of `limit`, or nil when it stayed.
    public mutating func evaluate(_ inputs: Inputs) -> Change? {
        _ = inputs
        return nil // step-0 placeholder: K implements
    }
}

// MARK: - Background parameters (Phase 1; implemented and tested in Phase 0)

public enum BackgroundEncoderPlan {
    /// Lowest background bitrate (bits/s).
    public static let minimumBitrate = 600_000
    /// Bits per macroblock per frame of the background plan (≈ the dense-map intra cost at QP 32–34).
    public static let bitsPerMacroblockPerFrame = 160

    /// The background encoder parameters: `frameRate = min(base.frameRate, fpsCap)` and
    /// `bitrate = min(base.bitrate, max(minimumBitrate, canvasMacroblocks × frameRate ×
    /// bitsPerMacroblockPerFrame))`; the other fields are `base`'s. At 800×384 (1,200 MBs): 1,536,000 at
    /// 8 fps, 960,000 at 5 fps, 600,000 at 2 fps; 1280×576 at 8 fps keeps a 3,375,000 base.
    /// The Phase 0 engine does NOT apply it (vt-sw keeps today's parameters); Phase 1 does.
    public static func parameters(base: EncoderParameters, canvasMacroblocks: Int, fpsCap: Int) -> EncoderParameters {
        _ = (canvasMacroblocks, fpsCap)
        return base // step-0 placeholder: K implements
    }
}
