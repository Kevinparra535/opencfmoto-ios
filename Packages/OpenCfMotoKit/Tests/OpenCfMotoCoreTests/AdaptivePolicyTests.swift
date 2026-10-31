// SPDX-License-Identifier: AGPL-3.0-or-later
// AdaptivePolicyTest.kt vectors (media-video.md §14.1) + the stateful controller.

import XCTest
@testable import OpenCfMotoCore

final class AdaptivePolicyTests: XCTestCase {
    private let base = 2_500_000
    private let baseFps = 30

    func testThermalNoneAndLightDoNotThrottle() {
        XCTAssertEqual(AdaptivePolicy.thermalBitrateFactor(status: 0), 1.0)
        XCTAssertEqual(AdaptivePolicy.thermalBitrateFactor(status: 1), 1.0)
        XCTAssertEqual(AdaptivePolicy.thermalBitrateFactor(.none), 1.0)
    }

    func testThermalStepsDownAsItHeats() {
        XCTAssertEqual(AdaptivePolicy.thermalBitrateFactor(status: 2), 0.8)
        XCTAssertEqual(AdaptivePolicy.thermalBitrateFactor(status: 3), 0.6)
        XCTAssertEqual(AdaptivePolicy.thermalBitrateFactor(status: 4), 0.5)
        XCTAssertEqual(AdaptivePolicy.thermalBitrateFactor(status: 6), 0.5)
        XCTAssertEqual(AdaptivePolicy.thermalBitrateFactor(.severe), 0.6)
    }

    func testFpsCapFullWhenCoolThenDrops() {
        XCTAssertEqual(AdaptivePolicy.thermalFpsCap(status: 0, baseFps: baseFps), 30)
        XCTAssertEqual(AdaptivePolicy.thermalFpsCap(status: 1, baseFps: baseFps), 30)
        XCTAssertEqual(AdaptivePolicy.thermalFpsCap(status: 2, baseFps: baseFps), 20)
        XCTAssertEqual(AdaptivePolicy.thermalFpsCap(status: 3, baseFps: baseFps), 15)
        XCTAssertEqual(AdaptivePolicy.thermalFpsCap(status: 5, baseFps: baseFps), 12)
        XCTAssertEqual(AdaptivePolicy.thermalFpsCap(.critical, baseFps: baseFps), 12)
    }

    func testFpsCapNeverExceedsBase() {
        XCTAssertEqual(AdaptivePolicy.thermalFpsCap(status: 0, baseFps: 20), 20)
        XCTAssertEqual(AdaptivePolicy.thermalFpsCap(status: 3, baseFps: 20), 15)
    }

    func testLinkBacksOffOnCongestion() {
        XCTAssertEqual(AdaptivePolicy.nextLinkFactor(1.0, dropsThisTick: AdaptivePolicy.dropCongestionThreshold), 0.8, accuracy: 1e-4)
    }

    func testLinkRecoversGentlyWhenClean() {
        XCTAssertEqual(AdaptivePolicy.nextLinkFactor(0.8, dropsThisTick: 0), 0.85, accuracy: 1e-4)
    }

    func testLinkNeverBelowFloorOrAboveCeiling() {
        var f: Float = 1.0
        for _ in 0 ..< 50 { f = AdaptivePolicy.nextLinkFactor(f, dropsThisTick: 100) }
        XCTAssertEqual(f, AdaptivePolicy.linkMin, accuracy: 1e-4)
        for _ in 0 ..< 200 { f = AdaptivePolicy.nextLinkFactor(f, dropsThisTick: 0) }
        XCTAssertEqual(f, AdaptivePolicy.linkMax, accuracy: 1e-4)
    }

    func testAFewDropsBelowThresholdAreNotCongestion() {
        XCTAssertEqual(AdaptivePolicy.nextLinkFactor(1.0, dropsThisTick: AdaptivePolicy.dropCongestionThreshold - 1), 1.0, accuracy: 1e-4)
    }

    func testCoolAndCleanYieldsFullQuality() {
        let d = AdaptivePolicy.decide(baseBitrate: base, baseFps: baseFps, thermalStatus: 0, prevLinkFactor: 1.0, dropsThisTick: 0)
        XCTAssertEqual(d, AdaptiveDecision(bitrate: 2_500_000, fps: 30, linkFactor: 1.0))
    }

    func testHotReducesBothBitrateAndFps() {
        let d = AdaptivePolicy.decide(baseBitrate: base, baseFps: baseFps, thermalStatus: 3, prevLinkFactor: 1.0, dropsThisTick: 0)
        XCTAssertEqual(d.bitrate, Int(Float(base) * Float(0.6)))
        XCTAssertEqual(d.bitrate, 1_500_000)
        XCTAssertEqual(d.fps, 15)
    }

