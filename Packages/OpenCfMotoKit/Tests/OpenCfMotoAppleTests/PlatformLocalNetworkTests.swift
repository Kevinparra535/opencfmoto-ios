// SPDX-License-Identifier: AGPL-3.0-or-later
// LocalNetworkAccess.isDecisive: the app remembers an explicit Local Network request only after an
// answer from Local Network privacy itself (review finding IOS-5), so later quiet checks never pop
// the system alert out of context after a request made off Wi-Fi.
// The browse-based check of a Wi-Fi without internet (review WIFI-2): a browser that got ready and was
// never refused counts as granted, also when nothing advertises the dash (runs on Linux: the decision
// rules are Network.framework-free, the browse outcomes are scripted).

import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoApple

final class PlatformLocalNetworkTests: XCTestCase {
    func testOnlyGrantedAndDeniedAreDecisive() {
        XCTAssertTrue(LocalNetworkAccess.granted.isDecisive)
        XCTAssertTrue(LocalNetworkAccess.denied.isDecisive)
        // Off Wi-Fi (no local network operation happened, no alert shown) or no answer in time.
        XCTAssertFalse(LocalNetworkAccess.unavailable.isDecisive)
        XCTAssertFalse(LocalNetworkAccess.undetermined.isDecisive)
    }

    func testDescriptionIsTheRawValue() {
        XCTAssertEqual(LocalNetworkAccess.granted.description, "granted")
        XCTAssertEqual(LocalNetworkAccess.unavailable.description, "unavailable")
    }

    // MARK: Browse-based check on a Wi-Fi without internet (review WIFI-2)

    func testBrowserStatesGiveTheOutcome() {
        var s = LocalNetworkBrowseState()
        XCTAssertEqual(s.outcome, .quiet, "never ready, never refused")
        s.ready()
        XCTAssertEqual(s.outcome, .readyQuiet, "ready and never refused: access works, nothing advertises")
        s.notReady(policyDenied: true)
        XCTAssertEqual(s.outcome, .denied, "refused after being ready")
        s.ready()
        XCTAssertEqual(s.outcome, .readyQuiet, "ready again after a denial: the rider allowed")
        s.notReady(policyDenied: false)
        XCTAssertEqual(s.outcome, .quiet, "waiting for another reason (no Wi-Fi)")
        var refused = LocalNetworkBrowseState()
        refused.notReady(policyDenied: true)
        refused.notReady(policyDenied: false)
        XCTAssertEqual(refused.outcome, .denied, "a refusal stays until the browser gets ready again")
    }

    private static let fast = LocalNetworkBrowseProbe.Timing(minimumCheck: 0.05, requestSlice: 0.02, requestQuietLimit: 0.1)

    /// Runs the probe with scripted browse outcomes (the last one repeats); returns the verdict and the
    /// `stopOnDenial` flag of every browse.
    private func probe(waitForDecision: Bool, timeout: TimeInterval,
                       _ script: [LocalNetworkBrowseOutcome]) async -> (LocalNetworkAccess, [Bool]) {
        let calls = Locked([Bool]())
        let access = await LocalNetworkBrowseProbe.run(
            timeout: timeout, waitForDecision: waitForDecision, timing: Self.fast,
            browse: { _, stopOnDenial in
                let n = calls.withLock { c -> Int in
                    c.append(stopOnDenial)
                    return c.count
                }
                return script[min(n, script.count) - 1]
            },
            pause: { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) })
        return (access, calls.current)
    }

    /// Onboarding's "Allow local network access" on the bike Wi-Fi before MotoPlay is open: nothing
    /// advertises the dash. The browser getting ready after Allow is the answer: granted, not
    /// "undetermined" with the button back on screen.
    func testRequestAfterAllowWithNothingAdvertisingIsGranted() async {
        let (access, calls) = await probe(waitForDecision: true, timeout: 1, [.denied, .denied, .readyQuiet])
        XCTAssertEqual(access, .granted)
        XCTAssertEqual(calls, [false, false, false], "request keeps browsing through denials")
    }

    /// Settings ▸ Permissions after access was turned back on, nothing advertising: the stale "Denied"
    /// is replaced (PermissionsModel keeps only decisive answers).
    func testQuickCheckWithAReadyBrowserIsGranted() async {
        let (access, calls) = await probe(waitForDecision: false, timeout: 0.05, [.readyQuiet])
        XCTAssertEqual(access, .granted)
        XCTAssertTrue(access.isDecisive)
        XCTAssertEqual(calls, [true], "one browse; a denial would end it")
    }

    func testDenialsFoundServicesAndSilence() async {
        let (checkDenied, _) = await probe(waitForDecision: false, timeout: 0.05, [.denied])
        XCTAssertEqual(checkDenied, .denied)
        let (found, _) = await probe(waitForDecision: false, timeout: 0.05, [.found])
        XCTAssertEqual(found, .granted)
        let (quiet, _) = await probe(waitForDecision: false, timeout: 0.05, [.quiet])
        XCTAssertEqual(quiet, .undetermined, "never ready, never refused: nothing learned")
        let (stillDenied, _) = await probe(waitForDecision: true, timeout: 0.15, [.denied])
        XCTAssertEqual(stillDenied, .denied, "request: refused until the deadline")
        let t0 = Date()
        let (silent, calls) = await probe(waitForDecision: true, timeout: 1, [.quiet])
        XCTAssertEqual(silent, .undetermined)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.6, "the quiet limit ends a request early")
        XCTAssertLessThan(calls.count, 40)
    }

    func testDefaultTimings() {
        let t = LocalNetworkBrowseProbe.Timing()
        XCTAssertEqual(t.minimumCheck, 3)
        XCTAssertEqual(t.requestSlice, 3)
        XCTAssertEqual(t.requestQuietLimit, 15)
    }
}
