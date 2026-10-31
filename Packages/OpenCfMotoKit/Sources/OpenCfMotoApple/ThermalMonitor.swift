// SPDX-License-Identifier: AGPL-3.0-or-later
// Thermal state + Low Power Mode → encoder caps (docs/spec/ios-platform-facts.md §k and design
// recommendation 15; media-video.md §15.6). iOS mapping of ProcessInfo.ThermalState to the
// Android PowerManager levels (contract ThermalLevel): nominal → none, fair → moderate,
// serious → severe, critical → critical.

import Foundation
import OpenCfMotoCore

// MARK: - Platform-neutral caps (unit-tested on Linux)

/// Frame-rate / bitrate ceilings for the phone's thermal and power state. Caps never raise a
/// value; they are applied on top of the parameters chosen by the profile / power mode / adaptive
/// policy.
///
/// | level            | fps cap | bitrate        |
/// |------------------|---------|----------------|
/// | none, light      | —       | full           |
/// | moderate (fair)  | 20      | full           |
/// | severe (serious) | 15      | × 0.6          |
/// | critical+        | 5       | × 0.5          |
/// | Low Power Mode   | 15      | (unchanged)    |
///
/// The bitrate never drops below min(600 kbit/s, requested) (AdaptivePolicy MIN_BITRATE).
public enum ThermalCaps {
    public static let lowPowerFrameRateCap = 15
    public static let minimumBitrate = 600_000

    public static func frameRateCap(level: ThermalLevel) -> Int? {
        switch level {
        case .none, .light: return nil
        case .moderate: return 20
        case .severe: return 15
        case .critical, .emergency, .shutdown: return 5
        }
    }

    public static func bitrateFactor(level: ThermalLevel) -> Double {
        switch level {
        case .none, .light, .moderate: return 1.0
        case .severe: return 0.6
        case .critical, .emergency, .shutdown: return 0.5
        }
    }

    /// `parameters` with the caps applied.
    public static func apply(to parameters: EncoderParameters, level: ThermalLevel, lowPowerMode: Bool,
                             thermal: Bool = true, lowPower: Bool = true) -> EncoderParameters {
        var p = parameters
        if thermal {
            if let cap = frameRateCap(level: level) { p.frameRate = min(p.frameRate, cap) }
            let factor = bitrateFactor(level: level)
            if factor < 1 {
                let floor = min(minimumBitrate, parameters.bitrate)
                p.bitrate = max(floor, Int(Double(parameters.bitrate) * factor))
            }
        }
        if lowPower, lowPowerMode { p.frameRate = min(p.frameRate, lowPowerFrameRateCap) }
        p.frameRate = max(1, p.frameRate)
        return p
    }
}

// MARK: - ProcessInfo observer (Apple platforms)

#if canImport(Darwin)
/// Observes `ProcessInfo.thermalState` and Low Power Mode. Thread-safe; observers are called on
/// the thread that posted the notification (a background queue), never with a lock held.
public final class ThermalMonitor: @unchecked Sendable {
    public struct State: Sendable, Equatable {
        public var level: ThermalLevel
        public var isLowPowerModeEnabled: Bool
        /// Raw `ProcessInfo.ThermalState` value (0 nominal … 3 critical).
        public var thermalStateRawValue: Int
        public init(level: ThermalLevel, isLowPowerModeEnabled: Bool, thermalStateRawValue: Int) {
            self.level = level
            self.isLowPowerModeEnabled = isLowPowerModeEnabled
            self.thermalStateRawValue = thermalStateRawValue
        }
    }

    public typealias Observer = @Sendable (State) -> Void

    /// Contract mapping (VideoTypes.swift): nominal → none, fair → moderate, serious → severe,
    /// critical → critical.
    public static func level(for state: ProcessInfo.ThermalState) -> ThermalLevel {
        switch state {
        case .nominal: return .none
        case .fair: return .moderate
        case .serious: return .severe
        case .critical: return .critical
        @unknown default: return .critical
        }
    }

    private let processInfo: ProcessInfo
    private let center: NotificationCenter
    private let lock = NSLock()
    private var observers: [UUID: Observer] = [:]
    private var tokens: [NSObjectProtocol] = []
    private var _state: State

    public init(processInfo: ProcessInfo = .processInfo, notificationCenter: NotificationCenter = .default) {
        self.processInfo = processInfo
        center = notificationCenter
        let t = processInfo.thermalState
        _state = State(level: Self.level(for: t), isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
                       thermalStateRawValue: t.rawValue)
    }

    deinit { stop() }

    public var state: State { lock.lock(); defer { lock.unlock() }; return _state }

    /// Starts observing (reads the current state first, as Apple requires, then registers).
    public func start() {
        lock.lock()
        let running = !tokens.isEmpty
        lock.unlock()
        guard !running else { return }
        refresh(reason: "start")
        let thermal = center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) {
            [weak self] _ in self?.refresh(reason: "thermal")
        }
        let power = center.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: nil) {
            [weak self] _ in self?.refresh(reason: "power")
        }
        lock.lock()
        tokens = [thermal, power]
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let t = tokens
        tokens = []
        lock.unlock()
        for token in t { center.removeObserver(token) }
    }

    /// Registers `observer`; it is called immediately with the current state.
    @discardableResult
    public func addObserver(_ observer: @escaping Observer) -> UUID {
        let id = UUID()
        lock.lock()
        observers[id] = observer
        let s = _state
        lock.unlock()
        observer(s)
        return id
    }

    public func removeObserver(_ id: UUID) {
        lock.lock(); observers[id] = nil; lock.unlock()
    }

    private func refresh(reason: String) {
        let t = processInfo.thermalState
        let next = State(level: Self.level(for: t), isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
                         thermalStateRawValue: t.rawValue)
        lock.lock()
        let changed = next != _state
        _state = next
        let list = Array(observers.values)
        lock.unlock()
        guard changed || reason == "start" else { return }
        Log.i("THERMAL", "thermalState=\(t.rawValue) → \(next.level) lowPower=\(next.isLowPowerModeEnabled) (\(reason))")
        if changed { for o in list { o(next) } }
    }
}
#endif
