// SPDX-License-Identifier: AGPL-3.0-or-later
// RSA identity (control-plane.md §9): pure SPKI / PKCS#1 helpers (all platforms) and the SecKey
// signer against the fixed test key of §9.5 (Apple platforms).

import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoApple

enum RSAFixture {
    /// control-plane.md §9.5 — PKCS#1 RSAPrivateKey DER (test fixture only).
    static let privateKeyPKCS1Base64 = "MIICWwIBAAKBgQCJK2qMkijMfOspHCr9UMR+djdNu6vnubHpqfJMacvtgSnbOmaMpse9gLsKp3Hd1GTK5k9W8Jk3PPU6JW3drsgdK43RdlotOlGT5PMiw7jmo0OydzXjuFrjfhLscuz6MbNPXO12IkrgoVWPsfOp3xskqWrlfQuCGNljUt/UzHJWFwIDAQABAoGAHOSYxnBZCK29aQTmZ0JWiV7ESmrgDGj4eUQTZhYY3vfIhcWY6UKOKzQM8fMQUI4XBwgZKTJ3y4NbEjrlF/9jZjaP+DySrn+U5HnVkIr4Hye3I2tOqeJaWL4LGFr0fV4qaiJVl4XxL2JMI2RlMt+S9Cw3bPkim4hIJKySXLLbjQkCQQDCzsFwYRj0ddspxVD1hVUQRaB10YTCBYoCMMKyxmWHLQqNukzWTc8EYctsz4T1u4MQnDTc3t6iWdS1of3QKKoPAkEAtEHCivoWq2bVXCViThK+BP/sHEMDyXqTgyMuv1jNkUxpwUmCoptcMNrZMBdfBowrxSe4LBersIMU1ixM/++7eQJARsTVgP3FEwm9lG8Z+hd1z3N711FF6TYZ7LHKCSgJuhGiw9nqD/A0RGNCg0TgCGUWN/KHQbW1K0V3AITYr8YWAQJAS3E+X/Y9qK0YXUGUPELh3qvSAR4XJqszs+30sccT+lz14hzHHRFS62uc/OC7N71Q0GpITcP2aqDiBqVx8KhAWQJAP3c2sgSFzB3rmQCvLG06zxM5wNmeNUiW5Vo6ZBHL8XnoFyJlMIft/pie0smdqoAZ/yCMxa4GVMUGEmc9T5THxA=="
    /// §9.5 — PKCS#1 RSAPublicKey DER (140 B).
    static let publicKeyPKCS1Base64 = "MIGJAoGBAIkraoySKMx86ykcKv1QxH52N027q+e5semp8kxpy+2BKds6Zoymx72Auwqncd3UZMrmT1bwmTc89Tolbd2uyB0rjdF2Wi06UZPk8yLDuOajQ7J3NeO4WuN+Euxy7Poxs09c7XYiSuChVY+x86nfGySpauV9C4IY2WNS39TMclYXAgMBAAE="
    /// §9.5 — expected `pubkey` (SPKI, 216 chars).
    static let expectedPubkey = "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCJK2qMkijMfOspHCr9UMR+djdNu6vnubHpqfJMacvtgSnbOmaMpse9gLsKp3Hd1GTK5k9W8Jk3PPU6JW3drsgdK43RdlotOlGT5PMiw7jmo0OydzXjuFrjfhLscuz6MbNPXO12IkrgoVWPsfOp3xskqWrlfQuCGNljUt/UzHJWFwIDAQAB"
    static let huid = "6GUVA2C00100055"
    /// §9.5 — expected `encryptedHUID` for `huid` (172 chars).
    static let expectedEncryptedHUID = "cfSiCV3iPlLnlyC9c70nMK+ssR6NtAo0nVB9D4IzEa6kszXDMylU7NtPTdLHMnPMqjphXhkVEjpeQ7sapLP0rniYP9fz+ZY5aS/xeGZvLzbxjOR4iHDec2JtAXMI4rJQ4vchKpmAxvQ4yZmKKFmhW2NXmraAKZF9RrzNyFhbZS0="
    /// §9.5 — modulus (hex).
    static let modulusHex = "892b6a8c9228cc7ceb291c2afd50c47e76374dbbabe7b9b1e9a9f24c69cbed8129db3a668ca6c7bd80bb0aa771ddd464cae64f56f099373cf53a256dddaec81d2b8dd1765a2d3a5193e4f322c3b8e6a343b27735e3b85ae37e12ec72ecfa31b34f5ced76224ae0a1558fb1f3a9df1b24a96ae57d0b8218d96352dfd4cc725617"
}

