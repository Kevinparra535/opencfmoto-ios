// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) BikeScope.kt
//
// Per-bike settings namespace (session-network.md §8.3, app-features.md §2.1). A scoped key is
// `"<base>#<bikeId>"` with `bikeId = "b" + Integer.toHexString(raw.hashCode())` — Java
// `String.hashCode` over UTF-16 units, printed as unsigned lower-case hex without padding.
// Reads fall back to the global (unscoped) key, then to the default; writes go to the scoped key
// (or the global key when no bike is selected). See `SettingsStore`.

import Foundation

public enum BikeScope {
    /// Java `String.hashCode()` of `s` (signed 32-bit, UTF-16 units, wrap-around).
    public static func javaHashCode(_ s: String) -> Int32 {
        AppJvmText.javaHashCode(s)
    }

    /// Android bike id for a raw QR string: `"b" + Integer.toHexString(raw.hashCode())`.
    /// Vectors: `""` → `b0`, `"a"` → `b61`, the doc-01 CFDL16 QR → `b58cde373`.
    public static func id(forRaw raw: String) -> String {
        "b" + String(UInt32(bitPattern: javaHashCode(raw)), radix: 16)
    }

    /// `"<base>#<bikeId>"`, or `base` itself when `bikeId` is nil (no bike selected).
    public static func scopedKey(_ base: String, bikeId: String?) -> String {
        guard let bikeId, !bikeId.isEmpty else { return base }
        return base + "#" + bikeId
    }

    /// True when `key` is a value scoped to `bikeId` (ends with `#<bikeId>`).
    public static func isKey(_ key: String, scopedTo bikeId: String) -> Bool {
        key.hasSuffix("#" + bikeId)
    }
}
