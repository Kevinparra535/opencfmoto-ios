// SPDX-License-Identifier: AGPL-3.0-or-later
// Minimal arbitrary-precision unsigned integer for the pure-Swift RSA identity
// (docs/spec/control-plane.md §9, §18.8). Little-endian 32-bit limbs; schoolbook multiplication,
// Knuth algorithm D division (Hacker's Delight `divmnu`), fixed-window modular exponentiation.
// Only what RSA-1024 key generation and PKCS#1 v1.5 signing need — not a general bignum library.

import Foundation

struct RSABigUInt: Equatable, Comparable, Sendable, CustomStringConvertible {
    /// Little-endian limbs, normalized (no most-significant zero limbs; zero is `[]`).
    private(set) var limbs: [UInt32]

    init() { limbs = [] }

    init(_ value: UInt64) {
        limbs = [UInt32(truncatingIfNeeded: value), UInt32(truncatingIfNeeded: value >> 32)]
        normalize()
    }

    init(limbs: [UInt32]) {
        self.limbs = limbs
        normalize()
    }

    /// Big-endian magnitude bytes (leading zeros allowed).
    init<C: Collection>(bigEndian bytes: C) where C.Element == UInt8 {
        let b = Array(bytes)
        var out = [UInt32](repeating: 0, count: (b.count + 3) / 4)
        for (i, byte) in b.reversed().enumerated() {
            out[i / 4] |= UInt32(byte) << (8 * UInt32(i % 4))
        }
        limbs = out
        normalize()
    }

    /// Hex magnitude (whitespace ignored); nil on a bad digit.
    init?(hex: String) {
        let clean = hex.filter { !$0.isWhitespace }
        guard !clean.isEmpty else { self.init(); return }
        var bytes: [UInt8] = []
        var chars = Array(clean)
        if chars.count % 2 == 1 { chars.insert("0", at: 0) }
        var i = 0
        while i < chars.count {
            guard let v = UInt8(String(chars[i ... i + 1]), radix: 16) else { return nil }
            bytes.append(v)
            i += 2
        }
        self.init(bigEndian: bytes)
    }

    private mutating func normalize() {
        while let last = limbs.last, last == 0 { limbs.removeLast() }
    }

    static let zero = RSABigUInt()
    static let one = RSABigUInt(1)

    var isZero: Bool { limbs.isEmpty }
    var isOdd: Bool { (limbs.first ?? 0) & 1 == 1 }
    var isEven: Bool { !isOdd }

    /// Number of significant bits (0 for zero).
    var bitWidth: Int {
        guard let top = limbs.last else { return 0 }
        return (limbs.count - 1) * 32 + (32 - top.leadingZeroBitCount)
    }

    func bit(_ i: Int) -> Bool {
        let li = i / 32
        guard li < limbs.count else { return false }
        return (limbs[li] >> UInt32(i % 32)) & 1 == 1
    }

    /// Minimal big-endian bytes (`[]` for zero).
    var bigEndianBytes: [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(limbs.count * 4)
        for limb in limbs.reversed() {
            out.append(UInt8(truncatingIfNeeded: limb >> 24))
            out.append(UInt8(truncatingIfNeeded: limb >> 16))
            out.append(UInt8(truncatingIfNeeded: limb >> 8))
            out.append(UInt8(truncatingIfNeeded: limb))
        }
        if let firstNonZero = out.firstIndex(where: { $0 != 0 }) {
            return Array(out[firstNonZero...])
        }
        return []
    }

    /// Big-endian bytes left-padded to `length`; nil if the value does not fit.
    func bigEndianBytes(length: Int) -> [UInt8]? {
        let b = bigEndianBytes
        guard b.count <= length else { return nil }
        return [UInt8](repeating: 0, count: length - b.count) + b
    }

    var hexString: String {
        let b = bigEndianBytes
        return b.isEmpty ? "0" : b.map { String(format: "%02x", $0) }.joined()
    }

    var description: String { "0x" + hexString }

    // MARK: Comparison

