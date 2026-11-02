// SPDX-License-Identifier: AGPL-3.0-or-later
// CONTRACT FILE — public surface of the PXC link (EasyConnLink) consumed by the app and the
// mirror extension. See docs/spec/control-plane.md, media-video.md, session-network.md.

import Foundation

/// Bike profile identifiers. Raw values match Android's manual-override ids where they exist
/// (`ProfileOverride.kt`); `morini` and `motoplayLandscape` have no Android override id.
public enum BikeProfileID: String, Sendable, Codable, CaseIterable, Hashable {
    case legacy = "legacy"                       // LegacyCfdl16Profile (CFDL16 675SR…)
    case nk800 = "nk800"                         // Nk800Profile (US 800NK CRCP)
    case nkAdvanced = "nk_adv"                   // Cfdl26NkTouchProfile (800NK Advanced, touch)
    case cfdl26Landscape = "cfdl26_land"         // Cfdl26LandscapeProfile (800MT)
    case cfdl26Portrait = "cfdl26_port"          // Cfdl26PortraitProfile (1000 MT-X)
    case clc450 = "clc450"                       // ClC450Profile
    case morini = "morini"                       // MoriniMlSoftApProfile
    case motoplayLandscape = "motoplay_land"     // Cfdl16MotoPlayLandscapeProfile (modelId 66660742)
}

/// Phone identity values sent to the dash. Defaults reproduce the verified Android spoof
/// (control-plane.md §18.7) — do not change them without a bike test.
public struct PhoneIdentity: Sendable, Equatable, Codable {
    public var phoneUUID: String
    public var phoneBrand: String
    public var phoneModel: String
    /// Android API-level-like string, e.g. "35" (phoneOs stays "Android").
    public var phoneOsVersion: String
    public var bluetoothName: String

    public init(phoneUUID: String = UUID().uuidString.lowercased(), phoneBrand: String = "Apple",
                phoneModel: String = "iPhone", phoneOsVersion: String = "35", bluetoothName: String = "OpenCfMoto") {
        self.phoneUUID = phoneUUID
        self.phoneBrand = phoneBrand
        self.phoneModel = phoneModel
        self.phoneOsVersion = phoneOsVersion
        self.bluetoothName = bluetoothName
    }
}

/// RSA identity used in the CLIENT_INFO reply (control-plane.md §9).
public protocol HuidSigner: Sendable {
    /// base64 (no line breaks) of the X.509 SubjectPublicKeyInfo DER of the 1024-bit RSA key.
    var publicKeyBase64: String { get }
    /// base64 (no line breaks) of RSA/ECB/PKCS1Padding "encryption" with the PRIVATE key of the
    /// UTF-8 HUID bytes (= PKCS#1 v1.5 type-1 signature without DigestInfo).
    func encryptedHUID(_ huid: String) throws -> String
}

/// Something that can find the dash's IP/port on the local network (Bonjour `_EasyConn._tcp`).
public protocol DashDiscovery: Sendable {
    /// Browses for up to `timeout` seconds; returns candidate endpoints (best first).
    func discover(timeout: TimeInterval) async -> [DiscoveredDash]
}

public struct DiscoveredDash: Sendable, Equatable, Hashable {
    public var host: String
    public var port: UInt16
    /// TXT record (huid, huname, channel, flavor, port, ip …) when available.
    public var txt: [String: String]
    public init(host: String, port: UInt16 = 10930, txt: [String: String] = [:]) {
        self.host = host
        self.port = port
        self.txt = txt
    }
}

/// Parsed bike CLIENT_INFO (0x10010) plus the profile chosen for it.
public struct DashInfo: Sendable, Equatable {
    public var huid: String
    public var huName: String
    public var sdkVersion: String
    public var versionName: String
    public var packageName: String
    public var channel: String
    public var socketTimeoutSeconds: Int?
    public var supportsScreenTouch: Bool
    public var profile: BikeProfileID
    /// Raw JSON text as received (for logs / diagnostics; redact before sharing).
    public var rawJSON: String

