// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) BikeWifi.kt (join / reuseOrJoin / releaseSession) — re-designed
// for NEHotspotConfiguration per docs/spec/ios-platform-facts.md (a) and session-network.md §3, §11.1.
//
// Joins the bike's WPA2 access point programmatically (full flavor), then CONFIRMS the association:
// iOS's apply() completion only means "configuration applied" — not "joined", and not "TCP/IP ready".
//
// - joinOnce defaults to FALSE: a joinOnce network is dropped after ~15 s in the background or on
//   device sleep, which kills a pocketed ride (ios-platform-facts.md (a), decision 6).
// - `.alreadyAssociated` is success; `.internal` (and `.unknown` / `.pending`) are retried once
//   (after `removeConfiguration` for `.internal`, as DTS suggests).
// - Free flavor (`OCM_NO_HOTSPOT`) or non-iOS builds compile a stub that always answers
//   `.manualJoinRequired` (the rider joins in Settings; the app detects it with `WiFiInfo`).
//   NOTE: Swift package targets do not inherit the app target's SWIFT_ACTIVE_COMPILATION_CONDITIONS,
//   so the app must ALSO pass `WifiJoinOptions(hotspotEnabled: false)` in its free flavor.
// - The dash's network has no internet: iOS may keep its Wi-Fi path unsatisfied after the join. The
//   confirmation therefore looks at the Wi-Fi interface's address (`WiFiSnapshot.isUp`), not the path.

#if canImport(Foundation)
import Foundation
import OpenCfMotoCore

// MARK: - Outcome / errors

/// Result of `WifiJoiner.join`.
public enum WifiJoinOutcome: Sendable, Equatable {
    /// Configuration applied and the association confirmed (Wi-Fi up with a usable IPv4 on the bike
    /// network, its path satisfied or not; SSID matched when iOS reveals it).
    case joined(WiFiSnapshot)
    /// The phone was already on the bike network: nothing was applied (no system prompt).
    case alreadyJoined(WiFiSnapshot)
    /// Programmatic join is unavailable (free flavor / not iOS): ask the rider to join the network
    /// in Settings › Wi-Fi (offer to copy the password), then wait for it with `WiFiInfo`.
    case manualJoinRequired
}

/// Typed join failures with EN/ES user-facing messages (`message(language:)`).
public enum WifiJoinError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    /// SSID empty or longer than 32 bytes (or rejected by iOS).
    case invalidSSID
    /// WPA2 passphrase not 8–63 printable ASCII characters (or rejected by iOS).
    case invalidPassphrase
    /// The rider tapped Cancel on the join prompt (NEHotspot 7; 16 userUnauthorized is treated alike).
    case userDenied
    /// iOS refused (e.g. Screen Time / restrictions, NEHotspot 17).
    case systemDenied
    /// The SSID is managed by MDM / a carrier or configuration profile (NEHotspot 10).
    case managedByProfile
    /// Another configuration is being applied (NEHotspot 9) — retried once already.
    case busy
    /// apply() needs the app in the foreground (NEHotspot 14).
    case notInForeground
    /// Transient iOS failure (NEHotspot 8 internal / 11 unknown) that persisted after one retry.
    case internalFailure(code: Int)
    /// A configuration iOS cannot use for this network (NEHotspot 0, 3–6, 12, 15).
    case unsupportedConfiguration(code: Int)
    /// The configuration was applied but the phone never joined the bike network within the
    /// confirmation window (bike off / out of range / wrong password / dash not showing its QR).
    case notAssociated(ssid: String)
    /// Any other error.
    case failed(code: Int, domain: String)

    /// The UI should offer the manual "join in Settings › Wi-Fi" path.
    public var suggestsManualJoin: Bool {
        switch self {
        case .busy, .notInForeground: return false
        default: return true
        }
    }

    public var errorDescription: String? { message(language: WifiJoinMessages.preferredLanguage()) }

    public var description: String {
        switch self {
        case .invalidSSID: return "invalid SSID"
        case .invalidPassphrase: return "invalid WPA2 passphrase"
        case .userDenied: return "user denied the join prompt"
        case .systemDenied: return "system denied the join"
        case .managedByProfile: return "network managed by a profile"
        case .busy: return "another join is pending"
        case .notInForeground: return "app not in foreground"
        case let .internalFailure(code): return "internal NEHotspot error \(code)"
        case let .unsupportedConfiguration(code): return "unsupported configuration (NEHotspot \(code))"
        case let .notAssociated(ssid): return "not associated to \(ssid)"
        case let .failed(code, domain): return "\(domain) \(code)"
        }
    }

    /// User-facing text. `language`: an ISO code or locale identifier; "es…" → Spanish, else English.
    public func message(language: String) -> String {
        WifiJoinMessages.text(for: self, spanish: WifiJoinMessages.isSpanish(language))
    }
}

