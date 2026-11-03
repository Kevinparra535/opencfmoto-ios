// SPDX-License-Identifier: AGPL-3.0-or-later
// Locked iPhone, Phase 0: the pure rules of the background encoder ladder (design §3.3, §3.6, §3.9):
// the rungs per policy, acceptance, demotion (EncoderHealth), the retry from hold, the budget governor
// (every rule and its hysteresis, with the returned change record) and the background parameters.
import XCTest
@testable import OpenCfMotoCore

final class BackgroundEncodingTests: XCTestCase {
    // MARK: - Policy and rungs

    func testPolicyAndRungRawValues() throws {
        XCTAssertEqual(LockedStreamPolicy.allCases.map(\.rawValue), ["auto", "cpu", "vtsw", "hold", "cpu-always"])
        XCTAssertEqual(LockedStreamPolicy(rawValue: "vtsw"), .videoToolboxSoftwareOnly)
        XCTAssertNil(LockedStreamPolicy(rawValue: "VTSW"))
        XCTAssertNil(LockedStreamPolicy(rawValue: ""))
        let json = try JSONEncoder().encode([LockedStreamPolicy.cpuAlways])
        XCTAssertEqual(String(data: json, encoding: .utf8), "[\"cpu-always\"]")
        XCTAssertEqual(try JSONDecoder().decode([LockedStreamPolicy].self, from: Data("[\"auto\"]".utf8)), [.automatic])
        XCTAssertEqual(BackgroundRung.allCases.map(\.rawValue), ["vt-sw", "cpu", "hold"])
    }

    func testRungsTable() {
        typealias L = BackgroundEncoderLadder
        let all: [(LockedStreamPolicy, Bool, Bool, [BackgroundRung])] = [
            (.automatic, true, true, [.videoToolboxSoftware, .cpu, .hold]),
            (.automatic, true, false, [.videoToolboxSoftware, .hold]),
            (.automatic, false, true, [.cpu, .hold]),
            (.automatic, false, false, [.hold]),
            (.cpuOnly, true, true, [.cpu, .hold]),
            (.cpuOnly, true, false, [.hold]),
            (.cpuOnly, false, true, [.cpu, .hold]),
            (.cpuOnly, false, false, [.hold]),
            (.videoToolboxSoftwareOnly, true, true, [.videoToolboxSoftware, .hold]),
            (.videoToolboxSoftwareOnly, true, false, [.videoToolboxSoftware, .hold]),
            (.videoToolboxSoftwareOnly, false, true, [.hold]),
            (.videoToolboxSoftwareOnly, false, false, [.hold]),
            (.holdOnly, true, true, [.hold]),
            (.holdOnly, true, false, [.hold]),
            (.holdOnly, false, true, [.hold]),
            (.holdOnly, false, false, [.hold]),
            (.cpuAlways, true, true, [.cpu, .hold]),
            (.cpuAlways, true, false, [.hold]),
            (.cpuAlways, false, true, [.cpu, .hold]),
            (.cpuAlways, false, false, [.hold]),
        ]
        XCTAssertEqual(all.count, LockedStreamPolicy.allCases.count * 4, "every policy × availability")
        for (policy, vt, cpu, expected) in all {
            XCTAssertEqual(L.rungs(policy: policy, vtSoftwareAvailable: vt, cpuAvailable: cpu), expected, "\(policy) vt=\(vt) cpu=\(cpu)")
        }
    }

    func testNextRung() {
        typealias L = BackgroundEncoderLadder
        let full: [BackgroundRung] = [.videoToolboxSoftware, .cpu, .hold]
        XCTAssertEqual(L.next(after: .videoToolboxSoftware, in: full), .cpu)
        XCTAssertEqual(L.next(after: .cpu, in: full), .hold, "the last encoder rung")
        XCTAssertEqual(L.next(after: .hold, in: full), .hold)
        XCTAssertEqual(L.next(after: .videoToolboxSoftware, in: [.videoToolboxSoftware, .hold]), .hold)
        XCTAssertEqual(L.next(after: .cpu, in: [.videoToolboxSoftware, .hold]), .hold, "a rung not in the list")
        XCTAssertEqual(L.next(after: .videoToolboxSoftware, in: [.hold]), .hold)
        XCTAssertEqual(L.next(after: .videoToolboxSoftware, in: []), .hold)
    }

    // MARK: - Acceptance

    private func decide(_ rung: BackgroundRung = .videoToolboxSoftware, created: Bool = true, hw: Bool? = false,
                        probe: ProbeOutcome = .keyframe(bytes: 20112, ms: 45), issues: [H264StreamIssue] = []) -> EncoderAcceptance.Verdict {
        EncoderAcceptance.decide(rung: rung, created: created, usesHardware: hw, probe: probe, issues: issues)
    }

