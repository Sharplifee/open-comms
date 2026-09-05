import Foundation

/// What the server hands back when you try to get onto a line.
///
/// Every one of these is a distinct thing the person needs told in different
/// words. Collapsing them into a single `failed` is how you end up showing
/// "something went wrong" to somebody who simply mistyped one digit.
enum JoinOutcome: String, Codable {
    case ok, invalid, rateLimited = "rate_limited", notFound = "not_found"
    case expired, full, taken
    /// Somebody on that line is blocked, in one direction or the other. The
    /// server refuses at the door rather than letting you in and muting them,
    /// because a mute only lasts as long as the app stays open.
    case blocked
}

struct Squad: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    /// Three digits, chosen by the person who opened the line. Short enough to
    /// call across a gym floor and type without looking.
    var code: String
    var isHost: Bool
}

struct Member: Identifiable, Codable, Equatable {
    var id: String { deviceID }
    let deviceID: String
    var displayName: String
    var isSelf: Bool = false
    /// Muted here means muted for you only. They can still hear everyone else.
    var mutedForMe: Bool = false
    var volume: Double = 1.0
    var isSpeaking: Bool = false

    var initials: String {
        let cleaned = displayName.trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(2)).uppercased()
    }
}

struct NearbyPerson: Identifiable, Equatable {
    let id: String
    let displayName: String
    let metres: Double
    let bearing: Double

    var initials: String { String(displayName.prefix(2)).uppercased() }

    /// Feet up close, miles beyond. Nobody thinks in metres about the far end
    /// of a gym, and nobody thinks in feet about the next town.
    var distanceText: String {
        metres < 300 ? "\(Int(metres * 3.28084)) ft"
                     : String(format: "%.2f mi", metres / 1609.34)
    }

    var bearingText: String {
        let points = ["N","NE","E","SE","S","SW","W","NW"]
        let index = Int((bearing * 180 / .pi / 45).rounded()) % 8
        return points[(index + 8) % 8]
    }
}

/// What happens to your music while somebody is talking.
///
/// This replaced six separate controls — duck amount, auto pause, pause after,
/// auto rewind, rewind seconds, smart rewind. It is one decision with three
/// honest answers, and nobody has to understand what ducking means.
enum MusicBehaviour: String, Codable, CaseIterable {
    case turnDown, pauseAndRewind, leaveAlone

    var title: String {
        switch self {
        case .turnDown: return "Turn it down"
        case .pauseAndRewind: return "Pause and rewind"
        case .leaveAlone: return "Leave it alone"
        }
    }
    var detail: String {
        switch self {
        case .turnDown: return "Drops to about a third and comes back up when the talking stops"
        case .pauseAndRewind: return "Stops the track, then jumps back so you don't miss any"
        case .leaveAlone: return "Voices come in over the top at full volume"
        }
    }
}

/// Who can find you. Ghost mode and private sessions were two controls asking
/// the same question, so they are one control with three answers.
enum Visibility: String, Codable, CaseIterable {
    case visible, codeOnly, hidden

    var title: String {
        switch self {
        case .visible: return "Visible nearby"
        case .codeOnly: return "Code only"
        case .hidden: return "Hidden"
        }
    }
    var detail: String {
        switch self {
        case .visible: return "People with the app can see you and open a line"
        case .codeOnly: return "You stay off the radar. Lines start from a code you share."
        case .hidden: return "Nobody sees you, and your stored location is deleted"
        }
    }
}

/// How long incoming voices stay suppressed. Four fixed lengths rather than a
/// picker, because the whole point is one tap in the middle of a set.
enum FocusLength: Int, CaseIterable, Identifiable {
    case thirty = 30, sixty = 60, ninety = 90, twoMinutes = 120
    var id: Int { rawValue }
    var title: String { "\(rawValue) seconds" }
}

/// How hard the microphone is cleaned up before it goes out.
///
/// Two settings, not three, because there are only two genuinely different
/// things the phone can do: run WebRTC's software noise suppression, or hand
/// the capture to Apple's voice processing as well. A third notch would be a
/// switch that moved and changed nothing.
enum NoiseSuppression: String, Codable, CaseIterable {
    case low, high
    var title: String { self == .low ? "Low" : "High" }
    var detail: String {
        self == .low ? "Software cleanup only. Cleaner if you're somewhere quiet."
                     : "Apple's voice processing on top. Filters gym noise before it goes out."
    }
}

struct Preferences: Codable {
    var displayName = ""
    var music: MusicBehaviour = .turnDown
    var visibility: Visibility = .visible
    /// −55 dB to −12 dB. Low means a whisper opens the line.
    var sensitivity: Double = 0.55
    var noise: NoiseSuppression = .high
    var lowPower = false
    var soundCues = true
    /// Intercom volume — how loud everybody else comes through.
    var theirVolume: Double = 0.8
    /// A little of your own voice back in your ear, so you can tell you are
    /// coming through without shouting. Headphones only; on the speaker it
    /// would feed back.
    var selfMonitor: Double = 0.2
    /// How far the music drops while somebody is talking, as a fraction.
    var duckAmount: Double = 0.35
    /// If the talking runs longer than `pauseAfter` seconds, pause the track
    /// entirely instead of leaving it ducked.
    var autoPause = false
    var pauseAfter: Int = 8
    /// Jump back after a conversation so you don't miss anything.
    var autoRewind = true
    var rewindSeconds: Int = 20
    /// Which of the nine radar ranges is selected.
    var radiusIndex: Int = 2
    var lightTheme = false
    var onboarded = false

    /// The Home screen shows these as two switches because that is how people
    /// think about them. They are not two settings: hidden beats code-only,
    /// and both off means visible, so all three states stay reachable and no
    /// combination is contradictory.
    var ghostMode: Bool {
        get { visibility == .hidden }
        set { visibility = newValue ? .hidden : .visible }
    }
    var privateLine: Bool {
        get { visibility != .visible }
        set { if visibility != .hidden { visibility = newValue ? .codeOnly : .visible } }
    }

    static let ranges: [(label: String, metres: Double)] = [
        ("100 FT", 30.5), ("250 FT", 76.2), ("500 FT", 152.4), ("0.25 MI", 402.3),
        ("1 MI", 1609.3), ("5 MI", 8046.7), ("25 MI", 40233.6), ("100 MI", 160934.4),
        ("ANYWHERE", 20_000_000)
    ]
    var radiusMetres: Double { Preferences.ranges[min(max(radiusIndex, 0), 8)].metres }
    var radiusLabel: String { Preferences.ranges[min(max(radiusIndex, 0), 8)].label }

    var thresholdDB: Double { -55 + sensitivity * 43 }
    var sensitivityLabel: String {
        let names = ["Whisper","Soft","Low","Medium","Normal","Elevated","Loud","Very loud","Shout"]
        return names[min(names.count - 1, Int(sensitivity * 9))]
    }
}

/// A line you keep. Without this, the same two people re-share a fresh code
/// every single day, which is the most tedious thing about the old app.
struct SavedSquad: Identifiable, Codable, Equatable {
    var id: String { code }
    let code: String
    var name: String
    var lastUsed: Date
}
