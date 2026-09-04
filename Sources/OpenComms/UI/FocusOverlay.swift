import SwiftUI

/// Focus takes over the whole screen on purpose.
///
/// It is the one state where the app is deliberately hiding your squad from
/// you, and a small badge somewhere would be too easy to forget — you would
/// wonder why nobody was talking. A countdown you cannot miss, and a cancel
/// button under your thumb, are the honest way to do that.
struct FocusOverlay: View {
    @EnvironmentObject private var line: LineManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Theme.base.ignoresSafeArea()
            VStack(spacing: 16) {
                Text("FOCUS")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .kerning(3)
                    .foregroundStyle(Theme.dim)

                Text("\(line.focusSecondsLeft)")
                    .font(.system(size: 60, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 206, height: 206)
                    .overlay(Circle().stroke(Theme.signal, lineWidth: 3))
                    .contentTransition(reduceMotion ? .identity : .numericText())

                Text("Incoming voices are suppressed. Your squad can still hear each other.")
                    .font(.system(size: 13.5, design: .rounded))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 248)

                Button("Cancel") { line.endFocus() }
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 38).padding(.vertical, 15)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.top, 12)
            }
        }
        .onReceive(tick) { now = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Focus. \(line.focusSecondsLeft) seconds left. Incoming voices suppressed.")
    }
}
