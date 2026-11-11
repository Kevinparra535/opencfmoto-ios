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
        // Dark glyph on the orange circle behind it (UI/UX P0, UX-06: 6.6:1; white was 2.9:1).
        picker.tintColor = UIColor(red: 0x0E / 255.0, green: 0x11 / 255.0, blue: 0x16 / 255.0, alpha: 1)
        return picker
    }

    func updateUIView(_ picker: RPSystemBroadcastPickerView, context: Context) {
        if picker.preferredExtension != extensionBundleID {
            picker.preferredExtension = extensionBundleID
        }
    }
}
