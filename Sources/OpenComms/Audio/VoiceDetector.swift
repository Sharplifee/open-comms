import AVFoundation
import Combine

/// Decides when you are talking, so nobody has to hold a button.
///
/// The envelope matters more than the threshold. A bare level test opens and
/// closes the line on every syllable, which sounds like a stutter to everyone
/// else. So: a short attack so the first word is not clipped, a hold that
/// carries the gaps inside a sentence, and a longer release so the line does
/// not slam shut on a trailing word.
@MainActor
final class VoiceDetector: ObservableObject {
    @Published private(set) var level: Double = 0      // 0...1 for the meter
    /// The live reading in decibels, on the same −55…−12 scale the threshold
    /// uses, so the meter and the marker can be drawn on one axis and a
    /// person can see exactly how far they are from opening the line.
    @Published private(set) var decibels: Double = -55
    @Published private(set) var speaking = false
    /// Whether the meter has a signal at all. True whenever the engine is
    /// running — on a line or just listening on the Home screen — so the
    /// reading is shown before anybody has opened anything.
    @Published private(set) var isListening = false

    private let engine = AVAudioEngine()
    private var holdUntil = Date.distantPast
    private var running = false

    private let attack: TimeInterval = 0.06
    private let hold: TimeInterval = 0.35
    private let release: TimeInterval = 0.45
    private var aboveSince: Date?

    var threshold: Double = -32          // dB, driven by the sensitivity slider
    var onChange: ((Bool) -> Void)?

    /// A little of your own voice back in your ear.
    ///
    /// The engine already has the input tapped for the meter, so routing it to
    /// the output at a low gain costs nothing extra. It is gated to headphones
    /// because on the speaker the same path is a feedback loop.
    private let monitor = AVAudioMixerNode()
    var selfMonitorGain: Float = 0 {
        didSet { applyMonitorGain() }
    }

    private func applyMonitorGain() {
        let onSpeaker = AVAudioSession.sharedInstance().currentRoute.outputs
            .first?.portType == .builtInSpeaker
        monitor.outputVolume = onSpeaker ? 0 : selfMonitorGain
    }

    /// Runs before anybody joins a line, so the meter is honest on the
    /// settings screen and you can see how loud you need to be.
    func start() {
        guard !running else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        if monitor.engine == nil {
            engine.attach(monitor)
            engine.connect(input, to: monitor, format: format)
            engine.connect(monitor, to: engine.mainMixerNode, format: format)
            applyMonitorGain()
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frames { sum += channel[i] * channel[i] }
            let rms = sqrt(sum / Float(max(frames, 1)))
            let db = Double(20 * log10(max(rms, 0.000_001)))
            Task { @MainActor in self?.consume(db) }
        }
        do {
            try engine.start()
            running = true
            isListening = true
        } catch {
            Log.audio.error("voice detector failed to start: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        isListening = false
        speaking = false
        level = 0
        decibels = -55
    }

    private func consume(_ db: Double) {
        // −55 is close to silence, −12 is a shout. Everything between maps
        // onto the meter.
        level = min(max((db + 55) / 43, 0), 1)
        decibels = min(max(db, -55), -12)

        let now = Date()
        if db > threshold {
            if aboveSince == nil { aboveSince = now }
            holdUntil = now.addingTimeInterval(hold)
            if !speaking, now.timeIntervalSince(aboveSince ?? now) >= attack {
                speaking = true
                onChange?(true)
            }
        } else {
            aboveSince = nil
            if speaking, now > holdUntil.addingTimeInterval(release) {
                speaking = false
                onChange?(false)
            }
        }
    }
}
