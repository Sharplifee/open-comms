import Foundation

/// What a coach says across a court, said without shouting.
///
/// Coaching happens at forty feet with a ball machine running. The coach ends
/// up shouting the same eight phrases all session, the player hears half of
/// them, and both of them lose the thread. These are those phrases, one tap
/// each: the words arrive spoken in the player's ear and land on their body
/// as a buzz, so nothing has to be repeated and nobody has to stop.
///
/// They are deliberately the short ones. Anything longer than a few words is
/// better said with your voice, and the line is already open for that.
enum CoachCue: String, Codable, CaseIterable, Identifiable {
    case again, reset, splitStep, tossHigher, followThrough, bendKnees
    case earlyPrep, moveFeet, slowDown, goodBall, lastOne, water, switchDrill, comeIn

    var id: String { rawValue }

    /// What the player hears. Spoken exactly as written, so it reads as
    /// somebody talking rather than a notification.
    var spoken: String {
        switch self {
        case .again:         return "Again"
        case .reset:         return "Reset"
        case .splitStep:     return "Split step"
        case .tossHigher:    return "Toss higher"
        case .followThrough: return "Finish the swing"
        case .bendKnees:     return "Bend your knees"
        case .earlyPrep:     return "Racket back early"
        case .moveFeet:      return "Move your feet"
        case .slowDown:      return "Slow it down"
        case .goodBall:      return "Good ball"
        case .lastOne:       return "Last one"
        case .water:         return "Water break"
        case .switchDrill:   return "Switching drill"
        case .comeIn:        return "Come in"
        }
    }

    /// What the coach reads on the button. Shorter than the spoken form,
    /// because a coach is glancing, not reading.
    var label: String {
        switch self {
        case .again:         return "Again"
        case .reset:         return "Reset"
        case .splitStep:     return "Split"
        case .tossHigher:    return "Toss ↑"
        case .followThrough: return "Finish"
        case .bendKnees:     return "Knees"
        case .earlyPrep:     return "Early"
        case .moveFeet:      return "Feet"
        case .slowDown:      return "Slower"
        case .goodBall:      return "Good"
        case .lastOne:       return "Last one"
        case .water:         return "Water"
        case .switchDrill:   return "Switch"
        case .comeIn:        return "Come in"
        }
    }

    var symbol: String {
        switch self {
        case .again:         return "arrow.clockwise"
        case .reset:         return "arrow.counterclockwise"
        case .splitStep:     return "figure.step.training"
        case .tossHigher:    return "arrow.up"
        case .followThrough: return "arrow.up.forward"
        case .bendKnees:     return "figure.flexibility"
        case .earlyPrep:     return "clock.arrow.circlepath"
        case .moveFeet:      return "figure.run"
        case .slowDown:      return "tortoise"
        case .goodBall:      return "hand.thumbsup.fill"
        case .lastOne:       return "flag.checkered"
        case .water:         return "drop.fill"
        case .switchDrill:   return "arrow.triangle.2.circlepath"
        case .comeIn:        return "arrow.down.to.line"
        }
    }

    /// Encouragement and housekeeping read differently from corrections, and
    /// a coach reaching for "water break" mid-rally should not have to hunt
    /// past six technical cues to find it.
    var isTechnical: Bool {
        switch self {
        case .goodBall, .lastOne, .water, .switchDrill, .comeIn: return false
        default: return true
        }
    }
}

/// What a player can say back without touching anything.
///
/// The player's phone is in a bag by the net post. They cannot tap it, which
/// is the whole reason the line stays open — but a coach mid-sentence does not
/// always want an answer out loud, and a player mid-drill cannot give one. So
/// these exist for the moments the player IS at the bench, and the rest of the
/// time their voice does the work.
enum PlayerReply: String, Codable, CaseIterable, Identifiable {
    case gotIt, again, oneMoment, needWater, doneIn

    var id: String { rawValue }

    var spoken: String {
        switch self {
        case .gotIt:     return "Got it"
        case .again:     return "Say that again"
        case .oneMoment: return "One moment"
        case .needWater: return "Need water"
        case .doneIn:    return "I'm done"
        }
    }

    var label: String {
        switch self {
        case .gotIt:     return "Got it"
        case .again:     return "Again?"
        case .oneMoment: return "One sec"
        case .needWater: return "Water"
        case .doneIn:    return "Done"
        }
    }

    var symbol: String {
        switch self {
        case .gotIt:     return "checkmark"
        case .again:     return "questionmark"
        case .oneMoment: return "hand.raised.fill"
        case .needWater: return "drop.fill"
        case .doneIn:    return "flag.checkered"
        }
    }
}

/// Which end of the session you are on. It only changes what is on the screen.
enum CourtRole: String, Codable, CaseIterable, Identifiable {
    case coach, player
    var id: String { rawValue }
    var title: String { self == .coach ? "Coaching" : "Playing" }
}
