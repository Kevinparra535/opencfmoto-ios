// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) RsaKeys.kt
//
// Pure-Swift RSA for the CLIENT_INFO identity (docs/spec/control-plane.md §9): a 1024-bit key,
// `pubkey` = base64(X.509 SubjectPublicKeyInfo DER), `encryptedHUID` = base64(PKCS#1 v1.5 block
// type 1 padding of the UTF-8 HUID raised to d mod n) — Java's `Cipher("RSA/ECB/PKCS1Padding")`
// ENCRYPT_MODE with the PRIVATE key, i.e. a "NONEwithRSA" signature. Deterministic.

import Foundation

public enum RSAError: Error, Equatable, CustomStringConvertible {
    /// Message longer than `modulusBytes - 11`.
    case messageTooLong(length: Int, max: Int)
    case invalidKey(String)
    case invalidDER(String)

    public var description: String {
        switch self {
        case let .messageTooLong(l, m): return "RSA message too long (\(l) > \(m) bytes)"
        case let .invalidKey(m): return "invalid RSA key: \(m)"
        case let .invalidDER(m): return "invalid DER: \(m)"
        }
    }
}

/// RSA key components (big-endian magnitudes). `p`/`q` are kept when known (generated / parsed keys).
public struct RSAKeyMaterial: Sendable, Equatable {
    let n: RSABigUInt
    let e: RSABigUInt
    let d: RSABigUInt
    let p: RSABigUInt?
    let q: RSABigUInt?

    /// Builds a key from big-endian modulus, public and private exponents.
    public init(modulus: Data, publicExponent: Data, privateExponent: Data) throws {
        try self.init(n: RSABigUInt(bigEndian: modulus), e: RSABigUInt(bigEndian: publicExponent),
                      d: RSABigUInt(bigEndian: privateExponent), p: nil, q: nil)
    }

    init(n: RSABigUInt, e: RSABigUInt, d: RSABigUInt, p: RSABigUInt?, q: RSABigUInt?) throws {
        guard n.bitWidth >= 512 else { throw RSAError.invalidKey("modulus too small (\(n.bitWidth) bits)") }
        guard n.isOdd else { throw RSAError.invalidKey("even modulus") }
        guard !e.isZero, !d.isZero, e < n, d < n else { throw RSAError.invalidKey("bad exponent") }
        self.n = n
        self.e = e
        self.d = d
        self.p = p
        self.q = q
    }

    /// Parses a PKCS#1 `RSAPrivateKey` DER (SEQUENCE { version, n, e, d, p, q, dp, dq, qinv }).
    public init(pkcs1PrivateKeyDER der: Data) throws {
        var outer = RSADERReader(bytes: [UInt8](der))
        var seq = try outer.readSequence()
        let version = try seq.readInteger()
        guard version.isZero else { throw RSAError.invalidDER("unsupported RSAPrivateKey version") }
        let n = try seq.readInteger()
        let e = try seq.readInteger()
        let d = try seq.readInteger()
        let p = try? seq.readInteger()
        let q = try? seq.readInteger()
        try self.init(n: n, e: e, d: d, p: p, q: q)
    }

    /// Parses a PKCS#8 `PrivateKeyInfo` DER wrapping an rsaEncryption PKCS#1 key (Java `PrivateKey.encoded`).
    public init(pkcs8PrivateKeyDER der: Data) throws {
        var outer = RSADERReader(bytes: [UInt8](der))
        var seq = try outer.readSequence()
        _ = try seq.readInteger() // version 0
        _ = try seq.readElement(tag: 0x30) // AlgorithmIdentifier
        let inner = try seq.readElement(tag: 0x04) // OCTET STRING
        try self.init(pkcs1PrivateKeyDER: Data(inner))
    }

    /// Modulus size in bytes (128 for RSA-1024).
    public var modulusByteCount: Int { (n.bitWidth + 7) / 8 }
    public var modulusBitCount: Int { n.bitWidth }
    public var modulus: Data { Data(n.bigEndianBytes) }
    public var publicExponent: Data { Data(e.bigEndianBytes) }
    public var privateExponent: Data { Data(d.bigEndianBytes) }

    /// PKCS#1 `RSAPublicKey` DER (140 bytes for a 1024-bit key with e = 65537).
    public var pkcs1PublicKeyDER: Data {
        Data(RSADER.sequence(RSADER.integer(n.bigEndianBytes) + RSADER.integer(e.bigEndianBytes)))
    }

    /// X.509 `SubjectPublicKeyInfo` DER (Java `PublicKey.encoded`; 162 bytes for RSA-1024).
    public var subjectPublicKeyInfoDER: Data {
        let algorithm = RSADER.sequence(RSADER.rsaEncryptionOID + [0x05, 0x00])
        let bitString = RSADER.bitString([UInt8](pkcs1PublicKeyDER))
        return Data(RSADER.sequence(algorithm + bitString))
    }

    /// The fixed 22-byte SPKI prefix in front of a 140-byte PKCS#1 RSA-1024 public key.
    public static let spkiPrefix1024: [UInt8] = [
        0x30, 0x81, 0x9F, 0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01,
        0x05, 0x00, 0x03, 0x81, 0x8D, 0x00,
    ]

