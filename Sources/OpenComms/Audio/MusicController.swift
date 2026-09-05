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

    /// How far back to drop in when the track restarts after a pause.
    ///
    /// Nothing is missed while the music is paused — the track is exactly
    /// where it stopped — so the only reason to rewind at all is that coming
    /// back mid-word is jarring. A couple of seconds of run-up fixes that.
    private let reentryLead: TimeInterval = 3

    func speechBegan(_ behaviour: MusicBehaviour) {
        switch behaviour {
        case .turnDown:
            // Nothing to do. The system ducks other audio for as long as a
            // voice is present, so there is no edge for this app to act on.
            break
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
            break
        case .pauseAndRewind:
            guard pausedByUs else { return }
            pausedByUs = false
            // Rewind by a short run-up, NOT by how long the talking lasted.
            //
            // The old version backed up by the full length of the
            // conversation, which is the rule for music that kept playing —
            // and this music did not. It was paused, so the track sat exactly
            // where it stopped and nothing was missed. Backing up two minutes
            // after a two minute chat replayed two minutes somebody had
            // already heard, every single time.
            player.currentPlaybackTime = max(0, player.currentPlaybackTime - reentryLead)
            player.play()
        case .leaveAlone:
            break
        }
    }

    /// Belt and braces for the moment a line closes: nothing should be left
    /// ducked or paused by us.
    func restore() {
        if pausedByUs {
            pausedByUs = false
            player.currentPlaybackTime = max(0, player.currentPlaybackTime - reentryLead)
            player.play()
        }
    }
}
