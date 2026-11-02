// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) MainActivity.kt (first-run gate, error dialogs §7.5.8, scanner
// on "no bike", mirror / map hand-offs) adapted to one SwiftUI NavigationStack.
//
// RootView owns:
// - the NavigationStack (typed `MainRoute` destinations; Home pushes them),
// - the onboarding gate (`permissions.hasCompletedOnboarding`),
// - the app-wide overlays: transient banner, ConnectionIssue alerts, the "Import settings?"
//   confirmation of a pack opened from another app, the manual Wi-Fi join sheet, the root QR
//   scanner sheet and the Ride Mode full-screen cover,
// - the dash's "type on phone" request when the top screen has no search field (back to Home).
// Alerts are attached to exactly one level at a time (the root when nothing is presented, else
// inside the presented sheet / cover) because a view that is already presenting cannot present an
// alert on iOS.

import SwiftUI
import OpenCfMotoAppModel
import OpenCfMotoCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var router = MainRouter()
    /// `-uiScreen` / `-uiOrientation` launch arguments (CI screenshots); nil / false in normal use.
    private let launchScreen: RootLaunchScreen?
    private let launchLandscape: Bool
    /// `-uiDashSheet` (with `-uiScreen dash`): a dash sheet to open on the Dash view ("music").
    private let launchDashSheet: String?
    @State private var launchApplied = false

    init(launchScreen: RootLaunchScreen? = nil, launchLandscape: Bool = false, launchDashSheet: String? = nil) {
        self.launchScreen = launchScreen
        self.launchLandscape = launchLandscape
        self.launchDashSheet = launchDashSheet
    }

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
        .pendingImportAlert(isActive: !isRootPresenting)
        .sheet(item: $router.scanRequest, onDismiss: runScanFollowUp) { request in
            NavigationStack {
                ScanScreen(showsCancelButton: true) { _ in
                    router.pendingFollowUp = request.followUp
                }
            }
            .connectionIssueAlert(isActive: true)
            .pendingImportAlert(isActive: true)
        }
        .sheet(item: manualJoinBinding) { prompt in
            ManualJoinPromptSheet(prompt: prompt)
                .connectionIssueAlert(isActive: true)
                .pendingImportAlert(isActive: true)
        }
        .fullScreenCover(isPresented: rideModeBinding) {
            RideModeOverlay()
                .connectionIssueAlert(isActive: true)
                .pendingImportAlert(isActive: true)
        }
        .onChange(of: model.permissions.hasCompletedOnboarding) { _, completed in
            // Settings ▸ "Show onboarding again": show it right away instead of under the stack.
            if !completed { router.path.removeAll() }
        }
        .onChange(of: model.connection.issue, initial: true) { _, issue in
            // Android: Connect without a saved bike opens the QR scanner (§7.5.4).
            guard issue == .noBikePaired else { return }
            model.connection.dismissIssue()
            if model.permissions.hasCompletedOnboarding {
                router.scan(then: .connect)
            }
        }
        .onChange(of: typeOnPhoneNeedsHome, initial: true) { _, needsHome in
            // The dash asked to type on the phone but the top screen has no search field.
            if needsHome { router.path.removeAll() }
        }
        .task { await applyLaunchOptions() }
    }

    /// The dash's "type on phone" request can be shown now, but the top screen (Settings, Trips,
    /// Controls, Garage, Logs, About, Mirror) has no search field: go back to Home, whose field takes
    /// it (MainTypeOnPhone.swift). The Map hub and the Dash view — or the one of them they pushed —
    /// take it themselves.
    private var typeOnPhoneNeedsHome: Bool {
        guard model.permissions.hasCompletedOnboarding, let top = router.path.last,
              MainTypeOnPhone.isActionable(model: model, router: router, scenePhase: scenePhase) else { return false }
        return top != .navigate && top != .dashPreview
    }

    // MARK: - Launch arguments (CI screenshots)

    /// Opens the `-uiScreen` destination once, after the first layout pass.
    private func applyLaunchOptions() async {
        guard !launchApplied, launchScreen != nil || launchLandscape else { return }
        launchApplied = true
        try? await Task.sleep(for: .milliseconds(400))
        if launchLandscape { RootLaunchOrientation.applyLandscape() }
        guard let screen = launchScreen else { return }
        switch screen {
        case .home:
            Log.i("UI", "-uiScreen home")
        case let .route(route):
            Log.i("UI", "-uiScreen \(route)")
            router.path = [route]
            if route == .dashPreview, let sheet = launchDashSheet { await openDashSheet(sheet) }
        case .onboarding:
            Log.i("UI", "-uiScreen onboarding")
            model.permissions.resetOnboarding()
        case .scan:
            Log.i("UI", "-uiScreen scan")
            router.scan(then: .none)
        case .ride:
            Log.i("UI", "-uiScreen ride")
            MainRideMode.enter(model.ride)
        }
    }

    /// `-uiDashSheet music`: once the Dash view shows music on the dash (≤ 5 s), open the dash's
    /// Music sheet as if the rider tapped the now-playing tile (CI screenshots).
    private func openDashSheet(_ name: String) async {
        guard name == "music" else {
            Log.w("UI", "-uiDashSheet \(name): unknown sheet (music)")
            return
        }
        for _ in 0 ..< 50 where !model.music.isShownOnDash {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard model.music.isShownOnDash else {
            Log.w("UI", "-uiDashSheet music: no music on the dash after 5 s")
            return
        }
        model.ride.performDashIntent(.openMusic)
        Log.i("UI", "-uiDashSheet music (dash sheet: \(model.ride.dashUIState.sheet.rawValue))")
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
