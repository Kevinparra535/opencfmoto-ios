// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) MediaButtonBridge.kt (tap / ×2 / hold engine), ButtonPresencePrefs.kt
//
// Handlebar gesture engine (docs/spec/input-controls.md §7.2–§7.7, §9, §10.8–§10.9) as a pure,
// clock-driven state machine:
//   raw handlebar event (+ timestamp) → ButtonGesture (tap / double / hold) → ButtonAction (the bike's
//   map, read per press) → DashInput (knob ±1, keys, saved place).
//
// iOS adaptation of Android's MediaSession key path:
// - ★ / ▶ / ◀ arrive as DISCRETE remote commands (no press/release): they go straight into the
//   double-tap detector (Android's onPlay/onPause path) with snappy singles: the single fires at once,
//   a second tap on the same channel inside the window (1 ≤ gap < window) fires the double. Except
//   where the double is mapped to Select and the single is not (★ = next, ★★ = choose): that single
//   waits out the window, so a double fires the double alone (`defersSingleLocked`).
// - Holds exist only for ▶/◀ when the dash sends AVRCP FAST_FORWARD / REWIND, observed as seek
//   begin/end: begin = key down, end = key up (hold if held ≥ the hold threshold and holds are on,
//   else a tap). A hold whose action is `none` is swallowed. If the app calls `tick` while a button is
//   held, the hold fires at the threshold when its action is not `none` (Android's key-repeat path).
// - ▲/▼ (AVRCP absolute volume, experimental on iOS): ▲ = backward, ▼ = forward; a jump of ≥ 3 steps
//   is a forced double.
// - Presence: any track/select event marks the track keys PRESENT, any volume event the rocker
//   PRESENT. iOS fix of the Android quirk: the 90 s "rocker ABSENT" probe counts from when streaming
//   STARTS (not from capture start).
// All timestamps are milliseconds on one monotonic clock (`MonotonicClock` seconds × 1000).

import Foundation

/// One fired gesture.
public struct HandlebarCommand: Sendable, Equatable, CustomStringConvertible {
    public var gesture: ButtonGesture
    public var action: ButtonAction
    /// What to feed the dash UI; nil when the action is `none` (the press is swallowed).
    public var input: DashInput?
    /// Engine time (ms) when it fired.
    public var timeMs: Int64

    public init(gesture: ButtonGesture, action: ButtonAction, timeMs: Int64) {
        self.gesture = gesture
        self.action = action
        self.input = action.handlebarDashInput
        self.timeMs = timeMs
    }

    public var description: String { "\(timeMs) \(gesture.rawValue) \u{2192} \(action.rawValue)" }
}

/// Thread-safe (`NSLock`) handlebar gesture engine. Typical wiring in the app layer:
///
///     let engine = HandlebarGestureEngine(
///         configuration: .init(settings: store.settings(forBike: id), snappySingles: store.snappySingles),
///         presence: store.presence(forBike: id))
///     engine.onPresenceChange = { p in /* store.setVolumeRockerPresence(p.volumeRocker, forBike: id) … */ }
///     remote.onEvent = { e in
///         for cmd in engine.handle(e.raw, at: e.time, steps: e.steps) { if let input = cmd.input { dash.send(input) } }
///     }
///     // re-read settings on change: engine.configuration = .init(settings: …)
///     // streaming: engine.streamingStarted() / engine.streamingStopped()
///     // timers: call engine.tick() at engine.nextDeadlineMs() (or every ~100 ms while one is pending)
public final class HandlebarGestureEngine: @unchecked Sendable {

    /// The three gesture channels (each with single / double / hold).
    public enum Channel: String, Sendable, CaseIterable {
        case select, backward, forward

        var single: ButtonGesture {
            switch self {
            case .select: return .selectPress
            case .backward: return .navBack
            case .forward: return .navFwd
            }
        }

        var double: ButtonGesture {
            switch self {
            case .select: return .selectDouble
            case .backward: return .navBackDouble
            case .forward: return .navFwdDouble
            }
        }

        var long: ButtonGesture {
            switch self {
            case .select: return .selectLong
            case .backward: return .navBackLong
            case .forward: return .navFwdLong
            }
        }
    }

