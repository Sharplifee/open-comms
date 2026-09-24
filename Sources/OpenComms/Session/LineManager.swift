import Foundation
import Combine
import AVFoundation
import UIKit
import LiveKit

/// The state of the line, and everything that changes it.
///
/// One object owns this because the alternative — audio, backend and UI each
/// holding a piece — is how you end up muted on screen and live in the room.
@MainActor
final class LineManager: NSObject, ObservableObject {
    static let shared = LineManager()

    enum Phase: Equatable {
        case closed
        /// Kept for the reconnect path only. Opening a line no longer passes
        /// through it: the session appears immediately and `connecting`
        /// reports the handshake instead.
        case opening
        case open
        case failed(String)
    }

    @Published private(set) var phase: Phase = .closed
    @Published private(set) var squad: Squad?
    @Published private(set) var members: [Member] = []
    @Published private(set) var openedAt: Date?
    @Published var micLive = false
    /// A line of text at the top of the screen. Set it and it clears itself —
    /// a banner nothing dismisses is a banner that sits there for the rest of
    /// the session telling somebody about a thing that finished a minute ago.
    /// Reconnect messages are the exception and clear on success.
    @Published var banner: String?

    private var bannerTimer: Task<Void, Never>?

    func say(_ message: String, sticky: Bool = false) {
        banner = message
        bannerTimer?.cancel()
        guard !sticky else { return }
        bannerTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    /// Everyone silenced at once, and for how long. Mute All is the version
    /// you undo yourself; Focus is the version that undoes itself, because in
    /// the middle of a heavy set you will not remember to turn it back on.
    @Published private(set) var mutedEveryone = false
    @Published private(set) var focusUntil: Date?

    /// The line is on screen and usable; the server round trip and the LiveKit
    /// dial are still finishing. Shown as a thin line at the top of the
    /// session, never as something covering the screen.
    @Published private(set) var connecting = false

    /// Exposed read-only so the sound check can report what LiveKit actually
    /// has — subscribed tracks, mute states — rather than what the app thinks.
    let room = Room()
    /// Exposed so the meter can observe it directly. Reading `level` through
    /// this manager was a computed pass-through, and a computed property does
    /// not publish — the detector updated twenty times a second and the view
    /// never heard about it, so the meter sat still. Observing the detector
    /// itself also keeps those updates from repainting the whole screen.
    let detector = VoiceDetector()

    /// Everyone this device has blocked, loaded when a line opens. Held here
    /// so a block survives leaving and coming back — previously it lived only
    /// in the member list, so rejoining the same code made a blocked person
    /// audible again at full volume.
    private var blockedDevices: Set<String> = []

    /// Whether the music has already been asked to step aside. Ducking is a
    /// state, not an event: without this, overlapping speakers produce paired
    /// begin and end calls and the first person to stop restores the music
    /// while somebody else is still talking.
    private var musicIsYielding = false

    /// The pending un-duck. Held rather than fired immediately so a pause for
    /// breath does not bounce the music, and cancelled the moment anybody
    /// speaks again.
    private var restoreMusic: Task<Void, Never>?
    private var focus: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?
    private var silenceWatch: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var store: Store { Store.shared }

    var elapsed: String {
        guard let openedAt else { return "" }
        let s = Int(Date().timeIntervalSince(openedAt))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    var talker: Member? { members.first { $0.isSpeaking && !$0.isSelf && !$0.mutedForMe } }
    var level: Double { detector.level }
    var decibels: Double { detector.decibels }
    /// Whether you are talking. Off a line that is our own detector; on one it
    /// is LiveKit's, because by then LiveKit owns the microphone.
    var isSpeakingLocally: Bool { squad == nil ? detector.speaking : liveSpeaking }
    @Published private(set) var liveSpeaking = false

    /// Runs the meter before any line exists, so the mic card on Home is
    /// honest about how loud you need to be.
    /// Run the meter without being on a line, so somebody can see where their
    /// voice lands and set the marker.
    ///
    /// This is NEVER called just because a screen appeared. Touching
    /// `AVAudioEngine.inputNode` activates the shared audio session, and if
    /// the app has not set its category first that activation is a plain
    /// record session with no mixing — which stops whatever the person was
    /// listening to. Opening an app must not take somebody's podcast away.
    /// So: configure first, with .mixWithOthers, then start the engine, and
    /// only when the person asked for it.
    func startListeningOnly() {
        guard squad == nil else { return }
        // Tapping the mic when permission was refused, or never asked for,
        // used to do nothing at all — the meter simply stayed dead and there
        // was no way to tell why. Ask, and say so if the answer is no.
        guard AVAudioApplication.shared.recordPermission == .granted else {
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted { self.startListeningOnly() }
                    else { self.say("Microphone is off. Turn it on in Settings to use a line.") }
                }
            }
            return
        }
        // No line, so nothing else wants the session and this path owns it.
        AudioSession.shared.useHeadsetMic = store.prefs.useHeadsetMic
        applyNoiseSetting()
        AudioSession.shared.configure()
        detector.threshold = store.prefs.thresholdDB
        detector.selfMonitorGain = Float(store.prefs.selfMonitor)
        detector.start()
    }

