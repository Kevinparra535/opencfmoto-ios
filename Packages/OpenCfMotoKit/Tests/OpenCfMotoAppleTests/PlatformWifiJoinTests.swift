// SPDX-License-Identifier: AGPL-3.0-or-later
// Wi-Fi join policy: credential validation, NEHotspotConfiguration error decisions, association
// confirmation and the EN/ES messages (runs on Linux too).

import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoApple

final class PlatformWifiJoinTests: XCTestCase {
    private let domain = WifiJoinPolicy.hotspotErrorDomain

    func testCredentialValidation() {
        // QR vectors: CFDL16 SoftAP and the 1000 MT-X Wi-Fi Direct group (password 12345678).
        XCTAssertNoThrow(try WifiJoinPolicy.validate(ssid: "CFMOTO-f46457", passphrase: "12345678"))
        XCTAssertNoThrow(try WifiJoinPolicy.validate(ssid: "DIRECT-CF-CFMOTO-805120", passphrase: "12345678"))
        XCTAssertNoThrow(try WifiJoinPolicy.validate(ssid: String(repeating: "S", count: 32), passphrase: String(repeating: "p", count: 63)))
        XCTAssertThrowsError(try WifiJoinPolicy.validate(ssid: "", passphrase: "12345678")) {
            XCTAssertEqual($0 as? WifiJoinError, .invalidSSID)
        }
        XCTAssertThrowsError(try WifiJoinPolicy.validate(ssid: String(repeating: "S", count: 33), passphrase: "12345678"))
        XCTAssertThrowsError(try WifiJoinPolicy.validate(ssid: String(repeating: "ñ", count: 17), passphrase: "12345678"),
                             "34 UTF-8 bytes > 32")
        XCTAssertThrowsError(try WifiJoinPolicy.validate(ssid: "bike", passphrase: "1234567")) {
            XCTAssertEqual($0 as? WifiJoinError, .invalidPassphrase)
        }
        XCTAssertThrowsError(try WifiJoinPolicy.validate(ssid: "bike", passphrase: String(repeating: "p", count: 64)))
        XCTAssertFalse(WifiJoinPolicy.isValidPassphrase("contraseña1"), "non-ASCII")
        XCTAssertFalse(WifiJoinPolicy.isValidPassphrase("1234567\t"), "control character")
        XCTAssertTrue(WifiJoinPolicy.isValidPassphrase("pass word!~"), "printable ASCII incl. space")
    }

    func testDecisionsForEveryKnownCode() {
        typealias D = WifiJoinDecision
        let first: [Int: D] = [
            0: .fail(.unsupportedConfiguration(code: 0)), 1: .fail(.invalidSSID), 2: .fail(.invalidPassphrase),
            3: .fail(.unsupportedConfiguration(code: 3)), 4: .fail(.unsupportedConfiguration(code: 4)),
            5: .fail(.unsupportedConfiguration(code: 5)), 6: .fail(.unsupportedConfiguration(code: 6)),
            7: .fail(.userDenied), 8: .retry(removeConfigurationFirst: true), 9: .retry(removeConfigurationFirst: false),
            10: .fail(.managedByProfile), 11: .retry(removeConfigurationFirst: false),
            12: .fail(.unsupportedConfiguration(code: 12)), 13: .success, 14: .fail(.notInForeground),
            15: .fail(.invalidSSID), 16: .fail(.userDenied), 17: .fail(.systemDenied),
            99: .fail(.failed(code: 99, domain: WifiJoinPolicy.hotspotErrorDomain)),
        ]
        for (code, expected) in first {
            XCTAssertEqual(WifiJoinPolicy.decision(domain: domain, code: code, attempt: 1), expected, "code \(code)")
        }
        // Second attempt: transient errors are no longer retried; alreadyAssociated stays success.
        XCTAssertEqual(WifiJoinPolicy.decision(domain: domain, code: 8, attempt: 2), .fail(.internalFailure(code: 8)))
        XCTAssertEqual(WifiJoinPolicy.decision(domain: domain, code: 11, attempt: 2), .fail(.internalFailure(code: 11)))
        XCTAssertEqual(WifiJoinPolicy.decision(domain: domain, code: 9, attempt: 2), .fail(.busy))
        XCTAssertEqual(WifiJoinPolicy.decision(domain: domain, code: 13, attempt: 2), .success)
        // Other domains are never interpreted.
        XCTAssertEqual(WifiJoinPolicy.decision(domain: "NSPOSIXErrorDomain", code: 13, attempt: 1),
                       .fail(.failed(code: 13, domain: "NSPOSIXErrorDomain")))
    }

