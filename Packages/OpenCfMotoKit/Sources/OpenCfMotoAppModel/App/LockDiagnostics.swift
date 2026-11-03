// SPDX-License-Identifier: AGPL-3.0-or-later
// Locked iPhone, Phase 0 (design §2.2 P0-9 – P0-11, §4; contract §7): the exact text of the app-side
// diagnostics lines L14–L18, as pure functions so the text is unit-tested on Linux. Each function
// returns the MESSAGE only; the caller logs it with the level and tag noted on the function, and the
// log format adds `HH:mm:ss.SSS L/TAG: `. The engine's lines L1–L13 live in Core (`BackgroundLog`);
// durations use the same `BackgroundLog.duration` (`45s`, `5m00s`, `1h02m03s`).
//
// One owner log is meant to answer the Gate G0 questions (design §2.3): L14 says when the scene
// changed and what the session was doing, L15 (every 30 s while locked) whether the process, the
// Wi-Fi, the link, GPS and heading were alive, L16 (next launch) whether iOS ended the app in the
// background, L17 whether background location was armed in the documented order, L18 what MetricKit
// reported (CPU, hangs, disk writes, background exits).
//
// Privacy: no line carries `sn=`, `key=`, `token=`, `pwd=`, an SSID, a MAC, a serial, a password or
// coordinates (the log redactor's keys are never used, so it leaves the lines alone).

import Foundation
import OpenCfMotoCore

public enum LockDiagnostics {
    // MARK: - Key-value keys

    /// The unclean-background-exit marker (P0-9): `timeIntervalSince1970` (Double) of the moment the app
    /// went to `.background` during a Connect / Mirror session. Removed when the app becomes `.active`,
    /// when the session ends and at launch; a launch that finds it logs L16 first.
    public static let backgroundSessionMarkerKey = "ios.bg_session_marker"
    /// The locked-phone policy (`LockedStreamPolicy` raw value: `auto`, `cpu`, `vtsw`, `hold`,
    /// `cpu-always`). Phase 0 only reads it (RideModel pushes a valid stored value to the projection at
    /// start); the Phase 1 setting writes it.
    public static let lockedStreamPolicyKey = "ios.locked_stream_policy"

    // MARK: - L14 (I/APP): scene changes

    /// What the session does at a scene change: `own UI session, <ConnectionPhase raw>`,
    /// `mirror session, <phase>` or `no session`.
    public static func sessionContext(isSessionActive: Bool, mode: ProjectionMode, phase: ConnectionPhase) -> String {
        guard isSessionActive else { return "no session" }
        switch mode {
        case .dashUI: return "own UI session, \(phase.rawValue)"
        case .mirror: return "mirror session, \(phase.rawValue)"
        case .none: return "no session"
        }
    }

    /// L14, `I/APP`, at every scene-phase change: `scene active → inactive (own UI session, streaming)`;
    /// leaving `.background` adds how long it lasted: `scene background → inactive after 12m03s (…)`.
    public static func sceneChange(from old: AppScenePhase, to new: AppScenePhase, backgroundSeconds: TimeInterval?,
                                   context: String) -> String {
        let after = old == .background ? backgroundSeconds.map { " after \(BackgroundLog.duration($0))" } ?? "" : ""
        return "scene \(old.rawValue) \u{2192} \(new.rawValue)\(after) (\(context))"
    }

    // MARK: - L15 (I/APP): the `[lock]` status line

    /// What the `[lock]` line reports, read when it is logged.
    public struct LockStatus: Sendable, Equatable {
        /// Seconds since the scene went to `.background`.
        public var lockedSeconds: TimeInterval
        /// `ConnectionModel.phase`.
        public var link: ConnectionPhase
        /// `ConnectionModel.isBikeWifiLost`.
        public var bikeWifiLost: Bool
        /// The projection port's summary (`pulls=`, `dash=`).
        public var projection: ProjectionStatsSummary
        /// Age of the last GPS fix (wall clock − `LocationFix.timeMs`); nil when there was none.
        public var gpsAgeSeconds: TimeInterval?
        /// Age of the last raw heading (`RideModel.lastHeadingAt`, monotonic); nil when there was none.
        public var headingAgeSeconds: TimeInterval?
        /// `SystemControlling.batteryStatus`; nil without a reading.
        public var battery: BatteryStatus?
        public var thermal: ThermalLevel
        public var lowPowerMode: Bool

