// SPDX-License-Identifier: AGPL-3.0-or-later
// In-memory log bus (ring buffer) shared by the core, the Apple adapters, the app and the
// broadcast extension. The on-screen log + "Share logs" export is the primary field-debugging
// channel (same as the Android app), so every stage logs with a short stage tag, e.g. "PXC", "MEDIA".

import Foundation

public enum LogLevel: Int, Comparable, Codable, Sendable, CaseIterable {
    case debug = 0, info, warn, error

    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }

    public var letter: String {
        switch self {
        case .debug: return "D"
        case .info: return "I"
        case .warn: return "W"
        case .error: return "E"
        }
    }
}

public struct LogLine: Identifiable, Sendable, Equatable {
    public let id: UInt64
    public let date: Date
    public let level: LogLevel
    public let tag: String
    public let message: String

    public func formatted(redactor: ((String) -> String)? = nil) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        let msg = redactor?(message) ?? message
        return "\(f.string(from: date)) \(level.letter)/\(tag): \(msg)"
    }
}

/// Thread-safe log bus. Use `Log.i("PXC", "…")` etc.
public final class Log: @unchecked Sendable {
    public static let shared = Log()

    public typealias Subscriber = @Sendable (LogLine) -> Void

    private let lock = NSLock()
    private var ring: [LogLine] = []
    private var nextId: UInt64 = 1
    private var subscribers: [UUID: Subscriber] = [:]
    private var throttle: [String: Date] = [:]

    /// Max lines kept in memory.
    public var capacity: Int = 5000
    /// Lines below this level are dropped.
    public var minimumLevel: LogLevel = .debug
    /// Applied on export (and optionally on display). Set by the app to `LogRedactor.redact`.
    public var redactor: (@Sendable (String) -> String)?
    /// Also print to stdout (useful in tests / Xcode console).
    public var echoToConsole: Bool = false

    public init() {}

    public func log(_ level: LogLevel, _ tag: String, _ message: @autoclosure () -> String) {
        guard level >= minimumLevel else { return }
        let text = message()
        lock.lock()
        let line = LogLine(id: nextId, date: Date(), level: level, tag: tag, message: text)
        nextId &+= 1
        ring.append(line)
        if ring.count > capacity { ring.removeFirst(ring.count - capacity) }
        let subs = Array(subscribers.values)
        let echo = echoToConsole
        lock.unlock()
        if echo { print(line.formatted()) }
        for s in subs { s(line) }
    }

    /// Logs at most once per `interval` seconds for the given key (e.g. per-frame or touch-move spam).
    public func throttled(_ key: String, interval: TimeInterval, _ level: LogLevel, _ tag: String,
                          _ message: @autoclosure () -> String) {
        let now = Date()
        lock.lock()
        if let last = throttle[key], now.timeIntervalSince(last) < interval {
            lock.unlock()
            return
        }
        throttle[key] = now
        lock.unlock()
        log(level, tag, message())
    }

    public func lines() -> [LogLine] {
        lock.lock(); defer { lock.unlock() }
        return ring
    }

    public func clear() {
        lock.lock(); ring.removeAll(); throttle.removeAll(); lock.unlock()
    }

    /// Plain-text export; redacted with `redactor` when `redacted` is true.
    public func export(redacted: Bool = true) -> String {
        let r = redacted ? redactor : nil
        return lines().map { $0.formatted(redactor: r) }.joined(separator: "\n")
    }

    @discardableResult
    public func subscribe(_ s: @escaping Subscriber) -> UUID {
        let id = UUID()
        lock.lock(); subscribers[id] = s; lock.unlock()
        return id
    }

    public func unsubscribe(_ id: UUID) {
        lock.lock(); subscribers[id] = nil; lock.unlock()
    }

    // Convenience
    public static func d(_ tag: String, _ m: @autoclosure () -> String) { shared.log(.debug, tag, m()) }
    public static func i(_ tag: String, _ m: @autoclosure () -> String) { shared.log(.info, tag, m()) }
    public static func w(_ tag: String, _ m: @autoclosure () -> String) { shared.log(.warn, tag, m()) }
    public static func e(_ tag: String, _ m: @autoclosure () -> String) { shared.log(.error, tag, m()) }
}