    func testAssociationConfirmation() {
        let onBike = WiFiSnapshot(isSatisfied: true, interfaceName: "en0", phoneIPv4: "192.168.0.50", prefixLength: 24,
                                  gateways: ["192.168.0.1"])
        let subnets = WiFiSubnet.knownDashSubnets
        // SSID known → authoritative.
        XCTAssertTrue(WifiJoinPolicy.isConfirmed(onBike, currentSSID: "CFMOTO-f46457", targetSSID: "CFMOTO-f46457", expectedSubnets: subnets))
        XCTAssertFalse(WifiJoinPolicy.isConfirmed(onBike, currentSSID: "HomeWiFi", targetSSID: "CFMOTO-f46457", expectedSubnets: subnets))
        XCTAssertFalse(WifiJoinPolicy.isConfirmed(onBike, currentSSID: "cfmoto-f46457", targetSSID: "CFMOTO-f46457", expectedSubnets: subnets),
                       "SSIDs are case-sensitive")
        // SSID unknown → subnet / gateway rule.
        XCTAssertTrue(WifiJoinPolicy.isConfirmed(onBike, currentSSID: nil, targetSSID: "x", expectedSubnets: subnets))
        let direct = WiFiSnapshot(isSatisfied: true, phoneIPv4: "10.9.0.2", prefixLength: 24, gateways: ["192.168.49.1"])
        XCTAssertTrue(WifiJoinPolicy.isConfirmed(direct, currentSSID: nil, targetSSID: "x", expectedSubnets: subnets), "gateway in a dash subnet")
        let home = WiFiSnapshot(isSatisfied: true, phoneIPv4: "10.0.0.23", prefixLength: 24, gateways: ["10.0.0.1"])
        XCTAssertFalse(WifiJoinPolicy.isConfirmed(home, currentSSID: nil, targetSSID: "x", expectedSubnets: subnets))
        XCTAssertTrue(WifiJoinPolicy.isConfirmed(home, currentSSID: nil, targetSSID: "x", expectedSubnets: []), "no expectation → any address")
        // DHCP not done (169.254/16) or no path → not yet.
        let linkLocal = WiFiSnapshot(isSatisfied: true, phoneIPv4: "169.254.10.20", prefixLength: 16)
        XCTAssertFalse(WifiJoinPolicy.isConfirmed(linkLocal, currentSSID: "x", targetSSID: "x", expectedSubnets: subnets))
        XCTAssertFalse(WifiJoinPolicy.isConfirmed(.unavailable, currentSSID: "x", targetSSID: "x", expectedSubnets: subnets))
    }

    /// Field log 1: after the join the dash's Wi-Fi (no internet) keeps an unsatisfied path; the
    /// address on the Wi-Fi interface confirms it (the old rule waited 15 s for a satisfied path).
    func testAssociationConfirmationOnALocalOnlyWifi() {
        let subnets = WiFiSubnet.knownDashSubnets
        let bike = WiFiSnapshot(isSatisfied: false, interfaceName: "en0", phoneIPv4: "192.168.0.50", prefixLength: 24,
                                unsatisfiedReason: "notAvailable")
        XCTAssertTrue(bike.isLocalOnly)
        XCTAssertTrue(WifiJoinPolicy.isConfirmed(bike, currentSSID: "CFMOTO-f46457", targetSSID: "CFMOTO-f46457",
                                                 expectedSubnets: subnets, baseline: .unavailable))
        XCTAssertFalse(WifiJoinPolicy.isConfirmed(bike, currentSSID: "HomeWiFi", targetSSID: "CFMOTO-f46457",
                                                  expectedSubnets: subnets, baseline: .unavailable))
        // SSID hidden: a NEW address on a dash subnet (ConnectionModel.matchesManualJoin's rule).
        XCTAssertTrue(WifiJoinPolicy.isConfirmed(bike, currentSSID: nil, targetSSID: "x", expectedSubnets: subnets,
                                                 baseline: .unavailable))
        let home = WiFiSnapshot(isSatisfied: true, interfaceName: "en0", phoneIPv4: "10.0.0.23", prefixLength: 24,
                                gateways: ["10.0.0.1"])
        XCTAssertTrue(WifiJoinPolicy.isConfirmed(bike, currentSSID: nil, targetSSID: "x", expectedSubnets: subnets,
                                                 baseline: home))
        XCTAssertFalse(WifiJoinPolicy.isConfirmed(bike, currentSSID: nil, targetSSID: "x", expectedSubnets: subnets,
                                                  baseline: bike), "nothing changed since apply()")
        XCTAssertTrue(WifiJoinPolicy.isConfirmed(bike, currentSSID: nil, targetSSID: "x", expectedSubnets: subnets,
                                                 baseline: nil), "iOS answered alreadyAssociated")
        // A home network on the dash's address plan that was already there is not the bike.
        let homeOnDashPlan = WiFiSnapshot(isSatisfied: true, interfaceName: "en0", phoneIPv4: "192.168.0.50",
                                          prefixLength: 24, gateways: ["192.168.0.1"])
        XCTAssertFalse(WifiJoinPolicy.isConfirmed(homeOnDashPlan, currentSSID: nil, targetSSID: "x",
                                                  expectedSubnets: subnets, baseline: homeOnDashPlan))
        // Local-only, but not on a dash subnet; or no usable address yet.
        let other = WiFiSnapshot(isSatisfied: false, interfaceName: "en0", phoneIPv4: "10.9.0.2", prefixLength: 24,
                                 unsatisfiedReason: "notAvailable")
        XCTAssertFalse(WifiJoinPolicy.isConfirmed(other, currentSSID: nil, targetSSID: "x", expectedSubnets: subnets,
                                                  baseline: .unavailable))
        let leasePending = WiFiSnapshot(isSatisfied: false, interfaceName: "en0", phoneIPv4: "169.254.1.2", prefixLength: 16,
                                        unsatisfiedReason: "notAvailable")
        XCTAssertFalse(WifiJoinPolicy.isConfirmed(leasePending, currentSSID: "x", targetSSID: "x", expectedSubnets: subnets))
    }

