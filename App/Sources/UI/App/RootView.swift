// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) MainActivity.kt (first-run gate, error dialogs §7.5.8, scanner
// on "no bike", mirror / map hand-offs) adapted to one SwiftUI NavigationStack.
//
// RootView owns:
// - the NavigationStack (typed `MainRoute` destinations; Home pushes them),
// - the onboarding gate (`permissions.hasCompletedOnboarding`),
// - the app-wide overlays: transient banner, ConnectionIssue alerts, the "Import settings?"
//   confirmation of a pack opened from another app, the manual Wi-Fi join sheet, the root QR
//   scanner sheet and the pocket-mode («Modo bolsillo») full-screen cover,
// - the dash's "type on phone" request when the top screen has no search field (back to Home),
// - UI/UX P0: the «Modo bolsillo» countdown card after Connect / Go (PocketCountdownCard.swift) and
//   what only the UI knows about it — the keyboard or a root sheet is up, or the rider moved to
//   another screen: the phone is in use, so no countdown runs then (UX-01); an opened GPX track
//   opens the Map hub, which shows it as a preview (UX-17).
// Alerts are attached to exactly one level at a time (the root when nothing is presented, else
// inside the presented sheet / cover) because a view that is already presenting cannot present an
// alert on iOS.

import SwiftUI
import UIKit
import Combine
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
    /// `-uiSettingsAnchor` (with `-uiScreen settings`): the Settings section to scroll to ("music").
    private let launchSettingsAnchor: String?
    @State private var launchApplied = false

    init(launchScreen: RootLaunchScreen? = nil, launchLandscape: Bool = false, launchDashSheet: String? = nil,
         launchSettingsAnchor: String? = nil) {
        self.launchScreen = launchScreen
        self.launchLandscape = launchLandscape
        self.launchDashSheet = launchDashSheet
        self.launchSettingsAnchor = launchSettingsAnchor
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
        .overlay(alignment: .bottom) {
            PocketCountdownOverlay()
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
            if completed { showPendingGpx() }
        }
        .modifier(RootP0Hooks(router: router, showPendingGpx: showPendingGpx))
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

    /// Opens the `-uiScreen` destination once, after the first layout pass. A launched screen stays
    /// as launched: no «Modo bolsillo» countdown covers it (CI screenshots).
    private func applyLaunchOptions() async {
        guard !launchApplied, launchScreen != nil || launchLandscape else { return }
        launchApplied = true
        if launchScreen != nil { model.ride.offersPocketMode = false }
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
        case .gpxPreview:
            Log.i("UI", "-uiScreen gpx")
            openDemoGpxPreview()
        }
    }

    /// `-uiScreen gpx`: the demo loop opened as a GPX file while a route to Home runs, as when a track
    /// arrives from Files or AirDrop mid-ride — the Map hub shows it as a preview, nothing replaced.
    private func openDemoGpxPreview() {
        if let home = model.navigation.home { model.navigation.navigate(to: home) }
        let points = DemoRoutePlayer.defaultRoute.map { TrackPoint(lat: $0.lat, lon: $0.lon) }
        var waypoints: [TrackPoint] = []
        if let first = points.first { waypoints.append(TrackPoint(lat: first.lat, lon: first.lon, name: "Start")) }
        if points.count > 2 {
            let middle = points[points.count / 2]
            waypoints.append(TrackPoint(lat: middle.lat, lon: middle.lon, name: "Café"))
        }
        let track = GpxTrack(name: "Demo loop", points: points, waypoints: waypoints)
        model.navigation.previewGpx(data: Data(GpxWriter.write(track).utf8), fileName: "Demo loop.gpx")
    }

    /// `-uiDashSheet music`: once the Dash view shows music on the dash (≤ 5 s), open the dash's
    /// Music sheet as if the rider tapped the now-playing tile (CI screenshots). The sheet closes
    /// itself after 10 s without dash input while the bike moves (contract §3.7; the demo GPS rides)
    /// and the screenshot comes an unknown time after launch (`simctl launch` itself takes 2–9 s on
    /// CI), so the hook taps it open again every 3 s for 45 s — like a rider who keeps using it.
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
        for _ in 0 ..< 15 {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            if model.music.isShownOnDash { model.ride.performDashIntent(.openMusic) }
        }
    }

    // MARK: - Destinations

    @ViewBuilder
    private func destination(for route: MainRoute) -> some View {
        switch route {
        case .navigate: NavigateScreen()
        case .dashPreview: DashPreviewScreen()
        case .controls: ControlsScreen()
        case .settings: SettingsScreen(scrollAnchor: launchSettingsAnchor)
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

    /// Brings the Map hub up for a GPX track waiting as a preview (after the onboarding).
    private func showPendingGpx() {
        guard model.navigation.pendingGpx != nil, model.permissions.hasCompletedOnboarding else { return }
        if router.path.last != .navigate { router.path.append(.navigate) }
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

/// UI/UX P0 hooks of the root: an opened GPX track brings the Map hub up (UX-17), and what only the UI
/// knows about the «Modo bolsillo» countdown (UX-01) — the keyboard or the root scanner sheet is up, or
/// the rider moved to another screen — goes to the model, which ends a running countdown then.
private struct RootP0Hooks: ViewModifier {
    @Environment(AppModel.self) private var model
    let router: MainRouter
    let showPendingGpx: () -> Void
    /// The software keyboard is on screen (the rider is typing).
    @State private var keyboardVisible = false

    func body(content: Content) -> some View {
        content
            .onChange(of: model.navigation.pendingGpx?.id, initial: true) { _, id in
                // A GPX track opened from Files / AirDrop / Mail: the Map hub shows it as a preview with
                // «Seguir este track» / «Cancelar»; nothing is replaced before that.
                if id != nil { showPendingGpx() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardVisible = false
            }
            .onChange(of: isPhoneInUse, initial: true) { _, inUse in
                model.ride.isPhoneInUse = inUse
            }
            .onChange(of: router.path) { _, _ in
                // Another screen during the countdown: the rider is using the phone.
                if model.ride.pocketCountdown != nil { model.ride.cancelPocketCountdown() }
            }
            .onAppear {
                // Asked when an offer would start and when it runs out: a sheet, cover or alert opened
                // by any screen (file picker, share sheet…) — the pocket cover never goes over one.
                model.ride.isPhoneBusyNow = { RootPresentationProbe.isAnythingPresented() }
            }
    }

    /// Typing, or the root scanner sheet (the model knows its own dialogs and the manual join).
    private var isPhoneInUse: Bool {
        keyboardVisible || router.scanRequest != nil
    }
}

/// Whether UIKit shows a presentation (sheet, cover, alert) in the foreground window right now.
@MainActor
enum RootPresentationProbe {
    static func isAnythingPresented() -> Bool {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene, windowScene.activationState == .foregroundActive else {
                continue
            }
            for window in windowScene.windows where !window.isHidden {
                if window.rootViewController?.presentedViewController != nil { return true }
            }
        }
        return false
    }
}

#Preview {
    RootView()
        .environment(AppModel.preview())
        .preferredColorScheme(.dark)
}