    /// PKCS#1 v1.5 block type 1 encoding: `00 01 FF…FF 00 ‖ message` (at least 8 FF bytes).
    public func pkcs1Type1Encode(_ message: [UInt8]) throws -> [UInt8] {
        let k = modulusByteCount
        let maxLen = k - 11
        guard message.count <= maxLen else { throw RSAError.messageTooLong(length: message.count, max: maxLen) }
        return [0x00, 0x01] + [UInt8](repeating: 0xFF, count: k - 3 - message.count) + [0x00] + message
    }

    /// Private-key operation on a PKCS#1 v1.5 type-1 block: the `encryptedHUID` bytes (k bytes).
    public func signPKCS1v15Raw(_ message: [UInt8]) throws -> [UInt8] {
        let em = RSABigUInt(bigEndian: try pkcs1Type1Encode(message))
        let s = em.power(d, modulus: n)
        guard let out = s.bigEndianBytes(length: modulusByteCount) else { throw RSAError.invalidKey("signature overflow") }
        return out
    }

    /// Public-key operation (what the dash would do to recover the padded HUID block).
    public func publicOperation(_ signature: [UInt8]) -> [UInt8] {
        let s = RSABigUInt(bigEndian: signature)
        return s.power(e, modulus: n).bigEndianBytes(length: modulusByteCount) ?? []
    }

    /// Recovers the message of a type-1 block produced by `signPKCS1v15Raw` (nil if malformed).
    public func verifyPKCS1v15Raw(_ signature: [UInt8]) -> [UInt8]? {
        let em = publicOperation(signature)
        guard em.count >= 11, em[0] == 0, em[1] == 1 else { return nil }
        var i = 2
        while i < em.count, em[i] == 0xFF { i += 1 }
        guard i - 2 >= 8, i < em.count, em[i] == 0 else { return nil }
        return Array(em[(i + 1)...])
    }

    // MARK: Key generation

    /// Generates an RSA key (Miller-Rabin primes, two top bits set so `n` has exactly `bits` bits).
    public static func generate(bits: Int = 1024, publicExponent: UInt32 = 65537) -> RSAKeyMaterial {
        var rng = SystemRandomNumberGenerator()
        return generate(bits: bits, publicExponent: publicExponent, using: &rng)
    }

    /// Deterministic generation with an injected generator (tests).
    public static func generate<G: RandomNumberGenerator>(bits: Int = 1024, publicExponent: UInt32 = 65537,
                                                          using rng: inout G) -> RSAKeyMaterial {
        precondition(bits >= 512 && bits % 2 == 0, "RSA key size must be even and >= 512")
        precondition(publicExponent >= 3 && publicExponent % 2 == 1)
        let e = RSABigUInt(UInt64(publicExponent))
        while true {
            let p = RSAPrimes.generatePrime(bits: bits / 2, publicExponent: publicExponent, using: &rng)
            let q = RSAPrimes.generatePrime(bits: bits / 2, publicExponent: publicExponent, using: &rng)
            guard p != q else { continue }
            let n = p * q
            guard n.bitWidth == bits else { continue }
            let phi = (p - .one) * (q - .one)
            guard let d = RSAPrimes.inverseOfSmallExponent(publicExponent, modulo: phi) else { continue }
            if let key = try? RSAKeyMaterial(n: n, e: e, d: d, p: max(p, q), q: min(p, q)) {
                return key
            }
        }
    }
}

/// Prime generation helpers.
enum RSAPrimes {
    /// Odd primes below 2000 for trial division.
    static let smallPrimes: [UInt32] = {
        let limit = 2000
        var composite = [Bool](repeating: false, count: limit)
        var out: [UInt32] = []
        for i in 2 ..< limit where !composite[i] {
            if i > 2 { out.append(UInt32(i)) }
            var j = i * i
            while j < limit {
                composite[j] = true
                j += i
            }
        }
        return out
    }()

    /// Random prime of exactly `bits` bits with the two top bits set and `gcd(p-1, e) = 1`.
    static func generatePrime<G: RandomNumberGenerator>(bits: Int, publicExponent: UInt32, using rng: inout G) -> RSABigUInt {
        let rounds = bits >= 512 ? 7 : 12
        while true {
            var candidate = RSABigUInt.random(bits: bits, using: &rng)
            // Force the two most significant bits and oddness.
            var limbs = candidate.limbs
            limbs += [UInt32](repeating: 0, count: max(0, (bits + 31) / 32 - limbs.count))
            let top = bits - 1
            limbs[top / 32] |= 1 << UInt32(top % 32)
            limbs[(top - 1) / 32] |= 1 << UInt32((top - 1) % 32)
            limbs[0] |= 1
            candidate = RSABigUInt(limbs: limbs)
            if smallPrimes.contains(where: { candidate.remainder(dividingBy: $0) == 0 }) { continue }
            if candidate.remainder(dividingBy: publicExponent) == 1 { continue } // e | p-1
            if isProbablePrime(candidate, rounds: rounds, using: &rng) { return candidate }
        }
    }