    static func compare(_ a: [UInt32], _ b: [UInt32]) -> Int {
        if a.count != b.count { return a.count < b.count ? -1 : 1 }
        var i = a.count - 1
        while i >= 0 {
            if a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
            i -= 1
        }
        return 0
    }

    static func < (a: RSABigUInt, b: RSABigUInt) -> Bool { compare(a.limbs, b.limbs) < 0 }

    // MARK: Arithmetic

    static func + (a: RSABigUInt, b: RSABigUInt) -> RSABigUInt {
        let (long, short) = a.limbs.count >= b.limbs.count ? (a.limbs, b.limbs) : (b.limbs, a.limbs)
        var out = [UInt32](repeating: 0, count: long.count + 1)
        var carry: UInt64 = 0
        for i in 0 ..< long.count {
            let s = UInt64(long[i]) + (i < short.count ? UInt64(short[i]) : 0) + carry
            out[i] = UInt32(truncatingIfNeeded: s)
            carry = s >> 32
        }
        out[long.count] = UInt32(carry)
        return RSABigUInt(limbs: out)
    }

    /// `a - b`; requires `a >= b`.
    static func - (a: RSABigUInt, b: RSABigUInt) -> RSABigUInt {
        precondition(!(a < b), "RSABigUInt subtraction underflow")
        var out = a.limbs
        var borrow: Int64 = 0
        for i in 0 ..< out.count {
            let t = Int64(out[i]) - (i < b.limbs.count ? Int64(b.limbs[i]) : 0) - borrow
            out[i] = UInt32(truncatingIfNeeded: t)
            borrow = t < 0 ? 1 : 0
        }
        return RSABigUInt(limbs: out)
    }

    static func * (a: RSABigUInt, b: RSABigUInt) -> RSABigUInt {
        if a.isZero || b.isZero { return .zero }
        return RSABigUInt(limbs: multiply(a.limbs, b.limbs))
    }

