// SPDX-License-Identifier: AGPL-3.0-or-later
// App Group helpers shared by the app and the ReplayKit broadcast extension
// (docs/spec/ios-platform-facts.md (f): App Group container, shared UserDefaults suite, and an
// AF_UNIX socket file in the container — mind the 104-byte `sun_path` limit).
//
// The group is read from Info.plist, never hard-coded: `OCMAppGroupIdentifier` (set to
// $(APP_GROUP_ID) by project.yml for both targets) or, in a build AltStore / SideStore re-signed,
// the entitled entry of `ALTAppGroups` (OpenCfMotoCore/Util/AppGroupResolution.swift has the rule).

#if canImport(Foundation)
import Foundation
import OpenCfMotoCore

public enum AppGroup {
    /// Info.plist key holding the declared App Group identifier.
    public static let infoPlistKey = AppGroupResolution.declaredInfoKey
    /// Info.plist key AltStore / SideStore write with the groups of their re-signed build.
    public static let altStoreInfoKey = AppGroupResolution.altStoreInfoKey
    /// Longest Unix-socket path we hand out (sockaddr_un.sun_path is 104 bytes incl. the NUL on
    /// Darwin; keep a margin).
    public static let maxSocketPathBytes = 100
    /// Default socket file name for the mirror relay (short on purpose).
    public static let defaultSocketName = "ocm.sock"

    /// The App Group identifier `Bundle.main` declares (nil when missing / unexpanded / malformed).
    /// The group in use can differ: see `entitledIdentifier`.
    public static var identifier: String? { identifier(in: .main) }

    public static func identifier(in bundle: Bundle) -> String? {
        normalized(bundle.object(forInfoDictionaryKey: infoPlistKey) as? String)
    }

    /// The `ALTAppGroups` entries of `bundle` (empty unless AltStore / SideStore re-signed it).
    public static func altStoreGroups(in bundle: Bundle) -> [String] {
        AppGroupResolution.altStoreGroups(from: bundle.object(forInfoDictionaryKey: altStoreInfoKey))
    }

    /// Validates an identifier read from Info.plist: trimmed, starts with "group.", has something
    /// after the prefix and no unexpanded build variable ("$(").
    public static func normalized(_ raw: String?) -> String? {
        AppGroupResolution.normalized(raw)
    }

    /// `directory/name` if its UTF-8 path fits `maxBytes` (Unix-socket `sun_path` limit), else nil.
    public static func socketPath(in directory: URL, named name: String = defaultSocketName,
                                  maxBytes: Int = maxSocketPathBytes) -> String? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        let path = directory.appendingPathComponent(name, isDirectory: false).path
        return path.utf8.count <= maxBytes ? path : nil
    }

    #if canImport(Darwin)
    /// The App Group the process of `bundle` is entitled to (the declared one, else the one
    /// AltStore / SideStore re-signed it with), checked with the system's container lookup; nil
    /// when none is.
    public static func resolve(in bundle: Bundle, fileManager: FileManager = .default) -> AppGroupResolution.Choice? {
        AppGroupResolution.resolve(infoValue: { bundle.object(forInfoDictionaryKey: $0) }, isEntitled: {
            fileManager.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil
        })
    }

    /// `Bundle.main`'s group, resolved once per process (Info.plist and entitlements do not change
    /// while it runs), with one log line when it is not the declared group.
    public static let entitled: AppGroupResolution.Choice? = {
        let choice = resolve(in: .main)
        if let line = AppGroupResolution.logLine(for: choice, declared: identifier) {
            Log.shared.log(line.level, "APPGROUP", line.message)
        }
        return choice
    }()

    /// The App Group identifier in use (declared or re-signed); nil when none is entitled.
    public static var entitledIdentifier: String? { entitled?.identifier }

    /// `entitledIdentifier` for any bundle (`Bundle.main` gets the cached answer).
    public static func entitledIdentifier(in bundle: Bundle) -> String? {
        bundle == Bundle.main ? entitledIdentifier : resolve(in: bundle)?.identifier
    }

    /// The shared container (nil when no App Group is entitled: e.g. a misconfigured free-team
    /// build, or a sideloading tool that dropped the group).
    public static var containerURL: URL? {
        guard let id = entitledIdentifier else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    /// True when an App Group is configured AND entitled.
    public static var isAvailable: Bool { containerURL != nil }

    /// Socket path in the App Group container (nil if unavailable or too long).
    public static func socketPath(named name: String = defaultSocketName) -> String? {
        guard let dir = containerURL else { return nil }
        return socketPath(in: dir, named: name)
    }
    #endif
}
#endif
