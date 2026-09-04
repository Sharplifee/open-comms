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

    private let room = Room()
    private let detector = VoiceDetector()
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
        AudioSession.shared.cleanUpNoise = store.prefs.cleanUpNoise
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
        await teardown()
        Cues.closed(store.prefs.soundCues)
    }

    private func teardown() async {
        heartbeat?.cancel(); heartbeat = nil
        detector.stop()
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
        Task {
            try? await room.localParticipant.setMicrophone(enabled: on)
            if !on { MusicController.shared.restore() }
        }
        Haptics.tap(.light)
    }

    func setMuted(_ muted: Bool, for member: Member) {
        guard let index = members.firstIndex(where: { $0.deviceID == member.deviceID }) else { return }
        members[index].mutedForMe = muted
        apply(volume: muted ? 0 : members[index].volume, to: member.deviceID)
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
    func applySensitivity() {
        detector.threshold = store.prefs.thresholdDB
    }

    /// Push the noise setting into the audio session while a line is live.
    func applyNoiseSetting() {
        AudioSession.shared.cleanUpNoise = store.prefs.cleanUpNoise
        AudioSession.shared.refreshMode()
    }

    /// Apply the "how loud they are" slider to everyone currently on the line.
    func applyChosenVolume() {
        let chosen = store.prefs.theirVolume
        for index in members.indices where !members[index].isSelf {
            members[index].volume = chosen
            if !members[index].mutedForMe {
                apply(volume: chosen, to: members[index].deviceID)
            }
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
        members.removeAll { $0.deviceID == member.deviceID }
        apply(volume: 0, to: member.deviceID)
        banner = "\(member.displayName) blocked and reported"
    }

    private func localSpeech(_ speaking: Bool) {
        guard micLive else { return }
        if speaking {
            MusicController.shared.speechBegan(store.prefs.music)
        } else {
            MusicController.shared.speechEnded(store.prefs.music)
        }
        if let index = members.firstIndex(where: { $0.isSelf }) {
            members[index].isSpeaking = speaking
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
            members.append(Member(deviceID: id,
                                  displayName: participant.name ?? "Someone",
                                  volume: chosen))
            apply(volume: chosen, to: id)
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
        }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor in
            guard phase == .open else { return }
            banner = "Connection dropped. Reconnecting…"
        }
    }
}
