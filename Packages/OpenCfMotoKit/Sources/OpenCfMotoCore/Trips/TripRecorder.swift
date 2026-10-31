// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) TripRecorder.kt, TripAutoLog.kt
//
// Ride recorder state machine (app-features.md §5.3–§5.4). Constants are Android's:
// moving ⇔ speed ≥ 0.8 m/s; distance and moving time accumulate only for moving fixes with
// 1 ≤ dt ≤ 5000 ms; a leg auto-splits after > 180 000 ms without movement (once it has distance);
// a leg is saved only if ≥ 100 m AND ≥ 15 000 ms moving AND ≥ 2 points. Every fix is appended.
//
// iOS changes (app-features.md §13.5): `dt`, the idle-split clock and the point time come from the
// FIX timestamps (`LocationFix.timeMs`) instead of the callback time — iOS may batch deliveries, which
// would make callback deltas ≈ 0. A leg split by idleness ends (and the next one starts) at the time
// of the fix that triggered the split. Manual start/stop use the injected wall clock.
// The recorder does not talk to CoreLocation: the app feeds it `LocationFix`es.

import Foundation

public final class TripRecorder: @unchecked Sendable {
    // MARK: Constants (TripRecorder.kt:181-186)

    /// Below this speed the bike counts as stopped (≈ 2.9 km/h).
    public static let minMovingSpeedMs: Float = 0.8
    /// Parked longer than this → the leg is saved and a new one begins.
    public static let idleSplitMs: Int64 = 180_000
    public static let minSaveDistanceM: Double = 100.0
    public static let minSaveTimeMs: Int64 = 15_000
    /// Only fix gaps in 1…5000 ms count toward distance / moving time.
    public static let segmentWindowMs: ClosedRange<Int64> = 1 ... 5000

    /// Live statistics (`TripRecorder.Stats`).
    public struct Stats: Sendable, Equatable {
        public var recording: Bool
        public var speedKmh: Int
        public var distanceMeters: Double
        public var movingTimeMs: Int64
        public var maxSpeedMs: Float
        public var hasFix: Bool
        public var accuracyM: Int

        public init(recording: Bool = false, speedKmh: Int = 0, distanceMeters: Double = 0, movingTimeMs: Int64 = 0,
                    maxSpeedMs: Float = 0, hasFix: Bool = false, accuracyM: Int = 0) {
            self.recording = recording
            self.speedKmh = speedKmh
            self.distanceMeters = distanceMeters
            self.movingTimeMs = movingTimeMs
            self.maxSpeedMs = maxSpeedMs
            self.hasFix = hasFix
            self.accuracyM = accuracyM
        }
    }

    public typealias DistanceFunction = @Sendable (_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Float

    private let lock = NSLock()
    private let store: TripStore?
    private let wallClockMs: @Sendable () -> Int64
    private let distance: DistanceFunction
    private var callbacks: (stats: (@Sendable (Stats) -> Void)?, saved: (@Sendable (Trip) -> Void)?) = (nil, nil)

    // state
    private var recordingFlag = false
    private var points: [TripPoint] = []
    private var distanceMeters = 0.0
    private var movingTimeMs: Int64 = 0
    private var maxSpeedMs: Float = 0
    private var startTime: Int64 = 0
    private var lastFix: LocationFix?
    private var lastFixAt: Int64 = 0
    private var lastMovingAt: Int64 = 0
    private var hasFix = false
    private var lastAccuracy = 0
    private var curSpeedKmh = 0
    /// Log lines produced under the lock, emitted after unlocking (tag `trip`).
    private var pendingLog: [(LogLevel, String)] = []

    /// - Parameters:
    ///   - store: where finalised legs are saved (nil = only `onTripSaved` / return values).
    ///   - wallClockMs: epoch-ms clock for manual start/stop (injectable for tests).
    ///   - distance: metres between two fixes (default: Android's `Location.distanceTo`).
    public init(store: TripStore? = nil,
                wallClockMs: @escaping @Sendable () -> Int64 = { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) },
                distance: @escaping DistanceFunction = { TripGeodesy.androidDistance(lat1: $0, lon1: $1, lat2: $2, lon2: $3) }) {
        self.store = store
        self.wallClockMs = wallClockMs
        self.distance = distance
    }

