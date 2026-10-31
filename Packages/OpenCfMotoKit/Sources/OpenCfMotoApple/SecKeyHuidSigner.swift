// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) RsaKeys.kt.
//
// RSA identity of the CLIENT_INFO reply (docs/spec/control-plane.md §9):
// - 1024-bit RSA key generated in memory per process (never persisted, like Android).
// - `pubkey` = base64 (no line breaks) of the X.509 SubjectPublicKeyInfo DER: the fixed 22-byte
//   prefix `30 81 9f 30 0d 06 09 2a 86 48 86 f7 0d 01 01 01 05 00 03 81 8d 00` + the 140-byte PKCS#1
//   RSAPublicKey that `SecKeyCopyExternalRepresentation` returns (216 base64 chars).
// - `encryptedHUID` = RSA/ECB/PKCS1Padding "encryption" with the PRIVATE key of the UTF-8 HUID =
//   a PKCS#1 v1.5 type-1 signature without DigestInfo = `SecKeyCreateSignature(.rsaSignatureDigestPKCS1v15Raw)`
//   (fallback: build `00 01 FF…FF 00 ‖ HUID` ourselves and use `.rsaSignatureRaw`). Deterministic.
// Verified against the fixed test key of control-plane.md §9.5 (tests).

#if canImport(Foundation)
import Foundation
import OpenCfMotoCore

/// Errors of `SecKeyHuidSigner` (and the pure encoding helpers).
public enum HuidSignerError: Error, Equatable, CustomStringConvertible {
    case keyGeneration(String)
    case keyImport(String)
    case publicKeyExport(String)
    /// SecKeyCopyExternalRepresentation did not return a 140-byte PKCS#1 key (not RSA-1024 / e = 65537).
    case unexpectedPublicKeyLength(Int)
    case signing(String)
    /// The UTF-8 HUID is longer than modulus length − 11 bytes (117 for RSA-1024).
    case huidTooLong(Int, Int)

    public var description: String {
        switch self {
        case let .keyGeneration(m): return "RSA key generation failed: \(m)"
        case let .keyImport(m): return "RSA key import failed: \(m)"
        case let .publicKeyExport(m): return "public key export failed: \(m)"
        case let .unexpectedPublicKeyLength(n): return "unexpected PKCS#1 public key length \(n) (expected 140)"
        case let .signing(m): return "HUID signing failed: \(m)"
        case let .huidTooLong(n, max): return "HUID is \(n) bytes, max \(max)"
        }
    }
}

/// DER / padding helpers for the HUID signer (Foundation-only, unit-tested on Linux).
enum SecKeyHuidEncoding {
    /// AlgorithmIdentifier { rsaEncryption (1.2.840.113549.1.1.1), NULL }.
    static let rsaAlgorithmIdentifier: [UInt8] = [
        0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00,
    ]

    /// SPKI prefix for a 140-byte PKCS#1 RSAPublicKey (RSA-1024, e = 65537) — control-plane.md §9.2.
    static let spkiPrefixRSA1024: [UInt8] = [
        0x30, 0x81, 0x9F, 0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01,
        0x05, 0x00, 0x03, 0x81, 0x8D, 0x00,
    ]

    /// Size of the PKCS#1 RSAPublicKey DER of a 1024-bit key with e = 65537.
    static let pkcs1PublicKeyLengthRSA1024 = 140

    /// DER definite length encoding.
    static func derLength(_ n: Int) -> [UInt8] {
        precondition(n >= 0)
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    /// X.509 SubjectPublicKeyInfo wrapping a PKCS#1 RSAPublicKey. For a 140-byte key the result is
    /// `spkiPrefixRSA1024 + pkcs1` (162 bytes) — exactly Java's `PublicKey.encoded`.
    static func subjectPublicKeyInfo(pkcs1RSAPublicKey pkcs1: Data) -> Data {
        var bitString: [UInt8] = [0x03]
        bitString += derLength(pkcs1.count + 1)
        bitString.append(0x00) // no unused bits
        let content = rsaAlgorithmIdentifier + bitString + [UInt8](pkcs1)
        return Data([0x30] + derLength(content.count) + content)
    }

    /// PKCS#1 v1.5 encryption block type 1: `00 01 FF…FF 00 ‖ message` of `modulusLength` bytes
    /// (≥ 8 bytes of FF). Throws when the message is longer than modulusLength − 11.
    static func pkcs1Type1EncodedMessage(_ message: Data, modulusLength k: Int) throws -> Data {
        guard k >= 11, message.count <= k - 11 else { throw HuidSignerError.huidTooLong(message.count, max(0, k - 11)) }
        var em = [UInt8](repeating: 0xFF, count: k)
        em[0] = 0x00
        em[1] = 0x01
        em[k - message.count - 1] = 0x00
        em.replaceSubrange((k - message.count) ..< k, with: message)
        return Data(em)
    }

    /// Base64 without line breaks (Android `Base64.NO_WRAP`).
    static func base64(_ d: Data) -> String { d.base64EncodedString() }
}
#endif

#if canImport(Security) && canImport(Foundation)
import Security

/// `HuidSigner` backed by the Security framework (SecKey).
///
/// Thread-safety: immutable after init (`SecKey` operations are thread-safe).
public final class SecKeyHuidSigner: HuidSigner, @unchecked Sendable {
    public typealias SignerError = HuidSignerError