    func testAcceptanceReasons() {
        XCTAssertEqual(EncoderAcceptance.videoToolboxProbeLimitMs, 500)
        XCTAssertEqual(decide(), .accept)
        XCTAssertEqual(decide(created: false), .reject("not created"))
        XCTAssertEqual(decide(.cpu, created: false), .reject("not created"))
        XCTAssertEqual(decide(hw: true), .reject("hw=true"))
        XCTAssertEqual(decide(probe: .failed(code: -12903)), .reject("probe failed -12903"))
        XCTAssertEqual(decide(probe: .failed(code: nil)), .reject("probe failed"))
        XCTAssertEqual(decide(probe: .nothing(waitedMs: 500)), .reject("probe=none"))
        XCTAssertEqual(decide(probe: .keyframe(bytes: 0, ms: 3)), .reject("probe empty"))
        XCTAssertEqual(decide(probe: .keyframe(bytes: -1, ms: 3)), .reject("probe empty"))
        XCTAssertEqual(decide(probe: .keyframe(bytes: 9, ms: 612.4)), .reject("probe slow (612ms)"))
        XCTAssertEqual(decide(probe: .keyframe(bytes: 9, ms: 500)), .accept, "exactly the limit is in time")
        XCTAssertEqual(decide(probe: .keyframe(bytes: 9, ms: 500.6)), .reject("probe slow (501ms)"))
        XCTAssertEqual(decide(issues: [.size(width: 1280, height: 576), .level(22)]), .reject("sps: size-1280x576,level-22"))
        XCTAssertEqual(decide(issues: [.cabac]), .reject("sps: cabac"))
    }

    func testUnknownHardwareIsAcceptedOnlyWithAProbeIDR() {
        XCTAssertEqual(decide(hw: nil), .accept, "hw=? with a probe IDR (the CM F2 case)")
        XCTAssertEqual(decide(hw: nil, probe: .nothing(waitedMs: 500)), .reject("probe=none"))
        XCTAssertEqual(decide(hw: nil, probe: .failed(code: -12915)), .reject("probe failed -12915"))
        XCTAssertEqual(decide(hw: nil, issues: [.notIDR]), .reject("sps: no-idr"))
    }

    func testAcceptanceIsPerRung() {
        // hold needs no encoder; the CPU rung has no hardware question and no time limit.
        XCTAssertEqual(decide(.hold, created: false, hw: true, probe: .nothing(waitedMs: 0), issues: [.cabac]), .accept)
        XCTAssertEqual(decide(.cpu, hw: true), .accept)
        XCTAssertEqual(decide(.cpu, hw: nil), .accept)
        XCTAssertEqual(decide(.cpu, probe: .keyframe(bytes: 10, ms: 4000)), .accept)
        XCTAssertEqual(decide(.cpu, probe: .nothing(waitedMs: 500)), .reject("probe=none"))
        XCTAssertEqual(decide(.cpu, issues: [.size(width: 1, height: 2), .cabac]), .reject("sps: size-1x2,cabac"))
    }

    func testAcceptanceFirstMatchWins() {
        XCTAssertEqual(decide(created: false, hw: true, probe: .failed(code: 1), issues: [.cabac]), .reject("not created"))
        XCTAssertEqual(decide(hw: true, probe: .failed(code: 1), issues: [.cabac]), .reject("hw=true"))
        XCTAssertEqual(decide(probe: .failed(code: 1), issues: [.cabac]), .reject("probe failed 1"))
        XCTAssertEqual(decide(probe: .nothing(waitedMs: 1), issues: [.cabac]), .reject("probe=none"))
        XCTAssertEqual(decide(probe: .keyframe(bytes: 0, ms: 900), issues: [.cabac]), .reject("probe empty"))
        XCTAssertEqual(decide(probe: .keyframe(bytes: 10, ms: 900), issues: [.cabac]), .reject("probe slow (900ms)"))
    }

    // MARK: - Retry from hold