    func testOptionsDefaults() {
        let o = WifiJoinOptions()
        XCTAssertFalse(o.joinOnce, "persistent configuration survives lock / background")
        XCTAssertNil(o.lifeTimeInDays)
        XCTAssertEqual(o.confirmTimeout, 15)
        XCTAssertEqual(o.pollInterval, 0.5)
        XCTAssertTrue(o.hotspotEnabled)
        XCTAssertEqual(o.expectedSubnets, WiFiSubnet.knownDashSubnets)
    }

    func testMessagesExistInBothLanguagesAndDiffer() {
        let all: [WifiJoinError] = [
            .invalidSSID, .invalidPassphrase, .userDenied, .systemDenied, .managedByProfile, .busy, .notInForeground,
            .internalFailure(code: 8), .unsupportedConfiguration(code: 12), .notAssociated(ssid: "CFMOTO-1"),
            .failed(code: 99, domain: "D"),
        ]
        var en = Set<String>(), es = Set<String>()
        for e in all {
            let a = e.message(language: "en"), b = e.message(language: "es-CO")
            XCTAssertFalse(a.isEmpty)
            XCTAssertFalse(b.isEmpty)
            XCTAssertNotEqual(a, b, "\(e)")
            en.insert(a)
            es.insert(b)
            XCTAssertFalse(e.description.isEmpty)
            XCTAssertNotNil(e.errorDescription)
        }
        XCTAssertEqual(en.count, all.count, "distinct EN messages")
        XCTAssertEqual(es.count, all.count, "distinct ES messages")
        XCTAssertTrue(WifiJoinError.notAssociated(ssid: "CFMOTO-1").message(language: "es").contains("CFMOTO-1"))
        XCTAssertTrue(WifiJoinError.internalFailure(code: 8).message(language: "en").contains("8"))
        XCTAssertEqual(WifiJoinError.invalidPassphrase.message(language: "en"),
                       "The bike's Wi-Fi password must be 8–63 characters. Check the QR code or type it manually.")
        XCTAssertEqual(WifiJoinError.invalidPassphrase.message(language: "es"),
                       "La contraseña Wi-Fi de la moto debe tener entre 8 y 63 caracteres. Revisa el código QR o escríbela manualmente.")
    }

    func testLanguageSelectionAndManualJoinText() {
        XCTAssertEqual(WifiJoinMessages.preferredLanguage(["es-CO", "en-US"]), "es")
        XCTAssertEqual(WifiJoinMessages.preferredLanguage(["en-GB"]), "en")
        XCTAssertEqual(WifiJoinMessages.preferredLanguage([]), "en")
        XCTAssertTrue(WifiJoinMessages.manualJoin(ssid: "CFMOTO-1", language: "es").contains("Ajustes"))
        XCTAssertTrue(WifiJoinMessages.manualJoin(ssid: "CFMOTO-1", language: "en").contains("“CFMOTO-1”"))
    }

    func testManualJoinSuggestion() {
        XCTAssertTrue(WifiJoinError.userDenied.suggestsManualJoin)
        XCTAssertTrue(WifiJoinError.notAssociated(ssid: "x").suggestsManualJoin)
        XCTAssertFalse(WifiJoinError.notInForeground.suggestsManualJoin)
        XCTAssertFalse(WifiJoinError.busy.suggestsManualJoin)
    }

    #if !os(iOS)
    /// Non-iOS builds compile the stub joiner: validates, then always asks for a manual join.
    func testStubJoinerAlwaysRequiresManualJoin() async throws {
        let joiner = WifiJoiner()
        let outcome = try await joiner.join(ssid: "CFMOTO-f46457", passphrase: "12345678")
        XCTAssertEqual(outcome, .manualJoinRequired)
        do {
            _ = try await joiner.join(ssid: "CFMOTO-f46457", passphrase: "short")
            XCTFail("invalid passphrase must throw")
        } catch {
            XCTAssertEqual(error as? WifiJoinError, .invalidPassphrase)
        }
        joiner.forget(ssid: "CFMOTO-f46457")
        let configured = await joiner.configuredSSIDs()
        XCTAssertEqual(configured, [])
    }
    #endif
}
