// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) LogBus.kt, MainActivity.kt (Share Logs / Clear / Report a problem)
//
// WAVE-2 SKELETON — owner: logic-data. The PUBLIC SURFACE below is the contract the SwiftUI layer
// codes against: implement the bodies, add private helpers / new files freely, add new public
// members only if needed (report them), never rename or remove existing public members.
//
// Logs & problem report (docs/spec/app-features.md §6). `Log.shared` is the ring buffer.
//
// Behaviour to implement:
// - `entries`: subscribe to `Log.shared` (throttle UI updates to ≤ 4 Hz, keep the newest 1000),
//   parse the level from the line (D/I/W/E) into `LogLevelTag`.
// - `exportLogs()`: `Log.shared.export(redacted: !includeSecrets)` → text file in
//   `files.exportsDirectory` ("opencfmoto-log-<yyyyMMdd-HHmmss>.txt", POSIX format).
// - `clear()`: clears the ring buffer and `entries`.
// - `problemReport(...)`: `ProblemReport.build(problem:model:year:diagnostics:log:appVersion:)`
//   with `ProblemReport.Diagnostics` filled from the injected `diagnostics` closure (AppModel wires
//   it to connection/ride state) → text file export.
// - `LogRedactor.install(on: .shared, includeSecrets:)` at init with the current setting.
//
// Implementation notes:
// - The log bus redacts on export (Log.swift), so the on-screen lines are shown through the same
//   redactor (app-features §6.1): the "include secrets" toggle is retroactive, both ways.
// - `entries` holds the newest 1000 lines that pass `minimumLevel`, oldest first.
// - `diagnostics` keys understood by the problem report (see `DiagnosticsKey`): `phase`
//   (`ConnectionPhase` raw value or the Android NAME), `detail`, `profile`, `ssid`, `git`; every
//   other key is appended as an extra `key=value` line after the Android block.
// - `clear()` re-logs the session banner like Android (`[BUILD] …` lines).
// - Session log persistence (§6.4 iOS, review SPEC:CL-6, see SessionLogFiles.swift): AppModel calls
//   `hydrate()` once at launch (the previous session's log — and a pending crash report — is shown
//   first in `entries` and shared first by `exportLogs()` / `problemReport(…)`) and `persistSession`
//   when the app leaves the foreground and every ~30 s while a session runs. The app's MetricKit
//   subscriber hands crashes to `recordCrashReport(_:)`; `crashReport` drives the "Recovered after a
//   crash" dialog until `dismissCrashReport()`.

import Foundation
import Observation
import OpenCfMotoCore

@MainActor
@Observable
public final class LogsModel {
    @ObservationIgnored let core: AppCore

    public private(set) var entries: [LogEntry] = []
    /// The previous run's crash report (MetricKit, handed over by the app), kept until dismissed: the
    /// UI shows "Recovered after a crash" (Share Logs / Keep logs / Dismiss) while it is non-nil.
    public private(set) var crashReport: String?
    /// Filter shown in the UI (nil = all levels).
    public var minimumLevel: LogLevelTag? = nil {
        didSet { if minimumLevel != oldValue { refresh() } }
    }

    /// Extra diagnostics for problem reports (set by AppModel: bike, profile, link stats, settings).
    @ObservationIgnored var diagnostics: @MainActor () -> [String: String] = { [:] }

    /// Keys of `diagnostics` that fill the Android `SETUP` block.
    enum DiagnosticsKey {
        /// Connection phase: `ConnectionPhase.rawValue` (mapped to the Android NAME) or a NAME.
        static let phase = "phase"
        /// Status detail line of the phase.
        static let detail = "detail"
        /// Active profile display name (else the override / last identified profile).
        static let profile = "profile"
        /// Dash SSID (else the selected bike's).
        static let ssid = "ssid"
        /// Source revision, when the build knows it.
        static let git = "git"

        static let consumed: Set<String> = [phase, detail, profile, ssid, git]
    }

    /// Newest lines kept in `entries`.
    static let maxEntries = 1000

