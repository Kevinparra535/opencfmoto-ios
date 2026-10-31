// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) PxcHandshake.kt (shared handshake state)
//
// State shared by every connection of one link session: the active bike profile, the bike's
// CLIENT_INFO / HUID, the phone identity and RSA signer, the negotiated canvas and clock-frame
// counters. All :10922 sockets share ONE instance (control-plane.md §5.2), like Android's single
// `PxcHandshake`. Thread-safe: every mutable field is guarded by `lock`.

import Foundation

public final class LinkSessionContext: @unchecked Sendable {
    public let phone: PhoneIdentity
    public let signer: HuidSigner
    /// Manual profile override (nil = automatic).
    public let profileOverride: BikeProfileID?
    /// Setup "Force touchscreen".
    public let forceTouch: Bool
    /// Setup "Disable touchscreen" (wins over `forceTouch`).
    public let forceNonTouch: Bool
    /// Clock-lab "phone" knob for 0x10600.
    public let timeSyncForcePhone: Bool
    let clock: MonotonicClock
    let wallClockMillis: @Sendable () -> Int64
    let timeZone: @Sendable () -> TimeZone

    private let lock = NSLock()
    private var _activeProfile: BikeProfile
    private var _clientInfo: BikeClientInfo?
    private var _dashInfo: DashInfo?
    private var _canvas: VideoCanvas = .defaultLandscape
    private var _canvasNegotiated = false
    private var _mediaPrepared = false
    private var timeSyncCount = 0
    private var lastTimeSyncLogAt: TimeInterval = -.infinity
    private var signatureCache: [String: String] = [:]

    /// - Parameters:
    ///   - initialProfile: the early (QR / learned / override) guess; CLIENT_INFO replaces it.
    ///   - initialCanvas: canvas assumed before the first REQ 16 (Android 800×384).
    public init(phone: PhoneIdentity, signer: HuidSigner, initialProfile: BikeProfile = .legacy,
                profileOverride: BikeProfileID? = nil, forceTouch: Bool = false, forceNonTouch: Bool = false,
                timeSyncForcePhone: Bool = false, clock: MonotonicClock = SystemMonotonicClock(),
                wallClockMillis: @escaping @Sendable () -> Int64 = { HuTimeSync.currentMillis() },
                timeZone: @escaping @Sendable () -> TimeZone = { TimeZone.current },
                initialCanvas: VideoCanvas = .defaultLandscape) {
        self.phone = phone
        self.signer = signer
        self.profileOverride = profileOverride
        self.forceTouch = forceTouch
        self.forceNonTouch = forceNonTouch
        self.timeSyncForcePhone = timeSyncForcePhone
        self.clock = clock
        self.wallClockMillis = wallClockMillis
        self.timeZone = timeZone
        _activeProfile = initialProfile
        _canvas = initialCanvas
    }

    /// The active profile (QR guess until CLIENT_INFO, then authoritative).
    public var activeProfile: BikeProfile { lock.lock(); defer { lock.unlock() }; return _activeProfile }
    /// Last CLIENT_INFO from the bike.
    public var clientInfo: BikeClientInfo? { lock.lock(); defer { lock.unlock() }; return _clientInfo }
    public var dashInfo: DashInfo? { lock.lock(); defer { lock.unlock() }; return _dashInfo }
    /// Android `carHuid`.
    public var carHuid: String? { clientInfo?.huid }
    /// The negotiated canvas (initial canvas before any REQ 16; kept across reconnects of a session).
    public var canvas: VideoCanvas { lock.lock(); defer { lock.unlock() }; return _canvas }
    /// True once a REQ 16 with a usable size was seen.
    public var canvasNegotiated: Bool { lock.lock(); defer { lock.unlock() }; return _canvasNegotiated }

    /// Whether `VideoFrameSource.prepare` ran since the media sockets last (re)opened.
    var mediaPrepared: Bool { lock.lock(); defer { lock.unlock() }; return _mediaPrepared }

    func markMediaPrepared(_ prepared: Bool) {
        lock.lock(); _mediaPrepared = prepared; lock.unlock()
    }

