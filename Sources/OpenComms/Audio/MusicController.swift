import MediaPlayer

/// What happens to the person's music while somebody is talking.
///
/// Rewind only works for audio iOS lets another process seek — Apple Music,
/// Podcasts, Voice Memos. Spotify and YouTube run out of process and expose no
/// seek API, so it silently does nothing there. That is the accepted
/// behaviour, not a bug to keep chasing: failing quietly is better than
/// pausing somebody's podcast and being unable to put it back.
@MainActor
final class MusicController {
    static let shared = MusicController()
    private let player = MPMusicPlayerController.systemMusicPlayer

    private var pausedByUs = false
    private var talkStarted: Date?

    func speechBegan(_ behaviour: MusicBehaviour) {
        talkStarted = Date()
        switch behaviour {
        case .turnDown:
            AudioSession.shared.duck(true)
        case .pauseAndRewind:
            if player.playbackState == .playing {
                player.pause()
                pausedByUs = true
            }
        case .leaveAlone:
            break
        }
    }

    func speechEnded(_ behaviour: MusicBehaviour) {
        switch behaviour {
        case .turnDown:
            AudioSession.shared.duck(false)
        case .pauseAndRewind:
            guard pausedByUs else { return }
            pausedByUs = false
            // Back up by however long the talking lasted, plus a couple of
            // seconds, because the last thing said before you started
            // listening is usually the part you wanted.
            let spoken = Date().timeIntervalSince(talkStarted ?? Date())
            player.currentPlaybackTime = max(0, player.currentPlaybackTime - (spoken + 2))
            player.play()
        case .leaveAlone:
            break
        }
        talkStarted = nil
    }

    /// Belt and braces for the moment a line closes: nothing should be left
    /// ducked or paused by us.
    func restore() {
        AudioSession.shared.duck(false)
        if pausedByUs { player.play(); pausedByUs = false }
    }
}
