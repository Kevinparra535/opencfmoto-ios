// SPDX-License-Identifier: AGPL-3.0-or-later
// Handlebar gesture engine traces: input-controls.md §7.11 B1–B14 (default timing: window 300 ms,
// hold 600 ms, holds on, snappy on; Android shipped map), plus the iOS discrete-command adaptation,
// the iOS default map, live remapping, capture off and presence tracking.

import XCTest
@testable import OpenCfMotoCore

final class HandlebarEngineTests: XCTestCase {

    private struct FakeClock: MonotonicClock {
        let t: Locked<TimeInterval>
        func now() -> TimeInterval { t.current }
    }

    private func engine(map: [ButtonGesture: ButtonAction] = HandlebarPresets.androidDefaults,
                        timing: ButtonTiming = ButtonTiming(), snappy: Bool = true) -> HandlebarGestureEngine {
        HandlebarGestureEngine(configuration: .init(buttonMap: map, timing: timing, captureEnabled: true, snappySingles: snappy))
    }

    private func trace(_ cmds: [HandlebarCommand]) -> [String] { cmds.map(\.description) }

    // MARK: §7.11 traces (Android DOWN/UP mapped to press/release, repeat to keyRepeat)

    func testB1PreviousTap() {
        let e = engine()
        XCTAssertEqual(e.press(.backward, atMs: 0), [])
        XCTAssertEqual(trace(e.release(.backward, atMs: 80)), ["80 navBack → knobBack"])
    }

    func testB2NextDoubleTap() {
        let e = engine()
        var out = e.press(.forward, atMs: 0) + e.release(.forward, atMs: 70)
        out += e.press(.forward, atMs: 200) + e.release(.forward, atMs: 260)
        XCTAssertEqual(trace(out), ["70 navFwd → knobFwd", "260 navFwdDouble → right"])
    }

    func testB3PauseHold() {
        let e = engine()
        let out = e.press(.select, atMs: 0) + e.release(.select, atMs: 700)
        XCTAssertEqual(trace(out), ["700 selectLong → home"])
    }

    func testB4KeyRepeatFiresHoldOnce() {
        let e = engine()
        var out = e.press(.select, atMs: 0)
        out += e.keyRepeat(.select, atMs: 500)
        out += e.keyRepeat(.select, atMs: 550)
        out += e.release(.select, atMs: 900)
        XCTAssertEqual(trace(out), ["500 selectLong → home"])
    }

    func testB5UnmappedHoldIsSwallowed() {
        let e = engine()
        let out = e.press(.backward, atMs: 0) + e.release(.backward, atMs: 700)
        XCTAssertEqual(trace(out), ["700 navBackLong → none"])
        XCTAssertNil(out.first?.input)
    }

    func testB6HoldsDisabled() {
        var timing = ButtonTiming()
        timing.holdsEnabled = false
        let e = engine(timing: timing)
        XCTAssertEqual(trace(e.press(.backward, atMs: 0) + e.release(.backward, atMs: 700)), ["700 navBack → knobBack"])
        XCTAssertEqual(e.keyRepeat(.backward, atMs: 800), [])   // repeats ignored when holds are off
    }

    func testB7VolumeUpSingle() {
        XCTAssertEqual(trace(engine().volumeChange(steps: 1, atMs: 0)), ["0 navBack → knobBack"])
    }

    func testB8VolumeJumpForcesDouble() {
        XCTAssertEqual(trace(engine().volumeChange(steps: -3, atMs: 0)), ["0 navFwdDouble → right"])
    }

    func testB9TwoVolumeStepsInWindow() {
        let e = engine()
        XCTAssertEqual(trace(e.volumeChange(steps: 1, atMs: 0) + e.volumeChange(steps: 1, atMs: 150)),
                       ["0 navBack → knobBack", "150 navBackDouble → left"])
    }