final class PlatformRSAEncodingTests: XCTestCase {
    func testSPKIPrefixConstantMatchesSpec() {
        XCTAssertEqual(Data(SecKeyHuidEncoding.spkiPrefixRSA1024).hexString,
                       "30819f300d06092a864886f70d010101050003818d00")
        XCTAssertEqual(SecKeyHuidEncoding.spkiPrefixRSA1024.count, 22)
    }

    func testFixturePublicKeyIsPKCS1WithSpecModulus() throws {
        let pkcs1 = try XCTUnwrap(Data(base64Encoded: RSAFixture.publicKeyPKCS1Base64))
        XCTAssertEqual(pkcs1.count, 140)
        // 30 81 89 | 02 81 81 00 <128-byte modulus> | 02 03 01 00 01
        XCTAssertEqual(Data(pkcs1.prefix(7)).hexString, "30818902818100")
        XCTAssertEqual(Data(pkcs1[7 ..< 135]).hexString, RSAFixture.modulusHex)
        XCTAssertEqual(Data(pkcs1.suffix(5)).hexString, "0203010001")
    }

    func testSubjectPublicKeyInfoOfFixtureMatchesExpectedPubkey() throws {
        let pkcs1 = try XCTUnwrap(Data(base64Encoded: RSAFixture.publicKeyPKCS1Base64))
        let spki = SecKeyHuidEncoding.subjectPublicKeyInfo(pkcs1RSAPublicKey: pkcs1)
        XCTAssertEqual(spki.count, 162)
        XCTAssertEqual([UInt8](spki.prefix(22)), SecKeyHuidEncoding.spkiPrefixRSA1024)
        XCTAssertEqual(SecKeyHuidEncoding.base64(spki), RSAFixture.expectedPubkey)
        XCTAssertEqual(RSAFixture.expectedPubkey.count, 216)
        XCTAssertTrue(RSAFixture.expectedPubkey.hasPrefix("MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQ"))
    }

    func testDERLengthEncoding() {
        XCTAssertEqual(SecKeyHuidEncoding.derLength(0), [0x00])
        XCTAssertEqual(SecKeyHuidEncoding.derLength(127), [0x7F])
        XCTAssertEqual(SecKeyHuidEncoding.derLength(128), [0x81, 0x80])
        XCTAssertEqual(SecKeyHuidEncoding.derLength(159), [0x81, 0x9F])
        XCTAssertEqual(SecKeyHuidEncoding.derLength(255), [0x81, 0xFF])
        XCTAssertEqual(SecKeyHuidEncoding.derLength(256), [0x82, 0x01, 0x00])
        XCTAssertEqual(SecKeyHuidEncoding.derLength(270), [0x82, 0x01, 0x0E])
    }

    func testSPKIForLargerKeyUsesLongForms() {
        // RSA-2048 PKCS#1 public key is 270 bytes → BIT STRING 271 (82 01 0f), SEQUENCE 290 (82 01 22).
        let spki = SecKeyHuidEncoding.subjectPublicKeyInfo(pkcs1RSAPublicKey: Data(repeating: 0xAB, count: 270))
        XCTAssertEqual(Data(spki.prefix(4)).hexString, "30820122")
        XCTAssertEqual(Data(spki[19 ..< 24]).hexString, "038201" + "0f" + "00")
        XCTAssertEqual(spki.count, 294)
    }

    /// control-plane.md §9.3: the public-key operation on the §8.4 encryptedHUID recovers exactly this block.
    func testPKCS1Type1EncodedMessageMatchesSpecVector() throws {
        let em = try SecKeyHuidEncoding.pkcs1Type1EncodedMessage(Data(RSAFixture.huid.utf8), modulusLength: 128)
        var expected = Data([0x00, 0x01])
        expected.append(Data(repeating: 0xFF, count: 110))
        expected.append(0x00)
        expected.append(Data("6GUVA2C00100055".utf8))
        XCTAssertEqual(em, expected)
        XCTAssertEqual(em.count, 128)
        XCTAssertEqual(Data(em.suffix(16)).hexString, "0036475556413243303031303030 3535".replacingOccurrences(of: " ", with: ""))
    }

