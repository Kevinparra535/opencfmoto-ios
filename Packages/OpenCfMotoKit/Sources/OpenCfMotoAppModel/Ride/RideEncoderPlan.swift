// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) VideoPipeline.kt (createEncoder) and AdaptiveVideoController.kt
// (the AUTO power-mode controller, ticked by the AA service watchdog).
//
// Thread-safe inputs of `EncoderPlanner` (docs/spec/media-video.md §7.1–§7.3, §8): the rider's
// video quality and power mode, iOS Low Power Mode and the AUTO `AdaptiveController`. Shared by
// RideModel (live updates on the main actor) and the link (`LinkOptions.encoderParameters`, called
// on a link task when REQ 16 negotiates the canvas).

import Foundation
import OpenCfMotoCore

final class RideEncoderPlan: @unchecked Sendable {
    private let lock = NSLock()
    private var quality: VideoQuality
    private var powerMode: PowerMode
    private var lowPowerMode: Bool
    /// AUTO power mode controller (AdaptiveVideoController); thread-safe itself.
    let adaptive = AdaptiveController()

    init(settings: BikeSettings, lowPowerMode: Bool) {
        quality = settings.videoQuality
        powerMode = settings.powerMode
        self.lowPowerMode = lowPowerMode
    }

    /// Updates the inputs; returns true when something changed.
    @discardableResult
    func update(quality q: VideoQuality, powerMode p: PowerMode, lowPowerMode lp: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let changed = q != quality || p != powerMode || lp != lowPowerMode
        quality = q
        powerMode = p
        lowPowerMode = lp
        return changed
    }

    var currentPowerMode: PowerMode { lock.lock(); defer { lock.unlock() }; return powerMode }

    /// The encoder-relevant values of a bike profile.
    static func values(_ p: BikeProfile) -> EncoderProfileValues {
        EncoderProfileValues(forceBaseline: p.forceBaseline, bitrate: p.videoBitrate, frameRate: p.videoFrameRate,
                             keyframeIntervalSeconds: p.keyframeIntervalSeconds)
    }

    /// `EncoderPlanner.plan` for `profile` (own dash UI → map boost; mirror → none).
    func plan(profile: BikeProfile, ownUI: Bool) -> EncoderParameters {
        let (q, p, lp) = inputs()
        return EncoderPlanner.plan(profile: Self.values(profile), quality: q, powerMode: p, ownUI: ownUI,
                                   adaptive: p == .auto ? adaptive.lastDecision : nil, lowPowerMode: lp)
    }

    /// The bitrate the encoder is created with (quality multiplier and map boost included): the
    /// AdaptivePolicy base.
    func baseBitrate(profile: BikeProfile, ownUI: Bool) -> Int {
        let (q, _, _) = inputs()
        let boost = EncoderPlanner.isMapBoostActive(ownUI: ownUI, profileFrameRate: profile.videoFrameRate)
        return EncoderPlanner.baseBitrate(profileBitrate: profile.videoBitrate, quality: q, mapBoost: boost)
    }

    private func inputs() -> (VideoQuality, PowerMode, Bool) {
        lock.lock(); defer { lock.unlock() }
        return (quality, powerMode, lowPowerMode)
    }
}
