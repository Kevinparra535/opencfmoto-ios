// SPDX-License-Identifier: AGPL-3.0-or-later
// Which App Group the app and its screen-mirroring extension share: a pure rule, tested on Linux.
// OpenCfMotoApple/AppGroup.swift applies it with the real container lookup, for the shared settings
// suite (UserDefaultsKeyValueStore.appGroup) and the mirror relay socket (MirrorRelaySocket).
//
// project.yml declares the group in both bundles' Info.plist: `OCMAppGroupIdentifier` =
// group.<prefix>.opencfmoto. Xcode, TestFlight and paid-account builds are signed with exactly that
// group. AltStore and SideStore re-sign a sideloaded IPA with the rider's own Apple ID: App Group
// ids are unique across teams, so they register the group again as `<declared>.<team id>`, sign
// both bundles with that one and list it under `ALTAppGroups` in each bundle's Info.plist
// (OCMAppGroupIdentifier keeps the declared id). The declared group then has no container, and
// without this rule mirror mode would be off in a sideloaded build.
//
// Rule: the declared group when it is entitled; else the first entitled `ALTAppGroups` entry that
// extends it (`<declared>.<suffix>`); else the first other entitled entry; else none. "Entitled"
// is the platform's answer (iOS: containerURL(forSecurityApplicationGroupIdentifier:) is not nil).
// The app and the extension carry the same entries, so both resolve the same group.

import Foundation

public enum AppGroupResolution {
    /// Info.plist key of the declared group (project.yml: `$(APP_GROUP_ID)`), app and extension.
    public static let declaredInfoKey = "OCMAppGroupIdentifier"
    /// Info.plist key AltStore and SideStore write when they re-sign an app: the App Groups of the
    /// new signature (an array of strings), in the app and in each extension.
    public static let altStoreInfoKey = "ALTAppGroups"

    /// Where the resolved group comes from.
    public enum Source: String, Equatable, Sendable {
        /// The group project.yml declares (Xcode, TestFlight, a paid account).
        case declared
        /// A group AltStore or SideStore registered when they re-signed the app.
        case resigned
    }

    /// One App Group id and where it comes from.
    public struct Choice: Equatable, Sendable {
        public let identifier: String
        public let source: Source

        public init(identifier: String, source: Source) {
            self.identifier = identifier
            self.source = source
        }
    }

    /// A usable group id: trimmed, "group." plus something, no unexpanded build variable ("$("),
    /// no spaces; nil otherwise.
    public static func normalized(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), s.hasPrefix("group."),
              s.count > "group.".count, !s.contains("$("), !s.contains(" ") else { return nil }
        return s
    }

    /// `ALTAppGroups` as Info.plist holds it: an array of strings (a lone string is accepted, any
    /// other value or element is ignored).
    public static func altStoreGroups(from value: Any?) -> [String] {
        if let one = value as? String { return [one] }
        if let list = value as? [Any] { return list.compactMap { $0 as? String } }
        return []
    }

    /// The groups to try, best first: the declared one; then the `ALTAppGroups` entries that extend
    /// it (`<declared>.<suffix>`), in their order; then the other entries. Invalid ids and repeats
    /// are dropped.
    public static func candidates(declared: String?, altStoreGroups: [String]) -> [Choice] {
        var seen = Set<String>()
        var result: [Choice] = []
        let declaredID = normalized(declared)
        if let declaredID {
            seen.insert(declaredID)
            result.append(Choice(identifier: declaredID, source: .declared))
        }
        let resigned = altStoreGroups.compactMap(normalized)
        let extending = declaredID.map { id in resigned.filter { $0.hasPrefix(id + ".") } } ?? []
        let others = resigned.filter { !extending.contains($0) }
        for id in extending + others where seen.insert(id).inserted {
            result.append(Choice(identifier: id, source: .resigned))
        }
        return result
    }

    /// The first candidate (see `candidates`) that `isEntitled` accepts; candidates after it are
    /// not asked. nil when none is entitled.
    public static func resolve(declared: String?, altStoreGroups: [String],
                               isEntitled: (String) -> Bool) -> Choice? {
        candidates(declared: declared, altStoreGroups: altStoreGroups).first { isEntitled($0.identifier) }
    }

    /// `resolve` with both keys read through `infoValue` (a bundle's Info.plist lookup).
    public static func resolve(infoValue: (String) -> Any?, isEntitled: (String) -> Bool) -> Choice? {
        resolve(declared: infoValue(declaredInfoKey) as? String,
                altStoreGroups: altStoreGroups(from: infoValue(altStoreInfoKey)), isEntitled: isEntitled)
    }

    /// The one log line worth writing about a resolution (none when the declared group is in use).
    /// Never names a group: a re-signed id carries the rider's team id, and riders share their logs.
    public static func logLine(for choice: Choice?, declared: String?) -> (level: LogLevel, message: String)? {
        switch choice?.source {
        case .declared?:
            return nil
        case .resigned?:
            return (.info, "App Group: using the group AltStore / SideStore made when they re-signed this app")
        case nil:
            if normalized(declared) == nil {
                return (.warn, "App Group: none declared in Info.plist (OCMAppGroupIdentifier): "
                    + "screen mirroring and the shared settings suite are unavailable")
            }
            return (.warn, "App Group: this build is not entitled to its App Group (signed without it): "
                + "screen mirroring and the shared settings suite are unavailable")
        }
    }
}
