// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) CrashGuard.kt (persistSession / hydrateLogBus / last_crash.txt)
//
// The session log must survive a crash, a jetsam kill in the background or a force-quit mid-ride
// (docs/spec/app-features.md §6.4 iOS paragraph, §13.10, §14.10 — review SPEC:CL-6): Swift traps
// cannot be caught, so the redacted tail of the ring buffer is written to `last_session.log` when the
// app leaves the foreground and every ~30 s while a session runs; the next launch reads and DELETES
// it (consume-on-hydrate, the Android OOM field fix) and shows / shares it first. `last_crash.txt`
// holds a crash report the app hands over on the next launch (MetricKit `MXCrashDiagnostic`).
//
// Both files live in `<Application Support>/logs/` (next to `trips/`; the exports folder in Caches is
// cleared at launch).

import Foundation
import OpenCfMotoCore

struct SessionLogFiles: Sendable {
    let directory: URL

    static let sessionFileName = "last_session.log"
    static let crashFileName = "last_crash.txt"
    /// Android `MAX_SESSION_BYTES` (256 KiB).
    static let maxSessionBytes = 256 * 1024
    /// Android caps the crash file at 524 288 chars.
    static let maxCrashBytes = 512 * 1024

    /// Android banners (CrashGuard.kt:81-118).
    static let restoredBanner = "--- restored session log (saved before last exit/crash) ---"
    static let crashBanner = "--- previous fatal crash (also in last_crash.txt) ---"
    static let crashEndBanner = "--- end previous crash \u{2014} use Share Logs to send this ---"

    var sessionURL: URL { directory.appendingPathComponent(Self.sessionFileName, isDirectory: false) }
    var crashURL: URL { directory.appendingPathComponent(Self.crashFileName, isDirectory: false) }

    /// `<Application Support>/logs` for the app's file locations.
    static func directory(for files: AppFileLocations) -> URL {
        files.tripsDirectory.deletingLastPathComponent().appendingPathComponent("logs", isDirectory: true)
    }

    // MARK: Session log

    /// The newest `lines`, formatted like the log screen (`HH:mm:ss.SSS L/TAG: msg`) and ALWAYS
    /// redacted (the file outlives the "Include secrets" choice), within `maxBytes` UTF-8 bytes.
    /// Restore banners are never part of the ring, so nothing nests.
    static func snapshot(_ lines: [LogLine], timeZone: TimeZone = .current, maxBytes: Int = maxSessionBytes) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "HH:mm:ss.SSS"
        var kept: [String] = []
        var bytes = 0
        for line in lines.reversed() {
            let text = "\(f.string(from: line.date)) \(line.level.letter)/\(line.tag): \(LogRedactor.redactAll(line.message))"
            let size = text.utf8.count + 1
            if bytes + size > maxBytes { break }
            bytes += size
            kept.append(text)
        }
        return kept.reversed().joined(separator: "\n")
    }

    /// What `last_session.log` gets: `snapshot(lines)`, after `carried` (an earlier run's restored log,
    /// already redacted) when there is one, within `maxBytes` (the newest part, cut at a line start).
    static func sessionText(_ lines: [LogLine], carrying carried: String?, timeZone: TimeZone = .current,
                            maxBytes: Int = maxSessionBytes) -> String {
        let text = snapshot(lines, timeZone: timeZone, maxBytes: maxBytes)
        var earlier = carried ?? ""
        while earlier.last?.isNewline == true { earlier.removeLast() }
        guard !earlier.isEmpty else { return text }
        return tail(text.isEmpty ? earlier : earlier + "\n" + text, maxBytes: maxBytes)
    }

    func writeSession(_ text: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: sessionURL, options: .atomic)
    }

    /// Reads and deletes `last_session.log` (nil when absent or empty).
    func takeSession() -> String? {
        defer { try? FileManager.default.removeItem(at: sessionURL) }
        guard let data = try? Data(contentsOf: sessionURL), !data.isEmpty else { return nil }
        let text = Self.tail(String(decoding: data, as: UTF8.self), maxBytes: Self.maxSessionBytes)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    // MARK: Crash report

    func writeCrash(_ text: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(Self.tail(text, maxBytes: Self.maxCrashBytes).utf8).write(to: crashURL, options: .atomic)
    }

    /// `last_crash.txt` (kept until the rider dismisses it), nil when absent or blank.
    func readCrash() -> String? {
        guard let data = try? Data(contentsOf: crashURL) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    func deleteCrash() {
        try? FileManager.default.removeItem(at: crashURL)
    }

    // MARK: Helpers

    /// The last `maxBytes` UTF-8 bytes of `text`, cut at a line start (a whole first line when short).
    static func tail(_ text: String, maxBytes: Int) -> String {
        let utf8 = Array(text.utf8)
        guard utf8.count > maxBytes else { return text }
        var start = utf8.count - maxBytes
        if let newline = utf8[start...].firstIndex(of: 0x0A) { start = newline + 1 }
        return String(decoding: utf8[start...], as: UTF8.self)
    }

    /// What Android's hydrated log bus starts with: the restored session under its banner, then the
    /// previous crash between its banners (each non-empty line). "" when there is nothing.
    static func restoredSection(session: String?, crash: String?) -> String {
        var parts: [String] = []
        if let session, !session.isEmpty {
            parts.append(session.hasPrefix(restoredBanner) ? session : restoredBanner + "\n" + session)
        }
        if let crash {
            let lines = crash.split(whereSeparator: \.isNewline).map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if !lines.isEmpty { parts.append(([crashBanner] + lines + [crashEndBanner]).joined(separator: "\n")) }
        }
        return parts.joined(separator: "\n")
    }
}
