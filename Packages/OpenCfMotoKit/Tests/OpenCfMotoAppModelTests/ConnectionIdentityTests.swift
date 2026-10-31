// SPDX-License-Identifier: AGPL-3.0-or-later
// "Identify as an Android phone" compatibility option (docs/verification/pxc-differential.md: the
// CLIENT_INFO brand/model is the only byte difference between the iOS and Android phones).
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class ConnectionIdentityTests: XCTestCase {
    @MainActor
    func testIdentityDefaultsToTheIPhoneAndSwitchesToAndroidOnRequest() async {
        let h = AppTestHarness()
        XCTAssertFalse(h.model.settings.identifyAsAndroidPhone)
        let iphone = h.connection.phoneIdentity()
        XCTAssertEqual(iphone.phoneBrand, "Apple")
        XCTAssertEqual(iphone.phoneModel, h.system.deviceModel)

        h.model.settings.setIdentifyAsAndroidPhone(true)
        XCTAssertTrue(h.model.settings.identifyAsAndroidPhone)
        let android = h.connection.phoneIdentity()
        XCTAssertEqual(android.phoneBrand, ConnectionModel.androidCompatBrand)
        XCTAssertEqual(android.phoneModel, ConnectionModel.androidCompatModel)
        // Same per-process identity otherwise.
        XCTAssertEqual(android.phoneUUID, iphone.phoneUUID)
        XCTAssertEqual(android.phoneOsVersion, iphone.phoneOsVersion)
        XCTAssertEqual(android.bluetoothName, iphone.bluetoothName)
        // Persisted (global, not per bike).
        XCTAssertEqual(h.core.services.keyValueStore.bool(forKey: SettingsModel.identifyAsAndroidKey), true)
    }

    @MainActor
    func testOptionIsRestoredAtLaunch() async {
        let h = AppTestHarness(configure: { services in
            services.keyValueStore.set(true, forKey: SettingsModel.identifyAsAndroidKey)
        })
        XCTAssertTrue(h.model.settings.identifyAsAndroidPhone)
        XCTAssertEqual(h.connection.phoneIdentity().phoneBrand, ConnectionModel.androidCompatBrand)
    }
}
