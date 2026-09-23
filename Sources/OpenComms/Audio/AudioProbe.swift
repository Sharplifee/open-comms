import AVFoundation

/// Plays a short tone through whatever the app is currently using for output.
///
/// This exists because "I hear nothing" and "they hear nothing" are different
/// faults with the same symptom, and telling them apart used to need a second
/// person, a second phone, and a lot of guessing. A tone that you either hear
/// or do not settles the playback half on its own, in about a second.
///
/// It deliberately goes through the SAME session the line uses rather than
/// setting up its own. A test that configures its own audio proves that a test
/// can configure audio, which is not the question.
@MainActor
final class AudioProbe {
    static let shared = AudioProbe()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var wired = false

    private init() {}

    /// Two short notes, an octave apart — distinguishable from any system
    /// sound, and short enough not to interrupt a conversation if somebody
    /// taps it mid-line.
    func play() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
        guard let format else { return }

        if !wired {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            wired = true
        }

        guard let buffer = AudioProbe.tone(format: format) else { return }

        do {
            if !engine.isRunning {
                // Starting an AVAudioEngine ACTIVATES the shared session with
                // whatever category is currently set — and if this app has not
                // set one, that default is solo playback, which stops the
                // person's music. A diagnostic that interrupts the thing you
                // are diagnosing is worse than no diagnostic, so the session is
                // configured with .mixWithOthers first, every time.
                AudioSession.shared.configure()
                engine.prepare()
                try engine.start()
            }
        } catch {
            Log.audio.error("audio probe could not start: \(error.localizedDescription)")
            return
        }

        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }
        releaseAfterTone()
    }

    func stop() {
        if player.isPlaying { player.stop() }
        if engine.isRunning { engine.stop() }
    }

    /// Stop holding the audio system once the tone has finished, unless a line
    /// is using it. Leaving an engine running for a half-second sound keeps
    /// the session active for the life of the app.
    private func releaseAfterTone() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, LineManager.shared.squad == nil else { return }
            self.stop()
            AudioSession.shared.deactivate()
        }
    }

    private static func tone(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let seconds = 0.5
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = frames

        let first = 660.0, second = 990.0
        for frame in 0..<Int(frames) {
            let t = Double(frame) / format.sampleRate
            let hz = t < seconds / 2 ? first : second
            // Fade the edges, or the tone clicks on a good pair of headphones
            // and sounds like a fault rather than a test.
            let position = t < seconds / 2 ? t : t - seconds / 2
            let envelope = min(1, min(position, seconds / 2 - position) * 40)
            let value = Float(sin(2 * .pi * hz * t) * 0.22 * envelope)
            for channel in 0..<Int(format.channelCount) {
                channels[channel][frame] = value
            }
        }
        return buffer
    }
}