/// EN/ES strings for the Wi-Fi join flow (the core keeps small in-code tables, no bundle lookups).
public enum WifiJoinMessages {
    /// "es" or "en" from `Locale.preferredLanguages`.
    public static func preferredLanguage(_ preferred: [String] = Locale.preferredLanguages) -> String {
        isSpanish(preferred.first ?? "en") ? "es" : "en"
    }

    public static func isSpanish(_ language: String) -> Bool {
        language.lowercased().hasPrefix("es")
    }

    /// Instructions for the manual join path (free flavor, or after a failure).
    public static func manualJoin(ssid: String, language: String) -> String {
        if isSpanish(language) {
            return "Abre Ajustes › Wi-Fi y únete a “\(ssid)” (la contraseña está copiada). Luego vuelve a OpenCfMoto."
        }
        return "Open Settings › Wi-Fi and join “\(ssid)” (the password is copied). Then come back to OpenCfMoto."
    }

    static func text(for e: WifiJoinError, spanish es: Bool) -> String {
        switch e {
        case .invalidSSID:
            return es ? "El nombre de la red Wi-Fi (SSID) de la moto no es válido. Escríbelo manualmente."
                : "The bike's Wi-Fi name (SSID) is not valid. Enter it manually."
        case .invalidPassphrase:
            return es ? "La contraseña Wi-Fi de la moto debe tener entre 8 y 63 caracteres. Revisa el código QR o escríbela manualmente."
                : "The bike's Wi-Fi password must be 8–63 characters. Check the QR code or type it manually."
        case .userDenied:
            return es ? "No se aprobó la conexión al Wi-Fi de la moto. Toca Conectar y elige Unirse, o únete desde Ajustes › Wi-Fi."
                : "Joining the bike's Wi-Fi was not approved. Tap Connect and choose Join, or join it in Settings › Wi-Fi."
        case .systemDenied:
            return es ? "iOS no permitió unirse a esta red (restricciones). Únete al Wi-Fi de la moto desde Ajustes › Wi-Fi."
                : "iOS did not allow joining this network (restrictions). Join the bike's Wi-Fi in Settings › Wi-Fi."
        case .managedByProfile:
            return es ? "Esta red Wi-Fi está administrada por un perfil de configuración. Únete desde Ajustes › Wi-Fi."
                : "This Wi-Fi network is managed by a configuration profile. Join it in Settings › Wi-Fi."
        case .busy:
            return es ? "Hay otra conexión Wi-Fi en curso. Espera un momento e inténtalo de nuevo."
                : "Another Wi-Fi join is still in progress. Wait a moment and try again."
        case .notInForeground:
            return es ? "Abre OpenCfMoto para unirte al Wi-Fi de la moto: iOS solo lo permite con la app en pantalla."
                : "Open OpenCfMoto to join the bike's Wi-Fi: iOS only allows it while the app is on screen."
        case let .internalFailure(code):
            return es ? "iOS no pudo unirse al Wi-Fi de la moto (error interno \(code)). Muestra el QR de emparejamiento en el tablero e inténtalo de nuevo, o únete desde Ajustes › Wi-Fi."
                : "iOS could not join the bike's Wi-Fi (internal error \(code)). Show the pairing QR on the dash and try again, or join it in Settings › Wi-Fi."
        case let .unsupportedConfiguration(code):
            return es ? "iOS no puede usar esta configuración Wi-Fi (código \(code)). Únete al Wi-Fi de la moto desde Ajustes › Wi-Fi."
                : "iOS cannot use this Wi-Fi configuration (code \(code)). Join the bike's Wi-Fi in Settings › Wi-Fi."
        case let .notAssociated(ssid):
            return es ? "El teléfono no se unió a “\(ssid)”. Verifica que la moto esté encendida, cerca y mostrando su QR de emparejamiento, que el Wi-Fi esté activado y que la contraseña sea correcta."
                : "The phone did not join “\(ssid)”. Make sure the bike is on, nearby and showing its pairing QR, that Wi-Fi is on, and that the password is correct."
        case let .failed(code, _):
            return es ? "Falló la conexión al Wi-Fi de la moto (código \(code)). Únete desde Ajustes › Wi-Fi."
                : "Joining the bike's Wi-Fi failed (code \(code)). Join it in Settings › Wi-Fi."
        }
    }
}

