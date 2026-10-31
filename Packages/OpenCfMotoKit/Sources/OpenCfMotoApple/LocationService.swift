// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) GpxDashUi.kt (location acquisition §4.9 "Location acquisition",
// rotation-vector compass smoothing α = 0.15 on sin/cos, processing throttled to 120 ms).
//
// CoreLocation adapter producing `LocationFix` (OpenCfMotoCore Nav/NavTypes.swift) and a smoothed
// compass heading. Background behaviour follows docs/spec/ios-platform-facts.md (e) / decision 5:
// classic CLLocationManager, BestForNavigation, `.automotiveNavigation`, automatic pausing OFF,
// `allowsBackgroundLocationUpdates` ONLY while a ride is active (App Review 2.5.4), the blue
// background indicator shown, When-In-Use authorization only (no Always).

#if canImport(Foundation)
import Foundation
import OpenCfMotoCore

/// Compass smoothing of the Android map (GpxDashUi.kt): the azimuth is filtered as a unit vector
/// (`s += α·(sin r − s)`, `c += α·(cos r − c)`, heading = atan2(s, c) in 0..<360) on EVERY sample;
/// downstream processing (map rotation, UI) is throttled to one tick per `minInterval`.
public struct CompassSmoother: Sendable, Equatable {
    public static let defaultAlpha = 0.15
    public static let defaultMinInterval: TimeInterval = 0.120

    public let alpha: Double
    public let minInterval: TimeInterval
    /// Latest smoothed heading (updated on every sample), degrees 0..<360.
    public private(set) var heading: Double?
    private var s = 0.0
    private var c = 0.0
    private var lastTick: TimeInterval?

    public init(alpha: Double = CompassSmoother.defaultAlpha, minInterval: TimeInterval = CompassSmoother.defaultMinInterval) {
        self.alpha = alpha
        self.minInterval = minInterval
    }

    /// Feeds one raw heading (degrees). Returns the smoothed heading when a processing tick is due
    /// (≥ `minInterval` since the previous tick; the first sample always ticks), else nil.
    public mutating func update(rawDegrees: Double, now: TimeInterval) -> Double? {
        let r = rawDegrees * .pi / 180
        if heading == nil {
            s = sin(r)
            c = cos(r)
        } else {
            s += alpha * (sin(r) - s)
            c += alpha * (cos(r) - c)
        }
        var az = atan2(s, c) * 180 / .pi
        if az < 0 { az += 360 }
        if az >= 360 - 1e-9 { az = 0 } // −0.0000…1° must read as north, not 359.999…
        heading = az
        if let last = lastTick, now - last < minInterval { return nil }
        lastTick = now
        return az
    }

    public mutating func reset() {
        heading = nil
        s = 0
        c = 0
        lastTick = nil
    }

    /// CLHeading → raw degrees: `trueHeading` when valid (≥ 0), else `magneticHeading`; nil when the
    /// heading is invalid (`headingAccuracy` < 0) or both values are negative.
    public static func rawHeading(trueHeading: Double, magneticHeading: Double, accuracy: Double) -> Double? {
        guard accuracy >= 0 else { return nil }
        if trueHeading >= 0 { return trueHeading.truncatingRemainder(dividingBy: 360) }
        if magneticHeading >= 0 { return magneticHeading.truncatingRemainder(dividingBy: 360) }
        return nil
    }
}

/// CLLocation values → `LocationFix` (Foundation-only so it is unit-tested on Linux).
public enum LocationFixConversion {
    /// - speed < 0 → nil (unknown), course < 0 → nil, horizontalAccuracy < 0 → nil (and such a
    ///   fix is invalid: see `isValid`), altitude only when verticalAccuracy ≥ 0, time in ms.
    public static func fix(latitude: Double, longitude: Double, speed: Double, course: Double,
                           horizontalAccuracy: Double, altitude: Double, verticalAccuracy: Double,
                           timestamp: Date) -> LocationFix {
        LocationFix(
            lat: latitude,
            lon: longitude,
            speedMps: speed >= 0 ? speed : nil,
            courseDeg: course >= 0 ? course : nil,
            accuracyM: horizontalAccuracy >= 0 ? horizontalAccuracy : nil,
            altitudeM: verticalAccuracy >= 0 ? altitude : nil,
            timeMs: Int64((timestamp.timeIntervalSince1970 * 1000).rounded())
        )
    }