    /// Give the audio system back when nobody is on a line, so other apps get
    /// their session and their quality back rather than sharing ours forever.
    func stopListeningOnly() {
        guard squad == nil else { return }
        detector.stop()
        AudioSession.shared.deactivate()
    }

    var isListening: Bool { detector.isListening }

    /// What audio is actually arriving, counted off the room rather than
    /// inferred from the member list. "Two people on the line and zero
    /// subscribed tracks" is the shape of one-way audio, and it should be
    /// readable on the phone rather than reasoned about afterwards.
    var incomingTracks: (subscribed: Int, playing: Int) {
        var subscribed = 0, playing = 0
        for participant in room.remoteParticipants.values {
            for publication in participant.audioTracks {
                if publication.isSubscribed { subscribed += 1 }
                // `isMuted` is the property Track actually exposes — a
                // subscribed track that is muted is subscribed and silent,
                // which is a different failure from not being subscribed at
                // all, and telling them apart is the point of this row.
                if let track = publication.track as? RemoteAudioTrack, !track.isMuted { playing += 1 }
            }
        }
        return (subscribed, playing)
    }

    private override init() {
        super.init()
        // Before anything else touches audio. Disallowing the platform voice
        // processor after a capture has already negotiated it means the first
        // line of the session still runs through it.
        try? AudioManager.shared.setPlatformVoiceProcessingAllowed(false)
        AudioManager.shared.isVoiceProcessingBypassed = true
        // LiveKit configures AVAudioSession itself when its engine starts, and
        // its default asks for `.allowBluetooth` — the Bluetooth hands-free
        // profile, which drops AirPods to telephone-grade mono for everything
        // they play. That is the "back room" sound.
        //
        // The previous attempt at this switched LiveKit's session management
        // OFF entirely. That fixed the quality and broke playback: LiveKit
        // also uses that path to activate the session for RENDERING, so with
        // it disabled the microphone still went out and nothing ever came
        // back — audio going one way, exactly as reported.
        //
        // The right answer is to keep LiveKit in charge of activation and
        // hand it OUR configuration to activate with. Same option set the app
        // uses everywhere else, minus HFP, plus a mode chosen for headphones.
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = true
        AudioManager.shared.audioSession.isAutomaticDeactivationEnabled = true
        // sessionConfiguration lives on AudioManager, not on the observer, and
        // it takes precedence over LiveKit's own dynamic choice. Set on the
        // manager it is a fixed override; the observer only exposes the
        // automatic switches.
        AudioManager.shared.sessionConfiguration = AudioSession.livekitConfiguration()
        room.add(delegate: self)
        detector.onChange = { [weak self] speaking in
            guard let self else { return }
            Task { @MainActor in self.localSpeech(speaking) }
        }
    }

    // MARK: - Opening and joining

    /// Everybody waiting to be let onto this line, refreshed while it is open.
    @Published private(set) var knocking: [RequestRow] = []
    private var knockWatch: Task<Void, Never>?

    /// The outcome of the last attempt, so the callers that pick a code
    /// themselves can tell a collision — which is their own dice roll and
    /// theirs to re-roll — from a refusal that should be shown to the person.
    /// A code somebody TYPED that comes back taken is real information and is
    /// never retried behind their back.
    private(set) var lastOutcome: JoinOutcome?

    func open(code: String, name: String) async {
        await connect(code: code, creating: true, name: name)
        // A public line has to be marked public and then watched, because from
        // that moment strangers can ask to get on it.
        if let squad, store.prefs.publicLine {
            await Backend.shared.setPublic(squad.id, isPublic: true)
            watchKnocks(squad.id)
        }
    }

