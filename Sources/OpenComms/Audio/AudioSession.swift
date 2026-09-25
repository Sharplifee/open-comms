import AVFoundation
import LiveKit

/// The audio session, configured once and then left alone.
///
/// This file is short on purpose, and every line in it is the result of
/// something that went wrong before.
///
/// `.mixWithOthers` is permanent, because the entire product is voices sitting
/// on top of music rather than replacing it.
///
/// `.duckOthers` is NEVER permanent. It goes on when somebody starts talking
/// and comes off when they stop. Left standing it holds every other app down
/// for the whole life of the line.
///
/// The mode is ALWAYS `.default`. `.voiceChat` engages Apple's Voice
/// Processing I/O, which is not a microphone feature — it reshapes everything
/// sharing the output into something distant and hollow, music included. That
/// was the "back room" sound, and it survived every other fix because nothing
/// else in the session undoes it. Echo cancellation for the speaker and the
/// car comes from WebRTC's software implementation instead, which works on the
/// captured microphone buffer alone and never touches playback.
///
/// Nothing here asks for a sample rate or a buffer size. Those reconfigure the
/// audio DEVICE, and a rate switch stops whatever is already playing.
@MainActor
final class AudioSession {
    static let shared = AudioSession()

    /// Whether the app has a live reason to hold the audio session — a line
    /// open, or the meter deliberately running. Set once by LineManager.
    ///
    /// Without this the app answered "yes, mine" to every interruption that
    /// ended, including the ones it caused by being in the foreground while
    /// somebody pressed play in another app.
    var wantsSession: () -> Bool = { false }
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

