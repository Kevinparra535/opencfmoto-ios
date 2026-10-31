// SPDX-License-Identifier: AGPL-3.0-or-later
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

import Foundation
import Observation
import OpenCfMotoCore

@MainActor
@Observable
public final class LogsModel {
    @ObservationIgnored let core: AppCore

    public private(set) var entries: [LogEntry] = []
    /// Filter shown in the UI (nil = all levels).
    public var minimumLevel: LogLevelTag? = nil

    /// Extra diagnostics for problem reports (set by AppModel: bike, profile, link stats, settings).
    @ObservationIgnored var diagnostics: @MainActor () -> [String: String] = { [:] }

    public init(core: AppCore) {
        self.core = core
        // TODO(logic-data): subscribe to Log.shared, install the redactor.
    }

    /// Redacted unless "Include secrets in shared logs" is on.
    public func exportLogs() throws -> ExportedFile {
        throw CocoaError(.featureUnsupported) // TODO(logic-data)
    }

    public func clear() { /* TODO(logic-data) */ }

    /// "Report a problem": what went wrong + bike model/year → markdown-ish text file to share.
    public func problemReport(problem: String, bikeModel: String, bikeYear: String) throws -> ExportedFile {
        throw CocoaError(.featureUnsupported) // TODO(logic-data)
    }
}