    private func watchKnocks(_ squadID: String) {
        knockWatch?.cancel()
        knockWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.squad?.id == squadID else { return }
                self.knocking = await Backend.shared.pendingRequests(squadID)
                if !self.knocking.isEmpty { Haptics.tap(.light) }
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    /// Let somebody in, or turn them away. Yes hands them the code.
    func answer(_ request: RequestRow, grant: Bool) async {
        guard let squad else { return }
        await Backend.shared.answerRequest(squad.id, device: request.device_id, grant: grant)
        knocking.removeAll { $0.device_id == request.device_id }
        say(grant ? "\(request.display_name) is on the line" : "Turned \(request.display_name) away")
    }

    /// Ask to get onto somebody else's public line, then wait for the answer.
    /// Polling rather than pushing, because a person deciding takes seconds
    /// and a socket for that would be machinery nobody sees.
    func knock(on line: PublicLineRow) async {
        let outcome = await Backend.shared.askToJoin(line.squad_id, displayName: store.prefs.displayName)
        guard outcome == "asked" else {
            say(outcome == "rate_limited" ? "Too many tries — give it a moment."
                                          : "That line isn't open any more.")
            return
        }
        say("Asked \(line.host_name) to let you on")
        for _ in 0..<45 {
            try? await Task.sleep(for: .seconds(2))
            let answer = await Backend.shared.requestAnswer(line.squad_id)
            if answer == "waiting" { continue }
            if answer == "denied" { say("\(line.host_name) said no."); return }
            await join(code: answer)
            return
        }
        say("No answer from \(line.host_name).")
    }

    func join(code: String) async {
        await connect(code: code, creating: false, name: "Squad")
    }

    /// Open the line NOW, and do the network work behind it.
    ///
    /// This used to put a modal spinner over the whole app and hold it there
    /// for two round trips and a LiveKit dial. Nothing about that wait was
    /// information: the line either opens or it does not, and a person staring
    /// at "opening the line" cannot do anything with the sentence. So the
    /// session screen appears immediately with the code already on it, the
    /// work runs underneath, and the only thing that ever interrupts is an
    /// actual refusal.
    ///
    /// The optimism is cheap to unwind. If the server says no, the screen
    /// closes and says why; nothing was published to anybody in between.
    private func connect(code: String, creating: Bool, name: String) async {
        guard Reachability.shared.online else {
            phase = .failed("You're offline. The line needs a connection.")
            return
        }

        // Onboarding used to ask for the microphone before anything happened.
        // With that gone, this is the moment it is genuinely needed — and
        // asking here means the prompt arrives with an obvious reason
        // attached, which is when people say yes.
        if AVAudioApplication.shared.recordPermission == .undetermined {
            let granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard granted else {
                phase = .failed("OpenComms needs the microphone to open a line. Turn it on in Settings.")
                return
            }
        }

        // On screen instantly. `connecting` is what the session view uses to
        // show a thin line at the top rather than a wall in the middle.
        // Hand back anything the meter was holding before LiveKit takes over.
        detector.stop()
        AudioSession.shared.deactivate()

        squad = Squad(id: "", name: name, code: code, isHost: creating)
        members = [Member(deviceID: DeviceIdentity.id,
                          displayName: store.prefs.displayName.isEmpty ? "You" : store.prefs.displayName,
                          isSelf: true)]
        openedAt = Date()
        phase = .open
        connecting = true
        Haptics.tap()

        // The session is LiveKit's from here. It activates and deactivates
        // around its own audio unit, using the configuration handed to it in
        // init — so this path sets the inputs to that decision and then keeps
        // its hands off. Configuring it here as well is two owners for one
        // session, and the previous build proved what that costs: the
        // microphone went out and nothing came back.
        AudioSession.shared.useHeadsetMic = store.prefs.useHeadsetMic
        AudioManager.shared.sessionConfiguration = AudioSession.livekitConfiguration()
        applyNoiseSetting()
        applyMusicPolicy()

        do {
            let result = try await Backend.shared.openLine(
                code: code, creating: creating, name: name,
                displayName: store.prefs.displayName)

            lastOutcome = result.outcome
            guard result.outcome == .ok, let opened = result.squad, let token = result.token else {
                await abandon(refusal(result.outcome, retryAfter: result.retryAfter, code: code))
                return
            }
            squad = opened
            try await room.connect(url: Config.livekitURL, token: token)
            try await room.localParticipant.setMicrophone(enabled: true)

            connecting = false
            micLive = true
            store.remember(opened)
            blockedDevices = Set(await Backend.shared.blocked().map(\.device_id))
            applyChosenVolume()
            Cues.opened(store.prefs.soundCues)
            applyCourtRole()
            startHeartbeat(opened.id)
            watchForSilence(opened.id)
        } catch {
            await abandon("Couldn't reach the line. Nothing was lost — try again.")
        }
    }

    /// Roll the optimistic session back and say why.
    private func abandon(_ why: String) async {
        connecting = false
        detector.stop()
        squad = nil
        members = []
        openedAt = nil
        micLive = false
        phase = .failed(why)
    }

    private func refusal(_ outcome: JoinOutcome, retryAfter: Int, code: String) -> String {
        switch outcome {
        case .ok: return ""
        case .invalid: return "Codes are three digits."
        case .taken: return "That code is somebody else's line right now. Pick another."
        case .notFound: return "No line on \(code) right now."
        case .expired: return "That line has already ended."
        // There is no member cap any more, so this can only arrive from a
        // server older than the app. Saying "full" would be a lie about a
        // limit that no longer exists.
        case .full: return "That line isn't accepting anybody right now."
        case .rateLimited: return "Too many tries. Give it \(max(retryAfter, 1)) seconds."
        // Deliberately vague about who and in which direction. Naming the
        // person tells a blocked stranger exactly who blocked them, and tells
        // anybody who blocked somebody that the person is on that line now.
        case .blocked: return "You can't join that line."
        }
    }

    /// Get the room back after a drop, without disturbing what is on screen.
    ///
    /// A pocket, a lift, a dead spot in a basement — the connection goes and
    /// comes back a few seconds later, and the person should not have to
    /// notice. Backing off rather than hammering, because a phone with no
    /// signal retried in a tight loop just burns battery.
    ///
    /// Six attempts over about a minute and a half. Past that it is not a blip
    /// and pretending otherwise wastes the person's time, so the line closes
    /// and says so.
    private func beginReconnect(to squad: Squad) {
        guard reconnect == nil else { return }
        say("Connection dropped. Reconnecting…", sticky: true)
        reconnect = Task { [weak self] in
            for attempt in 0..<6 {
                try? await Task.sleep(for: .seconds(Double(1 << attempt)))
                guard let self, !Task.isCancelled, self.phase == .open else { return }
                guard Reachability.shared.online else { continue }
                do {
                    try await self.enterRoom(squad)
                    self.bannerTimer?.cancel()
                    self.banner = nil
                    self.reconnect = nil
                    Cues.opened(self.store.prefs.soundCues)
                    return
                } catch {
                    Log.audio.info("reconnect attempt \(attempt + 1) failed")
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.reconnect = nil
            await self.teardown()
            self.phase = .failed("Lost the line and couldn't get it back. Open it again when you have signal.")
        }
    }

    /// Used by the reconnect path, which already has a squad and only needs
    /// the room back.
    private func enterRoom(_ squad: Squad) async throws {
        let token = try await Backend.shared.livekitToken(squadID: squad.id,
                                                          displayName: store.prefs.displayName)
        AudioSession.shared.useHeadsetMic = store.prefs.useHeadsetMic
        AudioManager.shared.sessionConfiguration = AudioSession.livekitConfiguration()
        applyNoiseSetting()
        applyMusicPolicy()
        try await room.connect(url: Config.livekitURL, token: token)
        try await room.localParticipant.setMicrophone(enabled: true)

        self.squad = squad
        self.openedAt = Date()
        self.phase = .open
        self.micLive = true
        self.members = [Member(deviceID: DeviceIdentity.id,
                               displayName: store.prefs.displayName.isEmpty ? "You" : store.prefs.displayName,
                               isSelf: true)]
        store.remember(squad)
        detector.threshold = store.prefs.thresholdDB
        detector.selfMonitorGain = Float(store.prefs.selfMonitor)
        detector.start()
        blockedDevices = Set(await Backend.shared.blocked().map(\.device_id))
        applyChosenVolume()
        Cues.opened(store.prefs.soundCues)
        Haptics.tap()
        startHeartbeat(squad.id)
    }

    // MARK: - Leaving

    func leave() async {
        guard let squad else { return }
        await Backend.shared.leave(squadID: squad.id)
        await teardown()
        Cues.closed(store.prefs.soundCues)
    }

    func endForEveryone() async {
        guard let squad else { return }
        await Backend.shared.endLine(squadID: squad.id)
        // Tell the room before leaving it. Ending the line only closed the
        // row on the server and tore down the ender's own session — everybody
        // else stayed connected to a room that no longer existed, talking to
        // nobody, with an open line on screen and no way to find out. Nothing
        // else would have told them: the heartbeat only touches rows that are
        // still live, so it fails silently, and LiveKit has no reason to
        // disconnect a room whose participants are all still present.
        try? await room.localParticipant.publish(
            data: Data(Self.endedMessage.utf8),
            options: DataPublishOptions(topic: Self.controlTopic, reliable: true)
        )
        await teardown()
        Cues.closed(store.prefs.soundCues)
    }

    /// Control messages ride their own topic so they can never be confused
    /// with anything else the room might carry later.
    static let controlTopic = "opencomms.control"
    static let endedMessage = "line-ended"
    /// Court mode's silent signals and the shared score ride their own topic,
    /// so a future message type can never be mistaken for one of them.
    static let courtTopic = "opencomms.court"

    private func teardown() async {
        heartbeat?.cancel(); heartbeat = nil
        detector.stop()
        restoreMusic?.cancel(); restoreMusic = nil
        focus?.cancel(); focus = nil
        // Without this, leaving during a reconnect pulled the person straight
        // back into the line they had just left.
        reconnect?.cancel(); reconnect = nil
        silenceWatch?.cancel(); silenceWatch = nil
        focusUntil = nil
        mutedEveryone = false
        musicIsYielding = false
        MusicController.shared.restore()
        await room.disconnect()
        AudioSession.shared.deactivate()
        squad = nil; members = []; openedAt = nil; micLive = false; connecting = false
        Speaker.shared.stop()
        knockWatch?.cancel(); knockWatch = nil
        knocking = []
        liveSpeaking = false
        UIApplication.shared.isIdleTimerDisabled = false
        // Leaving a line means giving the audio system back. Holding a
        // playAndRecord session open after the last person has gone keeps
        // everybody else's audio sharing our configuration for no reason.
        AudioSession.shared.deactivate()
        phase = .closed
    }

    func dismissFailure() { phase = .closed }

    // MARK: - While the line is open

    func setMic(_ on: Bool) {
        micLive = on
        if !on, let index = members.firstIndex(where: { $0.isSelf }) {
            // Muting yourself stops YOU talking; it says nothing about the
            // other people on the line. Restoring the music unconditionally
            // here used to shove your track back to full volume in the middle
            // of somebody else's sentence.
            members[index].isSpeaking = false
        }
        applyMusicBehaviour()
        Task {
            try? await room.localParticipant.setMicrophone(enabled: on)
        }
        Haptics.tap(.light)
    }

    func setMuted(_ muted: Bool, for member: Member) {
        guard let index = members.firstIndex(where: { $0.deviceID == member.deviceID }) else { return }
        members[index].mutedForMe = muted
        applyChosenVolume()
        applyMusicBehaviour()
    }

    func setVolume(_ volume: Double, for member: Member) {
        guard let index = members.firstIndex(where: { $0.deviceID == member.deviceID }) else { return }
        members[index].volume = volume
        if !members[index].mutedForMe { apply(volume: volume, to: member.deviceID) }
    }

    // MARK: - Court mode

    /// The last thing that arrived from the other end, and when. Shown large
    /// for a few seconds and then let go — a cue is about the next ball, not
    /// something to keep.
    @Published private(set) var lastCue: (text: String, at: Date)?

    /// The two roles genuinely differ in one way that is not on the screen.
    ///
    /// A coach holds the phone and taps it every few balls, so it must not
    /// lock between cues — nothing is worse than waking a phone to say "split
    /// step". A player's phone is in a bag by the net post and should be left
    /// to sleep, because an hour of an awake screen in a bag is an hour of
    /// battery for nothing.
    func applyCourtRole() {
        let coaching = store.prefs.courtMode && store.prefs.courtRole == .coach && squad != nil
        UIApplication.shared.isIdleTimerDisabled = coaching
    }

    /// Say something to the other end without either of you breaking stride.
    ///
    /// It arrives three ways at once because a court is a bad place to rely
    /// on any one of them: spoken into their ear, felt as a buzz, and written
    /// large on the screen if they happen to look. A player forty feet away
    /// with a ball machine running gets the words; a coach who has just been
    /// answered gets the buzz.
    func speak(_ text: String) {
        guard squad != nil else { return }
        Haptics.tap(.rigid)
        Task {
            try? await room.localParticipant.publish(
                data: Data("say:\(text)".utf8),
                options: DataPublishOptions(topic: LineManager.courtTopic, reliable: true))
        }
    }

    fileprivate func receiveCourt(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        guard text.hasPrefix("say:") else { return }
        let words = String(text.dropFirst(4))
        guard !words.isEmpty else { return }
        lastCue = (words, Date())
        // Two short taps: unmistakably this app, and distinguishable from
        // every other buzz a phone makes during a session.
        Haptics.tap(.rigid)
        Task {
            try? await Task.sleep(for: .milliseconds(110))
            Haptics.tap(.rigid)
        }
        Speaker.shared.say(words)
    }

    /// Push the sensitivity slider into the running detector.
    ///
    /// The threshold was only read when a line opened, so moving the slider
    /// mid-workout changed the number on screen and nothing else until the
    /// next line. The whole point of that control is adjusting it while you
    /// are talking.
    /// Silence every incoming voice, or let them back in.
    func setMuteEveryone(_ on: Bool) {
        mutedEveryone = on
        applyChosenVolume()
        Haptics.tap(.light)
    }

    /// Suppress incoming voices for a fixed stretch and put them back without
    /// being asked. Cancelling is one tap, so nobody is stuck in it.
    func startFocus(_ length: FocusLength) {
        focus?.cancel()
        focusUntil = Date().addingTimeInterval(TimeInterval(length.rawValue))
        applyChosenVolume()
        focus = Task { [weak self] in
            try? await Task.sleep(for: .seconds(length.rawValue))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.endFocus() }
        }
        Haptics.tap()
    }

    func endFocus() {
        focus?.cancel(); focus = nil
        guard focusUntil != nil else { return }
        focusUntil = nil
        applyChosenVolume()
        Haptics.tap(.light)
    }

    var focusSecondsLeft: Int {
        guard let focusUntil else { return 0 }
        return max(0, Int(focusUntil.timeIntervalSinceNow.rounded(.up)))
    }

    func applySensitivity() {
        detector.threshold = store.prefs.thresholdDB
    }

    /// Noise cleanup belongs on the microphone, not on the session.
    ///
    /// Routing it through the session mode meant switching the whole graph to
    /// voice processing, which reshapes the music playing through it too. This
    /// asks LiveKit whether Apple's voice processing may be used for capture
    /// and leaves everybody else's audio alone either way.
    /// Which microphone, and whether the session gives up music quality for it.
    func applyMicSource() {
        AudioSession.shared.useHeadsetMic = store.prefs.useHeadsetMic
        AudioSession.shared.refreshMode()
    }

    /// Apple's Voice Processing I/O is never used, and this is the fix for the
    /// "everything sounds like it moved to a back room" complaint.
    ///
    /// VPIO is a telephony processor. When it is engaged, EVERYTHING sharing
    /// the output — the music, the podcast, the other person — goes through
    /// echo cancellation, aggressive gain control and a speech-shaped filter.
    /// That is what makes a track suddenly sound distant, hollow and thin. No
    /// category, mode, buffer or route setting undoes it while it is on,
    /// which is why every previous attempt left the symptom untouched.
    ///
    /// LiveKit falls back to WebRTC's own SOFTWARE echo cancellation, which
    /// runs on the captured microphone buffer alone and never touches
    /// playback. The person on the other end still gets a clean signal; the
    /// music stays exactly as its own app rendered it.
    func applyNoiseSetting() {
        do {
            // Disallow the platform path outright, rather than leaving it to
            // whatever the next capture negotiates.
            try AudioManager.shared.setPlatformVoiceProcessingAllowed(false)
            AudioManager.shared.isVoiceProcessingBypassed = true
        } catch {
            Log.audio.error("could not disable voice processing: \(error.localizedDescription)")
        }
    }

    /// Ducking is off, and that is deliberate.
    ///
    /// LiveKit's ducking controls are Apple's ducking controls — they only do
    /// anything while Apple's voice processing is running, because that is the
    /// thing performing the duck. Asking for ducking therefore asks for VPIO,
    /// and VPIO is exactly what was wrecking the music. The two cannot both be
    /// had: system ducking costs the quality of everything you are listening
    /// to, for as long as the line is open.
    ///
    /// So the line arrives over the top at full quality and the music stays
    /// full quality behind it, which is how a conversation in a room actually
    /// works. "Pause and rewind" still does exactly what it says, because that
    /// is this app pausing a track rather than the system reprocessing one.
    func applyMusicPolicy() {
        AudioManager.shared.isAdvancedDuckingEnabled = false
        if #available(iOS 17, *) {
            AudioManager.shared.duckingLevel = .min
        }
        let prefs = store.prefs
        MusicController.shared.autoPause = prefs.autoPause
        MusicController.shared.pauseAfter = TimeInterval(prefs.pauseAfter)
        MusicController.shared.autoRewind = prefs.autoRewind
        MusicController.shared.rewindSeconds = TimeInterval(prefs.rewindSeconds)
    }

    /// Push the self-monitor level into the running detector. Headphones only;
    /// the detector refuses it on the speaker because that path is feedback.
    func applySelfMonitor() {
        detector.selfMonitorGain = Float(store.prefs.selfMonitor)
    }

    /// Apply the "how loud they are" slider to everyone currently on the line.
    /// The single place that decides how loud a remote voice actually is.
    ///
    /// Four things can silence somebody — the intercom slider, muting them,
    /// Mute All and Focus — and when each of them applied its own volume
    /// directly they overwrote each other: unmuting one person undid Focus,
    /// and leaving Focus restored somebody you had muted an hour ago.
    func applyChosenVolume() {
        let chosen = store.prefs.theirVolume
        let silenced = mutedEveryone || focusUntil != nil
        for index in members.indices where !members[index].isSelf {
            members[index].volume = chosen
            if blockedDevices.contains(members[index].deviceID) {
                members[index].mutedForMe = true
            }
            let audible = !silenced && !members[index].mutedForMe
            apply(volume: audible ? chosen : 0, to: members[index].deviceID)
        }
    }

    /// How everyone else's loudness is actually controlled — per remote track,
    /// not by touching the system volume, which belongs to the music.
    private func apply(volume: Double, to identity: String) {
        for participant in room.remoteParticipants.values
        where participant.identity?.stringValue == identity {
            for publication in participant.audioTracks {
                guard let track = publication.track as? RemoteAudioTrack else { continue }
                track.volume = volume
            }
        }
    }

    /// What is actually arriving from the other end, in plain terms.
    ///
    /// The one-way-audio failure was invisible from inside the app: the line
    /// said "connected", the microphone was going out, and nothing came back.
    /// Every fact needed to tell those apart was available and none of it was
    /// on screen. This is that, so the next time it happens the answer takes
    /// five seconds instead of a day.
    var incomingReport: (tracks: Int, subscribed: Int, audible: Int, muted: Int) {
        var tracks = 0, subscribed = 0, audible = 0, muted = 0
        for participant in room.remoteParticipants.values {
            for publication in participant.audioTracks {
                tracks += 1
                if publication.isSubscribed { subscribed += 1 }
                if publication.isMuted { muted += 1 }
                if let track = publication.track as? RemoteAudioTrack, track.volume > 0.001 {
                    audible += 1
                }
            }
        }
        return (tracks, subscribed, audible, muted)
    }

    func blockAndReport(_ member: Member, reason: String) async {
        await Backend.shared.report(member.deviceID, squadID: squad?.id, reason: reason, detail: nil)
        blockedDevices.insert(member.deviceID)
        members.removeAll { $0.deviceID == member.deviceID }
        apply(volume: 0, to: member.deviceID)
        say("\(member.displayName) blocked and reported")
    }

    private func localSpeech(_ speaking: Bool) {
        guard micLive else { return }
        if let index = members.firstIndex(where: { $0.isSelf }) {
            members[index].isSpeaking = speaking
        }
        applyMusicBehaviour()
    }

    /// Get out of the way whenever ANYBODY on the line is talking.
    ///
    /// The music only moved when you spoke. The entire product is hearing
    /// somebody else over your music, and that was the one case that did
    /// nothing: your partner talked, your track carried on at full volume,
    /// and you heard them underneath it.
    ///
    /// Driven from a single computed state rather than per-event, because two
    /// people talking over each other produced overlapping begin and end
    /// pairs — one person stopping restored the music while the other was
    /// still mid-sentence.
    private func applyMusicBehaviour() {
        let anyoneTalking = members.contains { member in
            guard member.isSpeaking else { return false }
            // Somebody muted for you is not talking as far as your music is
            // concerned — you cannot hear them, so there is nothing to make
            // room for.
            return member.isSelf || !member.mutedForMe
        }
        // Going quiet is held for a beat; going loud is immediate.
        //
        // Ducking works by reconfiguring the audio session, so every
        // transition is a real cost, and the gap between two sentences is
        // shorter than the gap between two conversations. Without the hold,
        // a normal back-and-forth flapped the music up and down between every
        // breath — the audible version of the same bug that made a permanent
        // .duckOthers so tempting in the first place.
        restoreMusic?.cancel(); restoreMusic = nil

        if anyoneTalking {
            guard !musicIsYielding else { return }
            musicIsYielding = true
            if store.prefs.music == .turnDown { AudioSession.shared.setDucking(true) }
            MusicController.shared.speechBegan(store.prefs.music)
            return
        }

        guard musicIsYielding else { return }
        restoreMusic = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, let self else { return }
            self.musicIsYielding = false
            AudioSession.shared.setDucking(false)
            MusicController.shared.speechEnded(self.store.prefs.music)
        }
    }

