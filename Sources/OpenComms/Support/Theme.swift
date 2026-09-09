import SwiftUI

/// Which skin the app is wearing.
///
/// Skins change colour and nothing else. Every screen, control and behaviour
/// is identical across them — that is the point, and it is why this is a
/// palette rather than a second set of views. A skin that forked the UI would
/// be a second app to maintain and a second app to break.
enum Skin: String, Codable, CaseIterable, Identifiable {
    /// The default: graphite with one sodium-yellow accent.
    case dark
    /// The same layout on paper-white, for bright sun.
    case light
    /// Championship green and cream, the way a grass-court tournament dresses
    /// itself: dark green surfaces, a white line, and the accent borrowed from
    /// the ball rather than from a logo.
    case court

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark:  return "Dark"
        case .light: return "Light"
        case .court: return "Court"
        }
    }

    /// Shown on the header pill.
    var badge: String {
        switch self {
        case .dark:  return "Dark"
        case .light: return "Light"
        case .court: return "Court"
        }
    }

    var next: Skin {
        switch self {
        case .dark:  return .light
        case .light: return .court
        case .court: return .dark
        }
    }
}

/// One accent, and it means exactly one thing: audio is live right now.
///
/// The temptation is to use it for anything important — buttons, the selected
/// tab, headings — and the moment that happens a glance mid-set stops
/// answering "is anyone talking". Everything else is the neutral.
enum Theme {
    /// Flipped by the header pill. Read on every access rather than cached,
    /// so a view that re-renders for any reason picks the right palette up.
    /// Every screen observes the store, so toggling re-renders all of them.
    nonisolated(unsafe) static var skin: Skin = .dark

    static var base: Color {
        switch skin {
        case .dark:  return Color(hex: 0x14161A)
        case .light: return Color(hex: 0xEDE9E1)
        // Not black and not a mid green: the deep bottle green a grass-court
        // scoreboard uses, dark enough that the ball colour is the only bright
        // thing on the screen.
        case .court: return Color(hex: 0x0C3B2A)
        }
    }

    static var surface: Color {
        switch skin {
        case .dark:  return Color(hex: 0x1C1F25)
        case .light: return Color(hex: 0xE4DFD5)
        case .court: return Color(hex: 0x11533A)
        }
    }

    static var raised: Color {
        switch skin {
        case .dark:  return Color(hex: 0x232730)
        case .light: return Color(hex: 0xD9D3C7)
        case .court: return Color(hex: 0x176847)
        }
    }

    static var line: Color {
        switch skin {
        case .dark:  return Color(hex: 0x2E333D)
        case .light: return Color(hex: 0xCFC8BB)
        // The court line. Chalk, not grey.
        case .court: return Color(hex: 0x2E7C58)
        }
    }

    static var text: Color {
        switch skin {
        case .dark:  return Color(hex: 0xF2F3F5)
        case .light: return Color(hex: 0x14161A)
        case .court: return Color(hex: 0xF6F4EC)
        }
    }

    static var muted: Color {
        switch skin {
        case .dark:  return Color(hex: 0x8A909C)
        case .light: return Color(hex: 0x6E6A62)
        case .court: return Color(hex: 0x9DC3AF)
        }
    }

    static var dim: Color {
        switch skin {
        case .dark:  return Color(hex: 0x5A616D)
        case .light: return Color(hex: 0x9A958B)
        case .court: return Color(hex: 0x6C9B84)
        }
    }

    /// Live audio. On court that is the ball, which is the one colour on a
    /// tennis broadcast your eye is already trained to find.
    static var signal: Color {
        switch skin {
        case .dark:  return Color(hex: 0xEBCB4B)
        case .light: return Color(hex: 0xB98F0B)
        case .court: return Color(hex: 0xD8F04A)
        }
    }

    static var danger: Color {
        switch skin {
        case .dark:  return Color(hex: 0xE5605A)
        case .light: return Color(hex: 0xA63B36)
        case .court: return Color(hex: 0xE8705F)
        }
    }

    /// What sits on top of the signal colour.
    static var onSignal: Color {
        switch skin {
        case .dark:  return Color(hex: 0x14161A)
        case .light: return .white
        case .court: return Color(hex: 0x0C3B2A)
        }
    }

    static let cardRadius: CGFloat = 20
    static let rowRadius: CGFloat = 16
    /// Rounded square, never a circle. A circle reads as a profile photo;
    /// this is a person on a line.
    static let avatarRadius: CGFloat = 13
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

extension View {
    func cardSurface(_ radius: CGFloat = Theme.cardRadius) -> some View {
        background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