    static func multiply(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: a.count + b.count)
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                out.withUnsafeMutableBufferPointer { op in
                    for i in 0 ..< ap.count {
                        let ai = UInt64(ap[i])
                        if ai == 0 { continue }
                        var carry: UInt64 = 0
                        for j in 0 ..< bp.count {
                            let t = ai &* UInt64(bp[j]) &+ UInt64(op[i + j]) &+ carry
                            op[i + j] = UInt32(truncatingIfNeeded: t)
                            carry = t >> 32
                        }
                        op[i + bp.count] = UInt32(truncatingIfNeeded: carry)
                    }
                }
            }
        }
        return out
    }

    /// Quotient and remainder; `divisor` must be non-zero.
    func quotientAndRemainder(dividingBy divisor: RSABigUInt) -> (quotient: RSABigUInt, remainder: RSABigUInt) {
        let (q, r) = RSABigUInt.divMod(limbs, divisor.limbs)
        return (RSABigUInt(limbs: q), RSABigUInt(limbs: r))
    }

    static func % (a: RSABigUInt, m: RSABigUInt) -> RSABigUInt {
        RSABigUInt(limbs: divMod(a.limbs, m.limbs).remainder)
    }

    static func / (a: RSABigUInt, m: RSABigUInt) -> RSABigUInt {
        RSABigUInt(limbs: divMod(a.limbs, m.limbs).quotient)
    }

    /// Remainder modulo a small divisor.
    func remainder(dividingBy d: UInt32) -> UInt32 {
        precondition(d != 0)
        var r: UInt64 = 0
        for limb in limbs.reversed() {
            r = ((r << 32) | UInt64(limb)) % UInt64(d)
        }
        return UInt32(r)
    }

    /// Knuth algorithm D (Hacker's Delight `divmnu`), 32-bit limbs.
    static func divMod(_ uIn: [UInt32], _ vIn: [UInt32]) -> (quotient: [UInt32], remainder: [UInt32]) {
        var u = uIn, v = vIn
        while let l = u.last, l == 0 { u.removeLast() }
        while let l = v.last, l == 0 { v.removeLast() }
        precondition(!v.isEmpty, "RSABigUInt division by zero")
        if compare(u, v) < 0 { return ([], u) }
        let n = v.count
        if n == 1 {
            let d = UInt64(v[0])
            var q = [UInt32](repeating: 0, count: u.count)
            var r: UInt64 = 0
            var i = u.count - 1
            while i >= 0 {
                let cur = (r << 32) | UInt64(u[i])
                q[i] = UInt32(cur / d)
                r = cur % d
                i -= 1
            }
            return (q, r == 0 ? [] : [UInt32(r)])
        }
        let m = u.count - n
        let s = UInt32(v[n - 1].leadingZeroBitCount)
        // Normalize.
        var vn = [UInt32](repeating: 0, count: n)
        for i in stride(from: n - 1, to: 0, by: -1) {
            vn[i] = s == 0 ? v[i] : (v[i] << s) | (v[i - 1] >> (32 - s))
        }
        vn[0] = v[0] << s
        var un = [UInt32](repeating: 0, count: m + n + 1)
        un[m + n] = s == 0 ? 0 : u[m + n - 1] >> (32 - s)
        for i in stride(from: m + n - 1, to: 0, by: -1) {
            un[i] = s == 0 ? u[i] : (u[i] << s) | (u[i - 1] >> (32 - s))
        }
        un[0] = u[0] << s
        var q = [UInt32](repeating: 0, count: m + 1)
        let b: UInt64 = 1 << 32
        vn.withUnsafeBufferPointer { vp in
            un.withUnsafeMutableBufferPointer { up in
                var j = m
                while j >= 0 {
                    let num = (UInt64(up[j + n]) << 32) | UInt64(up[j + n - 1])
                    var qhat = num / UInt64(vp[n - 1])
                    var rhat = num % UInt64(vp[n - 1])
                    while qhat >= b || qhat &* UInt64(vp[n - 2]) > ((rhat << 32) | UInt64(up[j + n - 2])) {
                        qhat -= 1
                        rhat += UInt64(vp[n - 1])
                        if rhat >= b { break }
                    }
                    // Multiply and subtract.
                    var k: Int64 = 0
                    var t: Int64 = 0
                    for i in 0 ..< n {
                        let p = qhat &* UInt64(vp[i])
                        t = Int64(up[i + j]) - k - Int64(p & 0xFFFF_FFFF)
                        up[i + j] = UInt32(truncatingIfNeeded: t)
                        k = Int64(p >> 32) - (t >> 32)
                    }
                    t = Int64(up[j + n]) - k
                    up[j + n] = UInt32(truncatingIfNeeded: t)
                    if t < 0 {
                        // Add back.
                        q[j] = UInt32(truncatingIfNeeded: qhat) &- 1
                        var c: UInt64 = 0
                        for i in 0 ..< n {
                            let sum = UInt64(up[i + j]) + UInt64(vp[i]) + c
                            up[i + j] = UInt32(truncatingIfNeeded: sum)
                            c = sum >> 32
                        }
                        up[j + n] = up[j + n] &+ UInt32(truncatingIfNeeded: c)
                    } else {
                        q[j] = UInt32(truncatingIfNeeded: qhat)
                    }
                    j -= 1
                }
            }
        }
        // Unnormalize the remainder.
        var r = [UInt32](repeating: 0, count: n)
        for i in 0 ..< n {
            r[i] = s == 0 ? un[i] : (un[i] >> s) | (un[i + 1] << (32 - s))
        }
        while let l = q.last, l == 0 { q.removeLast() }
        while let l = r.last, l == 0 { r.removeLast() }
        return (q, r)
    }

    func shiftedRight(by bits: Int) -> RSABigUInt {
        guard bits > 0 else { return self }
        let limbShift = bits / 32, bitShift = UInt32(bits % 32)
        guard limbShift < limbs.count else { return .zero }
        var out = [UInt32](repeating: 0, count: limbs.count - limbShift)
        for i in 0 ..< out.count {
            let lo = limbs[i + limbShift] >> bitShift
            let hi: UInt32 = (bitShift != 0 && i + limbShift + 1 < limbs.count) ? limbs[i + limbShift + 1] << (32 - bitShift) : 0
            out[i] = lo | hi
        }
        return RSABigUInt(limbs: out)
    }

    /// Count of trailing zero bits (0 for zero).
    var trailingZeroBitCount: Int {
        for (i, limb) in limbs.enumerated() where limb != 0 {
            return i * 32 + limb.trailingZeroBitCount
        }
        return 0
    }

    // MARK: Modular exponentiation

    /// `self^exponent mod modulus` (4-bit fixed window; Montgomery multiplication for odd moduli,
    /// which covers RSA and Miller-Rabin; division-based reduction otherwise).
    func power(_ exponent: RSABigUInt, modulus: RSABigUInt) -> RSABigUInt {
        precondition(!modulus.isZero)
        if modulus == .one { return .zero }
        if modulus.isOdd, modulus.limbs.count >= 2 {
            return RSAMontgomery(modulus: modulus).power(self, exponent)
        }
        let m = modulus.limbs
        func mulMod(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
            RSABigUInt.divMod(RSABigUInt.multiply(a, b), m).remainder
        }
        let base = RSABigUInt.divMod(limbs, m).remainder
        if exponent.isZero { return .one }
        if base.isEmpty { return .zero }
        var table = [[UInt32]](repeating: [1], count: 16)
        table[1] = base
        for i in 2 ..< 16 { table[i] = mulMod(table[i - 1], base) }
        var result: [UInt32] = [1]
        let nbits = exponent.bitWidth
        var started = false
        var i = ((nbits + 3) / 4) * 4 - 4
        while i >= 0 {
            var window = 0
            for k in stride(from: 3, through: 0, by: -1) where exponent.bit(i + k) {
                window |= 1 << k
            }
            if started {
                for _ in 0 ..< 4 { result = mulMod(result, result) }
            }
            if window != 0 {
                result = started ? mulMod(result, table[window]) : table[window]
                started = true
            }
            i -= 4
        }
        return RSABigUInt(limbs: started ? result : [1])
    }

    // MARK: Randomness

    /// Uniform random value with exactly `bits` bits available (top bits not forced).
    static func random<G: RandomNumberGenerator>(bits: Int, using rng: inout G) -> RSABigUInt {
        guard bits > 0 else { return .zero }
        var out = [UInt32](repeating: 0, count: (bits + 31) / 32)
        for i in 0 ..< out.count { out[i] = UInt32(truncatingIfNeeded: rng.next()) }
        let extra = out.count * 32 - bits
        if extra > 0 { out[out.count - 1] &= UInt32.max >> UInt32(extra) }
        return RSABigUInt(limbs: out)
    }

    /// Uniform random value in `[low, high)` (`high > low`).
    static func random<G: RandomNumberGenerator>(in low: RSABigUInt, _ high: RSABigUInt, using rng: inout G) -> RSABigUInt {
        let span = high - low
        let bits = span.bitWidth
        while true {
            let r = random(bits: bits, using: &rng)
            if r < span { return low + r }
        }
    }
}

