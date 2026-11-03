// SPDX-License-Identifier: AGPL-3.0-or-later
// Locked iPhone, Phase 0 (P0-7): ProcessCPUMeter, the process CPU load of the `[bg]` / `[bg-probe]`
// lines and the background budget: getrusage on this platform, and the window rules with synthetic
// samples.
import XCTest
@testable import OpenCfMotoCore

final class ProcessCPUMeterTests: XCTestCase {
    private func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    func testProcessCPUTimeIsReadAndNeverGoesBack() throws {
        let a = try XCTUnwrap(ProcessCPUMeter.processCPUSeconds())
        XCTAssertGreaterThan(a, 0)
        var x: UInt64 = 1
        let start = uptime()
        while uptime() - start < 0.05 { x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }
        XCTAssertNotEqual(x, 0)
        let b = try XCTUnwrap(ProcessCPUMeter.processCPUSeconds())
        XCTAssertGreaterThanOrEqual(b, a)
    }

    func testBusyLoopReadsAboveHalfACore() throws {
        var meter = ProcessCPUMeter()
        let start = uptime()
        meter.sample(now: start)
        var x: UInt64 = 1
        while uptime() - start < 0.3 { x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }
        XCTAssertNotEqual(x, 0)
        let end = uptime()
        meter.sample(now: end)
        XCTAssertEqual(meter.samples.count, 2)
        let percent = try XCTUnwrap(meter.percent(window: 15, now: end))
        XCTAssertGreaterThan(percent, 50, "one busy thread for 0.3 s")
    }

    func testIdleWaitStaysLow() throws {
        var meter = ProcessCPUMeter()
        let start = uptime()
        meter.sample(now: start)
        Thread.sleep(forTimeInterval: 0.3)
        let end = uptime()
        meter.sample(now: end)
        let percent = try XCTUnwrap(meter.percent(window: 15, now: end))
        XCTAssertLessThan(percent, 30, "sleeping for 0.3 s")
        XCTAssertGreaterThanOrEqual(percent, 0)
    }

    func testWindowSelection() throws {
        var m = ProcessCPUMeter()
        for (t, cpu) in [(0.0, 0.0), (10, 1), (20, 3), (30, 6)] { m.record(.init(time: t, cpuSeconds: cpu)) }
        // From the newest sample at least 15 s older than the newest (10 s): 5 s of CPU in 20 s.
        XCTAssertEqual(try XCTUnwrap(m.percent(window: 15, now: 30)), 25, accuracy: 1e-9)
        // None 60 s older: from the oldest sample (a shorter span).
        XCTAssertEqual(try XCTUnwrap(m.percent(window: 60, now: 30)), 20, accuracy: 1e-9)
        // `now` between samples: up to the newest sample at or before it.
        XCTAssertEqual(try XCTUnwrap(m.percent(window: 10, now: 25)), 20, accuracy: 1e-9)
        // A sample exactly `window` older qualifies.
        XCTAssertEqual(try XCTUnwrap(m.percent(window: 10, now: 20)), 20, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(m.percent(window: 10, now: 1000)), 30, accuracy: 1e-9)
        // Fewer than two samples up to `now`.
        XCTAssertNil(m.percent(window: 15, now: -1))
        XCTAssertNil(m.percent(window: 15, now: 5))
        var one = ProcessCPUMeter()
        one.record(.init(time: 5, cpuSeconds: 1))
        XCTAssertNil(one.percent(window: 1, now: 10))
        XCTAssertNil(ProcessCPUMeter().percent(window: 1, now: 10))
    }

    func testRecordRules() {
        var m = ProcessCPUMeter(horizon: 30)
        XCTAssertEqual(m.horizon, 30)
        XCTAssertEqual(ProcessCPUMeter().horizon, 120)
        m.record(.init(time: 10, cpuSeconds: 1))
        m.record(.init(time: 5, cpuSeconds: 2))          // older than the newest
        m.record(.init(time: 12, cpuSeconds: 0.5))       // the CPU time went back
        m.record(.init(time: .nan, cpuSeconds: 3))
        m.record(.init(time: 13, cpuSeconds: .infinity))
        XCTAssertEqual(m.samples, [.init(time: 10, cpuSeconds: 1)])
        m.record(.init(time: 10, cpuSeconds: 1.5))       // the same time is kept…
        XCTAssertEqual(m.samples.count, 2)
        XCTAssertNil(m.percent(window: 5, now: 10), "…and never divides by a 0-s span")
        // Samples older than the horizon before the newest are dropped.
        for t in stride(from: 20.0, through: 100, by: 10) { m.record(.init(time: t, cpuSeconds: t / 10)) }
        XCTAssertEqual(m.samples.map(\.time), [70, 80, 90, 100])
        XCTAssertEqual(try XCTUnwrap(m.percent(window: 60, now: 100)), 10, accuracy: 1e-9, "the window is cut to the horizon")
    }

    func testSampleRecordsTheProcessCPUTime() throws {
        var m = ProcessCPUMeter()
        m.sample(now: 7)
        XCTAssertEqual(m.samples.count, 1)
        XCTAssertEqual(m.samples.first?.time, 7)
        XCTAssertGreaterThan(try XCTUnwrap(m.samples.first?.cpuSeconds), 0)
    }
}