// MARK: - Options / policy

/// `WifiJoiner` configuration.
public struct WifiJoinOptions: Sendable, Equatable {
    /// NEHotspotConfiguration.joinOnce. Default false (persistent: survives lock / background).
    public var joinOnce: Bool
    /// NEHotspotConfiguration.lifeTimeInDays (1…365); nil = never expires.
    public var lifeTimeInDays: Int?
    /// How long to wait for the association after apply() (session-network.md §11.1, 500 ms polls).
    public var confirmTimeout: TimeInterval
    public var pollInterval: TimeInterval
    /// Used to confirm the join when the SSID cannot be read (no Access-WiFi-Information entitlement).
    public var expectedSubnets: [WiFiSubnet]
    /// false in the free flavor (no Hotspot entitlement) → `.manualJoinRequired` without calling iOS.
    public var hotspotEnabled: Bool
    /// Pause before the single retry of a transient failure.
    public var retryDelay: TimeInterval

    public init(joinOnce: Bool = false, lifeTimeInDays: Int? = nil, confirmTimeout: TimeInterval = 15,
                pollInterval: TimeInterval = 0.5, expectedSubnets: [WiFiSubnet] = WiFiSubnet.knownDashSubnets,
                hotspotEnabled: Bool = true, retryDelay: TimeInterval = 1.0) {
        self.joinOnce = joinOnce
        self.lifeTimeInDays = lifeTimeInDays
        self.confirmTimeout = confirmTimeout
        self.pollInterval = pollInterval
        self.expectedSubnets = expectedSubnets
        self.hotspotEnabled = hotspotEnabled
        self.retryDelay = retryDelay
    }
}

/// What to do after one `apply()` attempt.
public enum WifiJoinDecision: Sendable, Equatable {
    case success
    case retry(removeConfigurationFirst: Bool)
    case fail(WifiJoinError)
}

/// Pure decision rules of the join flow (unit-tested on Linux).
public enum WifiJoinPolicy {
    /// NEHotspotConfigurationErrorDomain.
    public static let hotspotErrorDomain = "NEHotspotConfigurationErrorDomain"

    /// SSID: 1…32 bytes (UTF-8). Passphrase: WPA2-PSK, 8…63 printable ASCII characters.
    public static func validate(ssid: String, passphrase: String) throws {
        let n = ssid.utf8.count
        guard n >= 1, n <= 32 else { throw WifiJoinError.invalidSSID }
        guard isValidPassphrase(passphrase) else { throw WifiJoinError.invalidPassphrase }
    }