/// Montgomery arithmetic modulo an odd `n` (CIOS, 32-bit limbs). `R = 2^(32·k)`, k = limb count.
struct RSAMontgomery {
    let n: [UInt32]
    let k: Int
    /// −n⁻¹ mod 2³².
    let n0inv: UInt32
    /// R² mod n.
    let r2: [UInt32]

    init(modulus: RSABigUInt) {
        precondition(modulus.isOdd)
        n = modulus.limbs
        k = n.count
        // Newton iteration for n[0]⁻¹ mod 2³² (5 steps double the correct bits 1 → 32+).
        var inv: UInt32 = 1
        for _ in 0 ..< 5 { inv = inv &* (2 &- n[0] &* inv) }
        n0inv = 0 &- inv
        var r2Limbs = [UInt32](repeating: 0, count: 2 * k + 1)
        r2Limbs[2 * k] = 1
        r2 = RSABigUInt.divMod(r2Limbs, n).remainder
    }

    /// a·b·R⁻¹ mod n for a, b < n (k limbs each, zero-padded).
    func multiply(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var t = [UInt32](repeating: 0, count: k + 2)
        let k = self.k
        let n0inv = UInt64(self.n0inv)
        n.withUnsafeBufferPointer { np in
            a.withUnsafeBufferPointer { ap in
                b.withUnsafeBufferPointer { bp in
                    t.withUnsafeMutableBufferPointer { tp in
                        for i in 0 ..< k {
                            let ai = UInt64(ap[i])
                            var c: UInt64 = 0
                            for j in 0 ..< k {
                                let s = UInt64(tp[j]) &+ ai &* UInt64(bp[j]) &+ c
                                tp[j] = UInt32(truncatingIfNeeded: s)
                                c = s >> 32
                            }
                            var s = UInt64(tp[k]) &+ c
                            tp[k] = UInt32(truncatingIfNeeded: s)
                            tp[k + 1] = UInt32(truncatingIfNeeded: s >> 32)
                            let m = (UInt64(tp[0]) &* n0inv) & 0xFFFF_FFFF
                            s = UInt64(tp[0]) &+ m &* UInt64(np[0])
                            c = s >> 32
                            for j in 1 ..< k {
                                s = UInt64(tp[j]) &+ m &* UInt64(np[j]) &+ c
                                tp[j - 1] = UInt32(truncatingIfNeeded: s)
                                c = s >> 32
                            }
                            s = UInt64(tp[k]) &+ c
                            tp[k - 1] = UInt32(truncatingIfNeeded: s)
                            tp[k] = tp[k + 1] &+ UInt32(truncatingIfNeeded: s >> 32)
                        }
                    }
                }
            }
        }
        // t < 2n: one conditional subtraction.
        var result = Array(t[0 ... k])
        if t[k] != 0 || !lessThanModulus(t) {
            var borrow: Int64 = 0
            for j in 0 ..< k {
                let d = Int64(result[j]) - Int64(n[j]) - borrow
                result[j] = UInt32(truncatingIfNeeded: d)
                borrow = d < 0 ? 1 : 0
            }
            result[k] = UInt32(truncatingIfNeeded: Int64(result[k]) - borrow)
        }
        return Array(result[0 ..< k])
    }

