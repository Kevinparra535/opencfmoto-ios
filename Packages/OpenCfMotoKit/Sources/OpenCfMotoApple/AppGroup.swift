// SPDX-License-Identifier: AGPL-3.0-or-later
// App Group helpers shared by the app and the ReplayKit broadcast extension
// (docs/spec/ios-platform-facts.md (f): App Group container, shared UserDefaults suite, and an
// AF_UNIX socket file in the container — mind the 104-byte `sun_path` limit).
//
// The group identifier is read from the Info.plist key `OCMAppGroupIdentifier` (set to
// $(APP_GROUP_ID) by project.yml for both targets), so no identifier is hard-coded in code.

#if canImport(Foundation)
import Foundation

public enum AppGroup {
    /// Info.plist key holding the App Group identifier.
    public static let infoPlistKey = "OCMAppGroupIdentifier"
    /// Longest Unix-socket path we hand out (sockaddr_un.sun_path is 104 bytes incl. the NUL on
    /// Darwin; keep a margin).
    public static let maxSocketPathBytes = 100
    /// Default socket file name for the mirror relay (short on purpose).
    public static let defaultSocketName = "ocm.sock"

    /// The App Group identifier of `Bundle.main` (nil when missing / unexpanded / malformed).
    public static var identifier: String? { identifier(in: .main) }

    public static func identifier(in bundle: Bundle) -> String? {
        normalized(bundle.object(forInfoDictionaryKey: infoPlistKey) as? String)
    }

    /// Validates an identifier read from Info.plist: trimmed, starts with "group.", has something
    /// after the prefix and no unexpanded build variable ("$(").
    public static func normalized(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), s.hasPrefix("group."),
              s.count > "group.".count, !s.contains("$("), !s.contains(" ") else { return nil }
        return s
    }

    /// `directory/name` if its UTF-8 path fits `maxBytes` (Unix-socket `sun_path` limit), else nil.
    public static func socketPath(in directory: URL, named name: String = defaultSocketName,
                                  maxBytes: Int = maxSocketPathBytes) -> String? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        let path = directory.appendingPathComponent(name, isDirectory: false).path
        return path.utf8.count <= maxBytes ? path : nil
    }

    #if canImport(Darwin)
    /// The shared container (nil when the App Group entitlement is missing, e.g. a misconfigured
    /// free-team build).
    public static var containerURL: URL? {
        guard let id = identifier else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    /// True when the App Group is configured AND entitled.
    public static var isAvailable: Bool { containerURL != nil }

    /// Socket path in the App Group container (nil if unavailable or too long).
    public static func socketPath(named name: String = defaultSocketName) -> String? {
        guard let dir = containerURL else { return nil }
        return socketPath(in: dir, named: name)
    }
    #endif
}
#endif
