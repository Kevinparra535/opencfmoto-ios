// SPDX-License-Identifier: AGPL-3.0-or-later
// NOTE (Linux): swift-corelibs-xctest cannot call synchronous @MainActor test methods; make every
// main-actor test `async` (as below) — the generated test runner awaits async tests correctly.
import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoAppModel

final class AppModelSmokeTests: XCTestCase {
    @MainActor
    func testPreviewModelBuildsOffline() async {
        let model = AppModel.preview()
        XCTAssertEqual(model.connection.phase, .idle)
        XCTAssertTrue(model.garage.bikes.isEmpty)
        XCTAssertNil(model.garage.selected)
        XCTAssertEqual(model.flavor, .full)
    }

    func testConnectionPhaseFlags() {
        XCTAssertTrue(ConnectionPhase.joiningWifi.isBusy)
        XCTAssertTrue(ConnectionPhase.streaming.isLive)
        XCTAssertTrue(ConnectionPhase.mirroring.showsStop)
        XCTAssertFalse(ConnectionPhase.stopped.showsStop)
    }
}
