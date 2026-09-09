import Foundation

/// Court mode's model: the score, who is serving, and the signals partners
/// send each other without speaking.
///
/// The signals are the reason this mode exists. Doubles partners already
/// communicate silently before every serve — the server's partner puts a hand
/// behind their back and shows a fist for "I'm poaching" or an open palm for
/// "staying". It works, and it is also the most awkward part of the sport for
/// anybody who has not played long enough to have agreed what the signs mean.
/// A tap that lands in your partner's ear and on their wrist says the same
/// thing, in words, and nobody has to learn a code.
enum PartnerSignal: String, Codable, CaseIterable, Identifiable {
    case poach, stay, switchSides, fake, iGotIt, yours, serveWide, serveT, serveBody

    var id: String { rawValue }

    var label: String {
        switch self {
        case .poach:       return "Poaching"
        case .stay:        return "Staying"
        case .switchSides: return "Switch"
        case .fake:        return "Fake it"
        case .iGotIt:      return "Mine"
        case .yours:       return "Yours"
        case .serveWide:   return "Wide"
        case .serveT:      return "Down the T"
        case .serveBody:   return "Body"
        }
    }

    var symbol: String {
        switch self {
        case .poach:       return "arrow.up.forward"
        case .stay:        return "figure.stand"
        case .switchSides: return "arrow.left.arrow.right"
        case .fake:        return "arrow.uturn.left"
        case .iGotIt:      return "hand.raised.fill"
        case .yours:       return "hand.point.right.fill"
        case .serveWide:   return "arrow.turn.up.right"
        case .serveT:      return "arrow.up"
        case .serveBody:   return "figure.tennis"
        }
    }

    /// Shown before the point, or during it. Splitting them keeps the row you
    /// need to hit in a hurry down to three buttons.
    var isPreServe: Bool {
        switch self {
        case .poach, .stay, .switchSides, .fake, .serveWide, .serveT, .serveBody: return true
        case .iGotIt, .yours: return false
        }
    }
}

/// Tennis scoring, kept honestly rather than approximately.
///
/// Points are 0/15/30/40, deuce needs two clear, and a tiebreak counts plainly
/// to seven. Nobody wants to argue with a scoreboard, so it is easier to undo
/// than to correct: every tap is reversible and the whole thing resets in one
/// press.
struct MatchScore: Codable, Equatable {
    /// Points in the current game, as raw counts — rendered as 15/30/40.
    var points: [Int] = [0, 0]
    /// Games in the current set.
    var games: [Int] = [0, 0]
    /// Completed sets.
    var sets: [Int] = [0, 0]
    /// 0 = us, 1 = them.
    var server: Int = 0
    /// Whether the current game is a tiebreak.
    var tiebreak = false
    /// Which side of the court you are standing on, for the diagram.
    var onDeuceSide = true

    private static let names = ["0", "15", "30", "40"]

    func display(_ side: Int) -> String {
        if tiebreak { return String(points[side]) }
        let mine = points[side], theirs = points[1 - side]
        if mine >= 3, theirs >= 3 {
            if mine == theirs { return "40" }
            return mine > theirs ? "AD" : "—"
        }
        return MatchScore.names[min(mine, 3)]
    }

    var isDeuce: Bool { !tiebreak && points[0] >= 3 && points[1] >= 3 && points[0] == points[1] }

    mutating func point(to side: Int) {
        points[side] += 1
        let mine = points[side], theirs = points[1 - side]

        if tiebreak {
            // First to seven, win by two, and the serve changes every two
            // points after the first.
            if mine >= 7, mine - theirs >= 2 { winGame(side) }
            else if (points[0] + points[1]) % 2 == 1 { server = 1 - server }
            return
        }

        if mine >= 4, mine - theirs >= 2 { winGame(side) }
    }

    private mutating func winGame(_ side: Int) {
        points = [0, 0]
        tiebreak = false
        games[side] += 1
        server = 1 - server

        let mine = games[side], theirs = games[1 - side]
        if mine >= 6, mine - theirs >= 2 {
            sets[side] += 1
            games = [0, 0]
        } else if mine == 6, theirs == 6 {
            tiebreak = true
        } else if mine == 7 {           // won the tiebreak
            sets[side] += 1
            games = [0, 0]
        }
    }

    /// Undo is a single step back through points only. A full rewind of games
    /// and sets is more machinery than an argument on court deserves — reset
    /// and re-enter is faster and less wrong.
    mutating func undoPoint(_ side: Int) {
        guard points[side] > 0 else { return }
        points[side] -= 1
    }

    mutating func reset() { self = MatchScore(server: server) }

    init(points: [Int] = [0, 0], games: [Int] = [0, 0], sets: [Int] = [0, 0],
         server: Int = 0, tiebreak: Bool = false, onDeuceSide: Bool = true) {
        self.points = points; self.games = games; self.sets = sets
        self.server = server; self.tiebreak = tiebreak; self.onDeuceSide = onDeuceSide
    }
}
