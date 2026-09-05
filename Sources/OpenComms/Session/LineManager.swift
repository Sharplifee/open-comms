import Foundation
import Combine
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
        case opening
        case open
        case failed(String)
    }

    @Published private(set) var phase: Phase = .closed
    @Published private(set) var squad: Squad?
    @Published private(set) var members: [Member] = []
    @Published private(set) var openedAt: Date?
    @Published var micLive = false
    @Published var banner: String?

    /// Everyone silenced at once, and for how long. Mute All is the version
    /// you undo yourself; Focus is the version that undoes itself, because in
    /// the middle of a heavy set you will not remember to turn it back on.
    @Published private(set) var mutedEveryone = false
    @Published private(set) var focusUntil: Date?

    private let room = Room()
    private let detector = VoiceDetector()

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
    private var heartbeat: Task<Void, Never>?
    private var store: Store { Store.shared }

    var elapsed: String {
        guard let openedAt else { return "" }
        let s = Int(Date().timeIntervalSince(openedAt))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    var talker: Member? { members.first { $0.isSpeaking && !$0.isSelf && !$0.mutedForMe } }
    var level: Double { detector.level }

    private override init() {
        super.init()
        room.add(delegate: self)
        detector.onChange = { [weak self] speaking in
            guard let self else { return }
            Task { @MainActor in self.localSpeech(speaking) }
        }
    }

    // MARK: - Opening and joining

    func open(code: String, name: String) async {
        await connect { [self] in
            try await Backend.shared.createSquad(code: code, name: name,
                                                 displayName: store.prefs.displayName)
        }
    }

    func join(code: String) async {
        await connect { [self] in
            try await Backend.shared.joinSquad(code: code, displayName: store.prefs.displayName)
        }
    }

    private func connect(_ work: () async throws -> Backend.JoinResult) async {
        guard Reachability.shared.online else {
            phase = .failed("You're offline. The line needs a connection.")
            return
        }
        phase = .opening
        do {
            let result = try await work()
            switch result.outcome {
            case .ok:
                guard let squad = result.squad else {
                    phase = .failed("The line opened but came back empty. Try again.")
                    return
                }
                try await enterRoom(squad)
            case .invalid:
                phase = .failed("Codes are three digits.")
            case .taken:
                phase = .failed("That code is somebody else's line right now. Pick another.")
            case .notFound:
                phase = .failed("No line on \(squad?.code ?? "that code") right now.")
            case .expired:
                phase = .failed("That line has already ended.")
            case .full:
                phase = .failed("That line is full.")
            case .rateLimited:
                let seconds = max(result.retryAfter, 1)
                phase = .failed("Too many tries. Give it \(seconds) seconds.")
            case .blocked:
                // Deliberately vague about who and in which direction. Naming
                // the person tells a blocked stranger exactly who blocked them,
                // and tells anybody who blocked somebody that the person is
                // standing on that line right now.
                phase = .failed("You can't join that line.")
            }
        } catch {
            // A timeout is the common case here, and it must say something a
            // person can act on rather than leaving them watching a spinner.
            phase = .failed("Couldn't reach the line. Nothing was lost — try again.")
        }
    }

    private func enterRoom(_ squad: Squad) async throws {
        let token = try await Backend.shared.livekitToken(squadID: squad.id,
                                                          displayName: store.prefs.displayName)
        applyNoiseSetting()
        applyMusicPolicy()
        AudioSession.shared.configure()
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

    private func teardown() async {
        heartbeat?.cancel(); heartbeat = nil
        detector.stop()
        restoreMusic?.cancel(); restoreMusic = nil
        focus?.cancel(); focus = nil
        focusUntil = nil
        mutedEveryone = false
        musicIsYielding = false
        MusicController.shared.restore()
        await room.disconnect()
        AudioSession.shared.deactivate()
        squad = nil; members = []; openedAt = nil; micLive = false
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
    func applyNoiseSetting() {
        do {
            try AudioManager.shared.setPlatformVoiceProcessingAllowed(store.prefs.cleanUpNoise)
        } catch {
            Log.audio.error("noise setting failed: \(error.localizedDescription)")
        }
    }

    /// How the music behaves is Apple's job, not ours.
    ///
    /// `isAdvancedDuckingEnabled` lowers other audio while a voice is actually
    /// present and lifts it the moment nobody is talking — the SharePlay
    /// behaviour — so there is nothing to flip on and off at the edges of a
    /// sentence and nothing left ducked if a line drops mid-word.
    func applyMusicPolicy() {
        AudioManager.shared.isAdvancedDuckingEnabled = store.prefs.music == .turnDown
        if #available(iOS 17, *) {
            AudioManager.shared.duckingLevel = store.prefs.music == .turnDown ? .default : .min
        }
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

    func blockAndReport(_ member: Member, reason: String) async {
        await Backend.shared.report(member.deviceID, squadID: squad?.id, reason: reason, detail: nil)
        blockedDevices.insert(member.deviceID)
        members.removeAll { $0.deviceID == member.deviceID }
        apply(volume: 0, to: member.deviceID)
        banner = "\(member.displayName) blocked and reported"
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
            MusicController.shared.speechBegan(store.prefs.music)
            return
        }

        guard musicIsYielding else { return }
        restoreMusic = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, let self else { return }
            self.musicIsYielding = false
            MusicController.shared.speechEnded(self.store.prefs.music)
        }
    }

    /// Also renews the line's expiry, so a line in genuine use never lapses
    /// mid-workout, and claims the host if whoever opened it has gone.
    private func startHeartbeat(_ squadID: String) {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                guard let self else { return }
                await Backend.shared.heartbeat(squadID: squadID)
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
            for index in members.indices where !members[index].isSelf {
                members[index].isSpeaking = speaking.contains(members[index].deviceID)
            }
            applyMusicBehaviour()
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant?,
                          didReceiveData data: Data, forTopic topic: String,
                          encryptionType: EncryptionType) {
        guard topic == LineManager.controlTopic,
              String(decoding: data, as: UTF8.self) == LineManager.endedMessage else { return }
        Task { @MainActor in
            guard phase == .open else { return }
            await teardown()
            banner = "The line was closed by whoever opened it"
            Cues.closed(store.prefs.soundCues)
        }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor in
            guard phase == .open else { return }
            banner = "Connection dropped. Reconnecting…"
        }
    }
}
