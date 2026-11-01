// SPDX-License-Identifier: AGPL-3.0-or-later
// Ride Mode — the iOS "pocket mode" (docs/spec/ios-platform-facts.md, design recommendation 1):
// the app stays frontmost with the idle timer disabled (RideModel), the screen is black (OLED
// pixels off) and swallows touches, and the dash keeps streaming. Minimal, static large text:
// connection phase, speed, the next maneuver. No animations. Long-press 1.5 s to exit.
// The screen brightness is lowered while the overlay is up ("lowered UIScreen.brightness, restored
// by the system at lock" — review finding UI-6): on LCD iPhones black is a lit backlight, and on
// OLED the large text would stay at full brightness for the whole ride, adding heat to the encoder,
// Wi-Fi and GPS load. Restored on exit and whenever the app leaves the foreground (an app's
// brightness would otherwise carry into other apps), re-applied when the rider comes back.
// The dash's "type on phone" request is NOT taken under this cover (the search field is hidden by
// it — review finding UI-2): it stays pending with a hint here and the visible screen takes it
// once the rider long-presses out; never answered within 2 minutes, it is dropped. Ride Mode does
// not leave by itself: in a pocket a lit screen with a keyboard would take stray touches.

import SwiftUI
import UIKit
import OpenCfMotoAppModel
import OpenCfMotoCore

/// Ride Mode's dimmed screen: saves the brightness, lowers it, and puts it back.
@MainActor
final class RideModeBrightness {
    /// Brightness while Ride Mode is on screen (a darker screen is never brightened).
    static let level: CGFloat = 0.15

    private weak var screen: UIScreen?
    private var saved: CGFloat?
    private var applied: CGFloat?

    /// Saves the current brightness and dims; a no-op while already dimmed.
    func dim() {
        guard applied == nil, let screen = Self.activeScreen() else { return }
        let current = screen.brightness
        let target = min(current, Self.level)
        self.screen = screen
        saved = current
        applied = target
        if target < current { screen.brightness = target }
    }

    /// Puts the saved brightness back, unless the rider changed it meanwhile (Control Center).
    func restore() {
        let screen = self.screen, saved = self.saved, applied = self.applied
        self.screen = nil
        self.saved = nil
        self.applied = nil
        guard let screen, let saved, let applied else { return }
        if abs(screen.brightness - applied) < 0.02 { screen.brightness = saved }
    }

    private static func activeScreen() -> UIScreen? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)?.screen
    }
}

/// Enter / leave Ride Mode without the cover's slide animation.
enum MainRideMode {
    @MainActor
    static func enter(_ ride: RideModel) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { ride.enterRideMode() }
    }

    @MainActor
    static func exit(_ ride: RideModel) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { ride.exitRideMode() }
    }
}

struct RideModeOverlay: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .largeTitle) private var speedSize: CGFloat = 92
    @State private var brightness = RideModeBrightness()

    var body: some View {
        let phase = model.connection.phase
        let ride = model.ride
        let cue = model.navigation.snapshot.cue
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 22) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Theme.tint(for: phase))
                        .frame(width: 10, height: 10)
                    Text(MainStrings.phaseLabel(phase))
                        .font(.headline)
                        .foregroundStyle(Color.white.opacity(0.6))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }

                Spacer(minLength: 0)

                if !ride.speedText.isEmpty {
                    Text(verbatim: ride.speedText)
                        .font(.system(size: speedSize, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                } else if !ride.gpsStatus.isEmpty {
                    Text(verbatim: ride.gpsStatus)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                }

                if let cue {
                    VStack(spacing: 8) {
                        HStack(spacing: 14) {
                            Image(systemName: MainStrings.turnSymbol(cue.dir))
                                .font(.system(size: 44, weight: .bold))
                                .accessibilityHidden(true)
                            Text(verbatim: cue.distanceText)
                                .font(.system(size: 44, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                        }
                        if !cue.text.isEmpty {
                            Text(verbatim: cue.text)
                                .font(.title3.weight(.semibold))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .foregroundStyle(Color.white.opacity(0.8))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text("Next: \(cue.distanceText), \(cue.text)"))
                }

                Spacer(minLength: 0)

                if model.navigation.typeOnPhoneRequested {
                    // The dash asked to type the search on the phone: the field is under this cover.
                    Label("Bike search open — long-press to exit Ride Mode, then type your search",
                          systemImage: "keyboard")
                        .font(.headline)
                        .foregroundStyle(Theme.brand)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Label("Long-press to exit", systemImage: "hand.tap")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.4))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
        }
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 1.5) {
            MainRideMode.exit(model.ride)
        }
        .task(id: model.navigation.typeOnPhoneRequested) { @MainActor in
            // A request left unanswered under Ride Mode goes stale: drop it so leaving Ride Mode at
            // the end of the ride does not pop the keyboard out of context.
            guard model.navigation.typeOnPhoneRequested else { return }
            try? await Task.sleep(for: .seconds(MainTypeOnPhone.rideModeLifetime))
            guard !Task.isCancelled, model.navigation.typeOnPhoneRequested, model.ride.isRideModeActive else { return }
            Log.i("UI", "type-on-phone request expired under Ride Mode")
            model.navigation.acknowledgeTypeOnPhone()
        }
        .onAppear {
            if scenePhase == .active { brightness.dim() }
        }
        .onDisappear {
            brightness.restore()
        }
        .onChange(of: scenePhase) { _, phase in
            // Back from the lock screen (the system restored the brightness) → dim again; leaving the
            // foreground (call, Control Center, app switcher, lock) → the rider's brightness.
            if phase == .active {
                brightness.dim()
            } else {
                brightness.restore()
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .accessibilityAction(named: Text("Exit Ride Mode")) {
            MainRideMode.exit(model.ride)
        }
    }
}

#Preview {
    RideModeOverlay()
        .environment(AppModel.preview())
}
