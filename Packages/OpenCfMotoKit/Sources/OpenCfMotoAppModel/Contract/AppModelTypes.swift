// SPDX-License-Identifier: AGPL-3.0-or-later
// CONTRACT FILE (wave 2). Do not edit; report a contract change request instead.
//
// UI-facing value types of the app model (docs/spec/app-features.md §7 home screen and flows).

import Foundation
import OpenCfMotoCore

// MARK: - Connection (app-features §7.2 – §7.4)

/// Home status phases (Android ConnectionState minus the Android Auto phases).
public enum ConnectionPhase: String, Sendable, Equatable, CaseIterable {
    case idle
    case joiningWifi
    case linking
    case streaming
    case mirroring
    case reconnecting
    case waitingForBike
    case stopped
    case error

    /// Progress bar + "Stop" button.
    public var isBusy: Bool {
        switch self {
        case .joiningWifi, .linking, .reconnecting, .waitingForBike: return true
        default: return false
        }
    }

    /// Green state: something is on the dash.
    public var isLive: Bool { self == .streaming || self == .mirroring }

    /// The Connect button acts as "Stop everything".
    public var showsStop: Bool { isBusy || isLive }
}

/// What the dash is showing.
public enum ProjectionMode: String, Sendable, Equatable {
    case none
    /// Our own map / turn-by-turn UI (DashUIController → DashProjectionEngine).
    case dashUI
    /// ReplayKit broadcast of the whole iPhone screen (no touch back).
    case mirror
}

/// A problem that deserves a dialog (Android error dialogs, §7.5.8), beyond the status line.
public enum ConnectionIssue: Sendable, Equatable {
    /// Ports 10920–10922 are taken (the official CFMoto / Carbit app is running).
    case portsInUse
    /// Local Network permission denied: the dash cannot be reached.
    case localNetworkDenied
    /// No usable Wi-Fi address (Wi-Fi off / not joined).
    case wifiUnavailable
    /// Joining the bike Wi-Fi failed (message already localized).
    case wifiJoinFailed(message: String)
    /// The dash never answered the probe.
    case dashNotFound
    /// Gave up after the reconnect budget.
    case lostLink
    /// No bike paired: the UI should open the scanner.
    case noBikePaired
    /// Anything else (message already localized).
    case other(String)
}

/// Shown when the rider has to join the bike Wi-Fi in Settings (free flavor or iOS refused).
public struct ManualWifiJoinPrompt: Sendable, Equatable, Identifiable {
    public var id: String { ssid }
    public var ssid: String
    /// nil for open networks. Show it with a copy button.
    public var password: String?
    /// Localized instructions.
    public var message: String

    public init(ssid: String, password: String?, message: String) {
        self.ssid = ssid
        self.password = password
        self.message = message
    }
}

/// Live link diagnostics for the status card / logs screen.
public struct LinkDiagnostics: Sendable, Equatable {
    public var state: LinkState
    public var stats: LinkStats
    public var dashInfo: DashInfo?
    /// Active bike profile display name (Android names, e.g. "800NK Advanced").
    public var profileName: String?
    public var canvas: VideoCanvas?
    public var projection: ProjectionStatsSummary

    public init(state: LinkState = .idle, stats: LinkStats = LinkStats(), dashInfo: DashInfo? = nil,
                profileName: String? = nil, canvas: VideoCanvas? = nil,
                projection: ProjectionStatsSummary = ProjectionStatsSummary()) {
        self.state = state
        self.stats = stats
        self.dashInfo = dashInfo
        self.profileName = profileName
        self.canvas = canvas
        self.projection = projection
    }
}

// MARK: - Pairing

public enum PairingOutcome: Sendable, Equatable {
    case paired(GarageBike)
    /// Not a pairing QR; `hint` is a localized explanation (BikeQR.iosFailureHint) or "Invalid QR".
    case invalid(hint: String)
}

// MARK: - App lifecycle

/// SwiftUI ScenePhase without SwiftUI.
public enum AppScenePhase: String, Sendable, Equatable {
    case active
    case inactive
    case background
}

// MARK: - Dash preview on the phone

/// Canvas presets for previewing the dash UI on the phone when no dash is connected.
public enum DashPreviewCanvas: String, Sendable, Equatable, CaseIterable, Identifiable {
    /// 800×384 (CFDL16, most CFMoto dashes).
    case landscape800x384
    /// 800×944 (CFDL26 portrait).
    case portrait800x944
    /// 1280×576 (800MT / wide).
    case wide1280x576

    public var id: String { rawValue }

    public var size: DashSize {
        switch self {
        case .landscape800x384: return DashSize(width: 800, height: 384)
        case .portrait800x944: return DashSize(width: 800, height: 944)
        case .wide1280x576: return DashSize(width: 1280, height: 576)
        }
    }
}

// MARK: - Trips list

public struct TripDaySection: Sendable, Equatable, Identifiable {
    /// "yyyy-MM-dd" of the local day.
    public var id: String
    /// Localized day title ("Fri 31 Oct 2026").
    public var title: String
    /// e.g. "3 trips · 142.5 km".
    public var summary: String
    public var trips: [Trip]

    public init(id: String, title: String, summary: String, trips: [Trip]) {
        self.id = id
        self.title = title
        self.summary = summary
        self.trips = trips
    }
}

// MARK: - Logs

public struct LogEntry: Sendable, Equatable, Identifiable {
    public var id: Int
    /// One formatted line as Log.shared stores it.
    public var text: String
    public var level: LogLevelTag

    public init(id: Int, text: String, level: LogLevelTag) {
        self.id = id
        self.text = text
        self.level = level
    }
}

public enum LogLevelTag: String, Sendable, Equatable {
    case debug
    case info
    case warning
    case error
}

// MARK: - Exports (share sheet payloads)

/// A file ready for ShareLink / UIActivityViewController.
public struct ExportedFile: Sendable, Equatable, Identifiable {
    public var id: URL { url }
    public var url: URL
    public var fileName: String
    /// UTType identifier (e.g. "com.topografix.gpx", "public.json", "public.plain-text").
    public var typeIdentifier: String

    public init(url: URL, fileName: String, typeIdentifier: String) {
        self.url = url
        self.fileName = fileName
        self.typeIdentifier = typeIdentifier
    }
}

// MARK: - Onboarding

public enum OnboardingStep: String, Sendable, Equatable, CaseIterable {
    case welcome
    case location
    case localNetwork
    case pairBike
    case done
}

// MARK: - Opened files waiting for confirmation

/// A settings or map-data pack opened from another app (Files, AirDrop, Mail…).
public struct PendingImport: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable { case settings, mapData }
    public var id: String { fileName }
    public var kind: Kind
    /// Display name of the opened file.
    public var fileName: String
    /// The pack's JSON text (applied only after confirmation).
    public var text: String

    public init(kind: Kind, fileName: String, text: String) {
        self.kind = kind
        self.fileName = fileName
        self.text = text
    }
}

