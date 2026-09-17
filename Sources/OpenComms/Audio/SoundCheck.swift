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

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
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
        } else {
            say("No line open — this checks your own audio only")
        }
    }

    private func say(_ text: String) { lines.append(text) }

    /// A short, quiet, unmistakable tone through the shared session. Built on
    /// its own engine so it cannot disturb the line's audio, and stopped as
    /// soon as it has played.
    private func playTone() async -> Bool {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
        guard let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050) else { return false }
        buffer.frameLength = 22_050
        guard let samples = buffer.floatChannelData?[0] else { return false }
        // 880 Hz, faded in and out so it is a note rather than a click.
        for i in 0..<Int(buffer.frameLength) {
            let t = Double(i) / 44_100
            let fade = min(1, min(t * 12, (0.5 - t) * 12))
            samples[i] = Float(sin(2 * .pi * 880 * t) * 0.22 * max(0, fade))
        }

        if player.engine == nil { engine.attach(player) }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            return false
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
        player.play()
        try? await Task.sleep(for: .milliseconds(700))
        player.stop()
        engine.stop()
        return true
    }

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