    public static func isValidPassphrase(_ p: String) -> Bool {
        let scalars = p.unicodeScalars
        guard (8 ... 63).contains(scalars.count) else { return false }
        return scalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7E }
    }

    /// Maps an `apply()` error to the next step. `attempt` is 1 for the first apply.
    /// Raw NEHotspotConfigurationError codes (verified names: 7 userDenied, 8 internal, 13 alreadyAssociated).
    public static func decision(domain: String, code: Int, attempt: Int) -> WifiJoinDecision {
        guard domain == hotspotErrorDomain else { return .fail(.failed(code: code, domain: domain)) }
        let first = attempt <= 1
        switch code {
        case 13: return .success                                           // alreadyAssociated
        case 8: return first ? .retry(removeConfigurationFirst: true) : .fail(.internalFailure(code: 8))   // internal
        case 11: return first ? .retry(removeConfigurationFirst: false) : .fail(.internalFailure(code: 11)) // unknown
        case 9: return first ? .retry(removeConfigurationFirst: false) : .fail(.busy)                       // pending
        case 7, 16: return .fail(.userDenied)                              // userDenied / userUnauthorized
        case 17: return .fail(.systemDenied)                               // systemDenied
        case 10: return .fail(.managedByProfile)                           // systemConfiguration
        case 14: return .fail(.notInForeground)                            // applicationIsNotInForeground
        case 1, 15: return .fail(.invalidSSID)                             // invalidSSID / invalidSSIDPrefix
        case 2: return .fail(.invalidPassphrase)                           // invalidWPAPassphrase
        case 0, 3, 4, 5, 6, 12: return .fail(.unsupportedConfiguration(code: code))
        default: return .fail(.failed(code: code, domain: domain))
        }
    }

    /// Association confirmed? Requires Wi-Fi up with a usable IPv4 on the Wi-Fi interface (169.254/16
    /// ignored); the path may stay unsatisfied on the dash's network (no internet). When iOS reveals
    /// the SSID it must equal `targetSSID`. Otherwise the address must be new since `baseline` (the
    /// network before apply(); nil = no such check, e.g. iOS answered alreadyAssociated) — the rule of
    /// a manual join (`ConnectionModel.matchesManualJoin`) — and the phone address or a gateway must be
    /// in `expectedSubnets` (empty list = any usable address is accepted).
    public static func isConfirmed(_ snapshot: WiFiSnapshot, currentSSID: String?, targetSSID: String,
                                   expectedSubnets: [WiFiSubnet], baseline: WiFiSnapshot? = nil) -> Bool {
        guard snapshot.isUp, snapshot.usablePhoneIPv4 != nil else { return false }
        if let s = currentSSID { return s == targetSSID }
        if let baseline, !snapshot.hasNewAddress(since: baseline) { return false }
        if expectedSubnets.isEmpty { return true }
        return snapshot.isOn(expectedSubnets)
    }
}
#endif

// MARK: - iOS implementation (full flavor)

#if os(iOS) && canImport(NetworkExtension) && canImport(Network) && !OCM_NO_HOTSPOT
import NetworkExtension

/// Joins / forgets the bike Wi-Fi with NEHotspotConfiguration (full flavor; needs the Hotspot
/// Configuration entitlement and the Access WiFi Information entitlement for SSID checks).
///
/// Call `join` only while the app is in the foreground (iOS returns `.notInForeground` otherwise).
/// On Stop, call `forget(ssid:)` unless the rider chose to stay on the bike Wi-Fi (Android
/// "leave" vs "park", session-network.md §3.10); ignition-cycle re-joins rely on iOS auto-joining
/// the saved (joinOnce = false) configuration, detected with `WiFiInfo`.
/// Thread-safety: stateless apart from its immutable options.
public final class WifiJoiner: @unchecked Sendable {
    public let options: WifiJoinOptions

    public init(options: WifiJoinOptions = WifiJoinOptions()) {
        self.options = options
    }

    /// Joins `ssid` (WPA2 `passphrase`) and waits until the association is confirmed.
    /// Throws `WifiJoinError`.
    public func join(ssid: String, passphrase: String) async throws -> WifiJoinOutcome {
        try WifiJoinPolicy.validate(ssid: ssid, passphrase: passphrase)
        guard options.hotspotEnabled else {
            Log.i("WIFI", "[wifi] programmatic join disabled (free flavor) — manual join required")
            return .manualJoinRequired
        }

        // Already on the bike network? Then don't apply (every new/updated configuration prompts).
        // Up includes a local-only Wi-Fi: the dash's network has no internet, so iOS may keep its path
        // unsatisfied while the phone holds an address there.
        let info = WiFiInfo()
        defer { info.stop() }
        var before = await info.firstSnapshot(timeout: 1.0)
        if before.isUp { before.ssid = await WiFiInfo.fetchSSID() }
        if before.ssid == ssid, before.usablePhoneIPv4 != nil {
            Log.i("WIFI", "Wi-Fi already joined: \(ssid) — skipping re-join (\(before))")
            return .alreadyJoined(before)
        }

        let cfg = NEHotspotConfiguration(ssid: ssid, passphrase: passphrase, isWEP: false)
        cfg.joinOnce = options.joinOnce
        if let days = options.lifeTimeInDays { cfg.lifeTimeInDays = NSNumber(value: max(1, min(365, days))) }

        var attempt = 1
        var alreadyAssociated = false
        applyLoop: while true {
            Log.i("WIFI", "[wifi] applying hotspot configuration for \(ssid) (attempt \(attempt), joinOnce=\(options.joinOnce))")
            let error = await Self.apply(cfg)
            guard let error else { break applyLoop }
            let decision = WifiJoinPolicy.decision(domain: error.domain, code: error.code, attempt: attempt)
            Log.w("WIFI", "[wifi] apply error \(error.domain) \(error.code): \(error.localizedDescription) → \(decision)")
            switch decision {
            case .success:
                alreadyAssociated = true
                break applyLoop
            case let .retry(removeFirst):
                if removeFirst { NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid) }
                await sleepSeconds(options.retryDelay)
                attempt += 1
            case let .fail(e):
                throw e
            }
        }

