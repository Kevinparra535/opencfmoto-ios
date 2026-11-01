// SPDX-License-Identifier: AGPL-3.0-or-later
// ReplayKit Broadcast Upload Extension (mirror mode, iOS 17–26): the phone screen is fitted into
// the dash canvas and H.264-encoded HERE (MirrorFrameSource), then sent as access units to the host
// app over the App-Group Unix socket (MirrorRelayClient). The host owns the dash link and sends
// back the negotiated canvas / encoder settings / fit (CONFIG), keyframe requests and STOP.
// docs/spec/ios-platform-facts.md (f), design recommendation 14; media-video.md §10.3, §15.7.
//
// - Orientation: `RPVideoSampleOrientationKey` (CGImagePropertyOrientation) is honoured.
// - Logs are forwarded to the host's log (the extension has no UI); the ring buffer is kept small.
// - If the host app is not reachable for `hostGracePeriod` (not running / not in mirror mode) the
//   broadcast ends with a clear localized explanation; the same happens when the host stops.
// - Memory (~50 MB limit for the whole extension): no frame is retained here; MirrorFrameSource
//   keeps ≤ 3 canvas buffers and one VideoToolbox session. Extension-safe APIs only.

import Foundation
import CoreMedia
import ImageIO
import ReplayKit
import OpenCfMotoCore
import OpenCfMotoApple

final class SampleHandler: RPBroadcastSampleHandler {
    /// How long the host may stay unreachable before the broadcast is ended with an explanation.
    private static let hostGracePeriod: TimeInterval = 10
    /// Log lines kept in memory by this process (the host keeps the full log).
    private static let logCapacity = 300

    private struct State {
        var client: MirrorRelayClient?
        var source: MirrorFrameSource?
        var connected = false
        var finished = false
        var graceGeneration = 0
    }

    private let state = Locked(State())
    private let timerQueue = DispatchQueue(label: "ocm.mirror.extension.grace")

