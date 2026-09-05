import SwiftUI

/// One accent, and it means exactly one thing: audio is live right now.
///
/// The temptation is to use it for anything important — buttons, the selected
/// tab, headings — and the moment that happens a glance mid-set stops
/// answering "is anyone talking". Everything else is graphite.
enum Theme {
    /// Flipped by the header pill. Read on every access rather than cached,
    /// so a view that re-renders for any reason picks the right palette up.
    /// Every screen observes the store, so toggling re-renders all of them.
    nonisolated(unsafe) static var light = false

    static var base:    Color { light ? Color(hex: 0xEDE9E1) : Color(hex: 0x14161A) }
    static var surface: Color { light ? Color(hex: 0xE4DFD5) : Color(hex: 0x1C1F25) }
    static var raised:  Color { light ? Color(hex: 0xD9D3C7) : Color(hex: 0x232730) }
    static var line:    Color { light ? Color(hex: 0xCFC8BB) : Color(hex: 0x2E333D) }
    static var text:    Color { light ? Color(hex: 0x14161A) : Color(hex: 0xF2F3F5) }
    static var muted:   Color { light ? Color(hex: 0x6E6A62) : Color(hex: 0x8A909C) }
    static var dim:     Color { light ? Color(hex: 0x9A958B) : Color(hex: 0x5A616D) }
    static var signal:  Color { light ? Color(hex: 0xB98F0B) : Color(hex: 0xEBCB4B) }
    static var danger:  Color { light ? Color(hex: 0xA63B36) : Color(hex: 0xE5605A) }
    /// What sits on top of the signal colour — dark on yellow, white on the
    /// deeper gold the light palette uses.
    static var onSignal: Color { light ? .white : Color(hex: 0x14161A) }

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