    func testPKCS1Type1LimitsAndEdges() throws {
        XCTAssertNoThrow(try SecKeyHuidEncoding.pkcs1Type1EncodedMessage(Data(repeating: 0x41, count: 117), modulusLength: 128))
        XCTAssertThrowsError(try SecKeyHuidEncoding.pkcs1Type1EncodedMessage(Data(repeating: 0x41, count: 118), modulusLength: 128)) { e in
            XCTAssertEqual(e as? HuidSignerError, .huidTooLong(118, 117))
        }
        let empty = try SecKeyHuidEncoding.pkcs1Type1EncodedMessage(Data(), modulusLength: 128)
        XCTAssertEqual(empty.count, 128)
        XCTAssertEqual(empty[127], 0x00)
        XCTAssertEqual(empty[126], 0xFF)
        XCTAssertThrowsError(try SecKeyHuidEncoding.pkcs1Type1EncodedMessage(Data(), modulusLength: 8))
    }

    func testExpectedEncryptedHUIDShape() throws {
        XCTAssertEqual(RSAFixture.expectedEncryptedHUID.count, 172)
        XCTAssertEqual(try XCTUnwrap(Data(base64Encoded: RSAFixture.expectedEncryptedHUID)).count, 128)
        XCTAssertFalse(RSAFixture.expectedEncryptedHUID.contains("\n"))
    }
}

#if canImport(Security)
import Security

final class PlatformSecKeySignerTests: XCTestCase {
    private func fixtureSigner() throws -> SecKeyHuidSigner {
        let der = try XCTUnwrap(Data(base64Encoded: RSAFixture.privateKeyPKCS1Base64))
        return try SecKeyHuidSigner(privateKeyPKCS1DER: der)
    }

    func testFixtureKeyProducesSpecPubkey() throws {
        XCTAssertEqual(try fixtureSigner().publicKeyBase64, RSAFixture.expectedPubkey)
    }

    func testFixtureKeyProducesSpecEncryptedHUID() throws {
        let signer = try fixtureSigner()
        XCTAssertEqual(try signer.encryptedHUID(RSAFixture.huid), RSAFixture.expectedEncryptedHUID)
        // Deterministic (PKCS#1 v1.5 type 1).
        XCTAssertEqual(try signer.encryptedHUID(RSAFixture.huid), RSAFixture.expectedEncryptedHUID)
    }

    func testBothSigningPathsMatchTheVector() throws {
        let signer = try fixtureSigner()
        let message = Data(RSAFixture.huid.utf8)
        XCTAssertEqual(signer.modulusLength, 128)
        if let primary = signer.signPKCS1v15Raw(message) {
            XCTAssertEqual(primary.base64EncodedString(), RSAFixture.expectedEncryptedHUID)
        }
        XCTAssertEqual(try signer.signRawFallback(message).base64EncodedString(), RSAFixture.expectedEncryptedHUID)
    }

    func testHUIDTooLongThrows() throws {
        let signer = try fixtureSigner()
        XCTAssertThrowsError(try signer.encryptedHUID(String(repeating: "A", count: 118))) { e in
            XCTAssertEqual(e as? HuidSignerError, .huidTooLong(118, 117))
        }
        XCTAssertNoThrow(try signer.encryptedHUID(String(repeating: "A", count: 117)))
    }

    func testGeneratedKeyHasAndroidShapes() throws {
        let signer = try SecKeyHuidSigner()
        XCTAssertEqual(signer.publicKeyBase64.count, 216)
        XCTAssertTrue(signer.publicKeyBase64.hasPrefix("MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQ"))
        let sig = try signer.encryptedHUID(RSAFixture.huid)
        XCTAssertEqual(sig.count, 172)
        XCTAssertEqual(try signer.encryptedHUID(RSAFixture.huid), sig)
        XCTAssertNotEqual(sig, RSAFixture.expectedEncryptedHUID)
    }

    func testGenerateOffMainThread() async throws {
        let signer = try await SecKeyHuidSigner.generate()
        XCTAssertEqual(signer.publicKeyBase64.count, 216)
        let other = try await SecKeyHuidSigner.generate()
        XCTAssertNotEqual(signer.publicKeyBase64, other.publicKeyBase64, "fresh key per call")
    }

    func testInvalidPrivateKeyDERThrows() {
        XCTAssertThrowsError(try SecKeyHuidSigner(privateKeyPKCS1DER: Data([0x30, 0x03, 0x02, 0x01, 0x00])))
    }
}
#endif