    // MARK: - Broadcast lifecycle

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        Log.shared.capacity = Self.logCapacity
        guard let path = MirrorRelaySocket.defaultPath() ?? AppGroup.socketPath() else {
            Log.e("MIRROR", "extension: App Group container unavailable")
            finish(with: MirrorMessage.appGroupMissing)
            return
        }
        // No canvas until the host's CONFIG: an IDR encoded at a guessed 800×384 could reach a dash
        // that negotiated another size (MP-3). The newest screen frame waits for it.
        let source = MirrorFrameSource(configuration: nil)
        let client = MirrorRelayClient(socketPath: path)
        source.onFrame = { [weak client] frame in client?.send(frame: frame) }
        client.onConfig = { [weak source] config in source?.update(configuration: config) }
        client.onKeyframeRequest = { [weak source] in source?.requestKeyframe() }
        client.onStop = { [weak self] reason in self?.hostStopped(reason) }
        client.onConnectionChange = { [weak self] connected in self?.connectionChanged(connected) }
        client.forwardLogs(minimumLevel: .info)
        state.withLock { s in
            s.client = client
            s.source = source
        }
        Log.i("MIRROR", "extension: broadcast started")
        client.start()
        armGraceTimer()
    }

    override func broadcastPaused() {
        Log.i("MIRROR", "extension: broadcast paused")
    }

    override func broadcastResumed() {
        Log.i("MIRROR", "extension: broadcast resumed")
        state.withLock { $0.source }?.requestKeyframe() // the screen may have changed a lot
    }

    override func broadcastFinished() {
        Log.i("MIRROR", "extension: broadcast finished")
        shutDown(reason: "broadcast finished")
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video, let source = state.withLock({ $0.source }) else { return }
        source.append(sampleBuffer: sampleBuffer, orientation: Self.orientation(of: sampleBuffer))
    }

    // MARK: - Host connection

    private func connectionChanged(_ connected: Bool) {
        state.withLock { $0.connected = connected }
        if connected {
            Log.i("MIRROR", "extension: connected to OpenCfMoto")
            cancelGraceTimer()
        } else {
            armGraceTimer()
        }
    }

    private func hostStopped(_ reason: String) {
        Log.i("MIRROR", "extension: host stopped (\(reason))")
        finish(with: MirrorMessage.hostStopped)
    }

    /// Ends the broadcast if the host does not (re)connect within the grace period.
    private func armGraceTimer() {
        let generation = state.withLock { s -> Int in
            s.graceGeneration += 1
            return s.graceGeneration
        }
        timerQueue.asyncAfter(deadline: .now() + Self.hostGracePeriod) { [weak self] in
            guard let self else { return }
            let expired = self.state.withLock { s in !s.connected && !s.finished && s.graceGeneration == generation }
            guard expired else { return }
            Log.w("MIRROR", "extension: OpenCfMoto unreachable for \(Int(Self.hostGracePeriod))s \u{2014} ending the broadcast")
            self.finish(with: MirrorMessage.hostUnreachable)
        }
    }

    private func cancelGraceTimer() {
        state.withLock { $0.graceGeneration += 1 }
    }

    // MARK: - Teardown

    private func finish(with message: MirrorMessage) {
        let first = state.withLock { s -> Bool in
            if s.finished { return false }
            s.finished = true
            return true
        }
        guard first else { return }
        shutDown(reason: "ended: \(message)")
        let error = NSError(domain: "OpenCfMotoMirror", code: message.code,
                            userInfo: [NSLocalizedDescriptionKey: message.localizedText])
        DispatchQueue.main.async { [weak self] in
            self?.finishBroadcastWithError(error)
        }
    }

    private func shutDown(reason: String) {
        let (client, source) = state.withLock { s -> (MirrorRelayClient?, MirrorFrameSource?) in
            s.finished = true
            s.graceGeneration += 1
            let parts = (s.client, s.source)
            s.client = nil
            s.source = nil
            return parts
        }
        source?.stop()
        client?.stop(reason: reason)
    }

    // MARK: - Helpers

    /// `RPVideoSampleOrientationKey` → CGImagePropertyOrientation (`.up` when absent).
    private static func orientation(of sampleBuffer: CMSampleBuffer) -> CGImagePropertyOrientation {
        guard let value = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                          attachmentModeOut: nil) as? NSNumber,
              let orientation = CGImagePropertyOrientation(rawValue: value.uint32Value) else { return .up }
        return orientation
    }
}

/// Why the extension ends the broadcast (shown by iOS in an alert), EN / ES.
private enum MirrorMessage: CustomStringConvertible {
    case appGroupMissing
    case hostUnreachable
    case hostStopped

    var code: Int {
        switch self {
        case .appGroupMissing: return 1
        case .hostUnreachable: return 2
        case .hostStopped: return 3
        }
    }

    var description: String {
        switch self {
        case .appGroupMissing: return "app group missing"
        case .hostUnreachable: return "host unreachable"
        case .hostStopped: return "host stopped"
        }
    }

    var localizedText: String {
        let spanish = (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("es")
        switch self {
        case .appGroupMissing:
            return spanish
                ? "La duplicación no está configurada en esta compilación de OpenCfMoto (falta el App Group). Vuelve a compilar la app con la capacidad App Group."
                : "Mirroring is not set up in this OpenCfMoto build (the App Group is missing). Rebuild the app with the App Group capability."
        case .hostUnreachable:
            return spanish
                ? "OpenCfMoto no está listo para duplicar. Abre OpenCfMoto, toca Espejo y vuelve a iniciar la transmisión."
                : "OpenCfMoto is not ready to mirror. Open OpenCfMoto, tap Mirror, then start the broadcast again."
        case .hostStopped:
            return spanish
                ? "La duplicación se detuvo en OpenCfMoto."
                : "Mirroring was stopped in OpenCfMoto."
        }
    }
}
