// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) GpxVoice.kt (TextToSpeech, rate 0.95, QUEUE_FLUSH on every
// utterance).
//
// Speaks navigation prompts (`NavEffect.speak`) with AVSpeechSynthesizer:
// - QUEUE_FLUSH semantics: `stopSpeaking(at: .immediate)` before every new utterance.
// - rate = 0.95 × AVSpeechUtteranceDefaultSpeechRate; voice es-ES / es-MX / en-US by app language.
// - A TRANSIENT, mixable audio session per prompt (ios-platform-facts.md (e), decision 11):
//   `.playback` + `.voicePrompt` + [.duckOthers, .interruptSpokenAudioAndMixWithOthers], activated
//   just before speaking and deactivated with `.notifyOthersOnDeactivation` after the last utterance,
//   so the rider's music is only ducked while a prompt plays. The `audio` background mode covers these
//   audible prompts (never a silent keep-alive).
// - While `HandlebarRemote` holds its non-mixable Now Playing session, prompts are spoken inside that
//   session (no category change, no deactivation) so handlebar capture is not broken. "Holds" means
//   enabled AND claimed: once another app took the session (or a reclaim was declined because other
//   audio plays) prompts go back to the transient mixable session above.

#if canImport(Foundation)
import Foundation
import OpenCfMotoCore

/// Voice language selection (Foundation-only, unit-tested on Linux).
public enum SpeechVoiceLanguage {
    public static let spanishSpain = "es-ES"
    public static let spanishLatinAmerica = "es-MX"
    public static let english = "en-US"
    /// Android `setSpeechRate(0.95f)` relative to the platform default rate.
    public static let rateFactor: Float = 0.95

    /// Voice for the app language: Spanish UI → es-ES for Spain (or no region), es-MX for any other
    /// Spanish-speaking region (es-CO, es-419, es-US…); everything else → en-US.
    /// - Parameters:
    ///   - appLanguage: the UI localization in use ("es", "en", "es-CO"…); nil = first preferred language.
    ///   - preferredLanguages: the user's languages (region hint), e.g. `Locale.preferredLanguages`.
    public static func voiceLanguage(appLanguage: String?, preferredLanguages: [String]) -> String {
        let app = appLanguage ?? preferredLanguages.first ?? "en"
        guard languageCode(app) == "es" else { return english }
        // Region from the app language itself, else from the first Spanish preferred language.
        let region = regionCode(app) ?? preferredLanguages.first(where: { languageCode($0) == "es" }).flatMap(regionCode)
        guard let region, region != "ES" else { return spanishSpain }
        return spanishLatinAmerica
    }

    /// Default for this device: `Bundle.main.preferredLocalizations` + `Locale.preferredLanguages`.
    public static var current: String {
        voiceLanguage(appLanguage: Bundle.main.preferredLocalizations.first, preferredLanguages: Locale.preferredLanguages)
    }

    static func languageCode(_ tag: String) -> String {
        String(tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "").lowercased()
    }

    /// Region subtag: 2 letters (upper-cased) or 3 digits (UN M.49, e.g. 419); script subtags skipped.
    static func regionCode(_ tag: String) -> String? {
        let parts = tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).dropFirst()
        for p in parts {
            if p.count == 2, p.allSatisfy({ $0.isLetter }) { return p.uppercased() }
            if p.count == 3, p.allSatisfy({ $0.isNumber }) { return String(p) }
        }
        return nil
    }
}
#endif

#if canImport(AVFoundation) && os(iOS)
import AVFoundation

/// Shares the process-wide AVAudioSession between voice prompts and handlebar capture.
@MainActor
final class OCMAudioSessionCoordinator {
    static let shared = OCMAudioSessionCoordinator()
    /// True only while `HandlebarRemote` actually holds its ACTIVE non-mixable `.playback` session
    /// (capture enabled AND claimed — published by HandlebarRemote whenever either changes). False
    /// after another app interrupted it or while a reclaim is declined: prompts then use their own
    /// transient mixable session.
    var captureOwnsSession = false
    private init() {}
}

