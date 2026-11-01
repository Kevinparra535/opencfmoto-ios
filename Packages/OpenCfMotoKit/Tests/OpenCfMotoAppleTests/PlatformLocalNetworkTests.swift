// SPDX-License-Identifier: AGPL-3.0-or-later
// LocalNetworkAccess.isDecisive: the app remembers an explicit Local Network request only after an
// answer from Local Network privacy itself (review finding IOS-5), so later quiet checks never pop
// the system alert out of context after a request made off Wi-Fi.

import XCTest
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
}
