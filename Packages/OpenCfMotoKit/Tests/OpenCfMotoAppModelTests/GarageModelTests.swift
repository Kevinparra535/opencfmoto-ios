// SPDX-License-Identifier: AGPL-3.0-or-later
// GarageModel: pairing (QR / manual), secrets never logged, selection notifications, rename,
// photos as files, removal, learned canvas (docs/spec/app-features.md §4, session-network.md §2).

import Foundation
import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoAppModel

final class GarageModelTests: XCTestCase {

    // MARK: Pairing

    @MainActor
    func testPairValidQRSavesSelectsAndNotifies() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let garage = GarageModel(core: env.core)
        var notified: [GarageBike?] = []
        garage.observeSelection { notified.append($0) }

        let outcome = garage.pair(rawQR: "  \(LDTest.docQR)\n")
        guard case let .paired(bike) = outcome else { return XCTFail("expected .paired, got \(outcome)") }
        XCTAssertEqual(bike.id, "b58cde373")
        XCTAssertEqual(bike.ssid, "CFMOTO-f46457")
        XCTAssertEqual(bike.name, "CFMOTO-f46457")
        XCTAssertEqual(garage.bikes, [bike])
        XCTAssertEqual(garage.selected, bike)
        XCTAssertEqual(notified, [bike])
        // The raw QR (trimmed) lives in the secret store only.
        XCTAssertEqual(env.core.garage.raw(for: bike.id), LDTest.docQR)
        XCTAssertEqual(garage.qr(for: bike.id)?.password, LDTest.docPassword)
        for key in env.core.services.keyValueStore.allKeys() {
            if let s = env.core.services.keyValueStore.string(forKey: key) { XCTAssertFalse(s.contains(LDTest.docPassword), key) }
            if let d = env.core.services.keyValueStore.data(forKey: key) {
                XCTAssertFalse(String(decoding: d, as: UTF8.self).contains(LDTest.docPassword), key)
            }
        }
    }

    @MainActor
    func testPairingNeverLogsSecrets() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let garage = GarageModel(core: env.core)
        let before = Log.shared.lines().last?.id ?? 0

        _ = garage.pair(rawQR: LDTest.docQR)
        _ = garage.pair(rawQR: LDTest.qr4288)
        // Not a pairing QR, but it carries a password-like value the parser does not understand.
        _ = garage.pair(rawQR: "http://example.com/setup?secretpwd=Hunter2Secret&ssid")
        _ = garage.pairManually(ssid: "TRK702X-1A2B", password: "Manual Secret 99", name: "My TRK")

        let lines = Log.shared.lines().filter { $0.id > before }.map(\.message)
        XCTAssertTrue(lines.contains { $0.hasPrefix("QR parsed: ssid=CFMOTO-f46457") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("QR parse FAILED") }, "\(lines)")
        for secret in [LDTest.docPassword, LDTest.qr4288Password, "Hunter2Secret", "Manual Secret 99", "Manual%20Secret%2099",
                       LDTest.docQR, LDTest.qr4288] {
            XCTAssertFalse(lines.contains { $0.contains(secret) }, "secret \(secret) logged in \(lines)")
        }
    }

    @MainActor
    func testPairInvalidQRReturnsLocalizedHint() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let garage = GarageModel(core: env.core)
        var notified = 0
        garage.observeSelection { _ in notified += 1 }

        XCTAssertEqual(garage.pair(rawQR: "hello world"), .invalid(hint: env.strings.invalidQR))
        XCTAssertEqual(garage.pair(rawQR: "   "), .invalid(hint: env.strings.invalidQR))
        let url = "http://example.com/app"
        let expected = env.strings.qrHint(BikeQR.iosFailureHint(for: url)!)
        XCTAssertEqual(garage.pair(rawQR: url), .invalid(hint: expected))
        XCTAssertTrue(garage.bikes.isEmpty)
        XCTAssertNil(garage.selected)
        XCTAssertEqual(notified, 0)
    }

    func testInvalidQRStringsEnglishAndSpanish() {
        XCTAssertEqual(LogicData.Strings(.en).invalidQR, "Invalid QR")
        XCTAssertEqual(LogicData.Strings(.es).invalidQR, "QR no válido")
        XCTAssertEqual(LogicData.Strings(.es).ssidAndPasswordRequired, "El SSID y la contraseña son obligatorios")
    }

    /// Every iOS parse-failure hint of the core has a Spanish translation (catches wording drift).
    func testEveryQRHintHasASpanishTranslation() {
        let samples = [
            "http://admin.motomorini.com/app.html?MachineID=dc0d30da1b6c",        // 1 Morini without Wifi=
            "code:&engine:&vin:&color:Fuji White",                               // 2 vehicle info
            "http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37426",       // 3 Carbit download
            "http://www.carbit.com.cn/x?action=1&bm=zz",                         // 4 phone hotspot
            "CARBITDC0D3024876D",                                                // 5 Carbit ID token
            "Download KOVE APP",                                                 // 6 Kove / Thinkerride
            "http://example.com/app",                                            // 7 URL without credentials
        ]
        var seen = Set<String>()
        for raw in samples {
            guard let hint = BikeQR.iosFailureHint(for: raw) else { XCTFail("no hint for \(raw)"); continue }
            seen.insert(hint)
            XCTAssertFalse(hint.contains("Android hotspot"), hint)
            XCTAssertEqual(LogicData.Strings(.en).qrHint(hint), hint)
            let es = LogicData.Strings(.es).qrHint(hint)
            XCTAssertNotEqual(es, hint, "missing Spanish for: \(hint)")
            XCTAssertNotNil(LogicData.Strings.qrHintsES[hint])
        }
        XCTAssertEqual(seen.count, 6) // 4 and 5 share the "not supported on iPhone" text (IOS-3)
        XCTAssertEqual(LogicData.Strings.qrHintsES.count, 6)
        // Unknown hints pass through.
        XCTAssertEqual(LogicData.Strings(.es).qrHint("something new"), "something new")
    }

    /// Review IOS-3: a dash that joins the PHONE's hotspot cannot be connected from an iPhone — the
    /// QR is refused with a clear localized hint instead of saving a bike with a synthetic SSID.
    @MainActor
    func testPhoneHotspotQRsAreRefusedWithAClearHint() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let garage = GarageModel(core: env.core)
        let expected = PairingOutcome.invalid(hint: env.strings.qrHint(BikeQR.iosPhoneHotspotUnsupportedHint))
        XCTAssertEqual(garage.pair(rawQR: "http://www.carbit.com.cn/down6/645/644/_ylqxos?modelid=21322&sn=t6J4&action=128&bm=DD%3A0D%3A30%3A24%3A87%3A6D"), expected)
        XCTAssertEqual(garage.pair(rawQR: "CARBITDC0D3024876D"), expected)
        XCTAssertTrue(garage.bikes.isEmpty)
        XCTAssertNil(garage.selected)
        XCTAssertNotEqual(LogicData.Strings(.es).qrHint(BikeQR.iosPhoneHotspotUnsupportedHint), BikeQR.iosPhoneHotspotUnsupportedHint)
    }

    @MainActor
    func testPairManually() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let garage = GarageModel(core: env.core)

        XCTAssertEqual(garage.pairManually(ssid: "  ", password: "x", name: nil),
                       .invalid(hint: env.strings.ssidAndPasswordRequired))
        XCTAssertEqual(garage.pairManually(ssid: "CFMOTO-123", password: "", name: nil),
                       .invalid(hint: env.strings.ssidAndPasswordRequired))
        XCTAssertTrue(garage.bikes.isEmpty)

        let outcome = garage.pairManually(ssid: " CFMOTO-123 ", password: "pass word", name: nil)
        guard case let .paired(bike) = outcome else { return XCTFail("expected .paired, got \(outcome)") }
        XCTAssertEqual(bike.ssid, "CFMOTO-123")
        XCTAssertEqual(bike.name, "CFMOTO-123")
        XCTAssertEqual(bike.id, "b71cb90bd")   // Android id of the synthetic manual URL
        XCTAssertEqual(garage.qr(for: bike.id)?.password, "pass word")
        XCTAssertEqual(env.core.garage.raw(for: bike.id),
                       "http://manual.opencfmoto.local/?ssid=CFMOTO-123&pwd=pass%20word&auth=wpa2-psk&action=1&name=CFMOTO-123")

        guard case let .paired(trk) = garage.pairManually(ssid: "TRK702X-1A2B", password: "12345678", name: " My TRK ") else {
            return XCTFail("expected .paired")
        }
        XCTAssertEqual(trk.name, "My TRK")
        XCTAssertEqual(garage.selected, trk)
        XCTAssertEqual(garage.bikes.map(\.id), [trk.id, bike.id])
    }

    // MARK: Selection, rename

    @MainActor
    func testSelectRenameAndSelectionNotifications() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let garage = GarageModel(core: env.core)
        var notified: [GarageBike?] = []
        garage.observeSelection { notified.append($0) }

        guard case let .paired(first) = garage.pair(rawQR: LDTest.docQR),
              case let .paired(second) = garage.pair(rawQR: LDTest.qr4288) else { return XCTFail("pairing failed") }
        XCTAssertEqual(garage.selected, second)
        XCTAssertEqual(notified, [first, second])
        XCTAssertEqual(garage.bikes.map(\.id), [second.id, first.id])   // most recent first

        garage.select(first.id)
        XCTAssertEqual(garage.selected?.id, first.id)
        XCTAssertEqual(notified.count, 3)
        XCTAssertEqual(garage.bikes.map(\.id), [second.id, first.id])   // select does not reorder

        garage.select(first.id)          // unchanged → no notification
        garage.select("nope")            // unknown → ignored
        XCTAssertEqual(notified.count, 3)
        XCTAssertEqual(garage.selected?.id, first.id)

        garage.rename(first.id, to: "  My 675SR  ")
        XCTAssertEqual(garage.selected?.name, "My 675SR")
        XCTAssertEqual(garage.bikes.first { $0.id == first.id }?.name, "My 675SR")
        XCTAssertEqual(notified.last??.name, "My 675SR")   // the selected value changed
        XCTAssertEqual(notified.count, 4)

        garage.rename(first.id, to: "   ")   // blank keeps the name
        XCTAssertEqual(garage.selected?.name, "My 675SR")
        XCTAssertEqual(notified.count, 4)

        garage.rename(second.id, to: "Other")   // not the selected bike → no notification
        XCTAssertEqual(garage.bikes.first { $0.id == second.id }?.name, "Other")
        XCTAssertEqual(notified.count, 4)

        // Re-scanning the same bike keeps its custom name and selects it again.
        let rescan = LDTest.docQR.replacingOccurrences(of: "sn=peTz", with: "sn=Zq9X")
        guard case let .paired(again) = garage.pair(rawQR: rescan) else { return XCTFail("rescan failed") }
        XCTAssertEqual(again.id, first.id)
        XCTAssertEqual(again.name, "My 675SR")
        XCTAssertEqual(garage.bikes.count, 2)
    }

    @MainActor
    func testReloadPicksUpExternalChanges() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let garage = GarageModel(core: env.core)
        var notified = 0
        garage.observeSelection { _ in notified += 1 }
        env.core.garage.save(BikeQR.parse(LDTest.docQR)!)
        XCTAssertTrue(garage.bikes.isEmpty)
        garage.reload()
        XCTAssertEqual(garage.bikes.count, 1)
        XCTAssertEqual(garage.selected?.ssid, "CFMOTO-f46457")
        XCTAssertEqual(notified, 1)
        // A second model on the same storage sees the bike at init.
        XCTAssertEqual(GarageModel(core: env.core).bikes.count, 1)
    }

    // MARK: Photos

    @MainActor
    func testPhotoLifecycle() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let garage = GarageModel(core: env.core)
        guard case let .paired(bike) = garage.pair(rawQR: LDTest.docQR) else { return XCTFail("pairing failed") }
        let dir = env.services.files.photosDirectory
        XCTAssertNil(garage.photoURL(for: bike.id))

        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        try garage.setPhoto(bike.id, imageData: jpeg)
        let first = try XCTUnwrap(garage.photoURL(for: bike.id))
        XCTAssertEqual(first.deletingLastPathComponent().standardizedFileURL.path, dir.standardizedFileURL.path)
        XCTAssertEqual(try Data(contentsOf: first), jpeg)
        XCTAssertTrue(first.lastPathComponent.hasPrefix("b58cde373-"))
        XCTAssertEqual(first.pathExtension, "jpg")
        // Only the file NAME is persisted.
        XCTAssertEqual(garage.bikes.first?.photoFileName, first.lastPathComponent)
        XCTAssertEqual(env.core.garage.bike(id: bike.id)?.photoFileName, first.lastPathComponent)

        let png = Data([0x89, 0x50, 0x4E, 0x47])
        try garage.setPhoto(bike.id, imageData: png, fileExtension: ".PNG")
        let second = try XCTUnwrap(garage.photoURL(for: bike.id))
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(second.pathExtension, "png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "previous photo file must be deleted")
        XCTAssertEqual(try Data(contentsOf: second), png)
        XCTAssertEqual(garage.selected?.photoFileName, second.lastPathComponent)

        XCTAssertThrowsError(try garage.setPhoto(bike.id, imageData: Data()))
        XCTAssertThrowsError(try garage.setPhoto("unknown", imageData: jpeg))
        XCTAssertEqual(garage.photoURL(for: bike.id), second)

        garage.removePhoto(bike.id)
        XCTAssertNil(garage.photoURL(for: bike.id))
        XCTAssertNil(garage.bikes.first?.photoFileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [], [])
    }

    @MainActor
    func testPhotoExtensionSanitising() async {
        XCTAssertEqual(GarageModel.safeExtension("JPEG"), "jpeg")
        XCTAssertEqual(GarageModel.safeExtension(".heic"), "heic")
        XCTAssertEqual(GarageModel.safeExtension("../../x"), "x")
        XCTAssertEqual(GarageModel.safeExtension(""), "jpg")
        XCTAssertEqual(GarageModel.safeExtension("..."), "jpg")
    }

    // MARK: Removal

    @MainActor
    func testRemoveDeletesPhotoSecretsScopedSettingsAndReselects() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let garage = GarageModel(core: env.core)
        guard case let .paired(first) = garage.pair(rawQR: LDTest.docQR),
              case let .paired(second) = garage.pair(rawQR: LDTest.qr4288) else { return XCTFail("pairing failed") }

        env.core.settings.setVideoQuality(.sharp, forBike: second.id)
        env.core.settings.setButtonAction(.home, for: .navBack, forBike: second.id)
        env.core.dashMemory.observe(ssid: second.ssid, width: 800, height: 951)
        try garage.setPhoto(second.id, imageData: Data([1, 2, 3]))
        let photo = try XCTUnwrap(garage.photoURL(for: second.id))
        var notified: [GarageBike?] = []
        garage.observeSelection { notified.append($0) }

        garage.remove(second.id)
        XCTAssertEqual(garage.bikes.map(\.id), [first.id])
        XCTAssertEqual(garage.selected?.id, first.id)       // selection falls back to the first bike
        XCTAssertEqual(notified.map { $0?.id }, [first.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: photo.path))
        XCTAssertNil(env.core.garage.raw(for: second.id))
        let kv = env.core.services.keyValueStore
        XCTAssertTrue(kv.allKeys().filter { $0.hasSuffix("#" + second.id) }.isEmpty, "\(kv.allKeys())")
        XCTAssertNil(env.core.dashMemory.learnedSize(forSSID: second.ssid))

        garage.remove("unknown")   // no-op
        garage.remove(first.id)
        XCTAssertTrue(garage.bikes.isEmpty)
        XCTAssertNil(garage.selected)
        XCTAssertEqual(notified.count, 2)
        XCTAssertNil(notified.last!)
    }

    // MARK: Learned canvas

    @MainActor
    func testLearnedCanvas() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let garage = GarageModel(core: env.core)
        guard case let .paired(bike) = garage.pair(rawQR: LDTest.qr4288) else { return XCTFail("pairing failed") }
        XCTAssertNil(garage.learnedCanvas(for: bike.id))
        env.core.dashMemory.observe(ssid: bike.ssid, width: 800, height: 951)
        XCTAssertEqual(garage.learnedCanvas(for: bike.id), VideoCanvas.rounded(requestedWidth: 800, requestedHeight: 951))
        XCTAssertNil(garage.learnedCanvas(for: "unknown"))
    }
}
