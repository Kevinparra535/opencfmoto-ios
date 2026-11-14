// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) GpxDashUi.kt (preview card, nav + metrics cards, arrive card,
// menu Ride actions), GpxActivity.kt (hub Extras: parking / home)
//
// Bottom cards of the Map hub (docs/spec/navigation-dash.md §11.6–§11.8, §14): the phone shows the
// same states as the dash because both read the ONE navigation session (NavigationModel):
// route preview (chips → selectRoute, Go, Cancel/Done, Circuit, ★ Save, Home, Marker),
// an opened GPX track (Follow this track / Cancel, UI/UX P0), active navigation (cue + TIME /
// ARRIVE / LEFT / ALT + status, End, Recalc), arrival (Park here / Find parking / Done) and the
// free-ride action bar. Text on the green and red fills is dark (UX-06).

import SwiftUI
import OpenCfMotoCore
import OpenCfMotoAppModel

// MARK: - Route preview

@MainActor
struct NavigatePreviewCard: View {
    @Environment(AppModel.self) private var model
    let preview: RoutePreview

    var body: some View {
        let navigation = model.navigation
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: NavigateIcons.place(preview.place.category))
                    .font(.title2)
                    .foregroundStyle(Theme.brand)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: preview.place.name)
                        .font(.headline)
                        .foregroundStyle(Theme.text)
                    if !preview.meta.isEmpty {
                        Text(verbatim: preview.meta)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer(minLength: 0)
                if preview.loading {
                    ProgressView()
                        .tint(Theme.brand)
                        .accessibilityLabel(Text("Getting route…"))
                }
            }

            if !preview.chipLabels.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(preview.chipLabels.indices, id: \.self) { index in
                            routeChip(preview.chipLabels[index], index: index)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            // Fuel MVP: «Llegas con ~60 km antes de la reserva» / «Justo: carga antes de salir» / …
            FuelVerdictLine()

            HStack(spacing: 10) {
                Button {
                    navigation.go()
                } label: {
                    Label("Go", systemImage: "location.fill")
                }
                .buttonStyle(PrimaryButtonStyle())

                if preview.pinMode {
                    Button("Done") { navigation.cancelPreview() }
                        .buttonStyle(TonalButtonStyle())
                } else {
                    Button("Cancel") { navigation.cancelPreview() }
                        .buttonStyle(TonalButtonStyle())
                }
            }

            NavigateActionGrid {
                Button("Circuit") { navigation.startCircuit() }
                Button("★ Save") { navigation.saveFavorite(preview.place) }
                Button("Set as home") { navigation.setHome(preview.place) }
                if preview.pinMode {
                    Button("＋ Marker") { navigation.addMarker(preview.place) }
                }
            }
            .buttonStyle(TonalButtonStyle())
        }
        .cardStyle()
    }

    private func routeChip(_ label: String, index: Int) -> some View {
        let selected = index == preview.selectedIndex
        return Button {
            model.navigation.selectRoute(index)
        } label: {
            Text(verbatim: label)
                .font(.footnote.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(selected ? Theme.onAccent : Theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(selected ? Theme.live.opacity(0.85) : Theme.surfaceHigh, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Opened GPX track (UI/UX P0, UX-17)

/// A GPX track opened from another app or picked here, shown before it replaces anything: its name,
/// length and waypoints, what following it would replace, and «Seguir este track» / «Cancelar».
@MainActor
struct NavigateGpxPreviewCard: View {
    @Environment(AppModel.self) private var model
    let preview: GpxPreview

    var body: some View {
        let navigation = model.navigation
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.title2)
                    .foregroundStyle(Theme.live)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Track preview")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Text(verbatim: preview.name)
                        .font(.headline)
                        .foregroundStyle(Theme.text)
                    Text(verbatim: navigation.summary(of: preview))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                    if let replaces = navigation.pendingGpxReplaces {
                        Label {
                            Text(verbatim: replaces)
                        } icon: {
                            Image(systemName: "arrow.triangle.swap")
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.busy)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button {
                    navigation.followPendingGpx()
                } label: {
                    Label("Follow this track", systemImage: "location.fill")
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .buttonStyle(PrimaryButtonStyle())

                Button("Cancel") { navigation.cancelPendingGpx() }
                    .buttonStyle(TonalButtonStyle())
                    .accessibilityHint(Text("Nothing changes"))
            }
        }
        .cardStyle()
    }
}

// MARK: - Active navigation

@MainActor
struct NavigateRouteCard: View {
    @Environment(AppModel.self) private var model
    let snapshot: NavSnapshot

    var body: some View {
        let navigation = model.navigation
        let units = model.settings.current.map.units
        let metrics = snapshot.metrics
        VStack(alignment: .leading, spacing: 12) {
            if let cue = snapshot.cue {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: NavigateIcons.maneuver(cue.dir))
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(Theme.brand)
                        .frame(width: 48)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: cue.distanceText)
                            .font(.title.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.text)
                        Text(verbatim: cue.text)
                            .font(.headline)
                            .foregroundStyle(Theme.text)
                            .lineLimit(2)
                        if let lanes = cue.lanes, !lanes.isEmpty {
                            Text(verbatim: lanes)
                                .font(.subheadline.monospaced())
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 0)
                    if let limit = snapshot.speedLimit, NavigateRouteCard.showsLimit(limit) {
                        NavigateSpeedLimitSign(text: NavFormat.formatLimit(limit, units: units))
                    }
                }
            }

            HStack(alignment: .top, spacing: 8) {
                FeatureStatCell(title: "Time", value: metrics.time)
                FeatureStatCell(title: "Arrival", value: metrics.arrive)
                FeatureStatCell(title: "Remaining", value: metrics.left)
                FeatureStatCell(title: "Altitude", value: metrics.alt == "—" ? metrics.alt : "\(metrics.alt) \(metrics.altUnit)")
            }

            if !metrics.status.isEmpty {
                Text(verbatim: metrics.status)
                    .font(.footnote)
                    .foregroundStyle(metrics.statusWarning ? NavigateColors.warning : Theme.textSecondary)
            }

            HStack(spacing: 10) {
                Button(role: .destructive) {
                    navigation.endNavigation()
                } label: {
                    Label("End navigation", systemImage: "xmark.circle")
                }
                .buttonStyle(PrimaryButtonStyle(tint: Theme.error))

                Button {
                    navigation.recalc()
                } label: {
                    Label("Recenter / Recalc", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(TonalButtonStyle())
            }
        }
        .cardStyle()
    }

    /// Android shows the sign iff the label is not blank and not "—".
    static func showsLimit(_ limit: SpeedLimit) -> Bool {
        let label = limit.label.trimmingCharacters(in: .whitespaces)
        return !label.isEmpty && label != "—" && limit.kmh != nil
    }
}

/// EU-style speed-limit sign.
struct NavigateSpeedLimitSign: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.headline.weight(.heavy))
            .monospacedDigit()
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .foregroundStyle(Color.black)
            .frame(width: 52, height: 52)
            .background(Circle().fill(Color.white))
            .overlay(Circle().strokeBorder(Color(hex: 0xE53935), lineWidth: 5))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Speed limit \(text)"))
    }
}