    func testRetryRule() {
        typealias L = BackgroundEncoderLadder
        XCTAssertEqual(L.retryDelay, 60)
        XCTAssertEqual(L.maxRetriesPerBackgroundPeriod, 3)
        // Demotion: due 60 s after the hold began.
        XCTAssertFalse(L.shouldRetry(after: .demoted, holdSince: 100, budgetClearSince: nil, attempts: 0, now: 159.9))
        XCTAssertTrue(L.shouldRetry(after: .demoted, holdSince: 100, budgetClearSince: nil, attempts: 0, now: 160))
        XCTAssertTrue(L.shouldRetry(after: .demoted, holdSince: 100, budgetClearSince: nil, attempts: 2, now: 160))
        XCTAssertFalse(L.shouldRetry(after: .demoted, holdSince: 100, budgetClearSince: nil, attempts: 3, now: 1000), "3 per period")
        XCTAssertFalse(L.shouldRetry(after: .demoted, holdSince: 100, budgetClearSince: nil, attempts: 4, now: 1000))
        // Budget: due 60 s after the budget became clear; never while it is not.
        XCTAssertFalse(L.shouldRetry(after: .budget("thermal critical"), holdSince: 0, budgetClearSince: nil, attempts: 0, now: 1000))
        XCTAssertFalse(L.shouldRetry(after: .budget("x"), holdSince: 0, budgetClearSince: 10, attempts: 0, now: 69.9))
        XCTAssertTrue(L.shouldRetry(after: .budget("x"), holdSince: 0, budgetClearSince: 10, attempts: 0, now: 70))
        XCTAssertFalse(L.shouldRetry(after: .budget("x"), holdSince: 0, budgetClearSince: 10, attempts: 3, now: 700))
        // Holds that are not retried: policy, no encoder rung, every rung rejected at entry.
        for cause in [HoldCause.policy, .noEncoderRung, .allRungsRejected] {
            XCTAssertFalse(L.shouldRetry(after: cause, holdSince: 0, budgetClearSince: 0, attempts: 0, now: 10_000), "\(cause)")
            XCTAssertFalse(cause.isRetryable)
        }
        XCTAssertTrue(HoldCause.demoted.isRetryable)
        XCTAssertTrue(HoldCause.budget("low power mode").isRetryable)
    }

    // MARK: - Demotion

    func testThreeFailuresWithinTenSecondsDemote() {
        var h = EncoderHealth(rung: .videoToolboxSoftware)
        XCTAssertEqual(h.failure("a", requiresRecreation: false, now: 0), .healthy)
        XCTAssertEqual(h.failure("b", requiresRecreation: false, now: 5), .healthy)
        XCTAssertEqual(h.failure("VT output error: kVTInvalidSessionErr", requiresRecreation: false, now: 10),
                       .demote(reason: "3 encode errors in 10s (last VT output error: kVTInvalidSessionErr)"), "10 s is inside the window")
        // Spread over more than 10 s: the oldest one has left the window.
        var spread = EncoderHealth(rung: .videoToolboxSoftware)
        XCTAssertEqual(spread.failure("a", requiresRecreation: false, now: 0), .healthy)
        XCTAssertEqual(spread.failure("b", requiresRecreation: false, now: 5), .healthy)
        XCTAssertEqual(spread.failure("c", requiresRecreation: false, now: 10.5), .healthy)
        XCTAssertEqual(spread.failureTimes, [5, 10.5])
        XCTAssertEqual(spread.failure("d", requiresRecreation: false, now: 14), .demote(reason: "3 encode errors in 10s (last d)"))
        // The CPU rung counts ordinary failures the same way.
        var cpu = EncoderHealth(rung: .cpu)
        XCTAssertEqual(cpu.failure("x", requiresRecreation: false, now: 0), .healthy)
        XCTAssertEqual(cpu.failure("x", requiresRecreation: false, now: 1), .healthy)
        XCTAssertEqual(cpu.failure("y", requiresRecreation: false, now: 2), .demote(reason: "3 encode errors in 10s (last y)"))
    }

    func testRecreationFailures() {
        // CPU: unrecoverable at once. VideoToolbox: today's recreate path, it only counts.
        var cpu = EncoderHealth(rung: .cpu)
        XCTAssertEqual(cpu.failure("boom", requiresRecreation: true, now: 0), .demote(reason: "unrecoverable error (boom)"))
        var vt = EncoderHealth(rung: .videoToolboxSoftware)
        XCTAssertEqual(vt.failure("invalid session", requiresRecreation: true, now: 0), .healthy)
        XCTAssertEqual(vt.failure("invalid session", requiresRecreation: true, now: 1), .healthy)
        XCTAssertEqual(vt.failure("invalid session", requiresRecreation: true, now: 2),
                       .demote(reason: "3 encode errors in 10s (last invalid session)"))
    }

    func testOutputStall() {
        XCTAssertEqual(EncoderHealth.outputStallLimit, 3)
        var h = EncoderHealth(rung: .videoToolboxSoftware)
        XCTAssertEqual(h.check(now: 100), .healthy, "nothing submitted")
        XCTAssertEqual(h.submitted(accepted: true, now: 20), .healthy)
        XCTAssertEqual(h.submitted(accepted: true, now: 21), .healthy)
        XCTAssertEqual(h.pendingSince, 20, "the oldest submission without output")
        XCTAssertEqual(h.check(now: 22.9), .healthy)
        XCTAssertEqual(h.check(now: 23), .demote(reason: "no output for 3s"))
        h.output(now: 23)
        XCTAssertNil(h.pendingSince, "any output clears it")
        XCTAssertEqual(h.check(now: 30), .healthy)
        // Refused submissions do not start the clock.
        XCTAssertEqual(h.submitted(accepted: false, now: 31), .healthy)
        XCTAssertEqual(h.check(now: 40), .healthy)
        // The CPU encoder is synchronous: no stall rule.
        var cpu = EncoderHealth(rung: .cpu)
        XCTAssertEqual(cpu.submitted(accepted: true, now: 0), .healthy)
        XCTAssertEqual(cpu.check(now: 100), .healthy)
    }