    func testB10OppositeDirectionsAreSeparateChannels() {
        let e = engine()
        XCTAssertEqual(trace(e.volumeChange(steps: 1, atMs: 0) + e.volumeChange(steps: -1, atMs: 100)),
                       ["0 navBack → knobBack", "100 navFwd → knobFwd"])
    }

    func testB11TripleTap() {
        let e = engine()
        let out = e.handle(.forward, atMs: 50) + e.handle(.forward, atMs: 200) + e.handle(.forward, atMs: 350)
        XCTAssertEqual(trace(out), ["50 navFwd → knobFwd", "200 navFwdDouble → right", "350 navFwd → knobFwd"])
    }

    func testB12ZeroGapIsTwoSingles() {
        let e = engine()
        XCTAssertEqual(trace(e.handle(.forward, atMs: 50) + e.handle(.forward, atMs: 50)),
                       ["50 navFwd → knobFwd", "50 navFwd → knobFwd"])
    }

    func testB13BackSetVolumeFlick() {
        let e = engine(map: HandlebarPresets.androidMapping(for: .backSet))
        XCTAssertEqual(trace(e.volumeChange(steps: 3, atMs: 0)), ["0 navBackDouble → back"])
    }

    func testB14DeferredSingle() {
        let e = engine(snappy: false)
        XCTAssertEqual(e.handle(.forward, atMs: 50), [])
        XCTAssertEqual(e.nextDeadlineMs(), 350)
        XCTAssertEqual(e.tick(atMs: 349), [])
        XCTAssertEqual(trace(e.tick(atMs: 350)), ["350 navFwd → knobFwd"])
        XCTAssertNil(e.nextDeadlineMs())
        // deferred double: second tap inside the window replaces the single
        XCTAssertEqual(e.handle(.select, atMs: 1000), [])
        XCTAssertEqual(trace(e.handle(.select, atMs: 1200)), ["1200 selectDouble → back"])
        XCTAssertEqual(e.tick(atMs: 2000), [])
        // an overdue deferred single is flushed (with its own time) before the next event
        _ = e.handle(.backward, atMs: 3000)
        XCTAssertEqual(trace(e.handle(.forward, atMs: 3500)), ["3300 navBack → knobBack"])
    }

    // MARK: iOS discrete commands and seek holds

    func testIOSDefaultMapOnDiscreteCommands() {
        // P0 (D02): no double means anything of its own. The single still fires at once; a quick second ★ is
        // the double, whose action is none: swallowed (no input) — never Back. A quick second ◀ / ▶ is the
        // double, whose action is its own knob step: two presses, two steps (review DASH-REG-3) — never Home
        // or D-pad left.
        let e = engine(map: HandlebarPresets.iosDefaultMapping)
        XCTAssertEqual(e.handle(.select, atMs: 0).first?.input, .key(.enter))
        XCTAssertEqual(trace(e.handle(.select, atMs: 200)), ["200 selectDouble → none"])          // ★★ = ★
        XCTAssertEqual(e.handle(.select, atMs: 1000).first?.input, .key(.enter))                      // slow: a second ★
        XCTAssertEqual(e.handle(.forward, atMs: 2000).first?.input, .knob(1))
        let fwdDouble = e.handle(.forward, atMs: 2100)
        XCTAssertEqual(fwdDouble.map(\.action), [ButtonAction.knobFwd])                               // ▶▶ = ▶ ▶
        XCTAssertEqual(fwdDouble.compactMap(\.input), [.knob(1)])
        XCTAssertEqual(e.handle(.backward, atMs: 3000).first?.input, .knob(-1))
        XCTAssertEqual(e.handle(.backward, atMs: 3299).compactMap(\.input), [.knob(-1)])              // ◀◀ = ◀ ◀
        // a third quick press is a single again (the double disarmed the window): a mistimed double is
        // only ever harmless singles
        XCTAssertEqual(e.handle(.backward, atMs: 3400).first?.input, .knob(-1))
        XCTAssertEqual(e.handle(.backward, atMs: 4000).first?.input, .knob(-1))
        XCTAssertEqual(e.handle(.backward, atMs: 4300).first?.input, .knob(-1))                        // gap == window: single
    }