    public let publicKeyBase64: String
    private let privateKey: SecKey
    private let blockSize: Int

    /// Generates a fresh in-memory 1024-bit RSA key (≈ tens of ms: prefer `generate()` off the main thread).
    public convenience init() throws {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 1024,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: false],
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw SignerError.keyGeneration(Self.describe(error))
        }
        try self.init(privateKey: key)
    }

    /// Imports a PKCS#1 `RSAPrivateKey` DER (test fixtures, control-plane.md §9.5).
    public convenience init(privateKeyPKCS1DER der: Data) throws {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            throw SignerError.keyImport(Self.describe(error))
        }
        try self.init(privateKey: key)
    }

    /// Wraps an existing RSA-1024 private key.
    public init(privateKey: SecKey) throws {
        guard let pub = SecKeyCopyPublicKey(privateKey) else {
            throw SignerError.publicKeyExport("SecKeyCopyPublicKey returned nil")
        }
        var error: Unmanaged<CFError>?
        guard let pkcs1 = SecKeyCopyExternalRepresentation(pub, &error) as Data? else {
            throw SignerError.publicKeyExport(Self.describe(error))
        }
        guard pkcs1.count == SecKeyHuidEncoding.pkcs1PublicKeyLengthRSA1024 else {
            throw SignerError.unexpectedPublicKeyLength(pkcs1.count)
        }
        self.privateKey = privateKey
        self.blockSize = SecKeyGetBlockSize(privateKey)
        self.publicKeyBase64 = SecKeyHuidEncoding.base64(SecKeyHuidEncoding.subjectPublicKeyInfo(pkcs1RSAPublicKey: pkcs1))
    }

    /// Generates the key on a background task (spec §18.8: off the main thread at app start).
    public static func generate() async throws -> SecKeyHuidSigner {
        try await Task.detached(priority: .utility) { try SecKeyHuidSigner() }.value
    }

    public func encryptedHUID(_ huid: String) throws -> String {
        let message = Data(huid.utf8)
        guard message.count <= modulusLength - 11 else {
            throw SignerError.huidTooLong(message.count, modulusLength - 11)
        }
        if let sig = signPKCS1v15Raw(message) { return SecKeyHuidEncoding.base64(sig) }
        return SecKeyHuidEncoding.base64(try signRawFallback(message))
    }

    /// RSA modulus length in bytes (128 for RSA-1024).
    var modulusLength: Int { blockSize > 0 ? blockSize : 128 }

    /// Primary path: `.rsaSignatureDigestPKCS1v15Raw` ("PKCS#1 v1.5 padding, input not wrapped in
    /// DigestInfo"); nil when unsupported or failing.
    func signPKCS1v15Raw(_ message: Data) -> Data? {
        let algorithm = SecKeyAlgorithm.rsaSignatureDigestPKCS1v15Raw
        guard SecKeyIsAlgorithmSupported(privateKey, .sign, algorithm) else { return nil }
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(privateKey, algorithm, message as CFData, &error) as Data? else {
            Log.w("PXC", "[RSA] PKCS1v15Raw signature failed (\(Self.describe(error))) — using raw RSA")
            return nil
        }
        return sig
    }

    /// Fallback path: explicit `00 01 FF…FF 00 ‖ message` block + raw RSA private-key operation.
    func signRawFallback(_ message: Data) throws -> Data {
        let em = try SecKeyHuidEncoding.pkcs1Type1EncodedMessage(message, modulusLength: modulusLength)
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(privateKey, .rsaSignatureRaw, em as CFData, &error) as Data? else {
            throw SignerError.signing(Self.describe(error))
        }
        return sig
    }

    /// Consumes (+1 released) a Security-framework error and describes it.
    private static func describe(_ error: Unmanaged<CFError>?) -> String {
        guard let e = error?.takeRetainedValue() else { return "unknown error" }
        return (e as Error).localizedDescription
    }
}
#endif