    func testRefusals() {
        XCTAssertEqual(EncoderHealth.refusalLimit, 3)
        var cpu = EncoderHealth(rung: .cpu)
        XCTAssertEqual(cpu.submitted(accepted: false, now: 0), .healthy)
        XCTAssertEqual(cpu.submitted(accepted: false, now: 0.1), .healthy)
        XCTAssertEqual(cpu.submitted(accepted: true, now: 0.2), .healthy, "an accepted encode ends the run")
        XCTAssertEqual(cpu.consecutiveRefusals, 0)
        XCTAssertEqual(cpu.submitted(accepted: false, now: 0.3), .healthy)
        XCTAssertEqual(cpu.submitted(accepted: false, now: 0.4), .healthy)
        XCTAssertEqual(cpu.submitted(accepted: false, now: 0.5), .demote(reason: "3 encodes refused in a row"))
        // VideoToolbox refuses while it re-creates its session: refusals never demote it.
        var vt = EncoderHealth(rung: .videoToolboxSoftware)
        for i in 0 ..< 10 { XCTAssertEqual(vt.submitted(accepted: false, now: Double(i)), .healthy) }
        XCTAssertEqual(vt.consecutiveRefusals, 0)
    }

    // MARK: - Budget

    private typealias B = BackgroundBudget

    private func inputs(_ now: TimeInterval, cpu15: Double? = nil, cpu60: Double? = nil, thermal: ThermalLevel = .none,
                        lowPower: Bool = false, battery: BatteryStatus? = nil) -> B.Inputs {
        B.Inputs(now: now, cpu15s: cpu15, cpu60s: cpu60, thermal: thermal, lowPowerMode: lowPower, battery: battery)
    }

    /// Evaluates and returns (from, to, reason) of the change, nil when the limit stayed.
    private func step(_ b: inout B, _ i: B.Inputs, file: StaticString = #filePath, line: UInt = #line) -> String? {
        guard let c = b.evaluate(i) else { return nil }
        XCTAssertEqual(c.inputs, i, "the change carries its inputs", file: file, line: line)
        XCTAssertEqual(c.to, b.limit, file: file, line: line)
        func name(_ l: B.Limit) -> String {
            switch l {
            case let .fps(f): return "\(f)"
            case .hold: return "hold"
            }
        }
        return "\(name(c.from))→\(name(c.to)): \(c.reason)"
    }

    func testBudgetConstants() {
        XCTAssertEqual(B.fpsSteps, [8, 5, 3, 2])
        XCTAssertEqual([B.cpuStepDownPercent, B.cpuStepUpPercent, B.cpuHoldPercent, B.cpuHoldSeconds], [20, 10, 40, 30])
        XCTAssertEqual([B.lowBatteryPercent, B.criticalBatteryPercent], [20, 10])
        let b = B()
        XCTAssertEqual(b.startFps, 8)
        XCTAssertEqual(b.limit, .fps(8))
        XCTAssertNil(b.clearSince)
        XCTAssertEqual(B(startFps: 8).cpuSteps, [8, 5, 3, 2])
        XCTAssertEqual(B(startFps: 5).cpuSteps, [5, 3, 2])
        XCTAssertEqual(B(startFps: 12).cpuSteps, [12, 8, 5, 3, 2])
    }