    func testSeekBeginEndHolds() {
        var map = HandlebarPresets.iosDefaultMapping
        map[.navFwdLong] = .home
        let e = engine(map: map)
        // short seek press → tap
        XCTAssertEqual(trace(e.handle(.forwardHoldBegan, atMs: 0) + e.handle(.forwardHoldEnded, atMs: 120)), ["120 navFwd → knobFwd"])
        // long seek press, released without tick → hold at release
        XCTAssertEqual(trace(e.handle(.forwardHoldBegan, atMs: 1000) + e.handle(.forwardHoldEnded, atMs: 1700)), ["1700 navFwdLong → home"])
        // long seek press with tick → fires at the threshold, nothing at release
        _ = e.handle(.forwardHoldBegan, atMs: 3000)
        XCTAssertEqual(e.nextDeadlineMs(), 3600)
        XCTAssertEqual(e.tick(atMs: 3599), [])
        XCTAssertEqual(trace(e.tick(atMs: 3650)), ["3600 navFwdLong → home"])
        XCTAssertEqual(e.handle(.forwardHoldEnded, atMs: 4000), [])
        // unmapped hold (◀ hold = none): no early fire, swallowed at release
        _ = e.handle(.backwardHoldBegan, atMs: 5000)
        XCTAssertNil(e.nextDeadlineMs())
        XCTAssertEqual(e.tick(atMs: 5700), [])
        XCTAssertEqual(trace(e.handle(.backwardHoldEnded, atMs: 5800)), ["5800 navBackLong → none"])
        // UP without DOWN and a second DOWN are ignored
        XCTAssertEqual(e.handle(.backwardHoldEnded, atMs: 6000), [])
        _ = e.handle(.backwardHoldBegan, atMs: 7000)
        _ = e.handle(.backwardHoldBegan, atMs: 7100)
        XCTAssertEqual(trace(e.handle(.backwardHoldEnded, atMs: 7200)), ["7200 navBack → knobBack"])
    }

    func testHoldCancelsArmedDouble() {
        var map = HandlebarPresets.androidDefaults
        map[.navFwdLong] = .assistant
        let e = engine(map: map)
        _ = e.handle(.forward, atMs: 0)                                    // arms a ×2
        XCTAssertEqual(trace(e.press(.forward, atMs: 50) + e.release(.forward, atMs: 700)), ["700 navFwdLong → assistant"])
        XCTAssertEqual(trace(e.handle(.forward, atMs: 800)), ["800 navFwd → knobFwd"]) // no stale ×2
    }

    func testTimingChoices() {
        var t = ButtonTiming()
        t.doubleTapMs = 450
        t.holdMs = 800
        let e = engine(timing: t)
        XCTAssertEqual(trace(e.handle(.forward, atMs: 0) + e.handle(.forward, atMs: 449)), ["0 navFwd → knobFwd", "449 navFwdDouble → right"])
        XCTAssertEqual(trace(e.press(.select, atMs: 1000) + e.release(.select, atMs: 1799)), ["1799 selectPress → select"])
        t.doubleTapMs = 250 // not a choice → 300
        e.configuration = .init(buttonMap: HandlebarPresets.androidDefaults, timing: t)
        XCTAssertEqual(trace(e.handle(.backward, atMs: 5000) + e.handle(.backward, atMs: 5299)), ["5000 navBack → knobBack", "5299 navBackDouble → left"])
    }

