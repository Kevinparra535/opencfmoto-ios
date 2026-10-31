// SPDX-License-Identifier: AGPL-3.0-or-later
// The system screen-broadcast picker (ReplayKit, docs/spec/ios-platform-facts.md §f): tapping it
// shows the iOS "Screen Broadcast" sheet preselected on our upload extension. Apps cannot start a
// broadcast themselves; this public view is the supported entry point.

import SwiftUI
import UIKit
import ReplayKit

struct BroadcastPickerButton: UIViewRepresentable {
    /// Bundle identifier of the broadcast upload extension.
    let extensionBundleID: String

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 88, height: 88))
        picker.preferredExtension = extensionBundleID
        picker.showsMicrophoneButton = false
        picker.backgroundColor = .clear
        picker.tintColor = .white
        return picker
    }

    func updateUIView(_ picker: RPSystemBroadcastPickerView, context: Context) {
        if picker.preferredExtension != extensionBundleID {
            picker.preferredExtension = extensionBundleID
        }
    }
}
