// SPDX-License-Identifier: AGPL-3.0-or-later
// Vectors: docs/spec/control-plane.md §9.2, §9.3, §9.5 (fixed test key, DERIVED Java ↔ Python).
import XCTest
@testable import OpenCfMotoCore

final class RSASignerTests: XCTestCase {
    static let pkcs8PrivateKeyBase64 = "MIICdQIBADANBgkqhkiG9w0BAQEFAASCAl8wggJbAgEAAoGBAIkraoySKMx86ykcKv1QxH52N027q+e5semp8kxpy+2BKds6Zoymx72Auwqncd3UZMrmT1bwmTc89Tolbd2uyB0rjdF2Wi06UZPk8yLDuOajQ7J3NeO4WuN+Euxy7Poxs09c7XYiSuChVY+x86nfGySpauV9C4IY2WNS39TMclYXAgMBAAECgYAc5JjGcFkIrb1pBOZnQlaJXsRKauAMaPh5RBNmFhje98iFxZjpQo4rNAzx8xBQjhcHCBkpMnfLg1sSOuUX/2NmNo/4PJKuf5TkedWQivgfJ7cja06p4lpYvgsYWvR9XipqIlWXhfEvYkwjZGUy35L0LDds+SKbiEgkrJJcstuNCQJBAMLOwXBhGPR12ynFUPWFVRBFoHXRhMIFigIwwrLGZYctCo26TNZNzwRhy2zPhPW7gxCcNNze3qJZ1LWh/dAoqg8CQQC0QcKK+harZtVcJWJOEr4E/+wcQwPJepODIy6/WM2RTGnBSYKim1ww2tkwF18GjCvFJ7gsF6uwgxTWLEz/77t5AkBGxNWA/cUTCb2Ubxn6F3XPc3vXUUXpNhnsscoJKAm6EaLD2eoP8DREY0KDROAIZRY38odBtbUrRXcAhNivxhYBAkBLcT5f9j2orRhdQZQ8QuHeq9IBHhcmqzOz7fSxxxP6XPXiHMcdEVLra5z84Ls3vVDQakhNw/ZqoOIGpXHwqEBZAkA/dzayBIXMHeuZAK8sbTrPEznA2Z41SJblWjpkEcvxeegXImUwh+3+mJ7SyZ2qgBn/IIzFrgZUxQYSZz1PlMfE"
    static let pkcs1PublicKeyBase64 = "MIGJAoGBAIkraoySKMx86ykcKv1QxH52N027q+e5semp8kxpy+2BKds6Zoymx72Auwqncd3UZMrmT1bwmTc89Tolbd2uyB0rjdF2Wi06UZPk8yLDuOajQ7J3NeO4WuN+Euxy7Poxs09c7XYiSuChVY+x86nfGySpauV9C4IY2WNS39TMclYXAgMBAAE="
    static let expectedPubkey = "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCJK2qMkijMfOspHCr9UMR+djdNu6vnubHpqfJMacvtgSnbOmaMpse9gLsKp3Hd1GTK5k9W8Jk3PPU6JW3drsgdK43RdlotOlGT5PMiw7jmo0OydzXjuFrjfhLscuz6MbNPXO12IkrgoVWPsfOp3xskqWrlfQuCGNljUt/UzHJWFwIDAQAB"
    static let expectedEncryptedHUID = "cfSiCV3iPlLnlyC9c70nMK+ssR6NtAo0nVB9D4IzEa6kszXDMylU7NtPTdLHMnPMqjphXhkVEjpeQ7sapLP0rniYP9fz+ZY5aS/xeGZvLzbxjOR4iHDec2JtAXMI4rJQ4vchKpmAxvQ4yZmKKFmhW2NXmraAKZF9RrzNyFhbZS0="
    static let modulusHex = "892b6a8c9228cc7ceb291c2afd50c47e76374dbbabe7b9b1e9a9f24c69cbed8129db3a668ca6c7bd80bb0aa771ddd464cae64f56f099373cf53a256dddaec81d2b8dd1765a2d3a5193e4f322c3b8e6a343b27735e3b85ae37e12ec72ecfa31b34f5ced76224ae0a1558fb1f3a9df1b24a96ae57d0b8218d96352dfd4cc725617"

    private var key: RSAKeyMaterial { LinkTestKeys.fixtureSigner.key }

