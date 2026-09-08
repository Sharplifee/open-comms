import AVFoundation

/// The audio session, configured once and then left alone.
///
/// This file is short on purpose, and every line in it is the result of
/// something that went wrong before.
///
/// `.mixWithOthers` is permanent, because the entire product is voices sitting
/// on top of music rather than replacing it.
///
/// `.duckOthers` is NEVER permanent. Leaving it set — together with a
/// permanent `.voiceChat` mode — degraded background audio quality even when
/// nobody was talking, and it took weeks to find. Ducking belongs at the edges
/// of speech, applied and removed, never a standing condition.
///
/// The mode follows the route. On headphones there is no echo path worth
/// cancelling, so `.default` keeps the music clean. On the speaker there very
/// much is, so `.voiceChat` earns its cost there and only there.
@MainActor
final class AudioSession {
    static let shared = AudioSession()
    private let session = AVAudioSession.sharedInstance()
    private var configured = false

    private init() {}

    func configure() {
        guard !configured else { return }
        do {
            try session.setCategory(.playAndRecord,
                                    mode: modeForCurrentRoute(),
                                    options: [.mixWithOthers, .allowBluetooth,
                                              .allowBluetoothA2DP, .defaultToSpeaker])
            try session.setPreferredSampleRate(48_000)
            // 5 ms was chosen for latency, but a buffer that small forces the
            // hardware into a high-rate mode that everything sharing the
            // session inherits, and on headphones that is audible on music as
            // a thinner, harder sound. 10 ms is still well under anything a
            // person perceives in conversation and leaves other audio alone.
            try session.setPreferredIOBufferDuration(0.01)
            // NOT .notifyOthersOnDeactivation — that flag belongs on
            // deactivation. Passing it on activation does nothing useful, and
            // activation itself is what interrupts other audio if the category
            // is wrong, which is why the category is always set first.
            try session.setActive(true)
            configured = true
            observe()
            Log.audio.info("audio session ready on \(self.routeName)")
        } catch {
            Log.audio.error("audio session failed: \(error.localizedDescription)")
        }
    }

    /// Hand the audio system back.
    ///
    /// `.notifyOthersOnDeactivation` is what tells whatever was playing that it
    /// may return to full volume and full quality. Without it another app can
    /// sit ducked, or stay in the degraded shared configuration, long after
    /// this app has stopped caring.
    func deactivate() {
        guard configured else { return }
        configured = false
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            Log.audio.info("audio session released")
        } catch {
            // Deactivating while another part of the app still holds the
            // session throws, and that is not worth surfacing — it means
            // somebody else is using it, which is fine.
            Log.audio.info("audio session still in use: \(error.localizedDescription)")
        }
    }

    var routeName: String {
        session.currentRoute.outputs.first?.portName ?? "iPhone Speaker"
    }

    var onSpeaker: Bool {
        session.currentRoute.outputs.first?.portType == .builtInSpeaker
    }

    /// `.voiceChat` puts the whole session through Apple's voice processing.
    /// On the speaker that is mandatory — there is a real echo path between
    /// the speaker and the mic — and it is worth what it costs.
    ///
    /// On headphones there is no echo to cancel and it costs plenty: voice
    /// processing reshapes everything the session touches, which is exactly
    /// how the old app ended up with music that sounded thin and boxy the
    /// whole time a line was open. Headphones stay `.default` and the music
    /// stays untouched, no matter what the noise setting says. Noise cleanup
    /// happens on the microphone instead, where it belongs.
    private func modeForCurrentRoute() -> AVAudioSession.Mode {
        onSpeaker ? .voiceChat : .default
    }

    /// Re-apply the category when the noise setting changes mid-line, so the
    /// switch takes effect on the words you say next rather than the next
    /// time you open a line.
    func refreshMode() {
        guard configured else { return }
        do {
            try session.setCategory(.playAndRecord, mode: modeForCurrentRoute(),
                                    options: [.mixWithOthers, .allowBluetooth,
                                              .allowBluetoothA2DP, .defaultToSpeaker])
        } catch {
            Log.audio.error("refreshMode failed: \(error.localizedDescription)")
        }
    }

    // Ducking is NOT done here, and that is the most important fact in this
    // file. It used to flip `.duckOthers` on and off by reconfiguring the
    // category at the edges of every sentence. Reconfiguring a live session
    // interrupts the audio graph other apps play through, so a podcast got a
    // small hitch at the start and end of every utterance and a long
    // conversation produced dozens of them — the same family as the old bug
    // that left `.duckOthers` on permanently and quietly degraded everything.
    //
    // Ducking now runs through Apple's voice processing, driven by LiveKit in
    // `LineManager.applyMusicPolicy`. The system lowers other audio while a
    // voice is present and lifts it when nobody is talking, with no category
    // changes at all. That is what FaceTime and SharePlay do, and it is why
    // they never leave your music sounding wrong.


    private func observe() {
        let centre = NotificationCenter.default
        centre.addObserver(forName: AVAudioSession.interruptionNotification,
                           object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                // A phone call takes the mic. Nothing to undo here any more —
                // the system owns ducking, so it lifts on its own — but the
                // session must be rebuilt when the call ends.
                break
            case .ended:
                self.configured = false
                self.configure()
            @unknown default: break
            }
        }
        centre.addObserver(forName: AVAudioSession.routeChangeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            // AirPods in or out changes which mode is correct.
            try? self.session.setCategory(.playAndRecord, mode: self.modeForCurrentRoute(),
                                          options: [.mixWithOthers, .allowBluetooth,
                                                    .allowBluetoothA2DP, .defaultToSpeaker])
            NotificationCenter.default.post(name: .audioRouteChanged, object: nil)
        }
        centre.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                           object: nil, queue: .main) { [weak self] _ in
            self?.configured = false
            self?.configure()
        }
    }
}

extension Notification.Name {
    static let audioRouteChanged = Notification.Name("opencomms.routeChanged")
}