    func testBudgetCPUStepsDownHoldsResumesAndStepsUp() {
        var b = B()
        // Step down one step per fresh 15-s window above 20 %.
        XCTAssertNil(step(&b, inputs(0, cpu15: 25)), "the first window opens at the first evaluation")
        XCTAssertNil(step(&b, inputs(14.9, cpu15: 25)))
        XCTAssertEqual(step(&b, inputs(15, cpu15: 25)), "8→5: cpu 25% (15s)")
        XCTAssertNil(step(&b, inputs(20, cpu15: 30)), "a step needs a 15-s average taken entirely at the new rate")
        XCTAssertEqual(step(&b, inputs(30, cpu15: 26.6)), "5→3: cpu 27% (15s)")
        XCTAssertEqual(step(&b, inputs(45, cpu15: 25)), "3→2: cpu 25% (15s)")
        XCTAssertNil(step(&b, inputs(60, cpu15: 25)), "2 fps is the lowest step")
        // Above 40 % for 30 s at the lowest step: hold.
        XCTAssertNil(step(&b, inputs(65, cpu15: 45)))
        XCTAssertNil(step(&b, inputs(94.9, cpu15: 45)))
        XCTAssertEqual(step(&b, inputs(95, cpu15: 45)), "2→hold: cpu 45% for 30s")
        XCTAssertEqual(b.limit, .hold)
        XCTAssertNil(b.clearSince)
        // In hold the encoder is gone and the load drops: released at ≤ 20 %, back after 60 s clear.
        XCTAssertNil(step(&b, inputs(100, cpu15: 30, cpu60: 30)), "still above 20 %")
        XCTAssertNil(b.clearSince)
        XCTAssertNil(step(&b, inputs(105, cpu15: 15, cpu60: 25)))
        XCTAssertEqual(b.clearSince, 105)
        XCTAssertNil(step(&b, inputs(164.9, cpu15: 2, cpu60: 5)))
        XCTAssertEqual(step(&b, inputs(165, cpu15: 2, cpu60: 5)), "hold→2: clear", "resumes at the CPU cap (the lowest step)")
        // One step up per fresh 60-s window below 10 %, never above the start value.
        XCTAssertNil(step(&b, inputs(224.9, cpu15: 4, cpu60: 5)))
        XCTAssertEqual(step(&b, inputs(225, cpu15: 4, cpu60: 5)), "2→3: cpu 5% (60s)")
        XCTAssertNil(step(&b, inputs(270, cpu15: 4, cpu60: 5)))
        XCTAssertEqual(step(&b, inputs(285, cpu15: 4, cpu60: 5)), "3→5: cpu 5% (60s)")
        XCTAssertEqual(step(&b, inputs(345, cpu15: 4, cpu60: 5)), "5→8: cpu 5% (60s)")
        XCTAssertNil(step(&b, inputs(1000, cpu15: 4, cpu60: 1)))
        XCTAssertEqual(b.limit, .fps(8))
    }

    func testBudgetHoldEndsExactlyWhenTheEngineRetries() {
        // The engine's retry rule for a budget hold uses clearSince: it fires at the same evaluation as
        // the budget's own resume.
        var b = B()
        XCTAssertEqual(step(&b, inputs(0, thermal: .critical)), "8→hold: thermal critical")
        let cause = HoldCause.budget("thermal critical")
        var resumedAt: TimeInterval?
        for t in stride(from: 5.0, through: 120, by: 5) where resumedAt == nil {
            let resumed = step(&b, inputs(t, thermal: t >= 30 ? .none : .severe)) != nil
            let retry = BackgroundEncoderLadder.shouldRetry(after: cause, holdSince: 0, budgetClearSince: b.clearSince,
                                                            attempts: 0, now: t)
            XCTAssertEqual(resumed, retry, "at \(t) s")
            if resumed { resumedAt = t }
        }
        XCTAssertEqual(resumedAt, 90, "clear since 30 s, resumed 60 s later")
    }

    func testBudgetCPUHysteresisBand() {
        // Between 10 % and 20 % nothing moves, in either direction.
        var b = B()
        XCTAssertNil(step(&b, inputs(0, cpu15: 30)))
        XCTAssertEqual(step(&b, inputs(15, cpu15: 30)), "8→5: cpu 30% (15s)")
        for t in stride(from: 20.0, through: 600, by: 5) {
            XCTAssertNil(step(&b, inputs(t, cpu15: 20, cpu60: 10)), "at \(t) s")
        }
        XCTAssertEqual(b.limit, .fps(5))
        XCTAssertEqual(b.clearSince, 20, "20 % is not above the step-down threshold: the CPU is clear")
        // Exactly 40 % at the lowest step never starts the hold clock.
        var low = B(startFps: 2)
        for t in stride(from: 0.0, through: 200, by: 5) { XCTAssertNil(step(&low, inputs(t, cpu15: 40)), "at \(t) s") }
    }

    func testBudgetCPUHoldNeedsThirtySecondsInARow() {
        var b = B(startFps: 2)
        XCTAssertNil(step(&b, inputs(0, cpu15: 45)))
        XCTAssertNil(step(&b, inputs(25, cpu15: 45)))
        XCTAssertNil(step(&b, inputs(26, cpu15: 39)), "a dip below 40 % restarts the clock")
        XCTAssertNil(step(&b, inputs(30, cpu15: 45)))
        XCTAssertNil(step(&b, inputs(59.9, cpu15: 45)))
        XCTAssertEqual(step(&b, inputs(60, cpu15: 41)), "2→hold: cpu 41% for 30s")
    }