    func testFixtureKeySignsHuidByteForByte() throws {
        let signer = LinkTestKeys.fixtureSigner
        XCTAssertEqual(signer.publicKeyBase64, Self.expectedPubkey)
        XCTAssertEqual(signer.publicKeyBase64.count, 216)
        let sig = try signer.encryptedHUID("6GUVA2C00100055")
        XCTAssertEqual(sig, Self.expectedEncryptedHUID)
        XCTAssertEqual(sig.count, 172)
        XCTAssertFalse(sig.contains("\n"))
    }

    func testKeyComponents() {
        XCTAssertEqual(key.modulus.hexString, Self.modulusHex)
        XCTAssertEqual(key.modulusBitCount, 1024)
        XCTAssertEqual(key.modulusByteCount, 128)
        XCTAssertEqual(key.publicExponent, Data([0x01, 0x00, 0x01]))
    }

    func testPKCS1PublicKeyAndSPKIPrefix() {
        XCTAssertEqual(key.pkcs1PublicKeyDER.base64EncodedString(), Self.pkcs1PublicKeyBase64)
        XCTAssertEqual(key.pkcs1PublicKeyDER.count, 140)
        let spki = key.subjectPublicKeyInfoDER
        XCTAssertEqual(spki.count, 162)
        XCTAssertEqual([UInt8](spki.prefix(22)), RSAKeyMaterial.spkiPrefix1024)
        XCTAssertEqual(Array(spki.prefix(22)), [0x30, 0x81, 0x9F, 0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D,
                                                 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x81, 0x8D, 0x00])
        XCTAssertEqual(spki.dropFirst(22), key.pkcs1PublicKeyDER)
        XCTAssertTrue(spki.base64EncodedString().hasPrefix("MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQ"))
    }

    func testPublicOperationRecoversTheType1Block() throws {
        // §9.3: 00 01 FF…FF 00 ‖ "6GUVA2C00100055".
        let sig = [UInt8](Data(base64Encoded: Self.expectedEncryptedHUID)!)
        let em = key.publicOperation(sig)
        XCTAssertEqual(em.count, 128)
        XCTAssertEqual(Array(em.prefix(2)), [0x00, 0x01])
        XCTAssertEqual(Array(em[2 ..< 112]), [UInt8](repeating: 0xFF, count: 110))
        XCTAssertEqual(em[112], 0x00)
        XCTAssertEqual(Data(em[113...]), linkHex("36 47 55 56 41 32 43 30 30 31 30 30 30 35 35"))
        XCTAssertEqual(key.verifyPKCS1v15Raw(sig).map { String(decoding: $0, as: UTF8.self) }, "6GUVA2C00100055")
        XCTAssertEqual(try key.pkcs1Type1Encode(Array("6GUVA2C00100055".utf8)), em)
    }

    func testPKCS8ParsesToTheSameKey() throws {
        let k8 = try RSAKeyMaterial(pkcs8PrivateKeyDER: Data(base64Encoded: Self.pkcs8PrivateKeyBase64)!)
        XCTAssertEqual(k8.modulus, key.modulus)
        XCTAssertEqual(k8.privateExponent, key.privateExponent)
        XCTAssertEqual(PureSwiftHuidSigner(key: k8).publicKeyBase64, Self.expectedPubkey)
    }

    func testComponentInitializerMatchesDER() throws {
        let s = try PureSwiftHuidSigner(modulus: key.modulus, publicExponent: key.publicExponent,
                                        privateExponent: key.privateExponent)
        XCTAssertEqual(s.publicKeyBase64, Self.expectedPubkey)
        XCTAssertEqual(try s.encryptedHUID("6GUVA2C00100055"), Self.expectedEncryptedHUID)
    }

    func testMessageLengthLimitIs117Bytes() throws {
        XCTAssertNoThrow(try key.pkcs1Type1Encode([UInt8](repeating: 0x41, count: 117)))
        XCTAssertThrowsError(try key.pkcs1Type1Encode([UInt8](repeating: 0x41, count: 118))) { e in
            XCTAssertEqual(e as? RSAError, .messageTooLong(length: 118, max: 117))
        }
        XCTAssertThrowsError(try LinkTestKeys.fixtureSigner.encryptedHUID(String(repeating: "x", count: 118)))
        // Empty HUID still pads (the link never signs it, but the operation is defined).
        XCTAssertEqual(try key.pkcs1Type1Encode([]).count, 128)
    }

