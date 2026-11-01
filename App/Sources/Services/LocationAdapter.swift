// SPDX-License-Identifier: AGPL-3.0-or-later
// `LocationProviding` on iOS: OpenCfMotoApple.LocationService (CLLocationManager, When-In-Use,
// best-for-navigation fixes, background updates only while a ride is active, RAW compass samples
// for NavigationSession.updateHeading — the session filters them itself).
//
// The compass reference follows the interface orientation (review finding IOS-4): CLHeading is
// measured against `CLLocationManager.headingOrientation`, `.portrait` by default, so with the phone
// in a landscape handlebar mount the stationary heading-up dash map and puck would point 90° off
// the riding direction. Android remaps the rotation vector by the display rotation
// (GpxDashUi.kt:1170-1180); here the window scene's interface orientation is mapped to the matching
// device orientation on activation, on every geometry change and shortly after each rotation.

import Foundation
import UIKit
import CoreLocation
import OpenCfMotoCore
import OpenCfMotoApple
import OpenCfMotoAppModel

@MainActor
final class LocationAdapter: LocationProviding {
    private let service: LocationService
    private var orientationObservers: [NSObjectProtocol] = []
    private var geometryObservation: NSKeyValueObservation?
    private weak var orientationScene: UIWindowScene?

    var onFix: ((LocationFix) -> Void)? {
        didSet { service.onFix = onFix }
    }

    var onRawHeading: ((Double) -> Void)? {
        didSet { service.onRawHeading = onRawHeading }
    }

    var onPermissionChange: ((LocationPermission) -> Void)?

    init(clock: MonotonicClock) {
        service = LocationService(clock: clock)
        service.onAuthorizationChange = { [weak self] authorization in
            self?.onPermissionChange?(LocationAdapter.map(authorization))
        }
        service.onError = { error in
            Log.w("LOC", "location error: \(error.localizedDescription)")
        }
        followInterfaceOrientation()
    }

    var permission: LocationPermission { Self.map(service.authorization) }
    var isPrecise: Bool { service.isPreciseLocation }
    var isUpdating: Bool { service.isUpdating }
    var lastFix: LocationFix? { service.lastFix }

    func requestPermission() { service.requestWhenInUseAuthorization() }
    func start(rideActive: Bool) { service.start(rideActive: rideActive) }
    func setRideActive(_ active: Bool) { service.setRideActive(active) }
    func stop() { service.stop() }

    private static func map(_ a: LocationAuthorization) -> LocationPermission {
        switch a {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .whenInUse: return .whenInUse
        case .always: return .always
        }
    }

    // MARK: - Heading reference = interface orientation

    /// The app is created before its window scene exists: start following a scene once it activates.
    private func followInterfaceOrientation() {
        let center = NotificationCenter.default
        orientationObservers.append(center.addObserver(forName: UIScene.didActivateNotification, object: nil,
                                                       queue: .main) { [weak self] note in
            let scene = note.object as? UIWindowScene
            MainActor.assumeIsolated { self?.observeOrientation(of: scene) }
        })
        // Fallback in case a rotation does not report a geometry change: re-read once the interface
        // has finished rotating after the device did.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        orientationObservers.append(center.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil,
                                                       queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshOrientationSoon() }
        })
    }

    private func observeOrientation(of scene: UIWindowScene?) {
        guard let scene else { return }
        guard scene !== orientationScene else {
            refreshOrientation()
            return
        }
        orientationScene = scene
        // `effectiveGeometry` is key-value observable (iOS 16+); `.initial` applies the current value.
        geometryObservation = scene.observe(\.effectiveGeometry, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshOrientation() }
        }
    }

    private func refreshOrientationSoon() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            self?.refreshOrientation()
        }
    }

    private func refreshOrientation() {
        guard let scene = orientationScene,
              let reference = Self.headingReference(for: scene.effectiveGeometry.interfaceOrientation) else { return }
        service.headingOrientation = reference   // no-op when unchanged; resets the compass smoothing on a change
    }

    /// Interface orientation → the device orientation CoreLocation should measure headings against.
    /// UIKit defines interface `.landscapeLeft` as device `.landscapeRight` (the content rotates the
    /// opposite way to the device) and vice versa; unknown keeps the current reference.
    static func headingReference(for orientation: UIInterfaceOrientation) -> CLDeviceOrientation? {
        switch orientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        case .unknown: return nil
        @unknown default: return nil
        }
    }
}
