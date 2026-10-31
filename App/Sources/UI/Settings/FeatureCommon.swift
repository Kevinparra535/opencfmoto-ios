// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Shared building blocks of the ui-features screens (Navigate, Trips, Settings, Controls, Logs).
// Every type here is prefixed `Feature` so it cannot collide with the other UI agent's helpers:
// all app sources live in one module.

import SwiftUI
import Observation
import CoreTransferable
import UniformTypeIdentifiers
import OpenCfMotoCore
import OpenCfMotoAppModel

// MARK: - File types

enum FeatureFileTypes {
    /// GPX as declared in Info.plist (`UTImportedTypeDeclarations`, conforms to public.xml).
    static let gpx = UTType(importedAs: "com.topografix.gpx", conformingTo: .xml)

    /// What the GPX picker accepts: the declared type, whatever iOS maps ".gpx" to, plain XML.
    static var gpxImport: [UTType] {
        var types: [UTType] = [gpx]
        if let byExtension = UTType(filenameExtension: "gpx"), !types.contains(byExtension) {
            types.append(byExtension)
        }
        types.append(.xml)
        return types
    }

    /// Settings / map-data packs: JSON, text, or anything (Android offers `*/*` too).
    static let backupImport: [UTType] = [.json, .plainText, .data]
}

// MARK: - Files exported lazily through ShareLink

/// Picks the UTType a `FeatureLazyFile` advertises to the share sheet.
protocol FeatureFileKind {
    static var contentType: UTType { get }
}

enum FeatureGPXKind: FeatureFileKind {
    static var contentType: UTType { FeatureFileTypes.gpx }
}

enum FeatureJSONKind: FeatureFileKind {
    static var contentType: UTType { .json }
}

enum FeatureTextKind: FeatureFileKind {
    static var contentType: UTType { .plainText }
}

/// A file that is written only when the rider picks a share target (ShareLink calls `make` then):
/// logs, reports and exports are always fresh and nothing is written for a sheet that is cancelled.
struct FeatureLazyFile<Kind: FeatureFileKind>: Transferable, Sendable {
    /// Writes the file and returns its URL (runs off the main actor; hop to it inside).
    let make: @Sendable () async throws -> URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: Kind.contentType) { item in
            SentTransferredFile(try await item.make())
        }
    }
}

/// Collects failures of lazily exported files so the screen can show them after the share sheet.
@MainActor
@Observable
final class FeatureShareErrors {
    var message: String?

    func report(_ error: any Error) {
        message = FeatureErrorText.describe(error)
    }

    /// Alert binding: presented while a message is pending.
    var isPresented: Bool {
        get { message != nil }
        set { if !newValue { message = nil } }
    }

    /// Wraps an export so its failure is reported here before the share sheet sees it.
    func guarded(_ export: @escaping @MainActor @Sendable () throws -> ExportedFile) -> @Sendable () async throws -> URL {
        { [self] in
            do {
                return try await MainActor.run { try export().url }
            } catch {
                await self.report(error)
                throw error
            }
        }
    }
}

// MARK: - Errors and file reading

enum FeatureErrorText {
    /// A short, user-readable description of an error.
    static func describe(_ error: any Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription, !text.isEmpty {
            return text
        }
        return error.localizedDescription
    }
}

enum FeatureFileReadError: LocalizedError {
    case tooLarge
    case notText

    var errorDescription: String? {
        switch self {
        case .tooLarge: return String(localized: "That file is too large.")
        case .notText: return String(localized: "That file is not a text file.")
        }
    }
}

enum FeatureFileReader {
    /// Reads a document picked with `.fileImporter` (security-scoped) off the main actor.
    static func read(_ url: URL, maxBytes: Int) async throws -> Data {
        try await Task.detached(priority: .userInitiated) { () throws -> Data in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxBytes {
                throw FeatureFileReadError.tooLarge
            }
            let data = try Data(contentsOf: url)
            if data.count > maxBytes { throw FeatureFileReadError.tooLarge }
            return data
        }.value
    }

