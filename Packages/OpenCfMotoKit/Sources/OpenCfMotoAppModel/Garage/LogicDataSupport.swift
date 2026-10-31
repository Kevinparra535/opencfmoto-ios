// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Internal helpers shared by the data models (GarageModel, SettingsModel, NavigationModel,
// TripsModel, LogsModel). Everything lives in the `LogicData` namespace so the names cannot clash
// with helpers of the other wave-2 agents in the same module.

import Foundation
import OpenCfMotoCore

enum LogicData {
    // MARK: - Main-actor hop

    /// Runs `body` on the main actor: synchronously when the caller already is on the main thread
    /// (iOS: the main actor's thread), otherwise enqueued as a main-actor task. Callers must make
    /// `body` idempotent and have it re-read the current state (never apply a captured payload):
    /// enqueued hops are not guaranteed to run in emission order.
    static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            Task { @MainActor in body() }
        }
    }

    // MARK: - Lifetime

    /// Owned by a model (`@ObservationIgnored let`): when the model goes away, every registered
    /// task is cancelled and every cleanup runs (listener / subscriber removal). Avoids touching
    /// main-actor state from a nonisolated `deinit`.
    final class Lifetime: @unchecked Sendable {
        private let lock = NSLock()
        /// Long-lived tasks (subscriptions) — kept until the owner dies.
        private var tasks: [Task<Void, Never>] = []
        /// Replaceable tasks: one per slot, the previous one is cancelled on replacement.
        private var slots: [String: Task<Void, Never>] = [:]
        private var cleanups: [@Sendable () -> Void] = []

        init() {}

        /// Keeps a long-lived `task` until the owner dies.
        func add(_ task: Task<Void, Never>) {
            lock.lock(); tasks.append(task); lock.unlock()
        }

        /// Stores `task` in `slot`, cancelling the task previously stored there (nil just cancels).
        func replace(_ slot: String, with task: Task<Void, Never>?) {
            lock.lock()
            let previous = slots[slot]
            slots[slot] = task
            lock.unlock()
            previous?.cancel()
        }

        /// The task currently stored in `slot`.
        func task(in slot: String) -> Task<Void, Never>? {
            lock.lock(); defer { lock.unlock() }
            return slots[slot]
        }

        func onDeinit(_ cleanup: @escaping @Sendable () -> Void) {
            lock.lock(); cleanups.append(cleanup); lock.unlock()
        }

        deinit {
            lock.lock()
            let pending = tasks + Array(slots.values)
            let done = cleanups
            tasks.removeAll()
            slots.removeAll()
            cleanups.removeAll()
            lock.unlock()
            for t in pending { t.cancel() }
            for c in done { c() }
        }
    }

    /// A lock-protected "work already scheduled" latch used to coalesce bursts of callbacks.
    final class Latch: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = false

        /// True when the caller armed the latch (and must schedule the work); false when already armed.
        func arm() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if armed { return false }
            armed = true
            return true
        }

        func disarm() {
            lock.lock(); armed = false; lock.unlock()
        }
    }

    // MARK: - Exports

    /// Writes UTF-8 `text` atomically to `directory/fileName` (creating the directory) and
    /// describes it for the share sheet.
    static func writeExport(_ text: String, fileName: String, typeIdentifier: String,
                            in directory: URL) throws -> ExportedFile {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        try Data(text.utf8).write(to: url, options: .atomic)
        return ExportedFile(url: url, fileName: fileName, typeIdentifier: typeIdentifier)
    }

    /// `yyyyMMdd-HHmmss`-style stamps for file names (POSIX, never the user locale).
    static func posixStamp(_ date: Date, format: String, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = format
        return f.string(from: date)
    }

    /// A user-facing error carrying an already localized message (`localizedDescription`).
    struct UserError: LocalizedError, CustomStringConvertible, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
        var description: String { message }
    }

    /// Best short text for an error thrown by Foundation / the core, for "<prefix>: <detail>".
    static func detail(of error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription, !d.isEmpty { return d }
        let text = String(describing: error)
        return text.isEmpty ? "\(type(of: error))" : text
    }
}
