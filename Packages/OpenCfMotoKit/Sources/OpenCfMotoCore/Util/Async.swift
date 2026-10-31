// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

public struct TimeoutError: Error, CustomStringConvertible, Equatable {
    public let seconds: TimeInterval
    public let label: String
    public init(seconds: TimeInterval, label: String = "") { self.seconds = seconds; self.label = label }
    public var description: String { "Timed out after \(seconds)s" + (label.isEmpty ? "" : " (\(label))") }
}

/// Runs `operation`, throwing `TimeoutError` if it does not finish within `seconds`.
/// The operation is cancelled on timeout; operations that block on I/O must react to cancellation
/// (or be unblocked by closing their stream) — `ByteStream` implementations throw when closed.
public func withTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    label: String = "",
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            throw TimeoutError(seconds: seconds, label: label)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        return first
    }
}

/// Sleeps for `seconds` (cancellation-aware; returns early without throwing if cancelled).
public func sleepSeconds(_ seconds: TimeInterval) async {
    guard seconds > 0 else { return }
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

/// A tiny lock-protected box for sharing mutable state across threads/tasks in non-actor code.
public final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    public init(_ value: Value) { self.value = value }
    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock(); defer { lock.unlock() }
        return try body(&value)
    }
    public var current: Value { withLock { $0 } }
    public func set(_ newValue: Value) { withLock { $0 = newValue } }
}

/// Monotonic time source (seconds). Injected where timers matter so tests can control time.
public protocol MonotonicClock: Sendable {
    func now() -> TimeInterval
}

public struct SystemMonotonicClock: MonotonicClock {
    public init() {}
    public func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}
