// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) VideoPipeline.kt (createEncoder), VideoPrefs.kt (bitrateFor)
//
// Derives the encoder settings (`EncoderParameters`, contract) from the bike profile's encoder
// defaults, the rider's video quality and power mode, the AUTO adaptive state, the own-UI "map boost"
// and the iOS Low Power Mode (media-video.md §7.1–§7.3, §8; ios-platform-facts.md k / design 15):
//
//   base bitrate = int( int(profile.bitrate × quality) × (mapBoost ? 1.35 : 1) )   (Float32 math)
//   mapBoost     = own dash UI && profile.frameRate ≥ 30
//   IDR interval = mapBoost ? max(1, idrSec / 2) : idrSec                          (integer seconds)
//   frame rate   = min(power-mode cap — AUTO: adaptive fps (30 until the first tick) —, profile fps),
//                  then ≤ 15 in Low Power Mode
//   bitrate      = AUTO: the adaptive bitrate (clamped to [min(600k, base), base]); otherwise base
//
// Profile values are passed as plain numbers so this does not depend on the profile types.

import Foundation

/// The encoder-relevant values of a bike profile (`BikeProfile.forceBaseline / videoBitrate /
/// videoFrameRate / videoIFrameIntervalSec`).
public struct EncoderProfileValues: Sendable, Equatable, Codable {
    public var forceBaseline: Bool
    /// Target bitrate in bit/s.
    public var bitrate: Int
    /// Target frame rate (fps).
    public var frameRate: Int
    /// IDR interval in whole seconds.
    public var keyframeIntervalSeconds: Int

    public init(forceBaseline: Bool = true, bitrate: Int = 2_500_000, frameRate: Int = 30, keyframeIntervalSeconds: Int = 1) {
        self.forceBaseline = forceBaseline
        self.bitrate = bitrate
        self.frameRate = frameRate
        self.keyframeIntervalSeconds = keyframeIntervalSeconds
    }

    /// Every profile except Morini: Baseline, 2.5 Mbit/s, 30 fps, IDR 1 s.
    public static let standard = EncoderProfileValues()
    /// Moto Morini SoftAP (MLN): no forced Baseline, 2 Mbit/s, 10 fps, IDR 2 s.
    public static let morini = EncoderProfileValues(forceBaseline: false, bitrate: 2_000_000, frameRate: 10, keyframeIntervalSeconds: 2)
}

public enum EncoderPlanner {
    /// Own-UI bitrate boost (Android map/GPX presentation).
    public static let mapBoostFactor: Float = 1.35
    /// iOS Low Power Mode frame cap.
    public static let lowPowerModeFrameCap = 15
    /// Re-submit the last picture after this long without an encode (Android 0.9 s).
    public static let repeatLastFrameAfter: TimeInterval = 0.9

    /// `mapBoost = ownUI && profile.frameRate ≥ 30`.
    public static func isMapBoostActive(ownUI: Bool, profileFrameRate: Int) -> Bool {
        ownUI && profileFrameRate >= 30
    }

    /// `int( int(profile.bitrate × quality) × (mapBoost ? 1.35 : 1) )` with Float32 math.
    public static func baseBitrate(profileBitrate: Int, quality: VideoQuality, mapBoost: Bool) -> Int {
        let withQuality = AppJavaNumber.f2i(Float(profileBitrate) * Float(quality.bitrateFactor))
        return Int(AppJavaNumber.f2i(Float(withQuality) * (mapBoost ? mapBoostFactor : 1)))
    }

    /// `mapBoost ? max(1, idr / 2) : idr` (integer seconds).
    public static func keyframeIntervalSeconds(profileSeconds: Int, mapBoost: Bool) -> Int {
        mapBoost ? max(1, profileSeconds / 2) : profileSeconds
    }

    /// The full encoder plan.
    /// - Parameters:
    ///   - profile: encoder values of the active bike profile.
    ///   - ownUI: true for our own dash UI (map boost applies); false for ReplayKit mirroring.
    ///   - adaptive: the latest AUTO decision (`AdaptiveController.lastDecision`), if any.
    ///   - lowPowerMode: `ProcessInfo.isLowPowerModeEnabled`.
    public static func plan(profile: EncoderProfileValues, quality: VideoQuality, powerMode: PowerMode,
                            ownUI: Bool = true, adaptive: AdaptiveDecision? = nil,
                            lowPowerMode: Bool = false) -> EncoderParameters {
        let boost = isMapBoostActive(ownUI: ownUI, profileFrameRate: profile.frameRate)
        let base = baseBitrate(profileBitrate: profile.bitrate, quality: quality, mapBoost: boost)
        var bitrate = base
        var cap = powerMode.frameCap
        if powerMode == .auto, let adaptive {
            bitrate = min(max(adaptive.bitrate, min(AdaptivePolicy.minBitrate, base)), base)
            cap = adaptive.fps
        }
        var fps = max(1, min(cap, profile.frameRate))
        if lowPowerMode { fps = min(fps, lowPowerModeFrameCap) }
        return EncoderParameters(
            bitrate: bitrate,
            frameRate: fps,
            keyframeIntervalSeconds: Double(keyframeIntervalSeconds(profileSeconds: profile.keyframeIntervalSeconds, mapBoost: boost)),
            forceBaseline: profile.forceBaseline,
            repeatLastFrameAfter: repeatLastFrameAfter)
    }
}