    func testTheMoreAggressivePressureWinsOnBitrate() {
        let d = AdaptivePolicy.decide(baseBitrate: base, baseFps: baseFps, thermalStatus: 2, prevLinkFactor: 0.5, dropsThisTick: 100)
        XCTAssertEqual(d.linkFactor, 0.4, accuracy: 1e-4)
        XCTAssertEqual(d.bitrate, 1_000_000)
        XCTAssertEqual(d.fps, 20)
    }

    func testBitrateNeverDropsBelowTheFloor() {
        let d = AdaptivePolicy.decide(baseBitrate: 1_000_000, baseFps: baseFps, thermalStatus: 6, prevLinkFactor: AdaptivePolicy.linkMin, dropsThisTick: 100)
        XCTAssertGreaterThanOrEqual(d.bitrate, AdaptivePolicy.minBitrate)
        XCTAssertEqual(d.bitrate, 600_000)
    }

    func testFloorIsCappedByBaseWhenBaseIsTiny() {
        let d = AdaptivePolicy.decide(baseBitrate: 400_000, baseFps: baseFps, thermal: .shutdown, prevLinkFactor: AdaptivePolicy.linkMin, dropsThisTick: 100)
        XCTAssertLessThanOrEqual(d.bitrate, 400_000)
        XCTAssertEqual(d.bitrate, 400_000)
    }

    func testIOSThermalMapping() {
        XCTAssertEqual(ThermalLevel.fromProcessInfoThermalState(rawValue: 0), .none)
        XCTAssertEqual(ThermalLevel.fromProcessInfoThermalState(rawValue: 1), .moderate)
        XCTAssertEqual(ThermalLevel.fromProcessInfoThermalState(rawValue: 2), .severe)
        XCTAssertEqual(ThermalLevel.fromProcessInfoThermalState(rawValue: 3), .critical)
        XCTAssertEqual(ThermalLevel.moderate.androidName, "moderate")
        XCTAssertEqual(PowerMode.saver.englishLabel, "Battery saver \u{2014} 20 fps (coolest)")
        XCTAssertEqual(AdaptivePolicy.tickInterval, 5)
    }

    // MARK: Controller

    func testControllerTicks() {
        let c = AdaptiveController()
        XCTAssertNil(c.tick(powerMode: .auto, baseBitrate: 0, thermal: .none, overflowTotal: 0))       // no encoder yet
        XCTAssertEqual(c.tick(powerMode: .auto, baseBitrate: base, thermal: .none, overflowTotal: 0),
                       AdaptiveController.Adjustment(bitrate: 2_500_000, fps: 30))                    // first apply
        XCTAssertNil(c.tick(powerMode: .auto, baseBitrate: base, thermal: .none, overflowTotal: 3))    // 3 drops: clean
        // 8 more drops in this tick (cumulative 11) → link 0.8 → 2 000 000
        XCTAssertEqual(c.tick(powerMode: .auto, baseBitrate: base, thermal: .none, overflowTotal: 11),
                       AdaptiveController.Adjustment(bitrate: 2_000_000, fps: nil))
        XCTAssertEqual(c.currentLinkFactor, 0.8, accuracy: 1e-6)
        // heat: fps follows thermal, bitrate = min(0.6, 0.85)
        XCTAssertEqual(c.tick(powerMode: .auto, baseBitrate: base, thermal: .severe, overflowTotal: 11),
                       AdaptiveController.Adjustment(bitrate: 1_500_000, fps: 15))
        XCTAssertEqual(c.lastDecision?.fps, 15)
        // switching to a fixed mode restores once, then stays out
        XCTAssertEqual(c.tick(powerMode: .balanced, baseBitrate: base, thermal: .severe, overflowTotal: 11),
                       AdaptiveController.Adjustment(bitrate: 2_500_000, fps: 24))
        XCTAssertNil(c.tick(powerMode: .balanced, baseBitrate: base, thermal: .severe, overflowTotal: 50))
        XCTAssertEqual(c.currentLinkFactor, 1.0)
    }

    func testControllerCountersNeverNegative() {
        let c = AdaptiveController()
        _ = c.tick(powerMode: .auto, baseBitrate: base, thermal: .none, overflowTotal: 100)  // 100 "drops" first tick
        XCTAssertEqual(c.currentLinkFactor, 0.8, accuracy: 1e-6)
        _ = c.tick(powerMode: .auto, baseBitrate: base, thermal: .none, overflowTotal: 0)    // counter reset → 0 drops
        XCTAssertEqual(c.currentLinkFactor, 0.85, accuracy: 1e-6)
        c.reset()
        XCTAssertNil(c.lastDecision)
        XCTAssertNil(c.tick(powerMode: .smooth, baseBitrate: base, thermal: .none, overflowTotal: 0)) // never adapted
    }
}