    func testLiveRemapAndActionsToInputs() {
        let e = engine()
        XCTAssertEqual(e.handle(.select, atMs: 0).first?.input, .key(.enter))
        var cfg = e.configuration
        cfg.buttonMap[.selectPress] = .nav2
        e.configuration = cfg
        let c = e.handle(.select, atMs: 1000).first
        XCTAssertEqual(c?.action, .nav2)
        XCTAssertEqual(c?.input, .savedPlace(2))
        let expected: [ButtonAction: DashInput?] = [
            .none: nil, .knobFwd: .knob(1), .knobBack: .knob(-1), .select: .key(.enter), .back: .key(.back),
            .home: .key(.home), .assistant: .key(.assistant), .up: .key(.up), .down: .key(.down), .left: .key(.left),
            .right: .key(.right), .nav1: .savedPlace(1), .nav2: .savedPlace(2), .nav3: .savedPlace(3),
        ]
        for a in ButtonAction.allCases { XCTAssertEqual(a.handlebarDashInput, expected[a]!, a.rawValue) }
    }

    func testCaptureOffIgnoresEverything() {
        let e = HandlebarGestureEngine(configuration: .init(captureEnabled: false))
        XCTAssertEqual(e.handle(.select, atMs: 0), [])
        XCTAssertEqual(e.handle(.volumeUp, atMs: 10), [])
        XCTAssertEqual(e.handle(.forwardHoldBegan, atMs: 20) + e.handle(.forwardHoldEnded, atMs: 900), [])
        XCTAssertEqual(e.presence, HandlebarPresence())          // nothing marked
        // turning capture off mid-hold cancels pending state
        let f = engine()
        _ = f.press(.forward, atMs: 0)
        var cfg = f.configuration
        cfg.captureEnabled = false
        f.configuration = cfg
        cfg.captureEnabled = true
        f.configuration = cfg
        XCTAssertEqual(f.release(.forward, atMs: 100), [])
    }

    func testADoubleThatSelectsDefersItsSingle() {
        // The single-button option (★ = next, ★★ = choose): the snappy ★ would move the focus before the ★★
        // chose, so ★★ chose the next item (review DASH-SAFE-1). The single waits out the window instead.
        let e = engine(map: HandlebarPresets.iosSingleButtonMapping)
        XCTAssertEqual(e.handle(.select, atMs: 0), [])                                   // ★: waits
        XCTAssertEqual(e.nextDeadlineMs(), 300)
        XCTAssertEqual(e.tick(atMs: 299), [])
        XCTAssertEqual(e.tick(atMs: 300).compactMap(\.input), [.knob(1)])               // then moves
        XCTAssertEqual(e.handle(.select, atMs: 1000), [])
        XCTAssertEqual(trace(e.handle(.select, atMs: 1150)), ["1150 selectDouble → select"]) // ★★: only chooses
        XCTAssertEqual(e.tick(atMs: 2000), [])
        // ◀ / ▶ keep firing at once (their doubles repeat them), and maps whose ★★ does not select stay snappy
        XCTAssertEqual(e.handle(.forward, atMs: 3000).compactMap(\.input), [.knob(1)])
        let backSet = engine(map: HandlebarPresets.iosMapping(for: .backSet))
        XCTAssertEqual(backSet.handle(.select, atMs: 0).compactMap(\.input), [.key(.enter)])
        let ios = engine(map: HandlebarPresets.iosDefaultMapping)
        XCTAssertEqual(ios.handle(.select, atMs: 0).compactMap(\.input), [.key(.enter)])
    }

    func testSettingsInitAndClock() {
        var s = BikeSettings()
        s.buttonMap = HandlebarPresets.iosDefaultMapping
        s.handlebarControl = true
        let t = Locked<TimeInterval>(12.0)
        let e = HandlebarGestureEngine(configuration: .init(settings: s), clock: FakeClock(t: t))
        XCTAssertEqual(trace(e.handle(.forward)), ["12000 navFwd → knobFwd"])
        t.set(12.2)
        XCTAssertEqual(trace(e.handle(.forward)), ["12200 navFwdDouble → knobFwd"]) // P0 (D02): its own knob step
        XCTAssertEqual(trace(e.handle(.select, at: 13.0)), ["13000 selectPress → select"])
        s.handlebarControl = false
        XCTAssertFalse(HandlebarGestureEngine.Configuration(settings: s).captureEnabled)
    }