    /// CoreLocation marks an invalid coordinate with a negative horizontal accuracy.
    public static func isValid(latitude: Double, longitude: Double, horizontalAccuracy: Double) -> Bool {
        horizontalAccuracy >= 0 && (-90 ... 90).contains(latitude) && (-180 ... 180).contains(longitude)
    }
}

/// Location authorization as seen by the app (CoreLocation-free so the UI/model can use it anywhere).
public enum LocationAuthorization: String, Sendable, Equatable, CaseIterable {
    case notDetermined, restricted, denied, whenInUse, always

    public var isAuthorized: Bool { self == .whenInUse || self == .always }
}
#endif

#if canImport(CoreLocation) && os(iOS)
import CoreLocation

/// CoreLocation service for rides: fixes, smoothed heading and authorization, as callbacks and
/// AsyncStreams. Main-actor isolated: create it on the main thread (CoreLocation delivers delegate
/// callbacks on the run loop of the creating thread).
///
/// Typical use: `requestWhenInUseAuthorization()` (onboarding), observe `authorizationChanges()`,
/// then `start(rideActive:)` once authorized; `stop()` at the end of the ride.
///
/// Background: with `UIBackgroundModes` = location, calling `start(rideActive: true)` (or
/// `setRideActive(true)`) from the FOREGROUND keeps the process running while locked. Outside a ride
/// background updates are off (App Review 2.5.4). When-In-Use is enough (blue indicator shown).
@MainActor
public final class LocationService: NSObject, CLLocationManagerDelegate {
    public struct Configuration: Sendable, Equatable {
        public var desiredAccuracy: Double
        /// Metres; `kCLDistanceFilterNone` (every fix) by default.
        public var distanceFilter: Double
        public var headingEnabled: Bool
        public var headingAlpha: Double
        public var headingInterval: TimeInterval

        public init(desiredAccuracy: Double = kCLLocationAccuracyBestForNavigation,
                    distanceFilter: Double = kCLDistanceFilterNone, headingEnabled: Bool = true,
                    headingAlpha: Double = CompassSmoother.defaultAlpha,
                    headingInterval: TimeInterval = CompassSmoother.defaultMinInterval) {
            self.desiredAccuracy = desiredAccuracy
            self.distanceFilter = distanceFilter
            self.headingEnabled = headingEnabled
            self.headingAlpha = headingAlpha
            self.headingInterval = headingInterval
        }
    }

    private let manager: CLLocationManager
    private let clock: any MonotonicClock
    private var smoother: CompassSmoother
    private let fixBroadcaster = OCMPlatformBroadcaster<LocationFix>()
    private let headingBroadcaster = OCMPlatformBroadcaster<Double>()
    private let authorizationBroadcaster = OCMPlatformBroadcaster<LocationAuthorization>()

    public var configuration: Configuration {
        didSet { applyConfiguration() }
    }

    public private(set) var authorization: LocationAuthorization
    /// Precise (full accuracy) location granted.
    public private(set) var isPreciseLocation: Bool
    public private(set) var isUpdating = false
    public private(set) var isRideActive = false
    public private(set) var lastFix: LocationFix?
    /// Latest smoothed compass heading (degrees, 0..<360).
    public private(set) var heading: Double?

    public var onFix: ((LocationFix) -> Void)?
    /// Smoothed heading, at most every `headingInterval` (120 ms).
    public var onHeading: ((Double) -> Void)?
    /// Every valid RAW compass sample (degrees, true north when available, unfiltered and
    /// unthrottled). Feed THIS into `NavigationSession.updateHeading(_:)`, which applies the same
    /// α = 0.15 filter and 120 ms throttle itself — feeding `onHeading` there would filter twice.
    public var onRawHeading: ((Double) -> Void)?
    public var onAuthorizationChange: ((LocationAuthorization) -> Void)?
    public var onError: ((Error) -> Void)?

    public init(configuration: Configuration = Configuration(), clock: any MonotonicClock = SystemMonotonicClock()) {
        let m = CLLocationManager()
        self.manager = m
        self.clock = clock
        self.configuration = configuration
        self.smoother = CompassSmoother(alpha: configuration.headingAlpha, minInterval: configuration.headingInterval)
        self.authorization = Self.map(m.authorizationStatus)
        self.isPreciseLocation = m.accuracyAuthorization == .fullAccuracy
        super.init()
        m.delegate = self
        applyConfiguration()
    }

    /// Stream of fixes (starts with the last fix, if any).
    public func fixes() -> AsyncStream<LocationFix> { fixBroadcaster.stream(initial: lastFix) }

    /// Stream of smoothed headings.
    public func headings() -> AsyncStream<Double> { headingBroadcaster.stream(initial: heading) }

