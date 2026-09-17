import AVFoundation
import LiveKit

/// Answers "is the audio path actually working" on the device, in ten seconds,
/// without anybody else being on the line.
///
/// Every audio fault in this app so far has been reported the same way —
/// "I heard nothing" — and that one sentence covers at least five different
/// failures: the session never activated, it activated for capture but not
/// playback, the route went somewhere else, the remote track arrived muted, or
/// there was simply nobody talking. Guessing between them from a description
/// has cost days. This plays a tone through exactly the path a voice takes and
/// reports what every layer says about itself, so the answer comes back as
/// facts instead of adjectives.
@MainActor
final class SoundCheck: ObservableObject {
    static let shared = SoundCheck()

    @Published private(set) var running = false
    @Published private(set) var lines: [String] = []

    /// AVAudioPlayer, not AVAudioEngine, and that is deliberate.
    ///
    /// The whole point of this check is to prove the path a voice takes
    /// without disturbing it — and starting a second AVAudioEngine on a
    /// session LiveKit is already using is precisely the fight that broke
    /// playback in the first place. AVAudioPlayer renders through the session
    /// without claiming the engine, so the check is safe to run mid-line,
    /// which is exactly when somebody reaches for it.
    private var player: AVAudioPlayer?
    private init() {}

    /// Run it. Plays a short tone and collects what each layer reports.
    func run() async {
        guard !running else { return }
        running = true
        lines = []
        defer { running = false }

        let session = AVAudioSession.sharedInstance()

        // 1. What the session thinks it is.
        say("Category: \(session.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: ""))")
        say("Mode: \(session.mode.rawValue.replacingOccurrences(of: "AVAudioSessionMode", with: ""))")
        say("Options: \(describe(session.categoryOptions))")
        say("Sample rate: \(Int(session.sampleRate)) Hz · buffer \(Int(session.ioBufferDuration * 1000)) ms")

        // 2. Where sound is actually going and coming from. A route that says
        //    "Speaker" while AirPods are connected is the whole bug, visible.
        let out = session.currentRoute.outputs.first
        let input = session.currentRoute.inputs.first
        say("Output: \(out?.portName ?? "none") (\(out?.portType.rawValue ?? "—"))")
        say("Input: \(input?.portName ?? "none") (\(input?.portType.rawValue ?? "—"))")
        if out?.portType == .bluetoothHFP {
            say("⚠︎ Hands-free profile — everything sounds like a phone call")
        }

        // 3. Output volume. Silent because the ringer is down is a real
        //    answer and an embarrassing one to spend a day on.
        say("System volume: \(Int(session.outputVolume * 100))%")
        if session.outputVolume < 0.1 { say("⚠︎ Volume is almost off") }

        // 4. The tone. If this is inaudible, nothing else in the app will be
        //    audible either, and the fault is below LiveKit entirely.
        say(await playTone() ? "Tone played — did you hear it?" : "⚠︎ Tone failed to play")

        // 5. What LiveKit has, if a line is open.
        let line = LineManager.shared
        if let squad = line.squad {
            say("Line \(squad.code): \(line.members.count) on it")
            let remote = line.room.remoteParticipants.values
            if remote.isEmpty {
                say("Nobody else connected — nothing to hear yet")
            }
            for participant in remote {
                let name = participant.name ?? participant.identity?.stringValue ?? "someone"
                let tracks = participant.audioTracks
                if tracks.isEmpty {
                    say("\(name): no audio track published")
                    continue
                }
                for publication in tracks {
                    let subscribed = publication.isSubscribed ? "subscribed" : "NOT subscribed"
                    let muted = publication.isMuted ? ", muted" : ""
                    say("\(name): \(subscribed)\(muted)")
                }
            }
            say("Your mic: \(line.micLive ? "publishing" : "muted")")

            // 6. Is sound actually MOVING?
            //
            // Everything above can look perfect while nobody hears anything:
            // a track can be subscribed and carry silence, and a mic can be
            // publishing a dead input. So watch the levels for a couple of
            // seconds and say what they did. This is the difference between
            // "their audio never arrives" and "their audio arrives and this
            // phone will not play it" — two completely different faults that
            // feel identical when you are standing on a court.
            say("Listening for two seconds — talk now")
            var peaks: [String: Float] = [:]
            var localPeak: Float = 0
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(100))
                localPeak = max(localPeak, line.room.localParticipant.audioLevel)
                for participant in line.room.remoteParticipants.values {
                    let name = participant.name ?? participant.identity?.stringValue ?? "someone"
                    peaks[name] = max(peaks[name] ?? 0, participant.audioLevel)
                }
            }

