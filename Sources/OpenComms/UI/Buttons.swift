import SwiftUI

/// The two button shapes the whole app uses. Filled for the thing you came to
/// do, outlined for the alternative beside it.
struct PrimaryButton: ButtonStyle {
    var hot = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16.5, weight: .bold, design: .rounded))
            .frame(maxWidth: .infinity).padding(.vertical, 19)
            .background(hot ? Theme.signal : Theme.text)
            .foregroundStyle(hot ? Theme.onSignal : Theme.base)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .frame(maxWidth: .infinity).padding(.vertical, 18)
            .background(Theme.surface)
            .foregroundStyle(Theme.text)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