    /// Also renews the line's expiry, so a line in genuine use never lapses
    /// mid-workout, and claims the host if whoever opened it has gone.
    /// Notice a line that is up but silent, and fix it without being asked.
    ///
    /// The failure Connor hit looked exactly like this from the inside:
    /// somebody else on the line, their track subscribed, and nothing coming
    /// out — audio going one way. Every layer reported success, which is why
    /// it took three builds to find. The condition is cheap to detect, so the
    /// app should detect it rather than wait for somebody to describe it.
    ///
    /// Two attempts, escalating. First re-apply the volumes, which fixes a
    /// track that arrived at zero. If it is still silent, unsubscribe and
    /// resubscribe the track — the WebRTC-level version of turning it off and
    /// on again, and the only thing short of rejoining that rebuilds the
    /// receiving path.
    private func watchForSilence(_ squadID: String) {
        silenceWatch?.cancel()
        silenceWatch = Task { [weak self] in
            var strikes = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6))
                guard let self, self.squad?.id == squadID else { return }

                let tracks = self.incomingTracks
                // Nobody else here, or nothing subscribed yet, is not silence
                // — it is an empty room, and there is nothing to repair.
                guard tracks.subscribed > 0 else { strikes = 0; continue }
                guard tracks.playing == 0 else { strikes = 0; continue }