    func testBudgetCPUStepsBelowAnotherCapAfterAFreshWindow() {
        var b = B()
        XCTAssertEqual(step(&b, inputs(0, lowPower: true)), "8→5: low power mode")
        // Any change of the limit restarts the CPU window.
        XCTAssertNil(step(&b, inputs(10, cpu15: 30, lowPower: true)))
        XCTAssertEqual(step(&b, inputs(15, cpu15: 30, lowPower: true)), "5→3: cpu 30% (15s)", "one step below the current limit")
        // Low Power Mode ends; the CPU cap (3) still limits and recovers by the step-up rule only.
        XCTAssertNil(step(&b, inputs(20, cpu15: 15, cpu60: 12)))
        XCTAssertEqual(b.clearSince, 20)
        XCTAssertNil(step(&b, inputs(74.9, cpu15: 5, cpu60: 5)))
        XCTAssertEqual(step(&b, inputs(75, cpu15: 5, cpu60: 5)), "3→5: cpu 5% (60s)")
    }

    func testBudgetCPUStaysAtTheLowestStepAnotherCapSet() {
        var b = B()
        XCTAssertEqual(step(&b, inputs(0, thermal: .severe)), "8→2: thermal severe")
        // Over budget even at 2 fps: the CPU cap moves down to 2 too (no change of the limit).
        XCTAssertNil(step(&b, inputs(15, cpu15: 30, thermal: .severe)))
        // The phone cools down: the CPU cap keeps the rate at 2 until the load allows a step up.
        XCTAssertNil(step(&b, inputs(20, cpu15: 15, thermal: .none)))
        XCTAssertEqual(b.limit, .fps(2))
        XCTAssertEqual(step(&b, inputs(60, cpu15: 5, cpu60: 5)), "2→3: cpu 5% (60s)")
    }

    func testBudgetCPUStepUpOnlyWhileItLimits() {
        var b = B()
        XCTAssertNil(step(&b, inputs(0, cpu15: 30)))
        XCTAssertEqual(step(&b, inputs(15, cpu15: 30)), "8→5: cpu 30% (15s)")
        XCTAssertEqual(step(&b, inputs(20, cpu15: 5, thermal: .severe)), "5→2: thermal severe")
        // Low load measured at 2 fps says nothing about 5 fps: the CPU cap does not move.
        XCTAssertNil(step(&b, inputs(200, cpu15: 1, cpu60: 1, thermal: .severe)))
        XCTAssertEqual(step(&b, inputs(205, cpu15: 1, cpu60: 1)), "2→5: cpu 30% (15s)",
                       "the thermal cap lifted, the CPU cap (with its reason) limits")
        XCTAssertNil(step(&b, inputs(264.9, cpu15: 1, cpu60: 1)))
        XCTAssertEqual(step(&b, inputs(265, cpu15: 1, cpu60: 1)), "5→8: cpu 1% (60s)")
    }

    func testBudgetNoCPUStepInHold() {
        var b = B()
        XCTAssertEqual(step(&b, inputs(0, thermal: .critical)), "8→hold: thermal critical")
        for t in stride(from: 5.0, through: 100, by: 5) { XCTAssertNil(step(&b, inputs(t, cpu15: 50, thermal: .critical))) }
        // A load above 20 % keeps the budget from being clear, even with the phone cool.
        XCTAssertNil(step(&b, inputs(105, cpu15: 50)))
        XCTAssertNil(b.clearSince)
        XCTAssertNil(step(&b, inputs(110, cpu15: 10)))
        XCTAssertEqual(b.clearSince, 110)
        XCTAssertEqual(step(&b, inputs(170, cpu15: 10)), "hold→8: clear", "the CPU cap never moved in hold")
    }

    func testBudgetThermal() {
        var b = B()
        XCTAssertNil(step(&b, inputs(0, thermal: .light)), "light: no cap")
        XCTAssertEqual(b.clearSince, 0)
        XCTAssertEqual(step(&b, inputs(1, thermal: .moderate)), "8→5: thermal moderate")
        XCTAssertNil(b.clearSince)
        XCTAssertEqual(step(&b, inputs(2, thermal: .severe)), "5→2: thermal severe")
        XCTAssertEqual(step(&b, inputs(3, thermal: .critical)), "2→hold: thermal critical")
        XCTAssertNil(step(&b, inputs(4, thermal: .severe)), "hold stays until everything is clear")
        XCTAssertNil(step(&b, inputs(5, thermal: .moderate)))
        XCTAssertNil(b.clearSince)
        XCTAssertNil(step(&b, inputs(6, thermal: .none)))
        XCTAssertEqual(b.clearSince, 6)
        XCTAssertNil(step(&b, inputs(65.9)))
        XCTAssertEqual(step(&b, inputs(66)), "hold→8: clear")
        XCTAssertEqual(step(&b, inputs(67, thermal: .emergency)), "8→hold: thermal emergency")
        // The thermal caps apply at once in both directions.
        var c = B()
        XCTAssertEqual(step(&c, inputs(0, thermal: .severe)), "8→2: thermal severe")
        XCTAssertEqual(step(&c, inputs(0.1, thermal: .moderate)), "2→5: thermal moderate")
        XCTAssertEqual(step(&c, inputs(0.2, thermal: .none)), "5→8: clear")
    }