// MARK: - Arrival

@MainActor
struct NavigateArrivalCard: View {
    @Environment(AppModel.self) private var model
    let arrival: ArrivalCard
    let onFindParking: () -> Void

    var body: some View {
        let navigation = model.navigation
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "flag.checkered")
                    .font(.title2)
                    .foregroundStyle(Theme.live)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: arrival.title)
                        .font(.headline)
                        .foregroundStyle(Theme.text)
                    if !arrival.meta.isEmpty {
                        Text(verbatim: arrival.meta)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            // The dash's arrive actions: Park here marks the spot ("Marked on arrival") and closes
            // the card, Done hides it ("Free ride"), Find parking hides it and searches nearby.
            NavigateActionGrid {
                Button("Park here") { navigation.arrivalParkHere() }
                Button("Find parking") { onFindParking() }
                Button("Done · free ride") { navigation.dismissArrival() }
            }
            .buttonStyle(TonalButtonStyle())
        }
        .cardStyle()
    }
}

// MARK: - Selected place (pin / marker / result)

@MainActor
struct NavigatePlaceCard: View {
    @Environment(AppModel.self) private var model
    let place: Place
    let onClose: () -> Void

    var body: some View {
        let navigation = model.navigation
        let origin = navigation.snapshot.puck ?? model.ride.lastFix?.point
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: NavigateIcons.place(place.category))
                    .font(.title2)
                    .foregroundStyle(Theme.brand)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: place.name)
                        .font(.headline)
                        .foregroundStyle(Theme.text)
                    if !place.subtitle.isEmpty {
                        Text(verbatim: place.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if let meters = NavigateGeometry.distance(from: origin, to: place) {
                        Text(verbatim: NavigateGeometry.distanceText(meters, units: model.settings.current.map.units))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Close"))
            }

            HStack(spacing: 10) {
                Button {
                    navigation.preview(place)
                    onClose()
                } label: {
                    Label("Preview", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
                .buttonStyle(PrimaryButtonStyle())

                Button {
                    navigation.navigate(to: place)
                    onClose()
                } label: {
                    Label("Navigate", systemImage: "location.fill")
                }
                .buttonStyle(TonalButtonStyle())
            }

            NavigateActionGrid {
                Button("★ Save") { navigation.saveFavorite(place) }
                Button("＋ Marker") { navigation.addMarker(place) }
                Button("Set as home") { navigation.setHome(place) }
                if NavigatePlaceStatus.isSaved(place, in: navigation) {
                    Button("Delete", role: .destructive) {
                        navigation.delete(place)
                        onClose()
                    }
                }
            }
            .buttonStyle(TonalButtonStyle())
        }
        .cardStyle()
    }
}

enum NavigatePlaceStatus {
    /// The place is one of the rider's saved places (favorites, markers, history, home, parked).
    @MainActor
    static func isSaved(_ place: Place, in navigation: NavigationModel) -> Bool {
        if let home = navigation.home, home.isSameLocation(as: place) { return true }
        if let parked = navigation.parked, parked.isSameLocation(as: place) { return true }
        return navigation.favorites.contains { $0.isSameLocation(as: place) }
            || navigation.markers.contains { $0.isSameLocation(as: place) }
            || navigation.history.contains { $0.isSameLocation(as: place) }
    }
}

// MARK: - Free ride bar

@MainActor
struct NavigateIdleBar: View {
    @Environment(AppModel.self) private var model
    let onChooseGpx: () -> Void

    var body: some View {
        let navigation = model.navigation
        HStack(spacing: 8) {
            Button {
                navigation.startFreeRide()
            } label: {
                NavigateActionLabel(title: "Free ride", systemImage: "road.lanes")
            }
            .buttonStyle(.plain)

            Button {
                navigation.parkHere()
            } label: {
                NavigateActionLabel(title: "Park here", systemImage: "parkingsign")
            }
            .buttonStyle(.plain)

            Button {
                navigation.goHome()
            } label: {
                NavigateActionLabel(title: "Go Home", systemImage: "house.fill")
            }
            .buttonStyle(.plain)
            .disabled(navigation.home == nil)
            .opacity(navigation.home == nil ? 0.45 : 1)

            Menu {
                Button {
                    navigation.setHomeHere()
                } label: {
                    Label("Set Home here", systemImage: "house")
                }
                if let parked = navigation.parked {
                    Button {
                        navigation.navigate(to: parked)
                    } label: {
                        Label("Navigate to parked bike", systemImage: "parkingsign.circle")
                    }
                    Button(role: .destructive) {
                        navigation.delete(parked)
                    } label: {
                        Label("Clear parked spot", systemImage: "trash")
                    }
                }
                Button {
                    onChooseGpx()
                } label: {
                    Label("Choose GPX file…", systemImage: "doc.badge.plus")
                }
            } label: {
                NavigateActionLabel(title: "More", systemImage: "ellipsis.circle")
            }
        }
    }
}

/// Icon-over-title action tile (thumb-sized, wraps to two lines at large text sizes).
struct NavigateActionLabel: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Theme.brand)
                .accessibilityHidden(true)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 60)
        .padding(.horizontal, 4)
        .background(Theme.surface.opacity(0.97), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.outline, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Wrapping grid of secondary actions (re-flows instead of truncating at large Dynamic Type sizes).
struct NavigateActionGrid<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
            content
        }
    }
}

// MARK: - Banners

/// One-line status banner over the map (toasts, errors, permission hints).
struct NavigateBanner: View {
    enum Kind {
        case info
        case error
    }

    let text: String
    let kind: Kind
    var actionTitle: LocalizedStringKey? = nil
    var action: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: kind == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(kind == .error ? Theme.error : Theme.brand)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(.subheadline)
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.brand)
                    .buttonStyle(.plain)
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(minWidth: 32, minHeight: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Dismiss"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surfaceHigh.opacity(0.97), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(kind == .error ? Theme.error.opacity(0.6) : Theme.outline, lineWidth: 1))
    }
}