        public init(lockedSeconds: TimeInterval, link: ConnectionPhase, bikeWifiLost: Bool,
                    projection: ProjectionStatsSummary, gpsAgeSeconds: TimeInterval?, headingAgeSeconds: TimeInterval?,
                    battery: BatteryStatus?, thermal: ThermalLevel, lowPowerMode: Bool) {
            self.lockedSeconds = lockedSeconds
            self.link = link
            self.bikeWifiLost = bikeWifiLost
            self.projection = projection
            self.gpsAgeSeconds = gpsAgeSeconds
            self.headingAgeSeconds = headingAgeSeconds
            self.battery = battery
            self.thermal = thermal
            self.lowPowerMode = lowPowerMode
        }
    }

    /// L15, `I/APP`, every `AppModel.sessionLogInterval` (30 s) while the scene is `.background` and an
    /// own-UI session runs:
    /// `[lock] 5m00s locked link=streaming wifi=up pulls=5.1/s dash=backgroundSoftware vt-sw 5.2fps gps=1s
    /// heading=2s batt=63% charging thermal=none lowPower=false` — the encoder `-` when unknown, the ages
    /// `-` when never, `batt=-` without a reading.
    public static func lockStatus(_ s: LockStatus) -> String {
        let p = s.projection
        return "[lock] \(BackgroundLog.duration(s.lockedSeconds)) locked link=\(s.link.rawValue) "
            + "wifi=\(s.bikeWifiLost ? "down" : "up") pulls=\(fixed1(p.pullRate))/s "
            + "dash=\(dashMode(p.mode)) \(p.encoder ?? "-") \(fixed1(p.framesPerSecond))fps "
            + "gps=\(age(s.gpsAgeSeconds)) heading=\(age(s.headingAgeSeconds)) batt=\(s.battery?.logText ?? "-") "
            + "thermal=\(s.thermal) lowPower=\(s.lowPowerMode)"
    }

    /// The engine mode of the `dash=` field: the summary's `background-software` reads
    /// `backgroundSoftware` (the engine's own name, as in its `[bg]` lines); every other mode as is.
    public static func dashMode(_ summaryMode: String) -> String {
        summaryMode == "background-software" ? "backgroundSoftware" : summaryMode
    }

    // MARK: - L16 (W/APP): the previous run ended in the background

    /// L16, `W/APP`, at launch when the marker of the previous run is still there:
    /// `previous run ended in the background during a dash session (backgrounded 14:03:12): iOS stopped
    /// the app, or it was swiped away` — the local time (`HH:mm:ss`, en_US_POSIX) of the `.background`.
    public static func uncleanBackgroundExit(backgroundedAt: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "HH:mm:ss"
        return "previous run ended in the background during a dash session (backgrounded \(f.string(from: backgroundedAt))): "
            + "iOS stopped the app, or it was swiped away"
    }

    // MARK: - L17 (I/RIDE): GPS restarted with background updates

    /// L17, `I/RIDE`: a dash session (or a recording / navigation) started while GPS already ran for the
    /// phone's dash preview, in the foreground: updates were stopped and started again with background
    /// updates on ("set, then start in the foreground", the order Apple documents).
    public static let gpsRestartedForBackground = "GPS restarted with background updates (it was running for the preview)"

    // MARK: - L18 (W/CRASH, I/APP): MetricKit

    /// L18, `W/CRASH`, a CPU exception diagnostic (`MXCPUExceptionDiagnostic`: total CPU time over the
    /// sampled time): `[metrickit] CPU exception: 54s CPU in 60s (build 12, iOS 27.0.1)`.
    public static func cpuException(cpuSeconds: Double, sampledSeconds: Double, build: String, osVersion: String) -> String {
        "[metrickit] CPU exception: \(whole(cpuSeconds))s CPU in \(whole(sampledSeconds))s \(origin(build, osVersion))"
    }