                strikes += 1
                if strikes == 1 {
                    Log.audio.error("line is silent — reapplying volumes")
                    self.applyChosenVolume()
                } else if strikes >= 2 {
                    Log.audio.error("line still silent — resubscribing")
                    await self.resubscribeEverybody()
                    strikes = 0
                }
            }
        }
    }

    private func resubscribeEverybody() async {
        for participant in room.remoteParticipants.values {
            for publication in participant.audioTracks {
                guard let remote = publication as? RemoteTrackPublication else { continue }
                try? await remote.set(subscribed: false)
                try? await Task.sleep(for: .milliseconds(250))
                try? await remote.set(subscribed: true)
            }
        }
        applyChosenVolume()
    }

    private func startHeartbeat(_ squadID: String) {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                guard let self else { return }
                let alive = await Backend.shared.heartbeat(squadID: squadID)
                // The end-of-line broadcast only reaches a phone that is
                // connected. One that was asleep, or briefly offline, would
                // otherwise sit on a line that no longer exists showing a code
                // nobody can join. The heartbeat is the backstop.
                if !alive {
                    await self.teardown()
                    self.say("That line has ended.")
                    return
                }
                if self.squad?.isHost == false, self.members.count == 1 {
                    await Backend.shared.claimHost(squadID: squadID)
                }
            }
        }
    }
}