    // Tunables (tests shorten them).
    /// Minimum spacing of UI refreshes (≤ 4 Hz).
    @ObservationIgnored var throttleInterval: TimeInterval = 0.25
    /// Time zone of the export file stamp and of the on-screen times.
    @ObservationIgnored var timeZone: TimeZone = .current {
        didSet {
            lineTimeFormatter.timeZone = timeZone
            cache.removeAll()
        }
    }

    @ObservationIgnored let log: Log
    /// `last_session.log` / `last_crash.txt` (Application Support/logs).
    @ObservationIgnored let sessionFiles: SessionLogFiles
    /// The previous session's log (consumed at launch), nil when none.
    @ObservationIgnored private(set) var restoredSession: String?
    /// Set by AppModel at launch when the previous run ended in the background during a dash session
    /// (the unclean-exit marker, L16): this run's saves keep `restoredSession` in front of this run's
    /// lines (the same size cap), so one share after a second kill still has the first killed run. A
    /// normal relaunch leaves it false: the old log is shown and shared once, then consumed.
    @ObservationIgnored var carriesRestoredSession = false
    /// Restored session + previous crash, under the Android banners: shown and shared before the live
    /// lines until Clear.
    @ObservationIgnored private(set) var restoredSection = ""
    @ObservationIgnored private var restoredEntriesCache: (redacting: Bool, entries: [LogEntry])?
    @ObservationIgnored private var hydrated = false
    @ObservationIgnored private let lifetime = LogicData.Lifetime()
    @ObservationIgnored private let refreshLatch = LogicData.Latch()
    @ObservationIgnored private var cache: [UInt64: LogEntry] = [:]
    @ObservationIgnored private var cacheRedacting = true
    @ObservationIgnored private var lastRefreshAt: TimeInterval?
    @ObservationIgnored private let lineTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    public init(core: AppCore) {
        self.core = core
        self.log = .shared
        sessionFiles = SessionLogFiles(directory: SessionLogFiles.directory(for: core.services.files))
        start()
    }

    /// `log` is injectable for tests (production: `Log.shared`).
    init(core: AppCore, log: Log) {
        self.core = core
        self.log = log
        sessionFiles = SessionLogFiles(directory: SessionLogFiles.directory(for: core.services.files))
        start()
    }