    public init(huid: String = "", huName: String = "", sdkVersion: String = "", versionName: String = "",
                packageName: String = "", channel: String = "", socketTimeoutSeconds: Int? = nil,
                supportsScreenTouch: Bool = false, profile: BikeProfileID = .legacy, rawJSON: String = "") {
        self.huid = huid
        self.huName = huName
        self.sdkVersion = sdkVersion
        self.versionName = versionName
        self.packageName = packageName
        self.channel = channel
        self.socketTimeoutSeconds = socketTimeoutSeconds
        self.supportsScreenTouch = supportsScreenTouch
        self.profile = profile
        self.rawJSON = rawJSON
    }
}

public enum LinkFailure: Error, Sendable, Equatable, CustomStringConvertible {
    /// A listener port is already bound (typically the official CFMoto/Carbit app is running).
    case portInUse(UInt16)
    /// The system dropped the connection to the dash: iOS Local Network permission denied as far as the
    /// link can tell (a BSD socket gets the same EHOSTUNREACH from a VPN / data rule / filter, so the app
    /// checks the Local Network state before saying so).
    case localNetworkDenied
    /// The system dropped the connection to the dash although Local Network access works (the session's
    /// Bonjour browse listed the dash, or a probe connected): a VPN without local-network access, a
    /// per-app Wi-Fi data rule or a content filter (review POSIX-2). Re-armed like `.localNetworkDenied`.
    case localNetworkBlocked
    /// The phone has no IPv4 address on the bike Wi-Fi.
    case noWifiAddress
    /// No dash answered the :10930 probe (Bonjour, gateway and port scan exhausted).
    case dashNotFound
    /// Reconnect budget (20 attempts) exhausted.
    case lostLink
    case other(String)

    public var description: String {
        switch self {
        case let .portInUse(p): return "port \(p) is in use — close the official CFMoto / Carbit app"
        case .localNetworkDenied: return "Local Network access denied"
        case .localNetworkBlocked: return "connection to the dash blocked by the system (VPN, data restriction or filter)"
        case .noWifiAddress: return "not connected to the bike Wi-Fi"
        case .dashNotFound: return "dash not found on this Wi-Fi"
        case .lostLink: return "lost bike link"
        case let .other(m): return m
        }
    }
}

public enum LinkState: Sendable, Equatable, CustomStringConvertible {
    case idle
    /// Binding :10922/:10921/:10920.
    case startingServers
    /// Looking for the dash / sending the :10930 probe.
    case probing(attempt: Int)
    /// Probe accepted; waiting for the dash to connect back.
    case awaitingCallback
    /// Control connection(s) up; CLIENT_INFO / CHECK_SN / notify burst in progress.
    case handshaking
    /// Handshake done; waiting for media sockets / REQ 112.
    case awaitingMedia
    /// Frames are being pulled by the dash.
    case streaming
    /// All bike sockets closed or watchdog stall; re-probing.
    case reconnecting(attempt: Int)
    case failed(LinkFailure)
    case stopped

    public var description: String {
        switch self {
        case .idle: return "idle"
        case .startingServers: return "starting servers"
        case let .probing(a): return "probing (\(a))"
        case .awaitingCallback: return "waiting for dash"
        case .handshaking: return "handshaking"
        case .awaitingMedia: return "waiting for video request"
        case .streaming: return "streaming"
        case let .reconnecting(a): return "reconnecting (\(a))"
        case let .failed(f): return "failed: \(f)"
        case .stopped: return "stopped"
        }
    }

    public var isActive: Bool {
        switch self {
        case .idle, .stopped, .failed: return false
        default: return true
        }
    }
}

