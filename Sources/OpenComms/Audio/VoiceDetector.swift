import AVFoundation
import Combine

/// Decides when you are talking, so nobody has to hold a button.
///
/// The envelope matters more than the threshold. A bare level test opens and
/// closes the line on every syllable, which sounds like a stutter to everyone
/// else. So: a short attack so the first word is not clipped, a hold that
/// carries the gaps inside a sentence, and a longer release so the line does
/// not slam shut on a trailing word.
///
/// Everything here is defensive on purpose. AVAudioEngine reports most of its
/// problems by raising an Objective-C exception, which Swift cannot catch —
/// the process simply dies. Tapping a node with a zero-channel format, or
/// connecting nodes whose formats disagree, or leaving a tap installed across
/// a route change all do exactly that. So every one of those is checked before
/// it is attempted rather than after it has failed.
@MainActor
final class VoiceDetector: ObservableObject {
    @Published private(set) var level: Double = 0      // 0...1 for the meter
    /// The live reading in decibels, on the same −55…−12 scale the threshold
    /// uses, so the meter and the marker can be drawn on one axis and a
    /// person can see exactly how far they are from opening the line.
    @Published private(set) var decibels: Double = -55
    @Published private(set) var speaking = false
    /// Whether the meter has a signal at all, so the reading can be shown
    /// before anybody has opened a line.
    @Published private(set) var isListening = false

    private var engine = AVAudioEngine()
    private var holdUntil = Date.distantPast
    private var running = false
    private var tapped = false
    private var monitoring = false

    private let attack: TimeInterval = 0.06
    private let hold: TimeInterval = 0.35
    private let release: TimeInterval = 0.45
    private var aboveSince: Date?

    /// dB, driven by the sensitivity slider.
    var threshold: Double = -32
    var onChange: ((Bool) -> Void)?

    /// A little of your own voice back in your ear.
    ///
    /// Gated to headphones, because routing the microphone to the speaker is
    /// a feedback loop by definition. Changing it rebuilds the graph, which
    /// is why it goes through a function rather than being read live.
    private let monitor = AVAudioMixerNode()
    var selfMonitorGain: Float = 0 {
        didSet {
            guard abs(oldValue - selfMonitorGain) > 0.001 else { return }
            rebuildMonitorIfNeeded()
        }
    }

    private var observers: [NSObjectProtocol] = []

    init() {
        let centre = NotificationCenter.default

        // A route change replaces the hardware format underneath a running
        // engine. A tap installed against the old format is then holding a
        // pointer to something that no longer describes the input, and the
        // next buffer takes the process down with it. Rebuild instead.
        observers.append(centre.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restartIfRunning() }
        })

        // The whole audio server can be restarted out from under an app —
        // rare, but when it happens every node and every format is stale.
        observers.append(centre.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuildEngine() }
        })

        // A phone call takes the microphone away. Coming back needs a fresh
        // start, not a resume of an engine whose input was revoked.
        observers.append(centre.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor in
                switch type {
                case .began: self?.suspend()
                case .ended: self?.restartIfRunning()
                @unknown default: break
                }
            }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Running

    func start() {
        guard !running else { return }
        guard permissionGranted else {
            Log.audio.error("voice detector asked to start without microphone permission")
            return
        }
        running = true
        startEngine()
    }

    func stop() {
        running = false
        teardownEngine()
        isListening = false
        speaking = false
        level = 0
        decibels = -55
        aboveSince = nil
    }

    private var permissionGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    /// The one place the engine is built. Every precondition is checked here,
    /// because each of them is a crash rather than an error if it is wrong.
    private func startEngine() {
        guard !isListening else { return }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        // This is the crash. Before the audio session is active — or in the
        // instant after a route change — the input reports a format with no
        // channels and no sample rate. Installing a tap or connecting a node
        // with that format raises an exception and the app is gone. It is not
        // an error state, just a not-ready-yet state, so try again shortly.
        guard format.channelCount > 0, format.sampleRate > 0 else {
            Log.audio.info("input not ready (\(format.channelCount)ch @ \(format.sampleRate)Hz), retrying")
            retryShortly()
            return
        }

        connectMonitor(from: input, format: format)

        if !tapped {
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                guard let channel = buffer.floatChannelData?[0] else { return }
                let frames = Int(buffer.frameLength)
                guard frames > 0 else { return }
                var sum: Float = 0
                for i in 0..<frames { sum += channel[i] * channel[i] }
                let rms = sqrt(sum / Float(frames))
                let db = Double(20 * log10(max(rms, 0.000_001)))
                Task { @MainActor in self?.consume(db) }
            }
            tapped = true
        }

        engine.prepare()
        do {
            try engine.start()
            isListening = true
        } catch {
            // A failure here is usually the session not being active yet.
            // Worth one retry rather than leaving a dead meter on screen.
            Log.audio.error("voice detector failed to start: \(error.localizedDescription)")
            teardownEngine()
            retryShortly()
        }
    }

    /// Self monitoring only exists on headphones. On the speaker the same
    /// graph is a microphone pointed at a loudspeaker.
    private func connectMonitor(from input: AVAudioInputNode, format: AVAudioFormat) {
        let onSpeaker = AVAudioSession.sharedInstance().currentRoute.outputs
            .first?.portType == .builtInSpeaker
        let wanted = selfMonitorGain > 0.001 && !onSpeaker

        guard wanted != monitoring else {
            if monitoring { monitor.outputVolume = selfMonitorGain }
            return
        }

        if wanted {
            if monitor.engine == nil { engine.attach(monitor) }
            // Touching mainMixerNode instantiates the output chain, so it is
            // read once here rather than left to happen inside a connect.
            let output = engine.mainMixerNode
            engine.connect(input, to: monitor, format: format)
            engine.connect(monitor, to: output, format: format)
            monitor.outputVolume = selfMonitorGain
            monitoring = true
        } else {
            if monitor.engine != nil {
                engine.disconnectNodeInput(monitor)
                engine.disconnectNodeOutput(monitor)
            }
            monitoring = false
        }
    }

    private func rebuildMonitorIfNeeded() {
        guard isListening else { return }
        restartIfRunning()
    }

    /// Stop the engine but remember that the meter is meant to be live, so a
    /// route change or an interruption comes back on its own.
    private func restartIfRunning() {
        guard running else { return }
        teardownEngine()
        startEngine()
    }

    private func suspend() {
        guard isListening else { return }
        teardownEngine()
        speaking = false
        onChange?(false)
    }

    /// Media services reset invalidates the engine object itself, not just its
    /// configuration, so this one is replaced rather than restarted.
    private func rebuildEngine() {
        teardownEngine()
        engine = AVAudioEngine()
        monitoring = false
        guard running else { return }
        startEngine()
    }

    private func teardownEngine() {
        if tapped {
            engine.inputNode.removeTap(onBus: 0)
            tapped = false
        }
        if engine.isRunning { engine.stop() }
        isListening = false
    }

    private func retryShortly() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, self.running, !self.isListening else { return }
            self.startEngine()
        }
    }

    // MARK: - Envelope

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
