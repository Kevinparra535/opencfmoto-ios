// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) TripActivity.kt (trip computer), TripsListActivity.kt (saved trips)
//
// Trips (docs/spec/app-features.md §5.4, §5.6, §5.7): the live trip computer (speed, distance,
// moving time, max / avg speed, GPS state) with a manual recording (Start recording / Stop & save —
// the auto-log never stops a manual recording), Discard (Android "Reset", confirmed; throws the
// current recording away unsaved), the auto-log note, and the saved trips grouped by
// local day (TripsModel.sections, newest first) with route thumbnails; tap a trip for its map,
// stats, GPX export and delete; swipe or long-press to delete (with confirmation).

import SwiftUI
import OpenCfMotoCore
import OpenCfMotoAppModel

@MainActor
struct TripsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var pendingDelete: Trip?

    private var lease: FeatureLocationLease { .tripComputer }

    var body: some View {
        let trips = model.trips
        List {
            Section {
                TripsComputerCard()
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
            }

            if trips.sections.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No trips yet", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    } description: {
                        Text("Rides log automatically while the dash shows the map — or record one with Start recording above.")
                    }
                    .featureRowBackground()
                }
            }

            ForEach(trips.sections) { section in
                Section {
                    ForEach(section.trips) { trip in
                        NavigationLink {
                            TripsDetailScreen(trip: trip)
                        } label: {
                            TripsRowView(trip: trip)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = trip
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                pendingDelete = trip
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .featureRowBackground()
                } header: {
                    TripsDayHeader(section: section)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Trips")
        .featureScreenChrome()
        .confirmationDialog("Delete trip?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingDelete) { trip in
            Button("Delete", role: .destructive) {
                model.trips.delete(trip)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { trip in
            Text(verbatim: TripsText.deleteMessage(trip))
        }
        .onAppear { lease.acquire(model) }
        .onDisappear { lease.release(model) }
    }
}

/// The live trip computer (Android `TripActivity`): big speed, GPS line, 2×2 stats, recording
/// (Start recording / Stop & save / Discard — Android's Start / Pause / Reset).
@MainActor
struct TripsComputerCard: View {
    @Environment(AppModel.self) private var model
    @ScaledMetric(relativeTo: .largeTitle) private var speedSize: CGFloat = 76
    @State private var confirmDiscard = false

    var body: some View {
        let trips = model.trips
        let live = trips.live
        let recording = trips.isRecording
        let fix = model.ride.lastFix
        let speed = recording
            ? live.speedKmh
            : TripFormat.liveSpeedKmh(speedMs: Float(max(fix?.speedMps ?? 0, 0)))
        let numbers = TripsText.liveTrip(live)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text("Trip computer")
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if recording {
                    Group {
                        if trips.isManualRecording {
                            Label("Recording", systemImage: "record.circle")
                        } else {
                            Label("Logging automatically", systemImage: "record.circle")
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.error)
                    .labelStyle(.titleAndIcon)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: String(speed))
                    .font(.system(size: speedSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(verbatim: "km/h")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Speed"))
            .accessibilityValue(Text(verbatim: "\(speed) km/h"))

            TripsText.gpsLine(recording: recording, live: live, lastFix: fix,
                             authorized: model.permissions.location.isAuthorized)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    FeatureStatCell(title: "Distance", value: TripFormat.distanceText(meters: live.distanceMeters))
                    FeatureStatCell(title: "Duration", value: TripFormat.durationText(movingTimeMs: live.movingTimeMs))
                }
                GridRow {
                    FeatureStatCell(title: "Max speed", value: TripFormat.kmhText(numbers.maxKmh))
                    FeatureStatCell(title: "Avg speed", value: TripFormat.kmhText(numbers.avgKmh))
                }
            }

            if !model.permissions.location.isAuthorized && model.permissions.location != .notDetermined {
                Button {
                    model.permissions.openAppSettings()
                } label: {
                    Label("Open Settings", systemImage: "gear")
                }
                .buttonStyle(TonalButtonStyle())
            } else if trips.isManualRecording {
                Button {
                    trips.stopRecording()
                } label: {
                    Label("Stop & save", systemImage: "stop.fill")
                }
                .buttonStyle(PrimaryButtonStyle(tint: Theme.error))
            } else if !recording {
                Button {
                    trips.startRecording()
                } label: {
                    Label("Start recording", systemImage: "record.circle")
                }
                .buttonStyle(PrimaryButtonStyle())
            }

            // Android "Reset": throws the current recording (manual or automatic) away, unsaved.
            if recording {
                Button(role: .destructive) {
                    confirmDiscard = true
                } label: {
                    Label("Discard", systemImage: "trash")
                        .foregroundStyle(Theme.error)
                }
                .buttonStyle(TonalButtonStyle())
                .accessibilityHint(Text("Throws this recording away without saving it"))
            }

            if let error = trips.lastError, !error.isEmpty {
                Label {
                    Text(verbatim: error)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.error)
                }
                .font(.footnote)
                .foregroundStyle(Theme.text)
            }

            FeatureNote(model.settings.current.logTrips
                        ? Text("Rides are logged automatically while the dash shows the map (Settings ▸ Startup & recovery).")
                        : Text("Automatic trip logging is off (Settings ▸ Startup & recovery). Record rides by hand here."))
            FeatureNote("Speed and distance come from the phone's GPS (the bike doesn't share telemetry over the dash link). Keep a clear view of the sky for best accuracy.")
        }
        .cardStyle()
        .confirmationDialog("Discard this recording?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { model.trips.discardRecording() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if model.trips.isManualRecording {
                Text("The distance and time recorded so far are thrown away. Nothing is saved.")
            } else {
                Text("The distance and time logged so far are thrown away. Nothing is saved — automatic logging then starts a new ride.")
            }
        }
        .onChange(of: trips.isRecording) { _, isRecording in
            // The recording ended meanwhile (saved by Stop or the auto-log): nothing left to discard.
            if !isRecording { confirmDiscard = false }
        }
    }
}

#Preview("Trips") {
    NavigationStack {
        TripsScreen()
    }
    .environment(AppModel.preview())
}