    /// Miller-Rabin with random bases.
    static func isProbablePrime<G: RandomNumberGenerator>(_ n: RSABigUInt, rounds: Int, using rng: inout G) -> Bool {
        if n < RSABigUInt(4) { return n == RSABigUInt(2) || n == RSABigUInt(3) }
        if n.isEven { return false }
        for p in smallPrimes where RSABigUInt(UInt64(p)) < n {
            if n.remainder(dividingBy: p) == 0 { return false }
        }
        let nMinus1 = n - .one
        let s = nMinus1.trailingZeroBitCount
        let d = nMinus1.shiftedRight(by: s)
        let two = RSABigUInt(2)
        outer: for _ in 0 ..< rounds {
            let a = RSABigUInt.random(in: two, nMinus1, using: &rng) // [2, n-2]
            var x = a.power(d, modulus: n)
            if x == .one || x == nMinus1 { continue }
            for _ in 1 ..< max(s, 1) {
                x = (x * x) % n
                if x == nMinus1 { continue outer }
                if x == .one { return false }
            }
            return false
        }
        return true
    }

    /// `e⁻¹ mod phi` for a small prime-like exponent: d = (1 + k·phi) / e with k ≡ −phi⁻¹ (mod e).
    /// nil when gcd(e, phi) ≠ 1.
    static func inverseOfSmallExponent(_ e: UInt32, modulo phi: RSABigUInt) -> RSABigUInt? {
        let r = Int64(phi.remainder(dividingBy: e))
        guard r != 0, let rInv = smallInverse(r, Int64(e)) else { return nil }
        let k = (Int64(e) - rInv) % Int64(e)
        let numerator = RSABigUInt.one + RSABigUInt(UInt64(k)) * phi
        let (dq, rem) = numerator.quotientAndRemainder(dividingBy: RSABigUInt(UInt64(e)))
        guard rem.isZero else { return nil }
        return dq
    }

    /// Modular inverse of `a` mod `m` for small values (extended Euclid); nil if not coprime.
    static func smallInverse(_ a: Int64, _ m: Int64) -> Int64? {
        var (oldR, r) = (a % m, m)
        var (oldS, s) = (Int64(1), Int64(0))
        while r != 0 {
            let q = oldR / r
            (oldR, r) = (r, oldR - q * r)
            (oldS, s) = (s, oldS - q * s)
        }
        guard oldR == 1 else { return nil }
        return ((oldS % m) + m) % m
    }
}

// MARK: - Minimal DER

enum RSADER {
    /// OBJECT IDENTIFIER 1.2.840.113549.1.1.1 (rsaEncryption), with tag and length.
    static let rsaEncryptionOID: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]

    static func length(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] { [tag] + length(content.count) + content }

    /// DER INTEGER of a non-negative magnitude: minimal, with a leading 0x00 when the high bit is set.
    static func integer(_ magnitude: [UInt8]) -> [UInt8] {
        var m = Array(magnitude.drop(while: { $0 == 0 }))
        if m.isEmpty { m = [0] }
        if m[0] & 0x80 != 0 { m.insert(0, at: 0) }
        return tlv(0x02, m)
    }

    static func sequence(_ content: [UInt8]) -> [UInt8] { tlv(0x30, content) }

    /// BIT STRING with 0 unused bits.
    static func bitString(_ content: [UInt8]) -> [UInt8] { tlv(0x03, [0x00] + content) }
}

struct RSADERReader {
    let bytes: [UInt8]
    var offset = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { offset >= bytes.count }

    mutating func readTLV() throws -> (tag: UInt8, content: [UInt8]) {
        guard offset + 2 <= bytes.count else { throw RSAError.invalidDER("truncated TLV") }
        let tag = bytes[offset]
        var len = Int(bytes[offset + 1])
        offset += 2
        if len & 0x80 != 0 {
            let n = len & 0x7F
            guard n >= 1, n <= 4, offset + n <= bytes.count else { throw RSAError.invalidDER("bad length") }
            len = 0
            for _ in 0 ..< n {
                len = (len << 8) | Int(bytes[offset])
                offset += 1
            }
        }
        guard len >= 0, offset + len <= bytes.count else { throw RSAError.invalidDER("length overflow") }
        let content = Array(bytes[offset ..< offset + len])
        offset += len
        return (tag, content)
    }

    mutating func readElement(tag expected: UInt8) throws -> [UInt8] {
        let (tag, content) = try readTLV()
        guard tag == expected else { throw RSAError.invalidDER("expected tag \(expected), got \(tag)") }
        return content
    }

    mutating func readSequence() throws -> RSADERReader {
        RSADERReader(bytes: try readElement(tag: 0x30))
    }

    mutating func readInteger() throws -> RSABigUInt {
        let content = try readElement(tag: 0x02)
        guard let first = content.first else { throw RSAError.invalidDER("empty INTEGER") }
        guard first & 0x80 == 0 else { throw RSAError.invalidDER("negative INTEGER") }
        return RSABigUInt(bigEndian: content)
    }
}