    func setCanvas(_ c: VideoCanvas) {
        lock.lock()
        _canvas = c
        _canvasNegotiated = true
        lock.unlock()
    }

    /// Replaces the active profile (e.g. the engine re-applies the QR guess on a new session).
    public func setActiveProfile(_ p: BikeProfile) {
        lock.lock(); _activeProfile = p; lock.unlock()
    }

    /// CLIENT_INFO handling (`PxcHandshake.onClientInfo`): select the profile (override or scores),
    /// apply the keep-landscape refinement against the early profile, store everything and build the
    /// 0x10011 reply with the NEW profile.
    public func applyClientInfo(_ info: BikeClientInfo, tag: String = ":10922") -> (profile: BikeProfile, reply: OrderedJSONObject, dashInfo: DashInfo) {
        let selected = BikeProfiles.select(info: info, override: profileOverride)
        lock.lock()
        let early = _activeProfile
        lock.unlock()
        let profile = BikeProfiles.refine(early: early, selected: selected)
        if profile != selected, let panel = early.panelSize {
            Log.i("LINK", "[\(tag)] keeping landscape QR/measured profile '\(early.name)' (CLIENT_INFO preferred '\(selected.name)' but panel \(panel.width)x\(panel.height) is wide)")
        }
        if early != profile {
            Log.i("LINK", "[\(tag)] profile refined from QR guess '\(early.name)' → CLIENT_INFO '\(profile.name)'")
        }
        let dash = info.dashInfo(profile: profile.id)
        lock.lock()
        _activeProfile = profile
        _clientInfo = info
        _dashInfo = dash
        lock.unlock()
        Log.i("LINK", "[\(tag)] *** BikeProfile selected: \(profile.name) ***")
        let reply = PhoneClientInfoReply.build(phone: phone, publicKeyBase64: signer.publicKeyBase64,
                                               encryptedHUID: encryptedHUID(for: info.huid),
                                               supportFunction: profile.supportFunction,
                                               appendScreenTouch: profile.appendsScreenTouchKey && advertisesScreenTouch(profile))
        return (profile, reply, dash)
    }

    /// `advertisesScreenTouch` for a profile with this session's force flags.
    public func advertisesScreenTouch(_ profile: BikeProfile) -> Bool {
        PhoneClientInfoReply.advertisesScreenTouch(profileSupportsTouch: profile.supportsScreenTouch,
                                                   forceTouch: forceTouch, forceNonTouch: forceNonTouch)
    }

    /// `encryptedHUID` for the bike HUID ("" when none; deterministic, so cached per HUID).
    /// A signer failure (HUID > 117 bytes) is logged loudly and yields "".
    public func encryptedHUID(for huid: String?) -> String {
        guard let huid, !huid.isEmpty else { return "" }
        lock.lock()
        if let cached = signatureCache[huid] { lock.unlock(); return cached }
        lock.unlock()
        let sig: String
        do {
            sig = try signer.encryptedHUID(huid)
        } catch {
            Log.e("LINK", "[:10922] !! encryptedHUID failed (\(huid.utf8.count)-byte HUID): \(error) — replying with \"\"")
            return ""
        }
        lock.lock(); signatureCache[huid] = sig; lock.unlock()
        return sig
    }

    /// 0x10600 → 0x10601 body with this session's clock settings.
    func timeSyncAck(for request: PxcFrame) -> HuTimeSync.Ack {
        HuTimeSync.ack(request: request.payload, forcePhone: timeSyncForcePhone,
                       nowMillis: wallClockMillis(), timeZone: timeZone())
    }

    /// Android log throttle for HU_TIME_SYNC: the first 3 acks, then at most one line per 30 s.
    func noteTimeSync() -> (count: Int, log: Bool) {
        let now = clock.now()
        lock.lock()
        defer { lock.unlock() }
        timeSyncCount += 1
        let shouldLog = timeSyncCount <= 3 || now - lastTimeSyncLogAt >= 30
        if shouldLog { lastTimeSyncLogAt = now }
        return (timeSyncCount, shouldLog)
    }
}