    func testBudgetLowPowerMode() {
        var b = B()
        XCTAssertEqual(step(&b, inputs(0, lowPower: true)), "8→5: low power mode")
        XCTAssertNil(b.clearSince)
        XCTAssertNil(step(&b, inputs(100, lowPower: true)))
        XCTAssertEqual(step(&b, inputs(101)), "5→8: clear")
        XCTAssertEqual(b.clearSince, 101)
    }

    func testBudgetBattery() {
        func batt(_ level: Double?, _ state: BatteryStatus.State) -> BatteryStatus { BatteryStatus(level: level, state: state) }
        var b = B()
        XCTAssertNil(step(&b, inputs(0, battery: batt(0.5, .unplugged))))
        XCTAssertEqual(step(&b, inputs(1, battery: batt(0.2, .unplugged))), "8→3: battery 20% unplugged")
        XCTAssertEqual(step(&b, inputs(2, battery: batt(0.21, .unplugged))), "3→8: clear")
        XCTAssertEqual(step(&b, inputs(3, battery: batt(0.15, .unplugged))), "8→3: battery 15% unplugged")
        XCTAssertEqual(step(&b, inputs(4, battery: batt(0.1, .unplugged))), "3→hold: battery 10% unplugged")
        // Plugged in: no battery cap at any level.
        XCTAssertNil(step(&b, inputs(5, battery: batt(0.05, .charging))))
        XCTAssertEqual(b.clearSince, 5)
        XCTAssertEqual(step(&b, inputs(65, battery: batt(0.05, .charging))), "hold→8: clear")
        for battery in [batt(0.01, .full), batt(0.01, .unknown), batt(nil, .unplugged), nil] {
            XCTAssertNil(step(&b, inputs(70, battery: battery)), "\(String(describing: battery))")
            XCTAssertEqual(b.limit, .fps(8))
        }
    }

    func testBudgetReasonPriorities() {
        // Several caps at the same value: thermal, battery, Low Power Mode, CPU.
        var b = B()
        XCTAssertEqual(step(&b, inputs(0, thermal: .moderate, lowPower: true)), "8→5: thermal moderate")
        var c = B()
        XCTAssertEqual(step(&c, inputs(0, thermal: .moderate, battery: BatteryStatus(level: 0.15, state: .unplugged))),
                       "8→3: battery 15% unplugged", "the lowest cap wins")
        // Lifting one cap: the next one names the new limit.
        var d = B()
        XCTAssertEqual(step(&d, inputs(0, thermal: .severe, lowPower: true)), "8→2: thermal severe")
        XCTAssertEqual(step(&d, inputs(1, lowPower: true)), "2→5: low power mode")
        // Several holds: thermal, battery, CPU.
        var e = B()
        XCTAssertEqual(step(&e, inputs(0, thermal: .critical, battery: BatteryStatus(level: 0.05, state: .unplugged))),
                       "8→hold: thermal critical")
        var f = B(startFps: 2)
        XCTAssertNil(step(&f, inputs(0, cpu15: 50)))
        XCTAssertEqual(step(&f, inputs(30, cpu15: 50, battery: BatteryStatus(level: 0.05, state: .unplugged))),
                       "2→hold: battery 5% unplugged")
    }

    func testBudgetClearSince() {
        var b = B()
        XCTAssertNil(step(&b, inputs(10)))
        XCTAssertEqual(b.clearSince, 10, "clear from the first evaluation")
        XCTAssertNil(step(&b, inputs(15)))
        XCTAssertEqual(b.clearSince, 10, "kept while clear")
        XCTAssertNil(step(&b, inputs(20, cpu15: 21)), "too early for a CPU step (10 s window)")
        XCTAssertNil(b.clearSince, "over budget is not clear")
        XCTAssertNil(step(&b, inputs(22, cpu15: 5)))
        XCTAssertEqual(b.clearSince, 22)
    }

    func testBudgetIgnoresNonFiniteCPU() {
        var b = B()
        for (t, value) in [(0.0, Double.nan), (20, .infinity), (40, -.infinity)] {
            XCTAssertNil(step(&b, inputs(t, cpu15: value, cpu60: value)))
            XCTAssertEqual(b.clearSince, 0, "an unmeasurable load counts as unmeasured")
        }
        XCTAssertEqual(b.limit, .fps(8))
        // A huge (finite) value is rounded into the reason without trapping.
        XCTAssertEqual(step(&b, inputs(50, cpu15: 1e300)), "8→5: cpu 1000000% (15s)")
    }

