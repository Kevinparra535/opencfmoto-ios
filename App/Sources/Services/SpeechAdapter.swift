// SPDX-License-Identifier: AGPL-3.0-or-later
// `SpeechProviding` on iOS: OpenCfMotoApple.SpeechAnnouncer (AVSpeechSynthesizer, QUEUE_FLUSH
// semantics, transient ducking `.voicePrompt` session, voice in the app language).

import Foundation
import OpenCfMotoCore
import OpenCfMotoApple
import OpenCfMotoAppModel

@MainActor
final class SpeechAdapter: SpeechProviding {
    private let announcer: SpeechAnnouncer

    init() {
        announcer = SpeechAnnouncer()
    }

    var isMuted: Bool {
        get { announcer.isMuted }
        set { announcer.isMuted = newValue }
    }

    var isSpeaking: Bool { announcer.isSpeaking }

    func speak(_ text: String) { announcer.speak(text) }

    func stop() { announcer.stop() }
}
