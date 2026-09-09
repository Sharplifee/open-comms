import AVFoundation

/// Says a cue out loud in the listener's ear.
///
/// A player at the baseline cannot look at a phone in a bag, so a cue that is
/// only text is a cue that does not exist. Spoken, it arrives the same way the
/// coach's own voice does — over the top of whatever is playing, through the
/// same earbuds, with no glance and no hands.
///
/// It deliberately does NOT touch the audio session. The line has already
/// configured it, and a speech synthesiser that reconfigures the session
/// mid-session is exactly the kind of thing that has taken this app's audio
/// down before. `.mixWithOthers` is inherited; the utterance simply joins what
/// is already playing.
@MainActor
final class Speaker {
    static let shared = Speaker()

    private let synth = AVSpeechSynthesizer()
    private init() {}

    func say(_ text: String) {
        // A cue that arrives late is worse than no cue, so a new one cancels
        // whatever is still being said rather than queueing behind it.
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }

        let utterance = AVSpeechUtterance(string: text)
        // Slightly quick and slightly low: a coach's instruction, not an
        // announcement. The default rate sounds like a station platform.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.06
        utterance.pitchMultiplier = 0.96
        utterance.postUtteranceDelay = 0
        utterance.voice = Speaker.preferredVoice
        synth.speak(utterance)
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    /// Prefer one of Apple's better-quality voices when the person has one
    /// downloaded; fall back to whatever the system gives for their language.
    private static let preferredVoice: AVSpeechSynthesisVoice? = {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        if let premium = voices.first(where: { $0.language == language && $0.quality == .premium }) {
            return premium
        }
        if let enhanced = voices.first(where: { $0.language == language && $0.quality == .enhanced }) {
            return enhanced
        }
        return AVSpeechSynthesisVoice(language: language)
    }()
}