public struct LinkStats: Sendable, Equatable {
    public var framesSent: Int = 0
    public var bytesSent: Int = 0
    public var keyframesSent: Int = 0
    /// 114 pulls answered with nothing (no frame within the timeout).
    public var missedPulls: Int = 0
    /// Pulls per second over the last stats window.
    public var pullRate: Double = 0
    /// Monotonic time of the last frame sent (seconds), nil if none yet.
    public var lastFrameAt: TimeInterval?
    public init() {}
}

/// A raw dash touch contact after ghost filtering, in CANVAS pixels (top-left origin).
public struct DashTouch: Sendable, Equatable {
    public enum Action: Int, Sendable, Codable { case down = 0, up = 1, move = 2 }
    public var action: Action
    /// Pointer id as reported by the dash (0 for single touch).
    public var pointerId: Int
    public var x: Int
    public var y: Int
    /// Monotonic seconds when received.
    public var time: TimeInterval
    public init(action: Action, pointerId: Int = 0, x: Int, y: Int, time: TimeInterval = 0) {
        self.action = action
        self.pointerId = pointerId
        self.x = x
        self.y = y
        self.time = time
    }
}

public enum LinkEvent: Sendable {
    case state(LinkState)
    /// CLIENT_INFO received and profile selected (authoritative).
    case dashIdentified(DashInfo)
    /// REQ 16: canvas negotiated (persist it per SSID as learned geometry).
    case canvas(VideoCanvas)
    /// REQ 112: the dash (re)started pulling video.
    case mediaStarted
    case touch(DashTouch)
    case stats(LinkStats)
}

/// Inputs for one link session.
public struct LinkConfiguration: Sendable {
    /// Parsed pairing QR (Wi-Fi creds, modelId, action bits) — drives the early profile pick.
    public var qr: BikeQR?
    /// nil = automatic profile selection.
    public var profileOverride: BikeProfileID?
    /// Measured canvas from a previous session on this SSID (DashMemory), if any.
    public var learnedCanvas: VideoCanvas?
    /// Advertise supportScreenTouch even on profiles that hide it (Android "Force touchscreen").
    public var forceTouchscreen: Bool
    public var phone: PhoneIdentity
    /// Phone IPv4 on the bike Wi-Fi (listeners and probe use it); nil = resolve automatically.
    public var localHost: String?
    /// Dash IPv4 if known (Bonjour/gateway); nil = resolve automatically.
    public var dashHost: String?
    /// Wait for the dash to call back after an accepted probe before re-probing (Android has none).
    public var connectBackTimeout: TimeInterval
    /// STREAMING with no frame sent for this long → force reconnect (Android 8 s).
    public var stallTimeout: TimeInterval
    /// Minimum gap between watchdog-forced reconnects (Android 20 s).
    public var stallReconnectCooldown: TimeInterval
    /// Reconnect budget after all sockets closed (Android 20).
    public var maxReconnectAttempts: Int
    /// How long `nextFrame` may wait on a 114 before giving up (Android 1.5 s; iOS recommends longer).
    public var framePullTimeout: TimeInterval

    public init(qr: BikeQR? = nil, profileOverride: BikeProfileID? = nil, learnedCanvas: VideoCanvas? = nil,
                forceTouchscreen: Bool = false, phone: PhoneIdentity = PhoneIdentity(), localHost: String? = nil,
                dashHost: String? = nil, connectBackTimeout: TimeInterval = 10, stallTimeout: TimeInterval = 8,
                stallReconnectCooldown: TimeInterval = 20, maxReconnectAttempts: Int = 20,
                framePullTimeout: TimeInterval = 3) {
        self.qr = qr
        self.profileOverride = profileOverride
        self.learnedCanvas = learnedCanvas
        self.forceTouchscreen = forceTouchscreen
        self.phone = phone
        self.localHost = localHost
        self.dashHost = dashHost
        self.connectBackTimeout = connectBackTimeout
        self.stallTimeout = stallTimeout
        self.stallReconnectCooldown = stallReconnectCooldown
        self.maxReconnectAttempts = maxReconnectAttempts
        self.framePullTimeout = framePullTimeout
    }
}
