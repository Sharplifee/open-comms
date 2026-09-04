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
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            configured = true
            observe()
            Log.audio.info("audio session ready on \(self.routeName)")
        } catch {
            Log.audio.error("audio session failed: \(error.localizedDescription)")
        }
    }

    func deactivate() {
        configured = false
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    var routeName: String {
        session.currentRoute.outputs.first?.portName ?? "iPhone Speaker"
    }

    var onSpeaker: Bool {
        session.currentRoute.outputs.first?.portType == .builtInSpeaker
    }

    private func modeForCurrentRoute() -> AVAudioSession.Mode {
        onSpeaker ? .voiceChat : .default
    }

    /// Ducking is applied for the length of the speech and then removed. A
    /// failure to remove it is worse than never applying it, so restore runs
    /// on interruption and on route change too.
    func duck(_ on: Bool) {
        do {
            if on {
                try session.setCategory(.playAndRecord, mode: modeForCurrentRoute(),
                                        options: [.mixWithOthers, .allowBluetooth,
                                                  .allowBluetoothA2DP, .defaultToSpeaker, .duckOthers])
            } else {
                try session.setCategory(.playAndRecord, mode: modeForCurrentRoute(),
                                        options: [.mixWithOthers, .allowBluetooth,
                                                  .allowBluetoothA2DP, .defaultToSpeaker])
            }
        } catch {
            Log.audio.error("duck \(on) failed: \(error.localizedDescription)")
        }
    }

    private func observe() {
        let centre = NotificationCenter.default
        centre.addObserver(forName: AVAudioSession.interruptionNotification,
                           object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                // A phone call takes the mic. Drop ducking so the person's
                // music is not left quiet after the call ends.
                self.duck(false)
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