    public struct Configuration: Sendable, Equatable {
        /// Gesture → action (read on every press, so changes apply live).
        public var buttonMap: [ButtonGesture: ButtonAction]
        public var timing: ButtonTiming
        /// Handlebar buttons drive the dash UI (`controlAa`). Off → events are ignored.
        public var captureEnabled: Bool
        /// Fire singles immediately (Android default and every preset). Off = wait the double-tap
        /// window before committing a single (Android's deferred path).
        public var snappySingles: Bool
        /// Fire a mapped hold at the threshold during `tick` (Android's key-repeat path).
        public var holdFiresAtThreshold: Bool

        public init(buttonMap: [ButtonGesture: ButtonAction] = HandlebarPresets.iosDefaultMapping,
                    timing: ButtonTiming = ButtonTiming(), captureEnabled: Bool = true,
                    snappySingles: Bool = true, holdFiresAtThreshold: Bool = true) {
            self.buttonMap = buttonMap
            self.timing = timing
            self.captureEnabled = captureEnabled
            self.snappySingles = snappySingles
            self.holdFiresAtThreshold = holdFiresAtThreshold
        }

        /// From a bike's resolved settings (`buttonMap`, `buttonTiming`, `handlebarControl`).
        public init(settings: BikeSettings, snappySingles: Bool = true, holdFiresAtThreshold: Bool = true) {
            self.init(buttonMap: settings.buttonMap, timing: settings.buttonTiming, captureEnabled: settings.handlebarControl,
                      snappySingles: snappySingles, holdFiresAtThreshold: holdFiresAtThreshold)
        }
    }

    /// No ▲/▼ for this long while streaming → the volume rocker is marked ABSENT.
    public static let absentVolumeProbeMs: Int64 = 90_000
    /// A coalesced volume jump of at least this many steps is a double tap.
    public static let doubleTapSteps = 3

    private struct Tap {
        var lastAt: Int64 = 0
        /// Pending timer: deadline + whether it fires the single (deferred path) or only expires.
        var pendingDeadline: Int64?
        var pendingFiresSingle = false
    }

    private struct Held {
        var downAt: Int64?
        var longFromRepeat = false
    }

    private let lock = NSLock()
    private let clock: MonotonicClock
    private var config: Configuration
    private var taps: [ButtonGesture: Tap] = [:]
    private var held: [Channel: Held] = [:]
    private var presenceState: HandlebarPresence
    private var streamingSinceMs: Int64?
    private var presenceCallback: (@Sendable (HandlebarPresence) -> Void)?
    // collected while locked, emitted after unlocking
    private var logLines: [String] = []
    private var presenceDirty = false

    public init(configuration: Configuration = Configuration(), presence: HandlebarPresence = HandlebarPresence(),
                clock: MonotonicClock = SystemMonotonicClock()) {
        self.config = configuration
        self.presenceState = presence
        self.clock = clock
    }

    // MARK: - Configuration / state

    public var configuration: Configuration {
        get { lock.lock(); defer { lock.unlock() }; return config }
        set {
            lock.lock()
            config = newValue
            if !newValue.captureEnabled { cancelAllLocked() }
            lock.unlock()
        }
    }

    public var presence: HandlebarPresence {
        lock.lock(); defer { lock.unlock() }
        return presenceState
    }