    /// The only route where using the far microphone costs anything.
    ///
    /// Bluetooth is the special case, not the general one. Taking a Bluetooth
    /// headset's microphone means the hands-free profile, and HFP drags
    /// everything that headset plays down to telephone quality. Nothing else
    /// works that way: CarPlay carries audio over USB or its own Wi-Fi link
    /// and exposes the car's microphone as a separate input, wired headsets
    /// have a real analogue mic, and the built-in speaker has the built-in
    /// mic. On all of those you get the near microphone AND full-quality
    /// playback at the same time, so there is nothing to trade.
    private var onBluetoothOutput: Bool {
        let bluetooth: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP]
        return session.currentRoute.outputs.contains { bluetooth.contains($0.portType) }
    }

    var onCarPlay: Bool {
        session.currentRoute.outputs.contains { $0.portType == .carAudio }
    }

    /// Whether other audio should be turned down right now. Set only while
    /// somebody is actually speaking.
    private var ducking = false

    /// Duck without Apple's voice processor.
    ///
    /// `.duckOthers` is a category option: it asks the system to lower other
    /// audio while this session is active, and it does not engage VPIO, so
    /// nothing is reprocessed and nothing loses quality — the music simply
    /// gets quieter and comes back. It is applied only while somebody is
    /// speaking, because left on permanently it holds every other app down
    /// for the whole life of the line.
    func setDucking(_ on: Bool) {
        guard configured, ducking != on else { return }
        ducking = on
        do {
            lastSelfChange = Date()
            try session.setCategory(.playAndRecord, mode: modeForCurrentRoute(), options: options)
        } catch {
            Log.audio.error("ducking change failed: \(error.localizedDescription)")
            ducking = !on
        }
    }

    var options: AVAudioSession.CategoryOptions {
        var o: AVAudioSession.CategoryOptions = [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker]
        if ducking { o.insert(.duckOthers) }
        // Only ask for HFP when the person has accepted what it costs, and
        // only when Bluetooth is actually the thing playing. Requesting it on
        // CarPlay or wired headphones would be asking for a downgrade that
        // buys nothing.
        if useHeadsetMic, onBluetoothOutput { o.insert(.allowBluetooth) }
        return o
    }

    /// Pick the microphone that belongs to whatever is playing.
    ///
    /// In a car this matters: the car's microphone is mounted near the
    /// driver's head and is the reason hands-free calling works at all, while
    /// the phone is usually face-down in a cup holder. iOS will not choose it
    /// on its own, so ask.
    private func chooseInput() {
        guard let inputs = session.availableInputs else { return }
        let wanted: AVAudioSession.Port? = {
            if onCarPlay { return .carAudio }
            if useHeadsetMic, onBluetoothOutput { return .bluetoothHFP }
            if session.currentRoute.outputs.contains(where: { $0.portType == .headphones }) {
                return .headsetMic
            }
            return nil          // built-in mic is the right answer otherwise
        }()
        guard let wanted, let port = inputs.first(where: { $0.portType == wanted }) else {
            try? session.setPreferredInput(nil)
            return
        }
        try? session.setPreferredInput(port)
    }

    /// The configuration LiveKit activates the session with.
    ///
    /// LiveKit owns activation — it is the only code that knows when its audio
    /// unit is starting and stopping — but its default configuration asks for
    /// the Bluetooth hands-free profile, which wrecks headphone quality. So it
    /// gets ours instead: the same options the rest of the app uses, without
    /// HFP unless the person asked for it, and a mode chosen for the route.
    ///
    /// `.default` is not negotiable here either — the mode travels with the
    /// configuration, so handing LiveKit a chat mode would re-engage the voice
    /// processor through the back door.
    static func livekitConfiguration() -> AudioSessionConfiguration {
        let shared = AudioSession.shared
        return AudioSessionConfiguration(category: .playAndRecord,
                                         categoryOptions: shared.options,
                                         mode: shared.modeForCurrentRoute())
    }

    func configure() {
        guard !configured else { return }
        do {
            lastSelfChange = Date()
            try session.setCategory(.playAndRecord,
                                    mode: modeForCurrentRoute(),
                                    options: options)
            // NOTHING about the hardware is requested here, and that is the
            // point.
            //
            // setPreferredSampleRate and setPreferredIOBufferDuration are not
            // requests about this app — they reconfigure the audio DEVICE,
            // which every app sharing it is then dragged through. Apple Music
            // plays 44.1 kHz; asking for 48 kHz forces the hardware to switch
            // rate, and a rate switch stops whatever is currently playing.
            // That is the "kicks my music into the background" behaviour, and
            // it happened on every single activation.
            //
            // Without them the session inherits whatever the device is
            // already doing. The voice line does not care — WebRTC resamples
            // internally regardless — and the person's music never notices
            // this app arrived.
            //
            // .notifyOthersOnDeactivation belongs on deactivation, not here.
            try session.setActive(true)
            chooseInput()
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
    /// What the session actually is right now, as opposed to what the app
    /// last asked for. When somebody says they can hear nothing, this is the
    /// difference between guessing and knowing.
    var liveDescription: String {
        let s = AVAudioSession.sharedInstance()
        var opts: [String] = []
        if s.categoryOptions.contains(.mixWithOthers) { opts.append("mix") }
        if s.categoryOptions.contains(.allowBluetooth) { opts.append("HFP") }
        if s.categoryOptions.contains(.allowBluetoothA2DP) { opts.append("A2DP") }
        if s.categoryOptions.contains(.defaultToSpeaker) { opts.append("spk") }
        let mode = s.mode.rawValue.replacingOccurrences(of: "AVAudioSessionMode", with: "")
        return "\(mode) · \(opts.joined(separator: "+"))"
    }

    var inputName: String {
        AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "none"
    }

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

    /// The mode this session runs in, on every route.
    ///
    /// It is always `.default`, and the body explains why at length: the
    /// alternative engages Apple's voice processor, which degrades everything
    /// sharing the output rather than just the microphone.
    func modeForCurrentRoute() -> AVAudioSession.Mode {
        // ALWAYS .default. Never .voiceChat — and this is the "back room" bug.
        //
        // .voiceChat engages Apple's Voice Processing I/O, and VPIO is not a
        // microphone feature. It takes over the whole output path: the music,
        // the podcast, the other person, all of it runs through echo
        // cancellation, hard gain control and a speech-shaped filter. That is
        // precisely the sound being described — distant, hollow, like it moved
        // to another room — and no category, option, buffer or route setting
        // undoes it while it is engaged.
        //
        // It was here for the speaker and the car, where a real echo path
        // exists between speaker and microphone. WebRTC has its own software
        // echo cancellation for exactly that, and it runs on the captured
        // microphone buffer alone without touching playback. So the speaker
        // still gets cancellation and everything the person is listening to
        // stays the quality its own app rendered.
        .default
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
                // Something else took the audio. That something is usually
                // the person opening Apple Music, and the app no longer
                // considers the session its own from this moment.
                self.configured = false
            case .ended:
                // THIS is what was killing the music.
                //
                // Starting Apple Music interrupts this session, and iOS then
                // posts .ended once the new owner has settled. The old code
                // treated that as "our turn again" and reactivated
                // .playAndRecord — which takes the route straight back and
                // stops the track the person just started. Every time. It did
                // not matter whether a line was open, because the only test
                // was whether the app had configured a session at some point.
                //
                // Two conditions now, both required. iOS has to actually ask
                // for a resume, and the app has to have a live reason to be
                // holding audio at all. Otherwise it stays out of the way and
                // the music keeps playing, which is the entire point of the
                // product.
                let raw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let invited = AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume)
                guard invited, self.wantsSession() else { break }
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
            // Getting into a car is a route change, and the car's microphone
            // only becomes available at that moment.
            self.chooseInput()
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
