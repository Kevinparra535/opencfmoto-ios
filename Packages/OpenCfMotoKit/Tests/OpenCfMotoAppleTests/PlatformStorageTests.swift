// SPDX-License-Identifier: AGPL-3.0-or-later
// UserDefaultsKeyValueStore (all platforms), AppGroup helpers (all platforms) and
// KeychainSecretStore (Apple platforms; skipped when no keychain is usable, e.g. headless CI).

import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoApple

final class PlatformUserDefaultsStoreTests: XCTestCase {
    private var suite = ""
    private var store: UserDefaultsKeyValueStore!

    override func setUp() {
        super.setUp()
        suite = "dev.opencfmoto.tests.\(UUID().uuidString)"
        store = UserDefaultsKeyValueStore(suiteName: suite)
    }

    override func tearDown() {
        store.removeAll()
        store = nil
        super.tearDown()
    }

    func testRoundTripsEveryType() {
        XCTAssertEqual(store.suiteName, suite)
        store.set("CFMOTO-f46457", forKey: "s")
        store.set(true, forKey: "b")
        store.set(42, forKey: "i")
        store.set(2.5, forKey: "d")
        store.set(Data([1, 2, 3]), forKey: "data")
        XCTAssertEqual(store.string(forKey: "s"), "CFMOTO-f46457")
        XCTAssertEqual(store.bool(forKey: "b"), true)
        XCTAssertEqual(store.int(forKey: "i"), 42)
        XCTAssertEqual(store.double(forKey: "d"), 2.5)
        XCTAssertEqual(store.data(forKey: "data"), Data([1, 2, 3]))
        XCTAssertEqual(Set(store.allKeys()), ["s", "b", "i", "d", "data"])
    }

    func testMissingKeysAndTypeMismatches() {
        XCTAssertNil(store.string(forKey: "nope"))
        XCTAssertNil(store.bool(forKey: "nope"))
        XCTAssertNil(store.int(forKey: "nope"))
        XCTAssertNil(store.double(forKey: "nope"))
        XCTAssertNil(store.data(forKey: "nope"))
        store.set("text", forKey: "k")
        XCTAssertNil(store.int(forKey: "k"))
        XCTAssertNil(store.data(forKey: "k"))
        store.set(7, forKey: "n")
        XCTAssertEqual(store.double(forKey: "n"), 7, "integral values read as Double")
        XCTAssertNil(store.string(forKey: "n"))
    }

    func testOverwriteNilRemovesAndRemoveValue() {
        store.set("a", forKey: "k")
        store.set("b", forKey: "k")
        XCTAssertEqual(store.string(forKey: "k"), "b")
        store.set(nil as String?, forKey: "k")
        XCTAssertNil(store.string(forKey: "k"))
        store.set(1, forKey: "i")
        store.set(nil as Int?, forKey: "i")
        XCTAssertNil(store.int(forKey: "i"))
        store.set(true, forKey: "b")
        store.removeValue(forKey: "b")
        XCTAssertNil(store.bool(forKey: "b"))
        store.set(Data([9]), forKey: "d")
        store.set(nil as Data?, forKey: "d")
        store.set(1.5, forKey: "x")
        store.set(nil as Double?, forKey: "x")
        store.set(false, forKey: "f")
        store.set(nil as Bool?, forKey: "f")
        XCTAssertEqual(store.allKeys(), [])
    }

    func testValuesPersistAcrossInstancesOfTheSameSuite() {
        store.set("persisted", forKey: "garage.current")
        let other = UserDefaultsKeyValueStore(suiteName: suite)
        XCTAssertEqual(other.string(forKey: "garage.current"), "persisted")
    }

    func testAppGroupFactoryFallsBackToStandardWithoutPlistKey() {
        // Test bundles have no OCMAppGroupIdentifier.
        let s = UserDefaultsKeyValueStore.appGroup()
        XCTAssertNil(s.suiteName)
    }
}