    /// Called (outside the engine's lock) when presence changes — persist it per bike.
    public var onPresenceChange: (@Sendable (HandlebarPresence) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return presenceCallback }
        set { lock.lock(); presenceCallback = newValue; lock.unlock() }
    }

    /// Replaces the presence (Teach my handlebar / per-bike load).
    public func setPresence(_ p: HandlebarPresence) {
        lock.lock(); presenceState = p; lock.unlock()
    }

    /// Cancels pending taps and holds (capture off, mode switch).
    public func reset() {
        lock.lock(); cancelAllLocked(); lock.unlock()
    }

    private func cancelAllLocked() {
        taps.removeAll()
        held.removeAll()
    }

    /// The dash started pulling video (starts the 90 s volume-rocker probe).
    public func streamingStarted(atMs now: Int64) {
        lock.lock()
        if streamingSinceMs == nil { streamingSinceMs = now }
        lock.unlock()
    }

    public func streamingStarted() { streamingStarted(atMs: nowMs()) }

    /// Streaming stopped (the probe restarts at the next start).
    public func streamingStopped() {
        lock.lock(); streamingSinceMs = nil; lock.unlock()
    }

    private func nowMs() -> Int64 { Self.milliseconds(clock.now()) }

    static func milliseconds(_ seconds: TimeInterval) -> Int64 { Int64((seconds * 1000).rounded()) }

    // MARK: - Raw events

    /// Handles a raw handlebar event at the engine clock's current time.
    @discardableResult
    public func handle(_ event: HandlebarRawEvent) -> [HandlebarCommand] { handle(event, atMs: nowMs()) }

    /// Handles a raw handlebar event at `seconds` (monotonic).
    @discardableResult
    public func handle(_ event: HandlebarRawEvent, at seconds: TimeInterval) -> [HandlebarCommand] {
        handle(event, atMs: Self.milliseconds(seconds))
    }

    /// Handles a raw event as delivered by the Apple adapter (`HandlebarRemoteEvent`: raw event,
    /// monotonic seconds, volume step count). For `.volumeUp` / `.volumeDown`, `steps` (≥ 1) is the
    /// size of the coalesced jump (≥ 3 → double); it is ignored for the other events.
    @discardableResult
    public func handle(_ event: HandlebarRawEvent, at seconds: TimeInterval, steps: Int) -> [HandlebarCommand] {
        let now = Self.milliseconds(seconds)
        switch event {
        case .volumeUp: return volumeChange(steps: max(1, steps), atMs: now)
        case .volumeDown: return volumeChange(steps: -max(1, steps), atMs: now)
        default: return handle(event, atMs: now)
        }
    }

    /// Handles a raw handlebar event at `now` (ms, monotonic).
    @discardableResult
    public func handle(_ event: HandlebarRawEvent, atMs now: Int64) -> [HandlebarCommand] {
        switch event {
        case .select: return tap(.select, atMs: now)
        case .forward: return tap(.forward, atMs: now)
        case .backward: return tap(.backward, atMs: now)
        case .forwardHoldBegan: return press(.forward, atMs: now)
        case .forwardHoldEnded: return release(.forward, atMs: now)
        case .backwardHoldBegan: return press(.backward, atMs: now)
        case .backwardHoldEnded: return release(.backward, atMs: now)
        case .volumeUp: return volumeChange(steps: 1, atMs: now)
        case .volumeDown: return volumeChange(steps: -1, atMs: now)
        }
    }

    // MARK: - Lower-level inputs (also used by tests / other adapters)

    /// A discrete press without press/release timing (remote command, Lock Screen, on-phone pad).
    @discardableResult
    public func tap(_ channel: Channel, atMs now: Int64) -> [HandlebarCommand] {
        perform(now) { out in
            guard config.captureEnabled else { return }
            markTrackSeenLocked()
            out += detectDoubleTapLocked(channel.single, channel.double, forceDouble: false, now: now)
        }
    }

    /// Key down (seek began).
    @discardableResult
    public func press(_ channel: Channel, atMs now: Int64) -> [HandlebarCommand] {
        perform(now) { _ in
            guard config.captureEnabled else { return }
            markTrackSeenLocked()
            var h = held[channel] ?? Held()
            if h.downAt != nil { return } // a second DOWN while held is ignored
            h.downAt = now
            held[channel] = h
        }
    }

    /// Key repeat while held (Android `repeatCount > 0`): fires the hold once if it is mapped.
    @discardableResult
    public func keyRepeat(_ channel: Channel, atMs now: Int64) -> [HandlebarCommand] {
        perform(now) { out in
            guard config.captureEnabled else { return }
            markTrackSeenLocked()
            out += fireHoldFromRepeatLocked(channel, now: now, reason: "key-repeat")
        }
    }

    /// Key up (seek ended).
    @discardableResult
    public func release(_ channel: Channel, atMs now: Int64) -> [HandlebarCommand] {
        perform(now) { out in
            guard config.captureEnabled else { return }
            var h = held[channel] ?? Held()
            if h.longFromRepeat {
                held[channel] = Held()
                return
            }
            guard let downAt = h.downAt else { return } // UP without our DOWN
            h.downAt = nil
            held[channel] = h
            let heldMs = now - downAt
            let holdsOn = config.timing.holdsEnabled
            let isLong = holdsOn && heldMs >= Int64(ButtonTiming.normalizedHoldMs(config.timing.holdMs))
            logLines.append("\(channel.rawValue) held \(heldMs)ms \u{2192} " + (isLong ? "long press" : (holdsOn ? "tap" : "tap (hold detection off)")))
            if isLong {
                taps[channel.single]?.pendingDeadline = nil
                out += runGestureLocked(channel.long, now: now)
            } else {
                out += detectDoubleTapLocked(channel.single, channel.double, forceDouble: false, now: now)
            }
        }
    }

    /// AVRCP absolute-volume change of `steps` (signed; ▲ = positive = backward). |steps| ≥ 3 is a
    /// coalesced double tap. 0 is ignored.
    @discardableResult
    public func volumeChange(steps: Int, atMs now: Int64) -> [HandlebarCommand] {
        perform(now) { out in
            guard config.captureEnabled, steps != 0 else { return }
            markVolumeSeenLocked()
            let up = steps > 0
            let force = abs(steps) >= Self.doubleTapSteps
            logLines.append("volume \(up ? "UP" : "DOWN") (jump=\(steps))" + (force ? " \u{00D7}2" : ""))
            let channel: Channel = up ? .backward : .forward
            out += detectDoubleTapLocked(channel.single, channel.double, forceDouble: force, now: now)
        }
    }

    /// Advances time: fires deferred singles, holds reaching the threshold (when mapped) and the
    /// presence probe. Call it at `nextDeadlineMs()` (or periodically).
    @discardableResult
    public func tick(atMs now: Int64) -> [HandlebarCommand] {
        perform(now) { out in
            out += holdsAtThresholdLocked(now: now)
            probePresenceLocked(now: now)
        }
    }

    @discardableResult
    public func tick() -> [HandlebarCommand] { tick(atMs: nowMs()) }

    /// The earliest time (ms) at which `tick` has something to do, or nil.
    public func nextDeadlineMs() -> Int64? {
        lock.lock(); defer { lock.unlock() }
        var candidates: [Int64] = []
        for (_, t) in taps where t.pendingFiresSingle {
            if let d = t.pendingDeadline { candidates.append(d) }
        }
        if config.captureEnabled && config.holdFiresAtThreshold && config.timing.holdsEnabled {
            for (ch, h) in held {
                if let down = h.downAt, actionLocked(ch.long) != ButtonAction.none {
                    candidates.append(down + Int64(ButtonTiming.normalizedHoldMs(config.timing.holdMs)))
                }
            }
        }
        if config.captureEnabled, presenceState.volumeRocker == .unknown, let s = streamingSinceMs {
            candidates.append(s + Self.absentVolumeProbeMs)
        }
        return candidates.min()
    }

    // MARK: - Core (lock held)

    /// Runs `body` under the lock after firing timers due at `now`, then emits logs / callbacks.
    private func perform(_ now: Int64, _ body: (inout [HandlebarCommand]) -> Void) -> [HandlebarCommand] {
        lock.lock()
        var out = fireDueTimersLocked(now: now)
        body(&out)
        let lines = logLines
        logLines.removeAll()
        let notify = presenceDirty ? presenceCallback : nil
        let p = presenceState
        presenceDirty = false
        lock.unlock()
        for l in lines { Log.d("BTN", l) }
        notify?(p)
        return out
    }

    /// The action mapped to `gesture` (Android default when missing).
    private func actionLocked(_ gesture: ButtonGesture) -> ButtonAction {
        config.buttonMap[gesture] ?? gesture.defaultAction
    }

    /// Fires deferred singles whose window ended at or before `now` (in deadline order) and drops
    /// expired snappy markers.
    private func fireDueTimersLocked(now: Int64) -> [HandlebarCommand] {
        var due: [(Int64, ButtonGesture)] = []
        for (g, t) in taps {
            guard let d = t.pendingDeadline, d <= now else { continue }
            taps[g]?.pendingDeadline = nil
            if t.pendingFiresSingle { due.append((d, g)) }
        }
        var out: [HandlebarCommand] = []
        for (d, g) in due.sorted(by: { $0.0 < $1.0 }) {
            out += runGestureLocked(g, now: d)
        }
        return out
    }

    /// Whether a single waits out the double-tap window before it fires (the deferred path) instead of
    /// firing at once (snappy). Snappy fires the single and then, on a quick second press, the double on
    /// top of it: fine while the double only adds to what the single did, wrong when the double CHOOSES.
    /// With ★ = next and ★★ = choose (the single-button option) the first ★ would move the focus and the
    /// second activate the item after the one the rider saw focused («Terminar» instead of «Seguir» on
    /// the End card). So a double mapped to Select defers its single (FINAL: "★ = next, ★★ = choose, with
    /// the single deferred"), and a double that repeats its own single is two singles at any tempo.
    private func defersSingleLocked(_ single: ButtonGesture, _ double: ButtonGesture) -> Bool {
        let singleAction = actionLocked(single), doubleAction = actionLocked(double)
        if doubleAction == singleAction { return false }
        if doubleAction == .select { return true }
        return !config.snappySingles
    }

    private func detectDoubleTapLocked(_ single: ButtonGesture, _ double: ButtonGesture, forceDouble: Bool, now: Int64) -> [HandlebarCommand] {
        var ch = taps[single] ?? Tap()
        let gap = now - ch.lastAt
        ch.lastAt = now
        let window = Int64(ButtonTiming.normalizedDoubleTapMs(config.timing.doubleTapMs))
        if forceDouble {
            ch.pendingDeadline = nil
            taps[single] = ch
            return runGestureLocked(double, now: now)
        }
        if !defersSingleLocked(single, double) {
            if ch.pendingDeadline != nil && gap >= 1 && gap < window {
                ch.pendingDeadline = nil
                taps[single] = ch
                return runGestureLocked(double, now: now)
            }
            ch.pendingDeadline = now + window  // only "arms" a possible ×2
            ch.pendingFiresSingle = false
            taps[single] = ch
            return runGestureLocked(single, now: now)
        }
        // Deferred path: wait the window before committing a single.
        let wasPending = ch.pendingDeadline != nil
        ch.pendingDeadline = nil
        if wasPending {
            taps[single] = ch
            return runGestureLocked(double, now: now)
        }
        ch.pendingDeadline = now + window
        ch.pendingFiresSingle = true
        taps[single] = ch
        return []
    }

    private func fireHoldFromRepeatLocked(_ channel: Channel, now: Int64, reason: String) -> [HandlebarCommand] {
        guard config.timing.holdsEnabled else { return [] } // hold detection off: a long press stays a tap
        var h = held[channel] ?? Held()
        guard !h.longFromRepeat, actionLocked(channel.long) != ButtonAction.none else { return [] }
        logLines.append("\(channel.rawValue) \(reason) \u{2192} long press")
        h.longFromRepeat = true
        h.downAt = nil
        held[channel] = h
        taps[channel.single]?.pendingDeadline = nil
        return runGestureLocked(channel.long, now: now)
    }

    private func holdsAtThresholdLocked(now: Int64) -> [HandlebarCommand] {
        guard config.captureEnabled, config.holdFiresAtThreshold else { return [] }
        let threshold = Int64(ButtonTiming.normalizedHoldMs(config.timing.holdMs))
        var out: [HandlebarCommand] = []
        for ch in Channel.allCases {
            guard let down = held[ch]?.downAt, now - down >= threshold else { continue }
            out += fireHoldFromRepeatLocked(ch, now: down + threshold, reason: "held \(threshold)ms")
        }
        return out
    }

    private func runGestureLocked(_ gesture: ButtonGesture, now: Int64) -> [HandlebarCommand] {
        guard config.captureEnabled else { return [] } // media mode: leave the buttons to music
        let action = actionLocked(gesture)
        logLines.append("\(gesture.englishLabel) \u{2192} \(action.englishLabel)")
        return [HandlebarCommand(gesture: gesture, action: action, timeMs: now)]
    }

    private func markTrackSeenLocked() {
        if presenceState.trackKeys != .present {
            presenceState.trackKeys = .present
            presenceDirty = true
            logLines.append("track keys marked PRESENT (event seen)")
        }
    }

    private func markVolumeSeenLocked() {
        if presenceState.volumeRocker != .present {
            presenceState.volumeRocker = .present
            presenceDirty = true
            logLines.append("volume rocker marked PRESENT (event seen)")
        }
    }

    private func probePresenceLocked(now: Int64) {
        guard config.captureEnabled, presenceState.volumeRocker == .unknown, let s = streamingSinceMs,
              now - s >= Self.absentVolumeProbeMs else { return }
        presenceState.volumeRocker = .absent
        presenceDirty = true
        logLines.append("no volume \u{25B2}/\u{25BC} for \(Self.absentVolumeProbeMs / 1000)s while streaming \u{2014} marking rocker ABSENT, unpinning")
    }
}
