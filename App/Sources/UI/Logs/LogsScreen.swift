// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) MainActivity.kt (log card: Share / Clear, Report a problem),
// LogBus.kt, ProblemReport.kt
//
// Logs & diagnostics (docs/spec/app-features.md §6.1–§6.5): the live log in monospace (#9CDCFE
// on the cockpit background), a level filter, auto-scroll to the newest line, Share (a fresh
// export written when a share target is picked; passwords and serials redacted unless "Include
// secrets in shared logs" is on), Clear with confirmation, a compact link-diagnostics card, and
// "Report a problem" (what went wrong + bike model + year → text report with diagnostics + log).

import SwiftUI
import OpenCfMotoCore
import OpenCfMotoAppModel

@MainActor
struct LogsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var autoScroll = true
    @State private var confirmClear = false
    @State private var showReport = false
    @State private var shareErrors = FeatureShareErrors()

    var body: some View {
        @Bindable var logs = model.logs
        let visible = LogsFilter.visible(model.logs.entries, minimum: model.logs.minimumLevel)
        VStack(spacing: 0) {
            Picker("Level", selection: $logs.minimumLevel) {
                Text("All").tag(LogLevelTag?.none)
                Text("Info").tag(LogLevelTag?.some(.info))
                Text("Warnings").tag(LogLevelTag?.some(.warning))
                Text("Errors").tag(LogLevelTag?.some(.error))
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.padding)
            .padding(.vertical, 10)

            if model.logs.crashReport != nil {
                LogsCrashCard()
                    .padding(.horizontal, Theme.padding)
                    .padding(.bottom, 8)
            }

            LogsDiagnosticsCard()
                .padding(.horizontal, Theme.padding)
                .padding(.bottom, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if visible.isEmpty {
                            Text("No log lines yet.")
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.vertical, 24)
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(visible) { entry in
                            Text(verbatim: entry.text)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(LogsFilter.color(entry.level))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .background(Color.black.opacity(0.35))
                .onAppear {
                    if let last = visible.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: visible.last?.id) { _, newest in
                    guard autoScroll, let newest else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(newest, anchor: .bottom)
                    }
                }
            }

            HStack(spacing: 12) {
                Toggle(isOn: $autoScroll) {
                    Text("Auto-scroll")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                .toggleStyle(.switch)
                .fixedSize()
                Spacer()
                Text("\(String(visible.count)) lines")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, Theme.padding)
            .padding(.vertical, 8)

            FeatureNote(model.settings.current.includeSecretsInLogs
                        ? Text("Shared logs include passwords and serials (Settings ▸ Privacy & logs). Turn it off before posting publicly.")
                        : Text("Shared logs and reports hide Wi-Fi passwords and serial numbers. Nothing leaves the phone until you share it."))
                .padding(.horizontal, Theme.padding)
                .padding(.bottom, 10)
        }
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .featureScreenChrome()
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: FeatureLazyFile<FeatureTextKind>(make: shareErrors.guarded { [logsModel = model.logs] in
                    try logsModel.exportLogs()
                }),
                          preview: SharePreview("OpenCfMoto log")) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Menu {
                    Button {
                        showReport = true
                    } label: {
                        Label("Report a problem", systemImage: "exclamationmark.bubble")
                    }
                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Clear the log?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { model.logs.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every line shown here. Share it first if you need it.")
        }
        .alert("Export failed", isPresented: $shareErrors.isPresented) {
        } message: {
            Text(verbatim: shareErrors.message ?? "")
        }
        .sheet(isPresented: $showReport) {
            NavigationStack {
                LogsProblemReportForm()
            }
            .environment(model)
        }
    }
}

/// Link + projection numbers from ConnectionModel.diagnostics (developer-facing values stay English).
@MainActor
struct LogsDiagnosticsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let diagnostics = model.connection.diagnostics
        DisclosureGroup {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Link")
                        .foregroundStyle(Theme.textSecondary)
                    Text(verbatim: diagnostics.state.description)
                }
                GridRow {
                    Text("Profile")
                        .foregroundStyle(Theme.textSecondary)
                    Text(verbatim: diagnostics.profileName ?? "—")
                }
                GridRow {
                    Text("Canvas")
                        .foregroundStyle(Theme.textSecondary)
                    Text(verbatim: diagnostics.canvas.map { "\($0.width)×\($0.height)" } ?? "—")
                }
                GridRow {
                    Text("Frames sent")
                        .foregroundStyle(Theme.textSecondary)
                    Text(verbatim: "\(diagnostics.stats.framesSent) (\(diagnostics.stats.keyframesSent) IDR) · \(String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), diagnostics.stats.pullRate))/s")
                }
                GridRow {
                    Text("Encoder")
                        .foregroundStyle(Theme.textSecondary)
                    Text(verbatim: "\(diagnostics.projection.mode) · \(String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), diagnostics.projection.framesPerSecond)) fps · \(diagnostics.projection.bitrate / 1000) kbit/s")
                }
                if let error = diagnostics.projection.lastError, !error.isEmpty {
                    GridRow {
                        Text("Last error")
                            .foregroundStyle(Theme.textSecondary)
                        Text(verbatim: error)
                            .foregroundStyle(Theme.error)
                    }
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Theme.text)
            .padding(.top, 6)

            LogsDashVideoRecorderRow()
                .padding(.top, 10)
        } label: {
            Label("Link diagnostics", systemImage: "waveform.path.ecg")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.text)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.outline, lineWidth: 1))
    }
}

/// Diagnostics (media-video.md §15.8): record the H.264 stream exactly as sent to the dash (the
/// first 600 access units, raw Annex-B) and share the file — how the black-screen bug was found.
@MainActor
struct LogsDashVideoRecorderRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ride = model.ride
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { ride.isRecordingDashVideo }, set: { ride.setDashVideoRecording($0) })) {
                Text("Record the dash video stream")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.text)
            }
            .toggleStyle(.switch)
            Text("Saves the first 600 frames sent to the dash (raw H.264) for a problem report.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
            if let url = ride.dashVideoRecordingURL, !ride.isRecordingDashVideo {
                ShareLink(item: url) {
                    Label("Share the recording", systemImage: "square.and.arrow.up")
                        .font(.footnote)
                }
            }
        }
    }
}

enum LogsFilter {
    static func rank(_ level: LogLevelTag) -> Int {
        switch level {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    /// Entries at or above `minimum` (all when nil).
    static func visible(_ entries: [LogEntry], minimum: LogLevelTag?) -> [LogEntry] {
        guard let minimum else { return entries }
        let floor = rank(minimum)
        return entries.filter { rank($0.level) >= floor }
    }

    static func color(_ level: LogLevelTag) -> Color {
        switch level {
        case .debug: return Theme.textSecondary
        case .info: return Theme.logText
        case .warning: return Theme.busy
        case .error: return Theme.error
        }
    }
}

#Preview("Logs") {
    NavigationStack {
        LogsScreen()
    }
    .environment(AppModel.preview())
}

/// "Recovered after a crash" (app-features §6.4): the previous run crashed; the crash details are
/// already part of the shared logs and of "Report a problem".
@MainActor
struct LogsCrashCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Recovered after a crash", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.busy)
            Text("The app closed unexpectedly last time. The details are included when you share the logs or report a problem.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Button("Dismiss") { model.logs.dismissCrashReport() }
                .font(.footnote)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.busy.opacity(0.6), lineWidth: 1))
    }
}