    func testBudgetOtherStartRate() {
        var b = B(startFps: 5)
        XCTAssertNil(step(&b, inputs(0, thermal: .moderate, lowPower: true)), "caps at the start rate change nothing")
        XCTAssertEqual(step(&b, inputs(15, cpu15: 30, thermal: .moderate, lowPower: true)), "5→3: cpu 30% (15s)")
        XCTAssertEqual(step(&b, inputs(16, cpu15: 15)), nil)
        XCTAssertEqual(step(&b, inputs(76, cpu15: 1, cpu60: 1)), "3→5: cpu 1% (60s)")
        XCTAssertNil(step(&b, inputs(500, cpu15: 1, cpu60: 1)), "never above the start value")
        XCTAssertEqual(b.limit, .fps(5))
    }

    func testBudgetChangeFormatsAsL11() throws {
        var b = B()
        _ = b.evaluate(inputs(0, cpu15: 27, battery: BatteryStatus(level: 0.64, state: .unplugged)))
        let down = try XCTUnwrap(b.evaluate(inputs(15, cpu15: 27, battery: BatteryStatus(level: 0.64, state: .unplugged))))
        XCTAssertEqual(BackgroundLog.budget(down), "[bg-budget] fps cap 8→5: cpu 27% (15s) thermal=none lowPower=false batt=64% unplugged")
        let hold = try XCTUnwrap(b.evaluate(inputs(16, thermal: .critical)))
        XCTAssertEqual(BackgroundLog.budget(hold), "[bg-budget] → hold: thermal critical")
        _ = b.evaluate(inputs(17, battery: BatteryStatus(level: 0.64, state: .unplugged)))
        let back = try XCTUnwrap(b.evaluate(inputs(77, battery: BatteryStatus(level: 0.64, state: .unplugged))))
        XCTAssertEqual(BackgroundLog.budget(back), "[bg-budget] hold → fps cap 5: clear thermal=none lowPower=false batt=64% unplugged")
    }

    // MARK: - Background parameters

    func testBackgroundPlanVectors() {
        let base = EncoderParameters(bitrate: 3_375_000, frameRate: 24, keyframeIntervalSeconds: 1, forceBaseline: true,
                                     repeatLastFrameAfter: 0.9)
        let mbs800x384 = (800 / 16) * (384 / 16)
        XCTAssertEqual(mbs800x384, 1200)
        for (fps, bitrate) in [(8, 1_536_000), (5, 960_000), (3, 600_000), (2, 600_000)] {
            let p = BackgroundEncoderPlan.parameters(base: base, canvasMacroblocks: mbs800x384, fpsCap: fps)
            XCTAssertEqual(p.frameRate, fps)
            XCTAssertEqual(p.bitrate, bitrate, "\(fps) fps")
            XCTAssertEqual(p.keyframeIntervalSeconds, 1)
            XCTAssertEqual(p.forceBaseline, true)
            XCTAssertEqual(p.repeatLastFrameAfter, 0.9)
        }
        // 1280×576 at 8 fps would plan 3,686,400: the 3,375,000 base stays.
        XCTAssertEqual(BackgroundEncoderPlan.parameters(base: base, canvasMacroblocks: 80 * 36, fpsCap: 8).bitrate, 3_375_000)
        // Never above the base bitrate or rate; other fields untouched.
        let slow = EncoderParameters(bitrate: 400_000, frameRate: 4, keyframeIntervalSeconds: 2, forceBaseline: false,
                                     repeatLastFrameAfter: 0.5)
        XCTAssertEqual(BackgroundEncoderPlan.parameters(base: slow, canvasMacroblocks: 1200, fpsCap: 8),
                       EncoderParameters(bitrate: 400_000, frameRate: 4, keyframeIntervalSeconds: 2, forceBaseline: false,
                                         repeatLastFrameAfter: 0.5))
        XCTAssertEqual(BackgroundEncoderPlan.minimumBitrate, 600_000)
        XCTAssertEqual(BackgroundEncoderPlan.bitsPerMacroblockPerFrame, 160)
    }

    func testBackgroundPlanDegenerateInput() {
        let base = EncoderParameters(bitrate: 3_375_000, frameRate: 24)
        XCTAssertEqual(BackgroundEncoderPlan.parameters(base: base, canvasMacroblocks: 1200, fpsCap: 0).frameRate, 1)
        XCTAssertEqual(BackgroundEncoderPlan.parameters(base: base, canvasMacroblocks: -5, fpsCap: 8).bitrate, 600_000)
        XCTAssertEqual(BackgroundEncoderPlan.parameters(base: base, canvasMacroblocks: Int.max, fpsCap: 8).bitrate, 3_375_000)
    }
}