    func testDeterminism() throws {
        let a = try LinkTestKeys.fixtureSigner.encryptedHUID("CRCP230501740")
        let b = try LinkTestKeys.fixtureSigner.encryptedHUID("CRCP230501740")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, Self.expectedEncryptedHUID)
    }

    func testInvalidKeysAreRejected() {
        XCTAssertThrowsError(try RSAKeyMaterial(pkcs1PrivateKeyDER: Data([0x30, 0x03, 0x02, 0x01, 0x00])))
        XCTAssertThrowsError(try RSAKeyMaterial(pkcs1PrivateKeyDER: Data([0x02, 0x01, 0x00])))
        XCTAssertThrowsError(try RSAKeyMaterial(modulus: Data([0x0F]), publicExponent: Data([3]), privateExponent: Data([1])))
    }

    func testDERIntegerEncoding() {
        XCTAssertEqual(RSADER.integer([0x01, 0x00, 0x01]), [0x02, 0x03, 0x01, 0x00, 0x01])
        XCTAssertEqual(RSADER.integer([0x80]), [0x02, 0x02, 0x00, 0x80]) // leading 0x00 when the high bit is set
        XCTAssertEqual(RSADER.integer([0x00, 0x00, 0x7F]), [0x02, 0x01, 0x7F]) // minimal
        XCTAssertEqual(RSADER.integer([]), [0x02, 0x01, 0x00])
        XCTAssertEqual(RSADER.length(0x7F), [0x7F])
        XCTAssertEqual(RSADER.length(0x81), [0x81, 0x81])
        XCTAssertEqual(RSADER.length(0x15F), [0x82, 0x01, 0x5F])
    }

    func testGeneratedKeyRoundTripsDeterministically() throws {
        var rng = LinkSplitMix64(seed: 0x0C_F3_07_0)
        let k = RSAKeyMaterial.generate(bits: 512, using: &rng)
        XCTAssertEqual(k.modulusBitCount, 512)
        XCTAssertEqual(k.publicExponent, Data([0x01, 0x00, 0x01]))
        let sig = try k.signPKCS1v15Raw(Array("HUID-1".utf8))
        XCTAssertEqual(sig.count, 64)
        XCTAssertEqual(k.verifyPKCS1v15Raw(sig), Array("HUID-1".utf8))
        // Same seed → same key.
        var rng2 = LinkSplitMix64(seed: 0x0C_F3_07_0)
        XCTAssertEqual(RSAKeyMaterial.generate(bits: 512, using: &rng2), k)
    }

    func testGenerated1024BitSignerHasJavaShapedOutputs() throws {
        var rng = LinkSplitMix64(seed: 42)
        let signer = PureSwiftHuidSigner(key: RSAKeyMaterial.generate(bits: 1024, using: &rng))
        XCTAssertEqual(signer.key.modulusBitCount, 1024)
        XCTAssertEqual(signer.publicKeyBase64.count, 216)
        XCTAssertTrue(signer.publicKeyBase64.hasPrefix("MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQ"))
        let sig = try signer.encryptedHUID("6GUVA2C00100055")
        XCTAssertEqual(sig.count, 172)
        XCTAssertTrue(sig.hasSuffix("="))
        XCTAssertEqual(signer.key.verifyPKCS1v15Raw([UInt8](Data(base64Encoded: sig)!)), Array("6GUVA2C00100055".utf8))
    }
}

final class RSABigUIntTests: XCTestCase {
    func testBytesAndHexRoundTrip() {
        let v = RSABigUInt(hex: "0100000000000000000000000001")!
        XCTAssertEqual(v.hexString, "0100000000000000000000000001")
        XCTAssertEqual(v.bigEndianBytes.count, 14)
        XCTAssertEqual(v.bigEndianBytes(length: 16)?.count, 16)
        XCTAssertNil(v.bigEndianBytes(length: 13))
        XCTAssertEqual(RSABigUInt(bigEndian: [0, 0, 5]), RSABigUInt(5))
        XCTAssertEqual(RSABigUInt().bigEndianBytes, [])
        XCTAssertEqual(RSABigUInt(hex: "zz"), nil)
        XCTAssertEqual(RSABigUInt(0x1234_5678_9ABC_DEF0).bitWidth, 61)
    }