    /// L18, `W/CRASH`, a hang diagnostic (`MXHangDiagnostic.hangDuration`):
    /// `[metrickit] hang: 3.2s (build 12, iOS 27.0.1)`.
    public static func hang(seconds: Double, build: String, osVersion: String) -> String {
        "[metrickit] hang: \(fixed1(seconds))s \(origin(build, osVersion))"
    }

    /// L18, `W/CRASH`, a disk-write exception (`MXDiskWriteExceptionDiagnostic.totalWritesCaused`, in
    /// MiB): `[metrickit] disk writes: 1024 MB (build 12, iOS 27.0.1)`.
    public static func diskWrites(megabytes: Double, build: String, osVersion: String) -> String {
        "[metrickit] disk writes: \(whole(megabytes)) MB \(origin(build, osVersion))"
    }

    /// The background exits of one daily metric payload (`MXAppExitMetric.backgroundExitData`).
    public struct BackgroundExits: Sendable, Equatable {
        public var cpuLimit: Int
        public var memory: Int
        public var memoryPressure: Int
        public var watchdog: Int
        public var lockedFile: Int
        public var taskTimeout: Int
        public var abnormal: Int
        public var normal: Int

        public init(cpuLimit: Int = 0, memory: Int = 0, memoryPressure: Int = 0, watchdog: Int = 0, lockedFile: Int = 0,
                    taskTimeout: Int = 0, abnormal: Int = 0, normal: Int = 0) {
            self.cpuLimit = cpuLimit
            self.memory = memory
            self.memoryPressure = memoryPressure
            self.watchdog = watchdog
            self.lockedFile = lockedFile
            self.taskTimeout = taskTimeout
            self.abnormal = abnormal
            self.normal = normal
        }
    }

    /// L18, `I/APP`, once per daily metric payload: `[metrickit] background exits (24h): cpu-limit=1
    /// memory=0 memory-pressure=0 watchdog=0 locked-file=0 task-timeout=0 abnormal=0 normal=3`.
    public static func backgroundExits(_ e: BackgroundExits) -> String {
        "[metrickit] background exits (24h): cpu-limit=\(e.cpuLimit) memory=\(e.memory) memory-pressure=\(e.memoryPressure) "
            + "watchdog=\(e.watchdog) locked-file=\(e.lockedFile) task-timeout=\(e.taskTimeout) abnormal=\(e.abnormal) "
            + "normal=\(e.normal)"
    }

    /// The system of a MetricKit report the way the app's own banner names it: `MXMetaData.osVersion`
    /// (`iPhone OS 27.0.1 (25A362)`) reads `iOS 27.0.1`; any other text is kept (trimmed).
    public static func osText(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix(")"), let open = s.range(of: " (", options: .backwards) {
            s = String(s[..<open.lowerBound])
        }
        if s.hasPrefix("iPhone OS ") { s = "iOS " + s.dropFirst("iPhone OS ".count) }
        return s.isEmpty ? "iOS ?" : s
    }

    // MARK: - Field helpers

    /// `(build 12, iOS 27.0.1)`.
    private static func origin(_ build: String, _ osVersion: String) -> String {
        let b = build.trimmingCharacters(in: .whitespacesAndNewlines)
        return "(build \(b.isEmpty ? "?" : b), \(osText(osVersion)))"
    }

    /// An age by `BackgroundLog.duration`, `-` when never.
    private static func age(_ seconds: TimeInterval?) -> String {
        seconds.map { BackgroundLog.duration($0) } ?? "-"
    }

    /// One decimal (POSIX), `?` when not finite.
    private static func fixed1(_ v: Double) -> String {
        v.isFinite ? String(format: "%.1f", v) : "?"
    }

    /// A whole number (rounded), `?` when not finite or out of range.
    private static func whole(_ v: Double) -> String {
        v.isFinite && abs(v) < 1e15 ? String(Int(v.rounded())) : "?"
    }
}
