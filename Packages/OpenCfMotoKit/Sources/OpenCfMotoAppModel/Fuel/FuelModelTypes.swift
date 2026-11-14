// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: the value types FuelModel publishes to the SwiftUI layer.

import Foundation
import OpenCfMotoCore

/// Everything the phone shows about one bike's fuel.
public struct FuelBikeState: Sendable, Equatable {
    public var bikeId: String
    public var profile: FuelProfile?
    /// The catalog row of `profile.catalogId` (nil: manual, or no longer listed).
    public var entry: FuelCatalogEntry?
    /// Oldest first.
    public var log: [RefuelEntry]
    public var stats: FuelStats
    public var estimate: FuelEstimate
    /// The app's km counter for this bike.
    public var odometerKm: Double
    public var isSetupDeferred: Bool

    public init(bikeId: String, profile: FuelProfile?, entry: FuelCatalogEntry?, log: [RefuelEntry], stats: FuelStats,
                estimate: FuelEstimate, odometerKm: Double, isSetupDeferred: Bool) {
        self.bikeId = bikeId
        self.profile = profile
        self.entry = entry
        self.log = log
        self.stats = stats
        self.estimate = estimate
        self.odometerKm = odometerKm
        self.isSetupDeferred = isSetupDeferred
    }

    /// A profile or at least one refuel: the bike counts km («Combustible» set up).
    public var isSetUp: Bool { profile != nil || !log.isEmpty }
}

/// «¿Cuál es tu moto?» on Home (a non-modal card, never a sheet by itself).
public struct FuelSetupPrompt: Sendable, Equatable {
    public var bikeId: String
    public var bikeName: String
    public init(bikeId: String, bikeName: String) {
        self.bikeId = bikeId
        self.bikeName = bikeName
    }
}

/// The fuel sheet RootView presents (only after a rider tap: `FuelModel.present`).
public enum FuelSheet: Sendable, Equatable, Identifiable {
    case picker(bikeId: String, fromPrompt: Bool)
    case editProfile(bikeId: String)
    /// `late` = opened from «¿Cargaste gasolina?»: the «Cargaste hace rato» field starts expanded.
    case refuel(bikeId: String, late: Bool)
    /// «Corregir nivel».
    case level(bikeId: String)

    public var id: String {
        switch self {
        case let .picker(b, prompt): return "picker-\(b)-\(prompt)"
        case let .editProfile(b): return "edit-\(b)"
        case let .refuel(b, late): return "refuel-\(b)-\(late)"
        case let .level(b): return "level-\(b)"
        }
    }

    public var bikeId: String {
        switch self {
        case let .picker(b, _), let .editProfile(b), let .refuel(b, _), let .level(b): return b
        }
    }
}

/// «Carga registrada · Deshacer».
public struct FuelUndoOffer: Sendable, Equatable {
    public var bikeId: String
    public var entryId: String
    public init(bikeId: String, entryId: String) {
        self.bikeId = bikeId
        self.entryId = entryId
    }
}

public enum FuelLogOutcome: Sendable, Equatable {
    case logged(RefuelEntry), refusedWhileMoving, invalid(RefuelInput.Field), noSuchBike
}

public enum FuelSaveOutcome: Sendable, Equatable { case saved, refusedWhileMoving, incomplete, noSuchBike }

/// Another bike of the garage whose profile can be copied (a replaced dash is a new Garage bike).
public struct FuelCopySource: Sendable, Equatable, Identifiable {
    public var bikeId: String
    public var bikeName: String
    public var profile: FuelProfile
    public var id: String { bikeId }
    public init(bikeId: String, bikeName: String, profile: FuelProfile) {
        self.bikeId = bikeId
        self.bikeName = bikeName
        self.profile = profile
    }
}

/// The dash's low-range alert (RideModel turns it into the toast and the voice line).
public struct FuelDashAlert: Sendable, Equatable {
    public var level: FuelAlertLevel
    public var kmToReserve: Double
    public init(level: FuelAlertLevel, kmToReserve: Double) {
        self.level = level
        self.kmToReserve = kmToReserve
    }
}