// MARK: - Room events

extension LineManager: RoomDelegate {
    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor in
            let id = participant.identity?.stringValue ?? UUID().uuidString
            guard !members.contains(where: { $0.deviceID == id }) else { return }
            // Somebody arriving mid-line must land at the volume you already
            // chose. Before this, the slider only applied to whoever was
            // already in the room, so every new joiner came in at full volume
            // and you had to nudge the control to fix a setting you had
            // already set.
            let chosen = Store.shared.prefs.theirVolume
            // The server refuses a blocked person at the door, but a block
            // made while both of you are already on a line has to take hold
            // without waiting for anybody to rejoin.
            let isBlocked = blockedDevices.contains(id)
            members.append(Member(deviceID: id,
                                  displayName: participant.name ?? "Someone",
                                  mutedForMe: isBlocked,
                                  volume: chosen))
            apply(volume: isBlocked ? 0 : chosen, to: id)
            Cues.joined(Store.shared.prefs.soundCues)
            Haptics.tap(.light)
        }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        Task { @MainActor in
            let id = participant.identity?.stringValue
            members.removeAll { $0.deviceID == id }
            // If everyone else has gone, this device owns the line now.
            if let squadID = squad?.id { await Backend.shared.claimHost(squadID: squadID) }
        }
    }

    nonisolated func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        Task { @MainActor in
            let speaking = Set(participants.compactMap { $0.identity?.stringValue })
            // Includes you. Our own voice detector has handed the microphone
            // to LiveKit by this point, so LiveKit's measurement of the
            // published track is the only honest source for whether you are
            // talking — and it is the same signal everybody else is hearing.
            for index in members.indices {
                members[index].isSpeaking = speaking.contains(members[index].deviceID)
            }
            liveSpeaking = speaking.contains(DeviceIdentity.id)
            applyMusicBehaviour()
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant?,
                          didReceiveData data: Data, forTopic topic: String,
                          encryptionType: EncryptionType) {
        if topic == LineManager.courtTopic {
            Task { @MainActor in receiveCourt(data) }
            return
        }
        guard topic == LineManager.controlTopic,
              String(decoding: data, as: UTF8.self) == LineManager.endedMessage else { return }
        Task { @MainActor in
            guard phase == .open else { return }
            await teardown()
            say("The line was closed by whoever opened it")
            Cues.closed(store.prefs.soundCues)
        }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor in
            guard phase == .open, let squad else { return }
            // This used to set a banner saying "reconnecting…" and then do
            // nothing at all. The line stayed dead and the message stayed on
            // screen, which is worse than saying nothing: it told somebody to
            // keep waiting for a thing that was never going to happen.
            beginReconnect(to: squad)
        }
    }
}
