// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) MainActivity.kt (first-run gate, error dialogs §7.5.8, scanner
// on "no bike", mirror / map hand-offs) adapted to one SwiftUI NavigationStack.
//
// RootView owns:
// - the NavigationStack (typed `MainRoute` destinations; Home pushes them),
// - the onboarding gate (`permissions.hasCompletedOnboarding`),
// - the app-wide overlays: transient banner, ConnectionIssue alerts, the manual Wi-Fi join sheet,
//   the root QR scanner sheet and the Ride Mode full-screen cover.
// Alerts are attached to exactly one level at a time (the root when nothing is presented, else
// inside the presented sheet / cover) because a view that is already presenting cannot present an
// alert on iOS.

import SwiftUI
import OpenCfMotoAppModel
import OpenCfMotoCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var router = MainRouter()

    var body: some View {
        NavigationStack(path: $router.path) {
            Group {
                if model.permissions.hasCompletedOnboarding {
                    HomeScreen()
                } else {
                    OnboardingScreen()
                }
            }
            .navigationDestination(for: MainRoute.self) { route in
                destination(for: route)
            }
        }
        .environment(\.mainRouter, router)
        .overlay(alignment: .top) {
            RootBannerOverlay()
        }
        .connectionIssueAlert(isActive: !isRootPresenting)
        .sheet(item: $router.scanRequest, onDismiss: runScanFollowUp) { request in
            NavigationStack {
                ScanScreen(showsCancelButton: true) { _ in
                    router.pendingFollowUp = request.followUp
                }
            }
            .connectionIssueAlert(isActive: true)
        }
        .sheet(item: manualJoinBinding) { prompt in
            ManualJoinPromptSheet(prompt: prompt)
                .connectionIssueAlert(isActive: true)
        }
        .fullScreenCover(isPresented: rideModeBinding) {
            RideModeOverlay()
                .connectionIssueAlert(isActive: true)
        }
        .onChange(of: model.connection.issue, initial: true) { _, issue in
            // Android: Connect without a saved bike opens the QR scanner (§7.5.4).
            guard issue == .noBikePaired else { return }
            model.connection.dismissIssue()
            if model.permissions.hasCompletedOnboarding {
                router.scan(then: .connect)
            }
        }
    }

    // MARK: - Destinations

    @ViewBuilder
    private func destination(for route: MainRoute) -> some View {
        switch route {
        case .navigate: NavigateScreen()
        case .dashPreview: DashPreviewScreen()
        case .controls: ControlsScreen()
        case .settings: SettingsScreen()
        case .garage: GarageScreen()
        case .trips: TripsScreen()
        case .logs: LogsScreen()
        case .about: AboutScreen()
        case .mirror: MirrorScreen()
        }
    }

    // MARK: - Presentations

    /// Something is presented from the root (the root itself cannot show an alert then).
    private var isRootPresenting: Bool {
        router.scanRequest != nil || model.connection.manualJoin != nil || model.ride.isRideModeActive
    }

    /// The manual join prompt: shown while the model has one; a swipe-down means Cancel.
    private var manualJoinBinding: Binding<ManualWifiJoinPrompt?> {
        Binding(
            get: { model.connection.manualJoin },
            set: { newValue in
                if newValue == nil, model.connection.manualJoin != nil {
                    model.connection.cancelManualJoin()
                }
            }
        )
    }

    private var rideModeBinding: Binding<Bool> {
        Binding(
            get: { model.ride.isRideModeActive },
            set: { active in
                if !active, model.ride.isRideModeActive {
                    model.ride.exitRideMode()
                }
            }
        )
    }

    /// Runs after the scanner sheet is gone (never while it is still animating out).
    private func runScanFollowUp() {
        let followUp = router.pendingFollowUp
        router.pendingFollowUp = .none
        switch followUp {
        case .none:
            break
        case .connect:
            model.connection.connect()
        case .mirror:
            model.connection.startMirror()
        }
    }
}

#Preview {
    RootView()
        .environment(AppModel.preview())
        .preferredColorScheme(.dark)
}