final class PlatformAppGroupTests: XCTestCase {
    func testIdentifierNormalisation() {
        XCTAssertEqual(AppGroup.normalized("group.com.example.opencfmoto"), "group.com.example.opencfmoto")
        XCTAssertEqual(AppGroup.normalized("  group.com.example.opencfmoto\n"), "group.com.example.opencfmoto")
        XCTAssertNil(AppGroup.normalized(nil))
        XCTAssertNil(AppGroup.normalized(""))
        XCTAssertNil(AppGroup.normalized("group."))
        XCTAssertNil(AppGroup.normalized("com.example.opencfmoto"))
        XCTAssertNil(AppGroup.normalized("$(APP_GROUP_ID)"), "unexpanded build setting")
        XCTAssertNil(AppGroup.normalized("group.$(BUNDLE_ID_PREFIX).opencfmoto"))
        XCTAssertNil(AppGroup.normalized("group.with space"))
        XCTAssertEqual(AppGroup.infoPlistKey, "OCMAppGroupIdentifier")
        XCTAssertNil(AppGroup.identifier, "the test bundle has no App Group key")
    }

    func testSocketPathLimit() {
        // Typical iOS App Group container: /private/var/mobile/Containers/Shared/AppGroup/<UUID>/
        let container = URL(fileURLWithPath: "/private/var/mobile/Containers/Shared/AppGroup/12345678-1234-1234-1234-123456789ABC",
                            isDirectory: true)
        let path = AppGroup.socketPath(in: container)
        XCTAssertEqual(path, "/private/var/mobile/Containers/Shared/AppGroup/12345678-1234-1234-1234-123456789ABC/ocm.sock")
        XCTAssertLessThanOrEqual(path!.utf8.count, AppGroup.maxSocketPathBytes)

        let dir = URL(fileURLWithPath: "/" + String(repeating: "d", count: 94), isDirectory: true) // "/ddd…" = 95 bytes
        XCTAssertEqual(AppGroup.socketPath(in: dir, named: "abcd")?.utf8.count, 100, "exactly at the limit")
        XCTAssertNil(AppGroup.socketPath(in: dir, named: "abcde"), "one byte over")
        XCTAssertNil(AppGroup.socketPath(in: dir, named: ""))
        XCTAssertNil(AppGroup.socketPath(in: dir, named: "a/b"))
    }
}

#if canImport(Security)
import Security

final class PlatformKeychainStoreTests: XCTestCase {
    private var store: KeychainSecretStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = KeychainSecretStore(service: "OpenCfMoto.tests.\(UUID().uuidString)")
        store.setSecret("probe", forKey: "probe")
        guard store.secret(forKey: "probe") == "probe" else {
            throw XCTSkip("keychain unavailable in this environment (OSStatus \(store.lastError))")
        }
        store.setSecret(nil, forKey: "probe")
    }

    override func tearDown() {
        store?.removeAll()
        store = nil
        super.tearDown()
    }

    func testSetGetOverwriteDeleteAndList() {
        XCTAssertEqual(KeychainSecretStore.defaultService, "OpenCfMoto")
        let qr = "http://www.carbit.com.cn/?ssid=CFMOTO-f46457&pwd=12345678&action=9"
        store.setSecret(qr, forKey: "garage.bike1")
        XCTAssertEqual(store.secret(forKey: "garage.bike1"), qr)
        store.setSecret("ñandú ✓", forKey: "garage.bike1")
        XCTAssertEqual(store.secret(forKey: "garage.bike1"), "ñandú ✓")
        store.setSecret("x", forKey: "garage.bike2")
        XCTAssertEqual(Set(store.allSecretKeys()), ["garage.bike1", "garage.bike2"])
        store.setSecret(nil, forKey: "garage.bike1")
        XCTAssertNil(store.secret(forKey: "garage.bike1"))
        XCTAssertEqual(store.allSecretKeys(), ["garage.bike2"])
        store.setSecret(nil, forKey: "never-existed")
        XCTAssertEqual(store.lastError, errSecSuccess, "deleting a missing item is not an error")
    }

    func testServicesAreIsolated() {
        let other = KeychainSecretStore(service: "OpenCfMoto.tests.other.\(UUID().uuidString)")
        defer { other.removeAll() }
        store.setSecret("mine", forKey: "k")
        XCTAssertNil(other.secret(forKey: "k"))
        XCTAssertEqual(other.allSecretKeys(), [])
    }
}
#endif