    /// x[0..<k] < n, both read as k-limb numbers.
    private func lessThanModulus(_ x: [UInt32]) -> Bool {
        var j = k - 1
        while j >= 0 {
            if x[j] != n[j] { return x[j] < n[j] }
            j -= 1
        }
        return false
    }

    private func padded(_ x: [UInt32]) -> [UInt32] {
        x.count >= k ? Array(x[0 ..< k]) : x + [UInt32](repeating: 0, count: k - x.count)
    }

    /// base^exponent mod n (4-bit fixed window).
    func power(_ base: RSABigUInt, _ exponent: RSABigUInt) -> RSABigUInt {
        if exponent.isZero { return .one }
        let reduced = RSABigUInt.divMod(base.limbs, n).remainder
        if reduced.isEmpty { return .zero }
        let baseM = multiply(padded(reduced), padded(r2)) // base·R mod n
        let oneM = multiply(padded([1]), padded(r2)) // R mod n
        var table = [[UInt32]](repeating: oneM, count: 16)
        table[1] = baseM
        for i in 2 ..< 16 { table[i] = multiply(table[i - 1], baseM) }
        var result = oneM
        var started = false
        let nbits = exponent.bitWidth
        var i = ((nbits + 3) / 4) * 4 - 4
        while i >= 0 {
            var window = 0
            for b in stride(from: 3, through: 0, by: -1) where exponent.bit(i + b) {
                window |= 1 << b
            }
            if started {
                for _ in 0 ..< 4 { result = multiply(result, result) }
            }
            if window != 0 {
                result = started ? multiply(result, table[window]) : table[window]
                started = true
            }
            i -= 4
        }
        let out = multiply(result, padded([1])) // leave Montgomery form
        return RSABigUInt(limbs: out)
    }
}
