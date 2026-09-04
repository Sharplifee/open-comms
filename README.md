# open comms

An always-open voice line between workout partners. No push to talk, no call to
answer — say something and your squad hears it, over the top of whatever
they're already listening to.

## The shape of it

- **Three digit codes, chosen by you.** Short enough to call across a gym
  floor. The same squad uses the same code tomorrow.
- **Your music keeps playing.** Voices sit on top. One setting decides whether
  the track turns down, pauses and rewinds, or is left alone.
- **No account.** A display name is the entire signup.
- **One accent colour, and it only ever means audio is live.**

## Layout

| Path | What lives there |
|---|---|
| `Sources/OpenComms/App` | Entry point and the three launch gates |
| `Sources/OpenComms/Session` | Backend RPCs, the line, nearby, device identity |
| `Sources/OpenComms/Audio` | Session config, voice detection, music, cues |
| `Sources/OpenComms/UI` | Line, Squad, Settings, onboarding, keypad |
| `supabase/functions` | LiveKit token minting, with a membership check |

## Backend

Supabase project `tbgcinfhgskcjoevfkea`. Every table is closed to the anon
role; the app reaches the database only through SECURITY DEFINER functions, so
the rules are enforced rather than suggested.

## Notes worth keeping

- Background modes are **audio only**. VoIP push is deliberately absent: since
  iOS 13 every VoIP push must report a call to CallKit, and a walkie-talkie
  must not ring like a phone call.
- `.duckOthers` is never a permanent option and `.voiceChat` is never a
  permanent mode. That pairing degrades background audio even in silence.
- Location is stored as a last known position only, purged after 15 minutes,
  and never reverse geocoded. Distance and bearing are all the UI needs.
