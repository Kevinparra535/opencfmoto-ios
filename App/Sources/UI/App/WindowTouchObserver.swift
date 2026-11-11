// SPDX-License-Identifier: AGPL-3.0-or-later
// Review PH-2: any touch on the phone during the «Modo bolsillo» countdown is the rider using it, so the
// countdown ends (RideModel.phoneTouched) and the pocket cover never drops onto a pan, a tap or a scroll
// in progress. A gesture recognizer on the window sees every touch-down and takes no part in any gesture:
// it never cancels or delays touches, recognizes alongside every other recognizer and fails at once, so
// buttons, lists, the map and the pocket screen's hold behave exactly as without it.

import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Reports each touch-down in the view it is attached to (the window), then fails.
final class TouchDownRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onTouchDown: (() -> Void)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouchDown?()
        state = .failed
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}

/// A zero-size background view that puts a `TouchDownRecognizer` on the window hosting it.
struct WindowTouchObserver: UIViewRepresentable {
    let onTouchDown: () -> Void

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.isUserInteractionEnabled = false
        view.recognizer.onTouchDown = onTouchDown
        return view
    }

    func updateUIView(_ view: HostView, context: Context) {
        view.recognizer.onTouchDown = onTouchDown
    }

    final class HostView: UIView {
        let recognizer = TouchDownRecognizer(target: nil, action: nil)

        override func didMoveToWindow() {
            super.didMoveToWindow()
            recognizer.view?.removeGestureRecognizer(recognizer)
            window?.addGestureRecognizer(recognizer)
        }
    }
}
