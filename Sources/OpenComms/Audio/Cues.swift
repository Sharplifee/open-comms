import AVFoundation

/// Short tones for the things you need to know without looking: the line
/// opened, somebody joined, it closed. Deliberately quiet and deliberately
/// short — this plays into somebody's music, so it has to be a signal rather
/// than an interruption.
enum Cues {
    static func opened(_ enabled: Bool) { play(1_113, enabled) }
    static func joined(_ enabled: Bool) { play(1_306, enabled) }
    static func closed(_ enabled: Bool) { play(1_112, enabled) }

    private static func play(_ id: SystemSoundID, _ enabled: Bool) {
        guard enabled else { return }
        AudioServicesPlaySystemSound(id)
    }
}
