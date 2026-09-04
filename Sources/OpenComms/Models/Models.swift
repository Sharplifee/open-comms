import Foundation

/// What the server hands back when you try to get onto a line.
///
/// Every one of these is a distinct thing the person needs told in different
/// words. Collapsing them into a single `failed` is how you end up showing
/// "something went wrong" to somebody who simply mistyped one digit.
enum JoinOutcome: String, Codable {
    case ok, invalid, rateLimited = "rate_limited", notFound = "not_found"
    case expired, full, taken
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

struct Preferences: Codable {
    var displayName = ""
    var music: MusicBehaviour = .turnDown
    var visibility: Visibility = .visible
    /// −55 dB to −12 dB. Low means a whisper opens the line.
    var sensitivity: Double = 0.55
    var hearYourself = true
    var cleanUpNoise = true
    var lowPower = false
    var soundCues = true
    var theirVolume: Double = 0.8
    var onboarded = false

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