        // "Applied" ≠ "joined": wait for a usable IPv4 on the Wi-Fi interface (its path may stay
        // unsatisfied: no internet) and the bike SSID — or, SSID hidden, a new address on a dash subnet.
        let baseline: WiFiSnapshot? = alreadyAssociated ? nil : before
        let deadline = Date().addingTimeInterval(options.confirmTimeout)
        var lastSeen = before
        var loggedOtherSSID: String?
        repeat {
            var s = info.refreshedSnapshot()
            if s.isUp { s.ssid = await WiFiInfo.fetchSSID() }
            lastSeen = s
            if WifiJoinPolicy.isConfirmed(s, currentSSID: s.ssid, targetSSID: ssid,
                                          expectedSubnets: options.expectedSubnets, baseline: baseline) {
                let how = s.ssid != nil ? "SSID matches"
                    : alreadyAssociated ? "iOS: already associated, SSID hidden" : "new address on a dash subnet, SSID hidden"
                Log.i("WIFI", "Wi-Fi joined: \(ssid) (\(s); \(how))")
                return .joined(s)
            }
            if let other = s.ssid, other != ssid, other != loggedOtherSSID {
                loggedOtherSSID = other
                Log.i("WIFI", "[wifi] still on \(other), waiting for \(ssid) (\(s))")
            }
            if Task.isCancelled { throw CancellationError() }
            await sleepSeconds(options.pollInterval)
        } while Date() < deadline
        Log.w("WIFI", "[wifi] \(ssid) not associated after \(options.confirmTimeout)s (last seen: \(lastSeen))")
        throw WifiJoinError.notAssociated(ssid: ssid)
    }

    /// "Forget bike Wi-Fi": removes the configuration this app created for `ssid` (iOS only lets an
    /// app remove its own configurations; iOS leaves the network if currently joined through it).
    public func forget(ssid: String) {
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        Log.i("WIFI", "Wi-Fi released: removed configuration for \(ssid)")
    }

    /// SSIDs configured by this app.
    public func configuredSSIDs() async -> [String] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            NEHotspotConfigurationManager.shared.getConfiguredSSIDs { ssids in
                cont.resume(returning: ssids)
            }
        }
    }

    private static func apply(_ cfg: NEHotspotConfiguration) async -> NSError? {
        await withCheckedContinuation { (cont: CheckedContinuation<NSError?, Never>) in
            NEHotspotConfigurationManager.shared.apply(cfg) { error in
                cont.resume(returning: error.map { $0 as NSError })
            }
        }
    }
}

#elseif canImport(Foundation)

/// Stub used when programmatic joins are unavailable (free flavor `OCM_NO_HOTSPOT`, or not iOS):
/// validates the credentials and always answers `.manualJoinRequired`.
public final class WifiJoiner: @unchecked Sendable {
    public let options: WifiJoinOptions

    public init(options: WifiJoinOptions = WifiJoinOptions()) {
        self.options = options
    }

    public func join(ssid: String, passphrase: String) async throws -> WifiJoinOutcome {
        try WifiJoinPolicy.validate(ssid: ssid, passphrase: passphrase)
        return .manualJoinRequired
    }

    /// No-op (nothing was configured by this build).
    public func forget(ssid: String) {}

    public func configuredSSIDs() async -> [String] { [] }
}
#endif