    func testAdapterEventEntryPointWithVolumeSteps() {
        let e = engine()
        XCTAssertEqual(trace(e.handle(.volumeUp, at: 1.0, steps: 4)), ["1000 navBackDouble → left"])     // coalesced jump
        XCTAssertEqual(trace(e.handle(.volumeDown, at: 2.0, steps: 1)), ["2000 navFwd → knobFwd"])
        XCTAssertEqual(trace(e.handle(.volumeDown, at: 2.1, steps: 0)), ["2100 navFwdDouble → right"])    // steps < 1 → 1
        XCTAssertEqual(trace(e.handle(.select, at: 3.0, steps: 7)), ["3000 selectPress → select"])        // steps ignored
        XCTAssertEqual(e.volumeChange(steps: 0, atMs: 4000), [])
    }

    // MARK: Presence

    func testPresenceMarkingAndCallback() {
        let e = engine()
        let seen = Locked<[HandlebarPresence]>([])
        e.onPresenceChange = { p in seen.withLock { $0.append(p) } }
        _ = e.handle(.forward, atMs: 0)
        XCTAssertEqual(e.presence.trackKeys, .present)
        _ = e.handle(.select, atMs: 1000)                         // already present: no new callback
        _ = e.handle(.volumeDown, atMs: 2000)
        XCTAssertEqual(e.presence, HandlebarPresence(volumeRocker: .present, trackKeys: .present))
        XCTAssertEqual(seen.current.count, 2)
    }

    func testAbsentProbeCountsFromStreamingStart() {
        let e = engine()
        let seen = Locked<[HandlebarPresence]>([])
        e.onPresenceChange = { p in seen.withLock { $0.append(p) } }
        XCTAssertNil(e.nextDeadlineMs())
        _ = e.tick(atMs: 200_000)                                    // not streaming: nothing
        XCTAssertEqual(e.presence.volumeRocker, .unknown)
        e.streamingStarted(atMs: 80_000)
        XCTAssertEqual(e.nextDeadlineMs(), 170_000)
        _ = e.tick(atMs: 169_999)
        XCTAssertEqual(e.presence.volumeRocker, .unknown)
        _ = e.tick(atMs: 170_000)
        XCTAssertEqual(e.presence.volumeRocker, .absent)
        XCTAssertEqual(seen.current.last?.volumeRocker, .absent)
        XCTAssertNil(e.nextDeadlineMs())
        // a later ▲/▼ flips it to PRESENT
        _ = e.handle(.volumeUp, atMs: 200_000)
        XCTAssertEqual(e.presence.volumeRocker, .present)
    }

    func testAbsentProbeRestartsWithStreamingAndRespectsTeach() {
        let e = engine()
        e.streamingStarted(atMs: 0)
        e.streamingStopped()
        e.streamingStarted(atMs: 50_000)
        _ = e.tick(atMs: 100_000)
        XCTAssertEqual(e.presence.volumeRocker, .unknown)            // only 50 s of this streaming run
        e.setPresence(HandlebarPresence(volumeRocker: .present, trackKeys: .unknown))
        _ = e.tick(atMs: 500_000)
        XCTAssertEqual(e.presence.volumeRocker, .present)            // taught values are sticky
        e.setPresence(HandlebarPresence())
        var cfg = e.configuration
        cfg.captureEnabled = false
        e.configuration = cfg
        _ = e.tick(atMs: 600_000)
        XCTAssertEqual(e.presence.volumeRocker, .unknown)            // probe only while capturing
    }

    func testConcurrentEventsDoNotCrash() {
        let e = engine()
        DispatchQueue.concurrentPerform(iterations: 500) { i in
            _ = e.handle(HandlebarRawEvent.allCases[i % HandlebarRawEvent.allCases.count], atMs: Int64(i))
            _ = e.tick(atMs: Int64(i))
            _ = e.nextDeadlineMs()
        }
        XCTAssertEqual(e.presence.trackKeys, .present)
    }
}