            say(localPeak > 0.01
                ? "Your voice measured \(percent(localPeak)) — going out"
                : "⚠︎ Your voice measured nothing — the mic is not reaching the line")

            if peaks.isEmpty {
                say("No remote audio to measure")
            }
            for (name, peak) in peaks.sorted(by: { $0.key < $1.key }) {
                say(peak > 0.01
                    ? "\(name) measured \(percent(peak)) — arriving at this phone"
                    : "⚠︎ \(name) measured nothing — no sound is arriving from them")
            }
            if let loudest = peaks.values.max(), loudest > 0.01 {
                say("Audio is arriving. If you cannot hear it, the fault is playback, not the line.")
            }
        } else {
            say("No line open — this checks your own audio only")
        }
    }

    private func say(_ text: String) { lines.append(text) }

    private func percent(_ level: Float) -> String { "\(Int(level * 100))%" }

    /// A short, quiet, unmistakable tone through the shared session. Built on
    /// its own engine so it cannot disturb the line's audio, and stopped as
    /// soon as it has played.
    private func playTone() async -> Bool {
        guard let url = Self.toneFile else { return false }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            self.player = player
            player.volume = 0.9
            guard player.play() else { return false }
            try? await Task.sleep(for: .milliseconds(700))
            player.stop()
            self.player = nil
            return true
        } catch {
            say("⚠︎ Tone error: \(error.localizedDescription)")
            return false
        }
    }

    /// A half-second 880 Hz note, faded at both ends so it is a note rather
    /// than a click, written once as a WAV in the temporary directory.
    private static let toneFile: URL? = {
        let rate = 44_100.0, seconds = 0.5
        let frames = Int(rate * seconds)
        var samples = [Int16]()
        samples.reserveCapacity(frames)
        for i in 0..<frames {
            let t = Double(i) / rate
            let fade = min(1, min(t * 12, (seconds - t) * 12))
            samples.append(Int16(sin(2 * .pi * 880 * t) * 0.22 * max(0, fade) * 32_767))
        }

        var data = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        let payload = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append32(36 + payload)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append32(16)
        append16(1); append16(1)                       // PCM, mono
        append32(UInt32(rate)); append32(UInt32(rate) * 2)
        append16(2); append16(16)                      // block align, bit depth
        data.append(contentsOf: Array("data".utf8)); append32(payload)
        samples.forEach { withUnsafeBytes(of: $0.littleEndian) { data.append(contentsOf: $0) } }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("opencomms-tone.wav")
        do { try data.write(to: url); return url } catch { return nil }
    }()

    private func describe(_ options: AVAudioSession.CategoryOptions) -> String {
        var names: [String] = []
        if options.contains(.mixWithOthers) { names.append("mixWithOthers") }
        if options.contains(.duckOthers) { names.append("duckOthers ⚠︎") }
        if options.contains(.allowBluetooth) { names.append("allowBluetooth (HFP) ⚠︎") }
        if options.contains(.allowBluetoothA2DP) { names.append("A2DP") }
        if options.contains(.defaultToSpeaker) { names.append("defaultToSpeaker") }
        if options.contains(.allowAirPlay) { names.append("AirPlay") }
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }
}
