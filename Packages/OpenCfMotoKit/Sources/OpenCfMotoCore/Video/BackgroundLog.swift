// SPDX-License-Identifier: AGPL-3.0-or-later
// Locked iPhone, Phase 0 (design §4): the exact text of the video diagnostics lines L1–L13, as pure
// functions so the text is unit-tested on Linux. Each function returns the MESSAGE only; the caller
// logs it with the level and tag noted on the function (e.g. `Log.i("VIDEO", BackgroundLog.…)`), and
// the log format adds `HH:mm:ss.SSS L/TAG: `. No line carries `sn=`, `key=`, `token=` or `pwd=`, so the
// log redactor leaves them alone.
//
// One owner log is meant to tell which step failed while the phone was locked (design §4 step table):
// L3–L6 the encoder choice, L7–L8 the first frame on the wire, L9 the steady state every 10 s, L10 the
// background CPU dry run, L11 the budget, L12 demotions and retries, L13 the summary at unlock.

import Foundation

public enum BackgroundLog {
    // MARK: - Field values

    /// A duration rounded to the second: `0s`, `45s`, `1m00s`, `12m03s`, `1h02m03s` (negative or
    /// non-finite → `0s`).
    public static func duration(_ seconds: Double) -> String {
        let total = seconds.isFinite && seconds > 0 ? Int(min(seconds, 1e9).rounded()) : 0
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h)h\(twoDigits(m))m\(twoDigits(s))s" }
        if m > 0 { return "\(m)m\(twoDigits(s))s" }
        return "\(s)s"
    }

    /// `true`, `false`, or `?` when unknown (VideoToolbox did not answer UsingHardwareAccelerated…).
    public static func hardware(_ usesHardware: Bool?) -> String {
        usesHardware.map { $0 ? "true" : "false" } ?? "?"
    }

    /// `IDR 20112b in 45ms`, `none in 500ms`, `failed -12903`, `failed` (no code); `-` when not probed.
    /// Milliseconds are rounded to whole numbers.
    public static func probe(_ outcome: ProbeOutcome?) -> String {
        guard let outcome else { return "-" }
        switch outcome {
        case let .keyframe(bytes, ms): return "IDR \(bytes)b in \(whole(ms))ms"
        case let .nothing(waitedMs): return "none in \(whole(waitedMs))ms"
        case let .failed(code): return code.map { "failed \($0)" } ?? "failed"
        }
    }

    /// `-` when not checked (no probe IDR), `ok` without issues, else the issue codes joined by `,`
    /// (`size-1280x576,level-22`).
    public static func streamCheck(_ issues: [H264StreamIssue]?) -> String {
        guard let issues else { return "-" }
        return issues.isEmpty ? "ok" : issues.map(\.description).joined(separator: ",")
    }

    /// `accepted` or `rejected: <reason>`.
    public static func verdict(_ verdict: EncoderAcceptance.Verdict) -> String {
        switch verdict {
        case .accept: return "accepted"
        case let .reject(reason): return "rejected: \(reason)"
        }
    }

    /// The log name of a rung: `vt-sw`, `hold`, `cpu-<backend>` (`cpu` when the backend is unknown).
    public static func rungName(_ rung: BackgroundRung, cpuBackend: String?) -> String {
        guard rung == .cpu else { return rung.rawValue }
        guard let backend = cpuBackend, !backend.isEmpty else { return "cpu" }
        return "cpu-\(backend)"
    }

    /// An OSStatus / backend status for `create=` / `configure=`: `noErr` for 0, `<name>(<code>)` when
    /// the caller knows the name (`kVTCouldNotFindVideoEncoderErr(-12908)`), else `OSStatus(<code>)`.
    public static func osStatus(_ code: Int32, name: String?) -> String {
        if code == 0 { return "noErr" }
        if let name, !name.isEmpty { return "\(name)(\(code))" }
        return "OSStatus(\(code))"
    }

    // MARK: - L1, L2, L3

    /// L1, `I/VIDEO`, logged by every encoder at its first IDR (labels `own`, `own-sw-pre`, `own-sw`,
    /// `own-sw-id`, `hold`, `mirror`, …):
    /// `[own] first IDR 23410b SPS 27 42 e0 1f … PPS 28 de 09 c8 — profile 66 constraints 0xE0 level 31
    /// 800x384 poc 0 refs 2 frame_num_bits 5 vui=yes reorder=- | pps cavlc deblock_ctrl=1 qp=28`.
    /// The hex is the FULL NAL (header byte included), lower-case bytes separated by spaces; `-` when
    /// absent. An unreadable SPS / PPS gives `sps ?` / `pps ?`.
    public static func firstIDR(label: String, bytes: Int, sps: Data?, pps: Data?) -> String {
        let spsHex = sps.map { $0.hexDump(limit: Int.max) } ?? "-"
        let ppsHex = pps.map { $0.hexDump(limit: Int.max) } ?? "-"
        let spsText = sps.flatMap { H264SPS.parse(nal: $0) }?.summary ?? "sps ?"
        let ppsText = pps.flatMap { H264PPS.parse(nal: $0) }?.summary ?? "pps ?"
        return "[\(label)] first IDR \(bytes)b SPS \(spsHex) PPS \(ppsHex) \u{2014} \(spsText) | \(ppsText)"
    }

    /// One `avc1` entry of `VTCopyVideoEncoderList`.
    public struct EncoderListEntry: Sendable, Equatable {
        public var id: String
        public var name: String
        /// `kVTVideoEncoderList_IsHardwareAccelerated`; nil when the entry has no such key.
        public var isHardwareAccelerated: Bool?

        public init(id: String, name: String, isHardwareAccelerated: Bool?) {
            self.id = id
            self.name = name
            self.isHardwareAccelerated = isHardwareAccelerated
        }
    }

    /// L2, `I/VIDEO`, once per app run at the first foreground prepare:
    /// `[vt-list] avc1 encoders: <id> name=<name> hw=<true|false|?>; <id> name=<name> hw=…` (entries in
    /// list order, joined by `; `), or `[vt-list] avc1 encoders: none`.
    public static func encoderList(_ entries: [EncoderListEntry]) -> String {
        guard !entries.isEmpty else { return "[vt-list] avc1 encoders: none" }
        let items = entries.map { "\($0.id) name=\($0.name) hw=\(hardware($0.isHardwareAccelerated))" }
        return "[vt-list] avc1 encoders: " + items.joined(separator: "; ")
    }

    /// L3, `I/VIDEO`, at `.inactive` (`prepareBackgroundEncoder`):
    /// `[bg] pre-warm vt-sw at inactive: create=noErr hw=? probe=IDR 20112b in 45ms` — `create` from
    /// `osStatus(_:name:)`; `probe=-` when the session was not created.
    public static func preWarm(create: String, usesHardware: Bool?, probe outcome: ProbeOutcome?) -> String {
        "[bg] pre-warm vt-sw at inactive: create=\(create) hw=\(hardware(usesHardware)) probe=\(probe(outcome))"
    }

    // MARK: - L4, L5, L6: the ladder

    /// L4, `I/VIDEO`, every ladder run (background entry, retry, canvas change while backgrounded):
    /// `[bg] enter: canvas 800x384 policy=auto rungs=vt-sw,cpu-minih264,hold last-live-idr=23410b
    /// hold-idrs=2` (`last-live-idr=none` without a live IDR of this canvas).
    public static func enter(canvas: VideoCanvas, policy: LockedStreamPolicy, rungs: [BackgroundRung], cpuBackend: String?,
                             lastLiveIDRBytes: Int?, holdIDRs: Int) -> String {
        let names = rungs.map { rungName($0, cpuBackend: cpuBackend) }.joined(separator: ",")
        let live = lastLiveIDRBytes.map { "\($0)b" } ?? "none"
        return "[bg] enter: canvas \(canvas.width)x\(canvas.height) policy=\(policy.rawValue) rungs=\(names) "
            + "last-live-idr=\(live) hold-idrs=\(holdIDRs)"
    }

    /// Which VideoToolbox software session an L5 line is about.
    public enum SoftwareSession: Sendable, Equatable {
        /// The session pre-warmed at `.inactive` (`own-sw-pre`), probed again at `.background`.
        case preWarmed
        /// A session created now with `EnableHardwareAcceleratedVideoEncoder = false` (`own-sw`).
        case fresh
        /// A session created now with `kVTVideoEncoderSpecification_EncoderID` = this id (`own-sw-id`).
        case encoderID(String)

        /// `pre-warmed`, `fresh`, `id=<EncoderID>`.
        public var text: String {
            switch self {
            case .preWarmed: return "pre-warmed"
            case .fresh: return "fresh"
            case let .encoderID(id): return "id=\(id)"
            }
        }
    }

    /// L5 (vt-sw), `I/VIDEO`, one per VideoToolbox software try:
    /// `[bg] try vt-sw (fresh): create=noErr hw=? probe=IDR 20112b in 45ms sps=ok → accepted`, or e.g.
    /// `[bg] try vt-sw (fresh): create=kVTCouldNotFindVideoEncoderErr(-12908) hw=? probe=- sps=- →
    /// rejected: not created`.
    public static func tryVideoToolbox(_ session: SoftwareSession, create: String, usesHardware: Bool?,
                                       probe outcome: ProbeOutcome?, issues: [H264StreamIssue]?,
                                       verdict result: EncoderAcceptance.Verdict) -> String {
        "[bg] try vt-sw (\(session.text)): create=\(create) hw=\(hardware(usesHardware)) probe=\(probe(outcome)) "
            + "sps=\(streamCheck(issues)) \u{2192} \(verdict(result))"
    }

    /// L5 (cpu), `I/VIDEO`: `[bg] try cpu-minih264: configure=ok probe=IDR 19876b in 12ms sps=ok →
    /// accepted` (`configure=ok`, or the error text).
    public static func tryCPU(encoder: String, configure: String, probe outcome: ProbeOutcome?, issues: [H264StreamIssue]?,
                              verdict result: EncoderAcceptance.Verdict) -> String {
        "[bg] try \(encoder): configure=\(configure) probe=\(probe(outcome)) sps=\(streamCheck(issues)) "
            + "\u{2192} \(verdict(result))"
    }

    /// L6 (encoder accepted), `I/VIDEO`: `background → backgroundSoftware @8fps (encoder vt-sw,
    /// 3375kbps)` (kbps = bitrate / 1000, truncated).
    public static func backgroundSoftware(fps: Int, encoder: String, bitrate: Int) -> String {
        "background \u{2192} backgroundSoftware @\(fps)fps (encoder \(encoder), \(bitrate / 1000)kbps)"
    }

    /// L6 (hold), `I/VIDEO`: `background → hold (2 hold IDR(s); reason: all rungs rejected)` (reason:
    /// `HoldCause.description`).
    public static func backgroundHold(holdIDRs: Int, cause: HoldCause) -> String {
        "background \u{2192} hold (\(holdIDRs) hold IDR(s); reason: \(cause))"
    }

    // MARK: - L7, L8: switches on the wire

    /// L7, `I/VIDEO`, whenever the engine changes the encoder that feeds the dash (lock, unlock,
    /// demotion, retry) and closes the keyframe gate:
    /// `[switch] vt-hw → vt-sw: gate closed; next frame on the wire is an IDR (dump frame #133)`.
    /// `dumpFrame` is the 1-based index in the wire dump the next served frame will get
    /// (`framesWritten + 1`); the parenthesis is omitted when no dump is recording.
    public static func switchStarted(from: String, to: String, dumpFrame: Int?) -> String {
        "[switch] \(from) \u{2192} \(to): gate closed; next frame on the wire is an IDR" + dumpSuffix(dumpFrame)
    }

    /// L8, `I/VIDEO`, at the first IDR of every new `encoderTag` served to the dash (hold included):
    /// `[switch] first vt-sw IDR on the wire: 19876b, 0.21s after the switch (dump frame #133)`.
    /// `secondsAfterSwitch` (2 decimals) is the time since the L7 line that announced this encoder,
    /// omitted with its comma when there was none (the first encoder of a session); `dumpFrame` is this
    /// frame's 1-based index in the wire dump, omitted when no dump is recording.
    public static func switchFirstIDR(encoder: String, bytes: Int, secondsAfterSwitch: Double?, dumpFrame: Int?) -> String {
        let after = secondsAfterSwitch.map { ", \(fixed($0, 2))s after the switch" } ?? ""
        return "[switch] first \(encoder) IDR on the wire: \(bytes)b" + after + dumpSuffix(dumpFrame)
    }

    // MARK: - L9: status every 10 s while backgrounded

    /// The values of one L9 line. Counters are for the current background period.
    public struct Status: Sendable, Equatable {
        /// Seconds since the app went to the background.
        public var backgroundSeconds: Double
        /// The engine mode: `backgroundSoftware` or `hold`.
        public var mode: String
        /// The encoder feeding the dash: `vt-sw`, `cpu-<backend>`, or `hold`.
        public var encoder: String
        /// The background frame-rate cap in effect; nil in hold.
        public var fpsCap: Int?
        public var outputFPS: Double
        /// REQ 114 pulls per second.
        public var pullRate: Double
        /// Pulls answered with a frame, of which hold IDRs, fallback IDRs; and pulls answered with nothing.
        public var served: Int
        public var holdServed: Int
        public var fallbackServed: Int
        public var unanswered: Int
        public var encoderErrors: Int
        /// Average render time; average encode time of the current encoder (nil in hold).
        public var renderMs: Double
        public var encodeMs: Double?
        /// Process CPU % of one core over the last interval; nil when unmeasured.
        public var cpuPercent: Double?
        public var thermal: ThermalLevel
        public var lowPowerMode: Bool
        /// Frames waiting in the frame queue.
        public var queued: Int

        public init(backgroundSeconds: Double, mode: String, encoder: String, fpsCap: Int?, outputFPS: Double,
                    pullRate: Double, served: Int, holdServed: Int, fallbackServed: Int, unanswered: Int,
                    encoderErrors: Int, renderMs: Double, encodeMs: Double?, cpuPercent: Double?, thermal: ThermalLevel,
                    lowPowerMode: Bool, queued: Int) {
            self.backgroundSeconds = backgroundSeconds
            self.mode = mode
            self.encoder = encoder
            self.fpsCap = fpsCap
            self.outputFPS = outputFPS
            self.pullRate = pullRate
            self.served = served
            self.holdServed = holdServed
            self.fallbackServed = fallbackServed
            self.unanswered = unanswered
            self.encoderErrors = encoderErrors
            self.renderMs = renderMs
            self.encodeMs = encodeMs
            self.cpuPercent = cpuPercent
            self.thermal = thermal
            self.lowPowerMode = lowPowerMode
            self.queued = queued
        }
    }

    /// L9, `I/VIDEO`, every 10 s while backgrounded (also in hold):
    /// `[bg] +1m00s mode=backgroundSoftware enc=vt-sw cap=8fps out=5.2fps pulls=5.1/s served=312
    /// (hold 0, fallback 2, none 0) errs=0 render=6.1ms enc=7.8ms cpu=14% thermal=none lowPower=false
    /// q=0` (`cap=-` without a cap, `enc=-` without an encode time, `cpu=?` unmeasured; one decimal for
    /// fps, pulls and ms; whole percent).
    public static func backgroundStatus(_ s: Status) -> String {
        let cap = s.fpsCap.map { "\($0)fps" } ?? "-"
        let enc = s.encodeMs.map { "\(fixed($0, 1))ms" } ?? "-"
        return "[bg] +\(duration(s.backgroundSeconds)) mode=\(s.mode) enc=\(s.encoder) cap=\(cap) "
            + "out=\(fixed(s.outputFPS, 1))fps pulls=\(fixed(s.pullRate, 1))/s served=\(s.served) "
            + "(hold \(s.holdServed), fallback \(s.fallbackServed), none \(s.unanswered)) errs=\(s.encoderErrors) "
            + "render=\(fixed(s.renderMs, 1))ms enc=\(enc) cpu=\(percent(s.cpuPercent)) thermal=\(s.thermal) "
            + "lowPower=\(s.lowPowerMode) q=\(s.queued)"
    }

    // MARK: - L10: the background CPU dry run (Phase 0 build)

    /// L10, `I/VIDEO`, every 60 s of the dry run:
    /// `[bg-probe] render=6.3ms convert=0.9ms load=10ms n=480 cpu=13%` (averages since the dry run
    /// began; `n` = iterations so far; `load` whole ms).
    public static func dryRun(renderMs: Double, convertMs: Double, loadMs: Double, iterations: Int,
                              cpuPercent: Double?) -> String {
        "[bg-probe] render=\(fixed(renderMs, 1))ms convert=\(fixed(convertMs, 1))ms load=\(whole(loadMs))ms "
            + "n=\(iterations) cpu=\(percent(cpuPercent))"
    }

    /// L10 (end), `I/VIDEO`: `[bg-probe] dry run ended after 10m00s`.
    public static func dryRunEnded(afterSeconds seconds: Double) -> String {
        "[bg-probe] dry run ended after \(duration(seconds))"
    }

    // MARK: - L11: budget (Phase 1 governor)

    /// L11: `I/VIDEO` for a frame-rate change, `W/VIDEO` when `change.to == .hold`:
    /// `[bg-budget] fps cap 8→5: cpu 27% (15s) thermal=none lowPower=false batt=64% unplugged`,
    /// `[bg-budget] → hold: thermal critical`,
    /// `[bg-budget] hold → fps cap 8: clear thermal=none lowPower=false batt=64% unplugged`
    /// (`batt=-` without a battery reading).
    public static func budget(_ change: BackgroundBudget.Change) -> String {
        let tail = " thermal=\(change.inputs.thermal) lowPower=\(change.inputs.lowPowerMode) "
            + "batt=\(change.inputs.battery?.logText ?? "-")"
        switch (change.from, change.to) {
        case (_, .hold):
            return "[bg-budget] \u{2192} hold: \(change.reason)"
        case let (.fps(a), .fps(b)):
            return "[bg-budget] fps cap \(a)\u{2192}\(b): \(change.reason)" + tail
        case let (.hold, .fps(b)):
            return "[bg-budget] hold \u{2192} fps cap \(b): \(change.reason)" + tail
        }
    }

    // MARK: - L12: demotion and retry

    /// L12 (demotion), `W/VIDEO`: `[bg] vt-sw demoted: 3 encode errors in 10s (last <message>) → hold`
    /// (`reason`: `EncoderHealth.Verdict.demote`; `next`: the rung tried next, by `rungName`).
    public static func demoted(encoder: String, reason: String, next: String) -> String {
        "[bg] \(encoder) demoted: \(reason) \u{2192} \(next)"
    }

    /// L12 (retry), `I/VIDEO`: `[bg] retry ladder (60s after the demotion, attempt 1/3)` or
    /// `[bg] retry ladder (clear for 60s, attempt 2/3)` (budget).
    public static func retryLadder(after cause: HoldCause, attempt: Int) -> String {
        let delay = Int(BackgroundEncoderLadder.retryDelay)
        let why: String
        switch cause {
        case .demoted: why = "\(delay)s after the demotion"
        case .budget: why = "clear for \(delay)s"
        case .policy, .noEncoderRung, .allRungsRejected: why = cause.description
        }
        return "[bg] retry ladder (\(why), attempt \(attempt)/\(BackgroundEncoderLadder.maxRetriesPerBackgroundPeriod))"
    }

    // MARK: - L13: back in the foreground

    /// What one background encoder did during the background period (L13).
    public struct EncoderSummary: Sendable, Equatable {
        /// `vt-sw`, `cpu-<backend>`.
        public var name: String
        public var frames: Int
        public var keyframes: Int
        public var errors: Int
        public var averageEncodeMs: Double?

        public init(name: String, frames: Int, keyframes: Int, errors: Int, averageEncodeMs: Double?) {
            self.name = name
            self.frames = frames
            self.keyframes = keyframes
            self.errors = errors
            self.averageEncodeMs = averageEncodeMs
        }
    }

    /// L13, `I/VIDEO`, when the hardware encoder takes over again:
    /// `foreground → hardware encoder, IDR forced (background 12m03s: vt-sw 3412 frames 812 IDR 0 errors
    /// enc 8.1ms; hold served 4)` — one item per background encoder, in order, joined by `, `
    /// (`enc -` without an encode time); without any: `(background 12m03s: hold served 600)`.
    public static func foreground(backgroundSeconds: Double, encoders: [EncoderSummary], holdServed: Int) -> String {
        let items = encoders.map { e in
            "\(e.name) \(e.frames) frames \(e.keyframes) IDR \(e.errors) errors enc "
                + (e.averageEncodeMs.map { "\(fixed($0, 1))ms" } ?? "-")
        }
        let used = items.isEmpty ? "" : items.joined(separator: ", ") + "; "
        return "foreground \u{2192} hardware encoder, IDR forced (background \(duration(backgroundSeconds)): "
            + "\(used)hold served \(holdServed))"
    }

    // MARK: - Private

    private static func twoDigits(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }

    /// `digits` decimals (POSIX formatting, never a locale comma); `?` when not finite.
    private static func fixed(_ v: Double, _ digits: Int) -> String {
        v.isFinite ? String(format: "%.\(digits)f", v) : "?"
    }

    /// A whole number (rounded); `?` when not finite or out of range.
    private static func whole(_ v: Double) -> String {
        v.isFinite && abs(v) < 1e15 ? String(Int(v.rounded())) : "?"
    }

    /// `14%`; `?` when unknown.
    private static func percent(_ v: Double?) -> String {
        guard let v, v.isFinite, abs(v) < 1e15 else { return "?" }
        return "\(Int(v.rounded()))%"
    }

    private static func dumpSuffix(_ dumpFrame: Int?) -> String {
        dumpFrame.map { " (dump frame #\($0))" } ?? ""
    }
}
