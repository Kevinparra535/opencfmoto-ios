// SPDX-License-Identifier: AGPL-3.0-or-later
// `MirrorHosting` on iOS: OpenCfMotoApple.MirrorRelayServer on the App-Group Unix socket shared with
// the ReplayKit broadcast extension (MirrorExtension/SampleHandler.swift). The host owns the dash
// link; the extension only encodes the screen and sends access units here.

import Foundation
import OpenCfMotoCore
import OpenCfMotoApple
import OpenCfMotoAppModel

final class MirrorAdapter: MirrorHosting, @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case appGroupUnavailable
        var description: String { "App Group container unavailable \u{2014} check the App Group capability of both targets" }
    }

    private let server: MirrorRelayServer?
    private let idle = IdleFrameSource()

    init() {
        if let path = MirrorRelaySocket.defaultPath() ?? AppGroup.socketPath() {
            server = MirrorRelayServer(socketPath: path)
        } else {
            server = nil
            Log.w("MIRROR", "no App Group container: mirroring is unavailable in this build")
        }
    }

    var frameSource: VideoFrameSource {
        if let server { return server }
        return idle
    }
    var isRunning: Bool { server?.isRunning ?? false }
    var isExtensionConnected: Bool { server?.isClientConnected ?? false }

    var onExtensionConnectionChange: (@Sendable (Bool) -> Void)? {
        get { server?.onClientChange }
        set { server?.onClientChange = newValue }
    }

    func start() throws {
        guard let server else { throw Failure.appGroupUnavailable }
        try server.start()
    }

    func stop() { server?.stop() }

    func setFit(_ fit: ScreenFit, margins: ScreenMargins) {
        server?.setFit(fit, margins: margins)
    }
}

/// A frame source that never produces a frame (no relay available).
private final class IdleFrameSource: VideoFrameSource, @unchecked Sendable {
    func prepare(canvas: VideoCanvas, parameters: EncoderParameters) {}
    func resynchronize() {}
    func nextFrame(timeout: TimeInterval) async -> EncodedFrame? { nil }
    func mediaStopped() {}
}
