import MediaPlayer

/// What happens to the person's music while somebody is talking.
///
/// Rewind only works for audio iOS lets another process seek — Apple Music,
/// Podcasts, Voice Memos. Spotify and YouTube run out of process and expose no
/// seek API, so it silently does nothing there. That is the accepted
/// behaviour, not a bug to keep chasing: failing quietly is better than
/// pausing somebody's podcast and being unable to put it back.
///
/// Ducking itself is not done here — Apple's voice processing lowers other
/// audio while a voice is present and lifts it when nobody is talking, driven
/// through LiveKit in `LineManager.applyMusicPolicy`. This file only owns the
/// things that need a real decision: pausing, and where to resume.
@MainActor
final class MusicController {
    static let shared = MusicController()
    private let player = MPMusicPlayerController.systemMusicPlayer

    private var pausedByUs = false
    private var pauseTimer: Task<Void, Never>?

    /// The saved settings, pushed in by `LineManager` so this file never has
    /// to know about the store.
    var autoPause = false
    var pauseAfter: TimeInterval = 8
    var autoRewind = true
    var rewindSeconds: TimeInterval = 20

    func speechBegan(_ behaviour: MusicBehaviour) {
        switch behaviour {
        case .turnDown:
            // The system is ducking. If the talking runs long, ducked music
            // is just noise under a conversation, so pause it outright after
            // the chosen number of seconds — and only then.
            guard autoPause else { return }
            pauseTimer?.cancel()
            pauseTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.pauseAfter ?? 8))
                guard !Task.isCancelled else { return }
                self?.pauseIfPlaying()
            }
        case .pauseAndRewind:
            pauseIfPlaying()
        case .leaveAlone:
            break
        }
    }

    func speechEnded(_ behaviour: MusicBehaviour) {
        pauseTimer?.cancel(); pauseTimer = nil
        switch behaviour {
        case .turnDown, .pauseAndRewind:
            resumeIfWePaused()
        case .leaveAlone:
            break
        }
    }

    /// Belt and braces for the moment a line closes: nothing should be left
    /// paused by us.
    func restore() {
        pauseTimer?.cancel(); pauseTimer = nil
        resumeIfWePaused()
    }

    private func pauseIfPlaying() {
        guard player.playbackState == .playing else { return }
        player.pause()
        pausedByUs = true
    }

    /// Where the track picks up is a setting, not a formula.
    ///
    /// The music was paused, so the track sits exactly where it stopped and
    /// nothing was missed; the rewind is a run-up so you do not land mid-word.
    /// With auto rewind off it resumes in place.
    private func resumeIfWePaused() {
        guard pausedByUs else { return }
        pausedByUs = false
        if autoRewind {
            player.currentPlaybackTime = max(0, player.currentPlaybackTime - rewindSeconds)
        }
        player.play()
    }
}
