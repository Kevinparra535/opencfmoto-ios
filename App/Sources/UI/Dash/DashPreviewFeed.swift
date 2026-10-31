// SPDX-License-Identifier: AGPL-3.0-or-later
// The phone "Dash view" picture (Android HudViewActivity.kt: live preview of what the dash shows).
//
// ~10 times per second while the Dash view is visible and the app is active, takes the current
// `RideModel.displayList(now:)` (thread-safe snapshot of the very display list the dash encoder
// draws) and renders it with the shared CoreGraphics `DashRenderer` OFF the main thread, then
// publishes the image on the main actor. The renderer serializes with the projection engine
// internally, so a busy encoder never stalls the UI. Stops as soon as the owning task is cancelled.

import Foundation
import CoreGraphics
import Observation
import OpenCfMotoCore
import OpenCfMotoApple
import OpenCfMotoAppModel

/// One rendered preview frame. `CGImage` is immutable, so handing it across threads is safe.
struct DashPreviewFrame: @unchecked Sendable {
    let image: CGImage
    /// Canvas of the display list the image was drawn from (dash pixels).
    let canvas: DashSize
}

@MainActor
@Observable
final class DashPreviewFeed {
    /// Latest picture (nil until the first render).
    private(set) var frame: DashPreviewFrame?
    /// Output pixels per canvas pixel (1…2), from the on-screen size of the preview.
    @ObservationIgnored var renderScale: Double = 1

    private static let frameInterval: Duration = .milliseconds(100)

    /// Renders until the calling task is cancelled (view gone, app inactive).
    func run(ride: RideModel, renderer: DashRenderer) async {
        let clock = ContinuousClock()
        while !Task.isCancelled {
            let started = clock.now
            let now = AppPlatform.shared.now()
            let scale = min(2, max(1, renderScale.isFinite ? renderScale : 1))
            let rendered = await Task.detached(priority: .userInitiated) { () -> DashPreviewFrame? in
                let list = ride.displayList(now: now)
                guard let image = renderer.makeImage(list, scale: scale) else { return nil }
                return DashPreviewFrame(image: image, canvas: list.size)
            }.value
            if Task.isCancelled { break }
            if let rendered { frame = rendered }
            let elapsed = started.duration(to: clock.now)
            let pause = max(Self.frameInterval - elapsed, .milliseconds(15))
            try? await Task.sleep(for: pause)
        }
    }
}
