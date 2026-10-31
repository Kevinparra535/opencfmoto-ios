// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) MainActivity.kt:352-405, 1493-1529 (Mirror, app-features
// §7.5.6) for iOS ReplayKit: the whole iPhone screen goes to the dash through the broadcast upload
// extension (no touch back). Step 1 connects the bike in mirror mode (`ConnectionModel.startMirror`
// opens the App Group relay first); step 2 is the system broadcast picker, the only way iOS lets an
// app start a screen broadcast. The model guards duplicate taps (15 s) and reports in `detail`.

import SwiftUI
import OpenCfMotoAppModel
import OpenCfMotoCore

struct MirrorScreen: View {
    @Environment(AppModel.self) private var model
    @State private var showsScanner = false
    @State private var mirrorAfterScan = false

    var body: some View {
        let connection = model.connection
        let phase = connection.phase
        let inMirrorFlow = connection.mode == .mirror && (phase.isBusy || phase.isLive)
        ScrollView {
            VStack(spacing: 16) {
                explanation
                status(phase: phase, inMirrorFlow: inMirrorFlow)
                if inMirrorFlow {
                    broadcastStep
                } else {
                    connectStep(phase: phase, mode: connection.mode)
                }
                if phase.showsStop {
                    stopSection
                }
                if AppPlatform.shared.isDemoMode {
                    Label("Screen broadcast needs a real iPhone — it is not available in demo mode or the Simulator.",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(Theme.busy)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(Theme.padding)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Mirror")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsScanner, onDismiss: {
            guard mirrorAfterScan else { return }
            mirrorAfterScan = false
            model.connection.startMirror()
        }) {
            NavigationStack {
                ScanScreen(showsCancelButton: true) { _ in
                    mirrorAfterScan = true
                }
            }
        }
    }

    // MARK: - Sections

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Mirror the whole iPhone screen", systemImage: "rectangle.on.rectangle")
                .font(.headline)
                .foregroundStyle(Theme.text)
            VStack(alignment: .leading, spacing: 8) {
                bullet("Everything on the iPhone screen is sent to the dash, whatever app is open.")
                bullet("The dash can't control the iPhone: touches and handlebar buttons don't reach mirrored apps.")
                bullet("Notifications appear on the dash too — turn on a Focus (for example Driving) to keep them private.")
                bullet("Mirroring stops when the iPhone locks. To ride with the phone in your pocket, use Connect — the OpenCfMoto map.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "•")
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .foregroundStyle(Theme.textSecondary)
    }

    private func status(phase: ConnectionPhase, inMirrorFlow: Bool) -> some View {
        let tint = Theme.tint(for: phase)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: MainStrings.phaseSymbol(phase))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(MainStrings.phaseLabel(phase))
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 0)
                if phase.isBusy {
                    ProgressView().tint(Theme.brand)
                }
            }
            MainStrings.statusDetail(detail: model.connection.detail, bikeName: model.garage.selected?.name)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if inMirrorFlow {
                if model.connection.isMirrorExtensionConnected {
                    Label("Screen broadcast is running", systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.live)
                } else {
                    Label("Screen broadcast not started yet", systemImage: "circle.dashed")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.busy)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(highlighted: phase.isLive)
        .accessibilityElement(children: .combine)
    }

    private func connectStep(phase: ConnectionPhase, mode: ProjectionMode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MainSectionCaption(text: "Step 1 · Connect the bike")
            Button {
                startMirroring()
            } label: {
                if phase.isLive && mode != .mirror {
                    Label("Switch the dash to Mirror", systemImage: "rectangle.on.rectangle")
                } else {
                    Label("Connect for mirroring", systemImage: "power")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(phase.isBusy)
            Text("Then start the screen broadcast in step 2.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var broadcastStep: some View {
        VStack(spacing: 12) {
            MainSectionCaption(text: "Step 2 · Start the screen broadcast")
            ZStack {
                Circle()
                    .fill(Theme.brand)
                BroadcastPickerButton(extensionBundleID: AppPlatform.shared.broadcastExtensionBundleID)
                    .frame(width: 88, height: 88)
            }
            .frame(width: 96, height: 96)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Start screen broadcast"))
            Text("Tap the button, choose OpenCfMoto Mirror, then Start Broadcast.")
                .font(.subheadline)
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    private var stopSection: some View {
        VStack(spacing: 8) {
            Button {
                model.connection.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(TonalButtonStyle())
            Text("To end the screen broadcast, tap the red indicator in the status bar or use Control Center.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private func startMirroring() {
        // No bike yet: pair first, then start the mirror link (Android scans, then mirrors).
        guard model.garage.selected != nil else {
            showsScanner = true
            return
        }
        model.connection.startMirror()
    }
}

#Preview {
    NavigationStack {
        MirrorScreen()
    }
    .environment(AppModel.preview())
    .preferredColorScheme(.dark)
}