    /// Called after every state change (outside the recorder's lock).
    public var onStats: (@Sendable (Stats) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return callbacks.stats }
        set { lock.lock(); callbacks.stats = newValue; lock.unlock() }
    }

    /// Called when a leg is saved (outside the recorder's lock).
    public var onTripSaved: (@Sendable (Trip) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return callbacks.saved }
        set { lock.lock(); callbacks.saved = newValue; lock.unlock() }
    }

    public var isRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return recordingFlag
    }

    // MARK: - Control

    /// Begins (or keeps) recording. Permission / location availability are the caller's business.
    @discardableResult
    public func start() -> Bool {
        lock.lock()
        if recordingFlag { lock.unlock(); return true }
        resetLegLocked(start: wallClockMs())
        recordingFlag = true
        let (stats, cb) = (snapshotLocked(), callbacks.stats)
        lock.unlock()
        cb?(stats)
        return true
    }

    /// Stops and saves the current leg if it is meaningful (Android "Pause" / leaving the screen).
    @discardableResult
    public func stopAndSave() -> Trip? {
        lock.lock()
        guard recordingFlag else { lock.unlock(); return nil }
        recordingFlag = false
        let trip = finalizeLegLocked(end: wallClockMs())
        curSpeedKmh = 0
        hasFix = false
        let (stats, cbs, logs) = (snapshotLocked(), callbacks, takeLogLocked())
        lock.unlock()
        emit(logs)
        if let trip { cbs.saved?(trip) }
        cbs.stats?(stats)
        return trip
    }

    /// Stops and throws the current leg away (Android "Reset").
    public func discard() {
        lock.lock()
        recordingFlag = false
        resetLegLocked(start: wallClockMs())
        curSpeedKmh = 0
        hasFix = false
        let (stats, cb) = (snapshotLocked(), callbacks.stats)
        lock.unlock()
        cb?(stats)
    }

    public func snapshot() -> Stats {
        lock.lock(); defer { lock.unlock() }
        return snapshotLocked()
    }

    /// The current leg's points (copy).
    public var currentPoints: [TripPoint] {
        lock.lock(); defer { lock.unlock() }
        return points
    }

    // MARK: - Fixes

    /// Feeds one GPS fix (`onLocationChanged`). Returns the leg saved by an idle split, if any.
    @discardableResult
    public func ingest(_ fix: LocationFix) -> Trip? {
        lock.lock()
        guard recordingFlag else { lock.unlock(); return nil }
        let now = fix.timeMs
        let prev = lastFix
        let d: Float = prev.map { distance($0.lat, $0.lon, fix.lat, fix.lon) } ?? 0
        let dt: Int64 = (prev != nil && lastFixAt > 0) ? now - lastFixAt : 0
        let inWindow = Self.segmentWindowMs.contains(dt)

        var speed: Float
        if let s = fix.speedMps {
            speed = Float(s)
        } else if inWindow {
            speed = d / (Float(dt) / 1000)
        } else {
            speed = 0
        }
        let moving = speed >= Self.minMovingSpeedMs
        if prev != nil && moving && inWindow {
            distanceMeters += Double(d)
            movingTimeMs += dt
        }
        var saved: Trip?
        if moving {
            lastMovingAt = now
        } else if lastMovingAt > 0 && now - lastMovingAt > Self.idleSplitMs && distanceMeters > 0 {
            // Parked long enough — bank this leg and start a fresh one, staying in recording mode.
            saved = finalizeLegLocked(end: now)
            resetLegLocked(start: now)
            speed = 0
        }
        if speed > maxSpeedMs { maxSpeedMs = speed }
        curSpeedKmh = TripFormat.liveSpeedKmh(speedMs: speed)
        hasFix = true
        lastAccuracy = fix.accuracyM.map { Int(AppJavaNumber.f2i(Float($0))) } ?? 0
        points.append(TripPoint(lat: fix.lat, lon: fix.lon, timeMs: now, speedMs: speed))
        lastFix = fix
        lastFixAt = now
        let (stats, cbs, logs) = (snapshotLocked(), callbacks, takeLogLocked())
        lock.unlock()
        emit(logs)
        if let saved { cbs.saved?(saved) }
        cbs.stats?(stats)
        return saved
    }

    // MARK: - Internals (lock held)

    /// Takes the pending log lines (call under the lock) for emission after unlocking.
    private func takeLogLocked() -> [(LogLevel, String)] {
        defer { pendingLog.removeAll() }
        return pendingLog
    }

    private func emit(_ lines: [(LogLevel, String)]) {
        for (level, text) in lines { Log.shared.log(level, "trip", text) }
    }

    private func resetLegLocked(start: Int64) {
        points = []
        distanceMeters = 0
        movingTimeMs = 0
        maxSpeedMs = 0
        startTime = start
        lastFix = nil
        lastFixAt = 0
        lastMovingAt = 0
    }

    private func finalizeLegLocked(end: Int64) -> Trip? {
        if distanceMeters < Self.minSaveDistanceM || movingTimeMs < Self.minSaveTimeMs || points.count < 2 { return nil }
        let trip = Trip(id: String(startTime), start: startTime, end: end, distanceMeters: distanceMeters,
                        movingTimeMs: movingTimeMs, maxSpeedMs: maxSpeedMs, points: points)
        if let store {
            do { try store.save(trip) } catch { pendingLog.append((.warn, "save failed: \(error)")) }
        }
        pendingLog.append((.info, "saved ride \(trip.distanceText) in \(trip.durationText)"))
        return trip
    }

    private func snapshotLocked() -> Stats {
        Stats(recording: recordingFlag, speedKmh: curSpeedKmh, distanceMeters: distanceMeters, movingTimeMs: movingTimeMs,
              maxSpeedMs: maxSpeedMs, hasFix: hasFix, accuracyM: lastAccuracy)
    }
}

/// When trips are recorded automatically (TripAutoLog.kt, adapted per app-features.md §5.4):
/// auto-logging runs while *Log trips automatically* is on and the dash is streaming or our dash UI is
/// live. iOS fix: a manual recording is never stopped by the automatic logic.
public enum TripAutoLogPolicy {
    public enum Action: Sendable, Equatable { case none, start, stopAndSave }

    /// Evaluate on every link-phase change and on a 5 s timer.
    /// - Parameters:
    ///   - manualRecording: the rider started the recording by hand (auto logic leaves it alone).
    public static func action(logTrips: Bool, streaming: Bool, dashUILive: Bool, recording: Bool,
                              manualRecording: Bool) -> Action {
        if manualRecording { return .none }
        let shouldRecord = logTrips && (streaming || dashUILive)
        if shouldRecord && !recording { return .start }
        if !shouldRecord && recording { return .stopAndSave }
        return .none
    }

    /// Log line for an automatic start: `auto-logging this ride (<dash + map|map|dash>)` (tag `trip`).
    public static func startLogMessage(streaming: Bool, dashUILive: Bool) -> String {
        let what: String
        switch (streaming, dashUILive) {
        case (true, true): what = "dash + map"
        case (false, true): what = "map"
        default: what = "dash"
        }
        return "auto-logging this ride (\(what))"
    }
}
