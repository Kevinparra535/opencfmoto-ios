// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) MainActivity.kt (Report a problem dialog), ProblemReport.kt
//
// "Report a problem" (docs/spec/app-features.md §6.5): what went wrong (multi-line), bike model
// (pre-filled with the active bike's name), year (optional) → LogsModel.problemReport builds the
// text report (diagnostics + full log, secrets redacted unless enabled) which is shared from here.

import SwiftUI
import OpenCfMotoCore
import OpenCfMotoAppModel

@MainActor
struct LogsProblemReportForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var problem = ""
    @State private var bikeModel = ""
    @State private var year = ""
    @State private var prefilled = false
    @State private var shareErrors = FeatureShareErrors()

    var body: some View {
        Form {
            Section {
                FeatureNote("Builds a shareable report with diagnostics + recent log (secrets redacted unless enabled in Settings).")
            }
            .featureRowBackground()

            Section {
                TextField("What went wrong?", text: $problem, axis: .vertical)
                    .lineLimit(4 ... 10)
            } header: {
                Text("What went wrong?")
            }
            .featureRowBackground()

            Section {
                TextField("Bike model (e.g. 800NK Advanced)", text: $bikeModel)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                TextField("Year (optional)", text: $year)
                    .keyboardType(.numberPad)
            } header: {
                Text("Bike")
            }
            .featureRowBackground()

            Section {
                ShareLink(item: reportFile, preview: SharePreview("OpenCfMoto problem report")) {
                    Label("Share problem report", systemImage: "square.and.arrow.up")
                }
            } footer: {
                FeatureNote("The report includes the app version, the active bike profile, the link state and the recent log.")
            }
            .featureRowBackground()
        }
        .navigationTitle("Report a problem")
        .navigationBarTitleDisplayMode(.inline)
        .featureScreenChrome()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .onAppear {
            guard !prefilled else { return }
            prefilled = true
            if bikeModel.isEmpty, let bike = model.garage.selected {
                bikeModel = bike.name
            }
        }
        .alert("Couldn't share the report", isPresented: $shareErrors.isPresented) {
        } message: {
            Text(verbatim: shareErrors.message ?? "")
        }
    }

    /// The report file, written with the current field values when a share target is picked.
    private var reportFile: FeatureLazyFile<FeatureTextKind> {
        let logs = model.logs
        let problem = self.problem
        let bikeModel = self.bikeModel
        let year = self.year.trimmingCharacters(in: .whitespacesAndNewlines)
        return FeatureLazyFile(make: shareErrors.guarded {
            try logs.problemReport(problem: problem, bikeModel: bikeModel, bikeYear: year)
        })
    }
}

#Preview("Report a problem") {
    NavigationStack {
        LogsProblemReportForm()
    }
    .environment(AppModel.preview())
}