/// Speaks prompts with QUEUE_FLUSH semantics and a transient ducking audio session.
/// Main-actor isolated.
@MainActor
public final class SpeechAnnouncer: NSObject, AVSpeechSynthesizerDelegate {
    /// When true, `speak` is a no-op (and current speech is stopped).
    public var isMuted = false {
        didSet { if isMuted { stop() } }
    }
    /// BCP-47 voice language ("es-ES", "es-MX", "en-US"…).
    public var language: String
    /// AVSpeechUtterance rate (default 0.95 × AVSpeechUtteranceDefaultSpeechRate).
    public var rate: Float
    public private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    /// Utterances in flight (strong refs keep their identities unique until they end).
    private var active: [ObjectIdentifier: AVSpeechUtterance] = [:]
    private var sessionActivatedByUs = false
    private var deactivationGeneration = 0

    public init(language: String? = nil) {
        self.language = language ?? SpeechVoiceLanguage.current
        self.rate = AVSpeechUtteranceDefaultSpeechRate * SpeechVoiceLanguage.rateFactor
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
    }

    /// Speaks `text`, interrupting anything being spoken (Android QUEUE_FLUSH).
    public func speak(_ text: String) {
        let phrase = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isMuted, !phrase.isEmpty else { return }
        if synthesizer.isSpeaking || synthesizer.isPaused {
            _ = synthesizer.stopSpeaking(at: .immediate)
        }
        activateSessionIfNeeded()
        let u = AVSpeechUtterance(string: phrase)
        u.rate = rate
        u.voice = AVSpeechSynthesisVoice(language: language) ?? AVSpeechSynthesisVoice(language: SpeechVoiceLanguage.english)
        active[ObjectIdentifier(u)] = u
        deactivationGeneration += 1
        isSpeaking = true
        synthesizer.speak(u)
        Log.i("TTS", "speak: \(phrase)")
    }

    /// Stops speaking immediately (the session is released once the synthesizer reports it).
    public func stop() {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            _ = synthesizer.stopSpeaking(at: .immediate)
        }
    }

    // MARK: AVSpeechSynthesizerDelegate

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.utteranceEnded(id) }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.utteranceEnded(id) }
    }

    // MARK: Private

    private func utteranceEnded(_ id: ObjectIdentifier) {
        active[id] = nil
        guard active.isEmpty else { return }
        isSpeaking = false
        scheduleDeactivation()
    }

    private func activateSessionIfNeeded() {
        // Handlebar capture keeps its own non-mixable session active: speak inside it.
        guard !OCMAudioSessionCoordinator.shared.captureOwnsSession else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .voicePrompt,
                                    options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try session.setActive(true)
            sessionActivatedByUs = true
        } catch {
            Log.w("TTS", "audio session activation failed: \(error.localizedDescription)")
        }
    }

    /// Deactivates shortly after the last utterance (the audio route drains first; a new prompt in
    /// the meantime cancels the deactivation).
    private func scheduleDeactivation() {
        guard sessionActivatedByUs else { return }
        let generation = deactivationGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self?.deactivateIfIdle(generation: generation)
        }
    }

    private func deactivateIfIdle(generation: Int) {
        guard generation == deactivationGeneration, active.isEmpty, !synthesizer.isSpeaking,
              sessionActivatedByUs else { return }
        if OCMAudioSessionCoordinator.shared.captureOwnsSession {
            // Handlebar capture re-claimed the session meanwhile: it is capture's now — never
            // deactivate it, and stop tracking it as ours.
            sessionActivatedByUs = false
            return
        }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActivatedByUs = false
        } catch {
            Log.w("TTS", "audio session deactivation failed: \(error.localizedDescription)")
        }
    }
}
#endif
