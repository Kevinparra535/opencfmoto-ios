// SPDX-License-Identifier: AGPL-3.0-or-later
// Crash capture (app-features §6.4 CrashGuard, iOS edition): MetricKit delivers the diagnostics of a
// crash on the next launch (iOS 15+: shortly after launch). Each MXCrashDiagnostic is formatted as
// text and handed to LogsModel.recordCrashReport, which persists it, shows the "Recovered after a
// crash" card on the Logs screen and includes it in shared logs and problem reports.
//
// Locked iPhone, Phase 0 (P0-11, L18): the same diagnostic payloads also carry CPU exceptions (the
// background CPU monitor), hangs and disk-write exceptions — each logged as one `W/CRASH: [metrickit] …`
// line — and the daily metric payloads carry the background exits (CPU limit, memory, watchdog, …),
// logged as `I/APP: [metrickit] background exits (24h): …`. The texts come from
// `LockDiagnostics` (Linux-tested). Crash handling itself is unchanged.

import Foundation
import OpenCfMotoAppModel
import OpenCfMotoCore
#if canImport(MetricKit) && os(iOS)
import MetricKit
#endif

@MainActor
final class CrashReporter: NSObject {
    static let shared = CrashReporter()

    /// Longest call-stack JSON kept per crash (the log tail and the report stay small).
    nonisolated static let maxStackBytes = 24_000

    private weak var model: AppModel?
    private var started = false

    func start(model: AppModel) {
        self.model = model
        guard !started else { return }
        started = true
        #if canImport(MetricKit) && os(iOS)
        MXMetricManager.shared.add(self)
        // Diagnostics already delivered while the app was not subscribed (iOS 14+ keeps the
        // latest ones available for a while).
        let past = MXMetricManager.shared.pastDiagnosticPayloads
        if !past.isEmpty { handle(past) }
        #endif
    }

    fileprivate func deliver(_ report: String) {
        guard let model else { return }
        Log.w("CRASH", "previous run crashed — report attached to the logs")
        model.logs.recordCrashReport(report)
    }
}

#if canImport(MetricKit) && os(iOS)
extension CrashReporter: MXMetricManagerSubscriber {
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        Task { @MainActor in self.handle(payloads) }
    }

    /// The daily metric payloads (L18 background exits). Logging is thread-safe: no hop needed.
    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            if let line = Self.backgroundExitsLine(payload) { Log.i("APP", line) }
        }
    }

    fileprivate func handle(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for line in Self.exceptionLines(payload) { Log.w("CRASH", line) }
        }
        let reports = payloads.flatMap { payload in
            (payload.crashDiagnostics ?? []).map { Self.format($0, payload: payload) }
        }
        guard !reports.isEmpty else { return }
        deliver(reports.joined(separator: "\n\n"))
    }

    /// L18 (`W/CRASH`): one line per CPU exception, hang and disk-write exception of the payload.
    nonisolated static func exceptionLines(_ payload: MXDiagnosticPayload) -> [String] {
        var lines: [String] = []
        for d in payload.cpuExceptionDiagnostics ?? [] {
            lines.append(LockDiagnostics.cpuException(cpuSeconds: d.totalCPUTime.converted(to: .seconds).value,
                                                      sampledSeconds: d.totalSampledTime.converted(to: .seconds).value,
                                                      build: d.metaData.applicationBuildVersion,
                                                      osVersion: d.metaData.osVersion))
        }
        for d in payload.hangDiagnostics ?? [] {
            lines.append(LockDiagnostics.hang(seconds: d.hangDuration.converted(to: .seconds).value,
                                              build: d.metaData.applicationBuildVersion, osVersion: d.metaData.osVersion))
        }
        for d in payload.diskWriteExceptionDiagnostics ?? [] {
            lines.append(LockDiagnostics.diskWrites(megabytes: d.totalWritesCaused.converted(to: .mebibytes).value,
                                                    build: d.metaData.applicationBuildVersion,
                                                    osVersion: d.metaData.osVersion))
        }
        return lines
    }

    /// L18 (`I/APP`): the background exits of a daily metric payload; nil when it has none.
    nonisolated static func backgroundExitsLine(_ payload: MXMetricPayload) -> String? {
        guard let exits = payload.applicationExitMetrics?.backgroundExitData else { return nil }
        return LockDiagnostics.backgroundExits(LockDiagnostics.BackgroundExits(
            cpuLimit: exits.cumulativeCPUResourceLimitExitCount,
            memory: exits.cumulativeMemoryResourceLimitExitCount,
            memoryPressure: exits.cumulativeMemoryPressureExitCount,
            watchdog: exits.cumulativeAppWatchdogExitCount,
            lockedFile: exits.cumulativeSuspendedWithLockedFileExitCount,
            taskTimeout: exits.cumulativeBackgroundTaskAssertionTimeoutExitCount,
            abnormal: exits.cumulativeAbnormalExitCount,
            normal: exits.cumulativeNormalAppExitCount))
    }

    nonisolated static func format(_ crash: MXCrashDiagnostic, payload: MXDiagnosticPayload) -> String {
        let stamp = ISO8601DateFormatter()
        var lines = ["CRASH \(stamp.string(from: payload.timeStampBegin)) – \(stamp.string(from: payload.timeStampEnd))"]
        let meta = crash.metaData
        lines.append("app \(meta.applicationBuildVersion) · \(meta.osVersion) · \(meta.deviceType)")
        if let type = crash.exceptionType { lines.append("exception type \(type)") }
        if let code = crash.exceptionCode { lines.append("exception code \(code)") }
        if let signal = crash.signal { lines.append("signal \(signal)") }
        if let reason = crash.terminationReason { lines.append("termination \(reason)") }
        if let region = crash.virtualMemoryRegionInfo { lines.append("memory \(region)") }
        let stackData = crash.callStackTree.jsonRepresentation()
        var stack = String(decoding: stackData, as: UTF8.self)
        if stack.utf8.count > maxStackBytes {
            stack = String(decoding: Data(stackData.prefix(maxStackBytes)), as: UTF8.self) + "\n… (truncated)"
        }
        lines.append("call stacks: \(stack)")
        return lines.joined(separator: "\n")
    }
}
#endif