    /// Stream of authorization changes (starts with the current state).
    public func authorizationChanges() -> AsyncStream<LocationAuthorization> {
        authorizationBroadcaster.stream(initial: authorization)
    }

    /// Asks for When-In-Use authorization (never Always).
    public func requestWhenInUseAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    /// Starts location (and heading) updates. Call from the foreground at ride start.
    public func start(rideActive: Bool = false) {
        setRideActive(rideActive)
        manager.startUpdatingLocation()
        if configuration.headingEnabled, CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
        isUpdating = true
        Log.i("LOC", "location updates started (ride=\(rideActive))")
    }

    /// Stops all updates and background location.
    public func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        setRideActive(false)
        isUpdating = false
        smoother.reset()
        Log.i("LOC", "location updates stopped")
    }

    /// Enables background location only while a ride / navigation is active. Requires the
    /// `location` UIBackgroundModes entry (checked: setting the flag without it is a fatal error).
    public func setRideActive(_ active: Bool) {
        isRideActive = active
        let allowed = active && Self.backgroundLocationDeclared
        if active && !allowed { Log.w("LOC", "UIBackgroundModes lacks 'location' — background updates disabled") }
        manager.allowsBackgroundLocationUpdates = allowed
        manager.showsBackgroundLocationIndicator = true
    }

    /// Orientation used to report the heading (match how the phone is mounted).
    public var headingOrientation: CLDeviceOrientation {
        get { manager.headingOrientation }
        set { manager.headingOrientation = newValue }
    }

    static var backgroundLocationDeclared: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("location") ?? false
    }

    private func applyConfiguration() {
        manager.desiredAccuracy = configuration.desiredAccuracy
        manager.distanceFilter = configuration.distanceFilter
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.headingFilter = kCLHeadingFilterNone
        smoother = CompassSmoother(alpha: configuration.headingAlpha, minInterval: configuration.headingInterval)
    }

    static func map(_ s: CLAuthorizationStatus) -> LocationAuthorization {
        switch s {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorizedWhenInUse: return .whenInUse
        case .authorizedAlways: return .always
        @unknown default: return .notDetermined
        }
    }

    // MARK: Delegate (CoreLocation calls these on the main run loop — see init note)

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated { self.handle(locations) }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let t = newHeading.trueHeading
        let m = newHeading.magneticHeading
        let a = newHeading.headingAccuracy
        MainActor.assumeIsolated { self.handleHeading(trueHeading: t, magneticHeading: m, accuracy: a) }
    }

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { self.refreshAuthorization() }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { self.handleError(error) }
    }

    // MARK: Private

    private func handle(_ locations: [CLLocation]) {
        for loc in locations {
            let c = loc.coordinate
            guard LocationFixConversion.isValid(latitude: c.latitude, longitude: c.longitude,
                                                horizontalAccuracy: loc.horizontalAccuracy) else { continue }
            let fix = LocationFixConversion.fix(latitude: c.latitude, longitude: c.longitude, speed: loc.speed,
                                                course: loc.course, horizontalAccuracy: loc.horizontalAccuracy,
                                                altitude: loc.altitude, verticalAccuracy: loc.verticalAccuracy,
                                                timestamp: loc.timestamp)
            lastFix = fix
            onFix?(fix)
            fixBroadcaster.yield(fix)
        }
    }

    private func handleHeading(trueHeading: Double, magneticHeading: Double, accuracy: Double) {
        guard let raw = CompassSmoother.rawHeading(trueHeading: trueHeading, magneticHeading: magneticHeading,
                                                   accuracy: accuracy) else { return }
        onRawHeading?(raw)
        guard let h = smoother.update(rawDegrees: raw, now: clock.now()) else { return }
        heading = h
        onHeading?(h)
        headingBroadcaster.yield(h)
    }

    private func refreshAuthorization() {
        let a = Self.map(manager.authorizationStatus)
        isPreciseLocation = manager.accuracyAuthorization == .fullAccuracy
        guard a != authorization else { return }
        authorization = a
        Log.i("LOC", "location authorization: \(a.rawValue)\(isPreciseLocation ? "" : " (approximate)")")
        onAuthorizationChange?(a)
        authorizationBroadcaster.yield(a)
    }

    private func handleError(_ error: Error) {
        if let e = error as? CLError, e.code == .locationUnknown { return } // transient, keeps trying
        Log.w("LOC", "location error: \(error.localizedDescription)")
        onError?(error)
    }
}
#endif