    /// The app's crash reporter (MetricKit `MXCrashDiagnostic` on the next launch) hands over a crash
    /// of a previous run: saved as `last_crash.txt`, shown by the crash dialog and shared with the logs.
    public func recordCrashReport(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try sessionFiles.writeCrash(trimmed)
        } catch {
            log.log(.warn, Self.tag, "crash report not saved: \(LogicData.detail(of: error))")
        }
        crashReport = SessionLogFiles.tail(trimmed, maxBytes: SessionLogFiles.maxCrashBytes)
        setRestoredSection(SessionLogFiles.restoredSection(session: restoredSession, crash: crashReport))
        log.log(.warn, "FATAL", "the previous run crashed \u{2014} report saved (Logs \u{25B8} Share Logs)")
    }

    /// "Dismiss" on the crash dialog: deletes `last_crash.txt` (the block stays in this run's log).
    public func dismissCrashReport() {
        sessionFiles.deleteCrash()
        crashReport = nil
    }

    /// Redacted unless "Include secrets in shared logs" is on.
    public func exportLogs() throws -> ExportedFile {
        let include = syncRedactor()
        var text = combinedLog(redacted: !include)
        if !text.isEmpty { text += "\n" }
        let stamp = LogicData.posixStamp(core.services.now(), format: "yyyyMMdd-HHmmss", timeZone: timeZone)
        let fileName = "opencfmoto-log-\(stamp).txt"
        do {
            let file = try LogicData.writeExport(text, fileName: fileName, typeIdentifier: "public.plain-text",
                                                 in: core.services.files.exportsDirectory)
            log.log(.info, Self.tag, "log saved: \(fileName) (\(text.utf8.count) bytes)")
            return file
        } catch {
            log.log(.warn, Self.tag, "log export failed: \(LogicData.detail(of: error))")
            throw LogicData.UserError(strings.exportFailed(LogicData.detail(of: error)))
        }
    }

    public func clear() {
        log.clear()
        restoredSession = nil
        setRestoredSection("", refresh: false)
        cache.removeAll()
        if !entries.isEmpty { entries = [] }
        logSessionBanner()
    }

    /// "Report a problem": what went wrong + bike model/year → markdown-ish text file to share.
    public func problemReport(problem: String, bikeModel: String, bikeYear: String) throws -> ExportedFile {
        let system = core.services.system
        let include = syncRedactor()
        var setup = diagnosticsBlock()
        if !include, let redactor = log.redactor { setup = redactor(setup) }
        let report = ProblemReport.build(problem: problem, model: bikeModel, year: bikeYear, diagnostics: setup,
                                         log: combinedLog(redacted: !include), appVersion: system.appVersion)
        var text = report.fileText
        if !text.hasSuffix("\n") { text += "\n" }
        do {
            let file = try LogicData.writeExport(text, fileName: ProblemReport.fileName, typeIdentifier: "public.plain-text",
                                                 in: core.services.files.exportsDirectory)
            log.log(.info, Self.tag, "problem report saved: \(file.fileName) (\(text.utf8.count) bytes)")
            return file
        } catch {
            log.log(.warn, Self.tag, "problem report failed: \(LogicData.detail(of: error))")
            throw LogicData.UserError(strings.shareReportFailed(LogicData.detail(of: error)))
        }
    }

    // MARK: Session log persistence (model-to-model)

    /// Once per process (AppModel.start): consumes the previous session's `last_session.log` and picks
    /// up a pending `last_crash.txt`.
    func hydrate() {
        guard !hydrated else { return }
        hydrated = true
        restoredSession = sessionFiles.takeSession()
        crashReport = sessionFiles.readCrash()
        setRestoredSection(SessionLogFiles.restoredSection(session: restoredSession, crash: crashReport))
        if let restored = restoredSession {
            let count = restored.split(whereSeparator: \.isNewline).count
            log.log(.info, Self.tag, "restored the previous session log (\(count) lines, shown and shared first)")
        }
        if crashReport != nil {
            log.log(.warn, Self.tag, "the previous run crashed \u{2014} open Logs and tap Share Logs")
        }
    }

    /// Writes the redacted tail of the ring buffer to `last_session.log` (app → background, and every
    /// ~30 s while a session runs), after the restored log when `carriesRestoredSession`.
    /// `synchronously: false` formats and writes off the main actor.
    func persistSession(synchronously: Bool = true) {
        let lines = log.lines()
        let files = sessionFiles
        let zone = timeZone
        let carried = carriesRestoredSession ? restoredSession : nil
        let work: @Sendable () -> Void = {
            do {
                try files.writeSession(SessionLogFiles.sessionText(lines, carrying: carried, timeZone: zone))
            } catch {
                Log.w("LOGS", "session log not saved: \(LogicData.detail(of: error))")
            }
        }
        if synchronously { work() } else { Task.detached(priority: .utility) { work() } }
    }

    // MARK: Private

    private static let tag = "LOGS"

    /// Restored section (if any) followed by the live ring, for Share Logs and the problem report.
    private func combinedLog(redacted: Bool) -> String {
        let live = log.export(redacted: redacted)
        guard !restoredSection.isEmpty else { return live }
        // The restored session is redacted already; the crash block is redacted here like any line.
        let restored = redacted
            ? restoredSection.split(separator: "\n", omittingEmptySubsequences: false)
                .map { LogRedactor.redactAll(String($0)) }.joined(separator: "\n")
            : restoredSection
        return live.isEmpty ? restored : restored + "\n" + live
    }

    private func setRestoredSection(_ text: String, refresh doRefresh: Bool = true) {
        restoredSection = text
        restoredEntriesCache = nil
        if doRefresh { refresh() }
    }

    /// The restored section as log entries (negative ids, oldest first, newest `maxEntries`).
    private func restoredEntries(redacting: Bool) -> [LogEntry] {
        guard !restoredSection.isEmpty else { return [] }
        if let cached = restoredEntriesCache, cached.redacting == redacting { return cached.entries }
        let lines = restoredSection.split(separator: "\n").suffix(Self.maxEntries)
        let entries = lines.enumerated().map { index, raw -> LogEntry in
            let text = redacting ? LogRedactor.redactAll(String(raw)) : String(raw)
            return LogEntry(id: -(lines.count - index), text: text, level: Self.levelTag(ofLine: text) ?? .info)
        }
        restoredEntriesCache = (redacting, entries)
        return entries
    }

    private var strings: LogicData.Strings { LogicData.Strings(core.language) }

    private func start() {
        LogRedactor.install(on: log, includeSecrets: core.currentSettings.includeSecretsInLogs)
        subscribe()
        // Lines logged before this model existed: formatted (and redacted) on the next main-actor
        // turn rather than during app launch.
        if refreshLatch.arm() { scheduleRefresh() }
    }

    /// Installs the redactor matching the setting; returns "include secrets".
    @discardableResult
    private func syncRedactor() -> Bool {
        let include = core.currentSettings.includeSecretsInLogs
        LogRedactor.install(on: log, includeSecrets: include)
        return include
    }

    private func subscribe() {
        let latch = refreshLatch
        let subscription = log.subscribe { [weak self] _ in
            guard latch.arm() else { return }
            let model = self
            LogicData.onMain { model?.scheduleRefresh() }
        }
        // A settings write may flip "include secrets": keep the bus redactor in sync and re-render
        // (the toggle is retroactive on screen).
        let settingsSubscription = core.settings.subscribe { [weak self] in
            let model = self
            LogicData.onMain { model?.settingsDidChange() }
        }
        let log = self.log
        let settings = core.settings
        lifetime.onDeinit {
            log.unsubscribe(subscription)
            settings.unsubscribe(settingsSubscription)
        }
    }

    private func settingsDidChange() {
        let wasRedacting = log.redactor != nil
        syncRedactor()
        guard (log.redactor != nil) != wasRedacting, refreshLatch.arm() else { return }
        scheduleRefresh()
    }

    /// Runs one refresh after the throttle interval (the latch is armed by the caller).
    private func scheduleRefresh() {
        let clock = core.services.clock
        let wait: TimeInterval
        if let last = lastRefreshAt { wait = max(0, last + throttleInterval - clock.now()) } else { wait = 0 }
        let task = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard let self else { return }
            // Disarm before reading: lines logged from now on schedule the next refresh.
            self.refreshLatch.disarm()
            guard !Task.isCancelled else { return }
            self.refresh()
        }
        lifetime.replace(Self.refreshSlot, with: task)
    }

    private static let refreshSlot = "refresh"

    /// Rebuilds `entries` from the ring buffer (formatting only lines not seen before).
    private func refresh() {
        lastRefreshAt = core.services.clock.now()
        let redactor = log.redactor
        if (redactor != nil) != cacheRedacting {
            cache.removeAll()
            cacheRedacting = redactor != nil
        }
        let minimumRank = Self.rank(minimumLevel)
        var picked: [LogLine] = []
        for line in log.lines().reversed() where Self.rank(Self.levelTag(line.level)) >= minimumRank {
            picked.append(line)
            if picked.count == Self.maxEntries { break }
        }
        var fresh: [LogEntry] = []
        fresh.reserveCapacity(picked.count)
        var nextCache: [UInt64: LogEntry] = [:]
        for line in picked.reversed() {
            let entry = cache[line.id] ?? LogEntry(id: Int(truncatingIfNeeded: line.id),
                                                   text: format(line, redactor: redactor),
                                                   level: Self.levelTag(line.level))
            fresh.append(entry)
            nextCache[line.id] = entry
        }
        cache = nextCache
        let restored = restoredEntries(redacting: redactor != nil).filter { Self.rank($0.level) >= minimumRank }
        if !restored.isEmpty { fresh = restored + fresh }
        if fresh != entries { entries = fresh }
    }

    /// One line exactly like `LogLine.formatted(redactor:)` (`HH:mm:ss.SSS L/TAG: msg`), with a
    /// cached formatter.
    private func format(_ line: LogLine, redactor: (@Sendable (String) -> String)?) -> String {
        let message = redactor?(line.message) ?? line.message
        return "\(lineTimeFormatter.string(from: line.date)) \(line.level.letter)/\(line.tag): \(message)"
    }

    /// The level letter of a log line (`D` / `I` / `W` / `E`) as a UI tag.
    static func levelTag(letter: String) -> LogLevelTag? {
        switch letter {
        case "D": return .debug
        case "I": return .info
        case "W": return .warning
        case "E": return .error
        default: return nil
        }
    }

    /// Level of a formatted line (`HH:mm:ss.SSS L/TAG: msg`), nil when it does not look like one.
    static func levelTag(ofLine text: String) -> LogLevelTag? {
        guard let space = text.firstIndex(of: " ") else { return nil }
        let rest = text[text.index(after: space)...]
        guard rest.count >= 2, rest.dropFirst().first == "/", let letter = rest.first else { return nil }
        return levelTag(letter: String(letter))
    }

    private static func levelTag(_ level: LogLevel) -> LogLevelTag {
        levelTag(letter: level.letter) ?? .info
    }

    private static func rank(_ tag: LogLevelTag?) -> Int {
        switch tag {
        case nil, .debug?: return 0
        case .info?: return 1
        case .warning?: return 2
        case .error?: return 3
        }
    }

    /// Android's session banner (re-logged after Clear).
    private func logSessionBanner() {
        let system = core.services.system
        log.log(.info, "BUILD", "versionName=\(system.appVersion) versionCode=\(system.buildNumber) "
                + "device=\(system.deviceModel) os=\(system.systemVersion) flavor=\(system.flavor.rawValue)")
        log.log(.info, "BUILD", "--- session start ---")
    }

    /// The `SETUP` block: Android's nine lines (MainActivity.kt:1653-1666) + iOS extras.
    private func diagnosticsBlock() -> String {
        let extra = diagnostics()
        func value(_ key: String) -> String? {
            guard let v = extra[key], !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return v
        }
        let system = core.services.system
        let settings = core.currentSettings
        let bike = core.garage.selected
        let identified = settings.profileOverride ?? bike?.profileHint
        let block = ProblemReport.Diagnostics(
            appVersion: system.appVersion,
            buildNumber: system.buildNumber,
            gitHash: value(DiagnosticsKey.git) ?? "n/a",
            profileName: value(DiagnosticsKey.profile) ?? BikeProfile.profile(identified ?? .legacy).name,
            profileOverride: settings.profileOverride,
            wifiTransport: settings.wifiTransport,
            marginsSummary: CanvasFit.marginsSummary(settings.screenMargins,
                                                     profileDefault: CanvasFit.profileDefaultMargins(identified)),
            forceNonTouch: settings.forceNonTouch,
            forceTouch: settings.forceTouch,
            ssid: value(DiagnosticsKey.ssid) ?? bike?.ssid,
            phase: value(DiagnosticsKey.phase).map(Self.androidPhaseName) ?? "\u{2014}",
            phaseDetail: value(DiagnosticsKey.detail) ?? "")
        var text = block.text
        text += "device=\(system.deviceModel) \(system.systemVersion) flavor=\(system.flavor.rawValue)\n"
        for (key, v) in extra.sorted(by: { $0.key < $1.key }) where !DiagnosticsKey.consumed.contains(key) {
            text += "\(key)=\(v)\n"
        }
        return text
    }

    /// `ConnectionPhase` raw value → Android `Phase` NAME (other values unchanged).
    static func androidPhaseName(_ value: String) -> String {
        guard let phase = ConnectionPhase(rawValue: value) else { return value }
        switch phase {
        case .idle: return "IDLE"
        case .joiningWifi: return "JOINING_WIFI"
        case .linking: return "PXC_CONNECTING"
        case .streaming: return "STREAMING"
        case .mirroring: return "MIRRORING"
        case .reconnecting: return "RECONNECTING"
        case .waitingForBike: return "WAITING_FOR_BIKE"
        case .stopped: return "STOPPED"
        case .error: return "ERROR"
        }
    }
}
