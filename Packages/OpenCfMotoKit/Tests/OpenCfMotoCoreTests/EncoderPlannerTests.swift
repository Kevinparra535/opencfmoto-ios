// SPDX-License-Identifier: AGPL-3.0-or-later
// Encoder parameter derivation (media-video.md §7.2–§7.3, §8.1; iOS Low Power Mode cap).

import XCTest
@testable import OpenCfMotoCore

final class EncoderPlannerTests: XCTestCase {

    func testBitrateTable() {
        // §7.3 table: base × quality (× 1.35 map boost), Float32 truncation
        XCTAssertEqual(EncoderPlanner.baseBitrate(profileBitrate: 2_500_000, quality: .smooth, mapBoost: false), 1_750_000)
        XCTAssertEqual(EncoderPlanner.baseBitrate(profileBitrate: 2_500_000, quality: .balanced, mapBoost: false), 2_500_000)
        XCTAssertEqual(EncoderPlanner.baseBitrate(profileBitrate: 2_500_000, quality: .sharp, mapBoost: false), 4_000_000)
        XCTAssertEqual(EncoderPlanner.baseBitrate(profileBitrate: 2_500_000, quality: .balanced, mapBoost: true), 3_375_000)
        XCTAssertEqual(EncoderPlanner.baseBitrate(profileBitrate: 2_000_000, quality: .smooth, mapBoost: false), 1_400_000)
        XCTAssertEqual(EncoderPlanner.baseBitrate(profileBitrate: 2_000_000, quality: .balanced, mapBoost: false), 2_000_000)
        XCTAssertEqual(EncoderPlanner.baseBitrate(profileBitrate: 2_000_000, quality: .sharp, mapBoost: false), 3_200_000)
        XCTAssertEqual(EncoderPlanner.baseBitrate(profileBitrate: 2_500_000, quality: .sharp, mapBoost: true), 5_400_000)
        XCTAssertEqual(EncoderPlanner.baseBitrate(profileBitrate: 2_500_000, quality: .smooth, mapBoost: true), 2_362_500)
    }

    func testMapBoostAndGop() {
        XCTAssertTrue(EncoderPlanner.isMapBoostActive(ownUI: true, profileFrameRate: 30))
        XCTAssertFalse(EncoderPlanner.isMapBoostActive(ownUI: true, profileFrameRate: 10))   // Morini
        XCTAssertFalse(EncoderPlanner.isMapBoostActive(ownUI: false, profileFrameRate: 30))  // mirror
        XCTAssertEqual(EncoderPlanner.keyframeIntervalSeconds(profileSeconds: 1, mapBoost: true), 1)  // max(1, 0)
        XCTAssertEqual(EncoderPlanner.keyframeIntervalSeconds(profileSeconds: 2, mapBoost: true), 1)
        XCTAssertEqual(EncoderPlanner.keyframeIntervalSeconds(profileSeconds: 4, mapBoost: true), 2)
        XCTAssertEqual(EncoderPlanner.keyframeIntervalSeconds(profileSeconds: 2, mapBoost: false), 2)
    }

    func testPlanOwnUIDefaults() {
        let p = EncoderPlanner.plan(profile: .standard, quality: .balanced, powerMode: .balanced)
        XCTAssertEqual(p, EncoderParameters(bitrate: 3_375_000, frameRate: 24, keyframeIntervalSeconds: 1,
                                            forceBaseline: true, repeatLastFrameAfter: 0.9))
    }

    func testPlanMirrorAndPowerModes() {
        XCTAssertEqual(EncoderPlanner.plan(profile: .standard, quality: .balanced, powerMode: .smooth, ownUI: false),
                       EncoderParameters(bitrate: 2_500_000, frameRate: 30, keyframeIntervalSeconds: 1, forceBaseline: true))
        XCTAssertEqual(EncoderPlanner.plan(profile: .standard, quality: .sharp, powerMode: .saver, ownUI: false).frameRate, 20)
        XCTAssertEqual(EncoderPlanner.plan(profile: .standard, quality: .sharp, powerMode: .saver, ownUI: false).bitrate, 4_000_000)
    }

    func testPlanMorini() {
        let p = EncoderPlanner.plan(profile: .morini, quality: .balanced, powerMode: .balanced)
        XCTAssertEqual(p, EncoderParameters(bitrate: 2_000_000, frameRate: 10, keyframeIntervalSeconds: 2,
                                            forceBaseline: false, repeatLastFrameAfter: 0.9))
    }

    func testPlanAutoUsesAdaptiveDecision() {
        let start = EncoderPlanner.plan(profile: .standard, quality: .balanced, powerMode: .auto)
        XCTAssertEqual(start.frameRate, 30)
        XCTAssertEqual(start.bitrate, 3_375_000)
        let d = AdaptiveDecision(bitrate: 1_500_000, fps: 15, linkFactor: 1)
        let hot = EncoderPlanner.plan(profile: .standard, quality: .balanced, powerMode: .auto, adaptive: d)
        XCTAssertEqual(hot.bitrate, 1_500_000)
        XCTAssertEqual(hot.frameRate, 15)
        // a stale decision above the current base is clamped to the base
        let stale = AdaptiveDecision(bitrate: 9_000_000, fps: 30, linkFactor: 1)
        XCTAssertEqual(EncoderPlanner.plan(profile: .standard, quality: .smooth, powerMode: .auto, ownUI: false, adaptive: stale).bitrate, 1_750_000)
        // fixed modes ignore adaptive state
        XCTAssertEqual(EncoderPlanner.plan(profile: .standard, quality: .balanced, powerMode: .smooth, adaptive: d).frameRate, 30)
    }

    func testLowPowerModeCap() {
        XCTAssertEqual(EncoderPlanner.plan(profile: .standard, quality: .balanced, powerMode: .smooth, lowPowerMode: true).frameRate, 15)
        XCTAssertEqual(EncoderPlanner.plan(profile: .morini, quality: .balanced, powerMode: .smooth, lowPowerMode: true).frameRate, 10)
        let d = AdaptiveDecision(bitrate: 1_000_000, fps: 12, linkFactor: 0.4)
        XCTAssertEqual(EncoderPlanner.plan(profile: .standard, quality: .balanced, powerMode: .auto, adaptive: d, lowPowerMode: true).frameRate, 12)
    }

    func testProfileValues() {
        XCTAssertEqual(EncoderProfileValues.standard, EncoderProfileValues(forceBaseline: true, bitrate: 2_500_000, frameRate: 30, keyframeIntervalSeconds: 1))
        XCTAssertFalse(EncoderProfileValues.morini.forceBaseline)
        XCTAssertEqual(EncoderPlanner.repeatLastFrameAfter, 0.9)
        XCTAssertEqual(EncoderPlanner.lowPowerModeFrameCap, 15)
    }
}
