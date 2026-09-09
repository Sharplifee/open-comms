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
    private var observing = false

    /// The moment we last changed the category ourselves. Setting a category
    /// posts a route-change notification exactly like unplugging headphones
    /// does, and the app was treating its own configure as an external event:
    /// configure → route change → restart the engine → engine touches the
    /// session → route change → restart … Each restart tore down and rebuilt
    /// the audio graph while the previous one was still settling, which is
    /// the glitching, and eventually one of those rebuilds hit a node in a
    /// state AVAudioEngine refuses, which is the crash.
    private(set) var lastSelfChange = Date.distantPast
    var justReconfigured: Bool { Date().timeIntervalSince(lastSelfChange) < 1.0 }

    private init() {}

    /// Whether to take the microphone from Bluetooth headphones.
    ///
    /// Off by default, and this is the single most important audio decision
    /// in the app. Using a Bluetooth headset's microphone means the
    /// hands-free profile, and HFP drops everything the headset plays — the
    /// music, the podcast, the other person — to telephone quality for as
    /// long as the mic is open. With it off, AirPods stay on A2DP at full
    /// quality and the phone's own microphone does the talking, which in a
    /// pocket or on a bench is quieter but does not wreck anything.
    var useHeadsetMic = false

    private var options: AVAudioSession.CategoryOptions {
        var o: AVAudioSession.CategoryOptions = [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker]
        if useHeadsetMic { o.insert(.allowBluetooth) }
        return o
    }

    func configure() {
        guard !configured else { return }
        do {
            lastSelfChange = Date()
            try session.setCategory(.playAndRecord,
                                    mode: modeForCurrentRoute(),
                                    options: options)
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
            // Once, not on every configure. This is called again after every
            // deactivate, interruption and media services reset, and each of
            // those was adding another copy of every observer — so a single
            // route change ran the handler as many times as the session had
            // ever been configured.
            if !observing { observe(); observing = true }
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
            lastSelfChange = Date()
            try session.setCategory(.playAndRecord, mode: modeForCurrentRoute(),
                                    options: options)
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
                // Only come back if the session was ours to begin with.
                // Reactivating after an interruption the app was not part of
                // would take audio away from whatever is playing now.
                guard self.configured else { break }
                self.configured = false
                self.configure()
            @unknown default: break
            }
        }
        centre.addObserver(forName: AVAudioSession.routeChangeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            guard let self, self.configured else { return }
            // Our own category change arrives here too. Ignore it, or this
            // handler re-applies the category, which posts another route
            // change, which lands here again.
            guard !self.justReconfigured else { return }
            // AirPods in or out changes which mode is correct — but only
            // touch the session if the mode actually differs, because
            // setting the same category again is itself a route change.
            if self.session.mode != self.modeForCurrentRoute() {
                self.lastSelfChange = Date()
                try? self.session.setCategory(.playAndRecord, mode: self.modeForCurrentRoute(),
                                              options: options)
            }
            NotificationCenter.default.post(name: .audioRouteChanged, object: nil)
        }
        centre.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                           object: nil, queue: .main) { [weak self] _ in
            guard let self, self.configured else { return }
            self.configured = false
            self.configure()
        }
    }
}

extension Notification.Name {
    static let audioRouteChanged = Notification.Name("opencomms.routeChanged")
}
