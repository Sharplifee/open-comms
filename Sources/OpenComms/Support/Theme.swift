import SwiftUI

/// One accent, and it means exactly one thing: audio is live right now.
///
/// The temptation is to use it for anything important — buttons, the selected
/// tab, headings — and the moment that happens a glance mid-set stops
/// answering "is anyone talking". Everything else is graphite.
enum Theme {
    static let base    = Color(hex: 0x14161A)
    static let surface = Color(hex: 0x1C1F25)
    static let raised  = Color(hex: 0x232730)
    static let line    = Color(hex: 0x2E333D)
    static let text    = Color(hex: 0xF2F3F5)
    static let muted   = Color(hex: 0x8A909C)
    static let dim     = Color(hex: 0x5A616D)
    static let signal  = Color(hex: 0xEBCB4B)
    static let danger  = Color(hex: 0xE5605A)

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
