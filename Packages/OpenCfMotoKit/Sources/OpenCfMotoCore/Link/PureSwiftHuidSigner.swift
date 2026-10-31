// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) RsaKeys.kt
//
// `HuidSigner` implemented in pure Swift (Linux-testable fallback for the Security-framework
// `SecKeyHuidSigner`). Android generates one 1024-bit key per process and never persists it.

import Foundation

/// Pure-Swift RSA identity for the CLIENT_INFO reply (`pubkey` + `encryptedHUID`).
public struct PureSwiftHuidSigner: HuidSigner {
    /// The key in use.
    public let key: RSAKeyMaterial
    /// base64 (standard alphabet, padded, no line breaks) of the X.509 SubjectPublicKeyInfo DER.
    public let publicKeyBase64: String

    public init(key: RSAKeyMaterial) {
        self.key = key
        self.publicKeyBase64 = key.subjectPublicKeyInfoDER.base64EncodedString()
    }

    /// Key from big-endian modulus / exponents.
    public init(modulus: Data, publicExponent: Data, privateExponent: Data) throws {
        self.init(key: try RSAKeyMaterial(modulus: modulus, publicExponent: publicExponent, privateExponent: privateExponent))
    }

    /// Key from a PKCS#1 `RSAPrivateKey` DER (e.g. the control-plane.md §9.5 fixture).
    public init(pkcs1PrivateKeyDER: Data) throws {
        self.init(key: try RSAKeyMaterial(pkcs1PrivateKeyDER: pkcs1PrivateKeyDER))
    }

    /// A freshly generated RSA-1024 key (e = 65537). Takes a moment — call off the main thread.
    public static func generate(bits: Int = 1024) -> PureSwiftHuidSigner {
        PureSwiftHuidSigner(key: RSAKeyMaterial.generate(bits: bits))
    }

    /// base64 of `RSA/ECB/PKCS1Padding` private-key "encryption" of the UTF-8 HUID
    /// (PKCS#1 v1.5 type-1 padding, then m^d mod n). Throws for HUIDs longer than 117 bytes.
    public func encryptedHUID(_ huid: String) throws -> String {
        Data(try key.signPKCS1v15Raw(Array(huid.utf8))).base64EncodedString()
    }
}

/// Name used by docs/ARCHITECTURE.md for the pure-Swift signer.
public typealias PureSwiftRSASigner = PureSwiftHuidSigner