    /// Reads a UTF-8 text document (settings / map-data packs).
    static func readText(_ url: URL, maxBytes: Int) async throws -> String {
        let data = try await read(url, maxBytes: maxBytes)
        guard let text = String(data: data, encoding: .utf8) else { throw FeatureFileReadError.notText }
        return text
    }
}

// MARK: - GPS while a feature screen is visible

/// Keeps GPS + the navigation session fed while the Map hub or the trip computer is on screen
/// (`RideModel.startLocationPreview`). The lease only stops what it started itself, and never
/// while a ride, a recording, a navigation or a route preview still needs fixes.
@MainActor
final class FeatureLocationLease {
    /// One lease per feature, shared by every instance of its screen (ownership survives a pop).
    static let mapHub = FeatureLocationLease()
    static let tripComputer = FeatureLocationLease()

    private var owned = false

    func acquire(_ model: AppModel) {
        if model.permissions.location == .notDetermined {
            model.permissions.requestLocation()
        }
        guard !owned else { return }
        // Someone else (a ride, the dash preview) already runs GPS: use it, do not take it over.
        if model.core.services.location.isUpdating { return }
        model.ride.startLocationPreview()
        owned = true
    }

    /// Another screen that needs GPS (the dash preview) took over: do not stop on disappear.
    func handOff() {
        owned = false
    }

    /// Stops the preview GPS if this lease started it and nothing needs fixes any more; otherwise
    /// keeps the ownership so a later release (the screen shown and left again) can stop it.
    func release(_ model: AppModel) {
        guard owned else { return }
        let snapshot = model.navigation.snapshot
        guard !model.ride.isProjecting, !model.ride.isRideModeActive, !model.trips.isRecording,
              !snapshot.mode.isNavigating, snapshot.preview == nil else { return }
        owned = false
        model.ride.stopLocationPreview()
    }
}

// MARK: - Look

extension View {
    /// Dark cockpit chrome for a pushed feature screen (forms, lists and the navigation bar).
    func featureScreenChrome() -> some View {
        self
            .environment(\.colorScheme, .dark)
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .toolbarBackground(Theme.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .tint(Theme.brand)
    }

    /// Row background of the cockpit forms.
    func featureRowBackground() -> some View {
        listRowBackground(Theme.surface)
    }
}

/// Secondary explanation line under a setting.
struct FeatureNote: View {
    private let text: Text

    init(_ key: LocalizedStringKey) {
        text = Text(key)
    }

    init(verbatim: String) {
        text = Text(verbatim: verbatim)
    }

    init(_ text: Text) {
        self.text = text
    }

    var body: some View {
        text
            .font(.footnote)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A titled choice (segmented control or menu) followed by the description of the current value,
/// like the Android Setup rows (`SetupActivity.kt:627-638`).
struct FeatureChoiceRow<Value: Hashable>: View {
    let title: LocalizedStringKey
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> Text
    var detail: ((Value) -> Text)? = nil
    var segmented = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if segmented {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                Picker(title, selection: $selection) {
                    ForEach(options, id: \.self) { option in
                        label(option).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } else {
                Picker(selection: $selection) {
                    ForEach(options, id: \.self) { option in
                        label(option).tag(option)
                    }
                } label: {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text)
                }
                .pickerStyle(.menu)
            }
            if let detail {
                FeatureNote(detail(selection))
            }
        }
        .padding(.vertical, 4)
    }
}

/// A toggle with a title and an explanation underneath.
struct FeatureToggleRow: View {
    let title: LocalizedStringKey
    var detail: Text? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .foregroundStyle(Theme.text)
                if let detail {
                    FeatureNote(detail)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// One labelled value of a stats grid (trip computer, trip detail, link diagnostics).
struct FeatureStatCell: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(Theme.textSecondary)
            Text(verbatim: value)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