    func testArithmetic() {
        let a = RSABigUInt(hex: "ffffffffffffffffffffffffffffffff")!
        let b = RSABigUInt(hex: "1")!
        XCTAssertEqual((a + b).hexString, "0100000000000000000000000000000000")
        XCTAssertEqual(((a + b) - b), a)
        let p = RSABigUInt(hex: "fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f")!
        let sq = p * p
        XCTAssertEqual(sq.hexString, "fffffffffffffffffffffffffffffffffffffffffffffffffffffffdfffff85e000000000000000000000000000000000000000000000001000007a2000e90a1")
        let (q, r) = sq.quotientAndRemainder(dividingBy: p)
        XCTAssertEqual(q, p)
        XCTAssertTrue(r.isZero)
        let (q2, r2) = (sq + RSABigUInt(12345)).quotientAndRemainder(dividingBy: p)
        XCTAssertEqual(q2, p)
        XCTAssertEqual(r2, RSABigUInt(12345))
        XCTAssertEqual(RSABigUInt(1_000_000_007).remainder(dividingBy: 97), UInt32(1_000_000_007 % 97))
        XCTAssertEqual(RSABigUInt(0b1011_0000).trailingZeroBitCount, 4)
        XCTAssertEqual(RSABigUInt(hex: "0100000000")!.shiftedRight(by: 4).hexString, "10000000")
    }

    func testDivisionAddBackPath() {
        // Knuth D corner cases: divisors whose top limb forces qhat corrections.
        let u = RSABigUInt(limbs: [0, 0, 0x8000_0000, 0x7FFF_FFFF])
        let v = RSABigUInt(limbs: [1, 0, 0x8000_0000])
        let (q, r) = u.quotientAndRemainder(dividingBy: v)
        XCTAssertEqual(q * v + r, u)
        XCTAssertTrue(r < v)
        // Randomized cross-check q·v + r = u, r < v.
        var rng = LinkSplitMix64(seed: 7)
        for _ in 0 ..< 200 {
            let ub = Int(rng.next() % 300) + 1, vb = Int(rng.next() % 200) + 1
            let x = RSABigUInt.random(bits: ub, using: &rng)
            var y = RSABigUInt.random(bits: vb, using: &rng)
            if y.isZero { y = .one }
            let (qq, rr) = x.quotientAndRemainder(dividingBy: y)
            XCTAssertEqual(qq * y + rr, x)
            XCTAssertTrue(rr < y)
        }
    }

    func testModPow() {
        XCTAssertEqual(RSABigUInt(4).power(RSABigUInt(13), modulus: RSABigUInt(497)), RSABigUInt(445))
        XCTAssertEqual(RSABigUInt(2).power(RSABigUInt(0), modulus: RSABigUInt(7)), .one)
        XCTAssertEqual(RSABigUInt(0).power(RSABigUInt(5), modulus: RSABigUInt(7)), .zero)
        XCTAssertEqual(RSABigUInt(5).power(RSABigUInt(3), modulus: .one), .zero)
        // Fermat: a^(p-1) ≡ 1 mod p for the secp256k1 field prime.
        let p = RSABigUInt(hex: "fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f")!
        XCTAssertEqual(RSABigUInt(3).power(p - .one, modulus: p), .one)
    }

    func testPrimality() {
        var rng = LinkSplitMix64(seed: 1)
        XCTAssertTrue(RSAPrimes.isProbablePrime(RSABigUInt(hex: "fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f")!, rounds: 8, using: &rng))
        XCTAssertFalse(RSAPrimes.isProbablePrime(RSABigUInt(561), rounds: 8, using: &rng)) // Carmichael
        XCTAssertTrue(RSAPrimes.isProbablePrime(RSABigUInt(65537), rounds: 8, using: &rng))
        XCTAssertFalse(RSAPrimes.isProbablePrime(RSABigUInt(65537 * 65539), rounds: 8, using: &rng))
        XCTAssertEqual(RSAPrimes.smallInverse(3, 11), 4)
        XCTAssertNil(RSAPrimes.smallInverse(4, 8))
    }
}

/// Deterministic generator for reproducible key generation in tests.
struct LinkSplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
