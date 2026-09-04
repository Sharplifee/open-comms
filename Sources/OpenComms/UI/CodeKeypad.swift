import SwiftUI

/// Three digits and a number pad.
///
/// The code is chosen by the person, not generated, because a code you picked
/// is one you can shout across a gym floor — and it is what lets the same
/// squad use the same line tomorrow without re-sharing anything.
struct CodeKeypad: View {
    enum Mode { case join, create }
    let mode: Mode

    @EnvironmentObject private var line: LineManager
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var digits = ""

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Theme.line).frame(width: 38, height: 5).padding(.vertical, 12)

            Text(mode == .join ? "Enter the code" : "Pick a code")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .padding(.top, 10)

            Text(mode == .join ? "Three digits, from whoever opened the line."
                               : "Three digits. Pick something your squad will remember.")
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .padding(.top, 8).padding(.horizontal, 30)

            HStack(spacing: 11) {
                ForEach(0..<3, id: \.self) { index in
                    Text(character(at: index))
                        .font(.system(size: 30, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.signal)
                        .frame(width: 70, height: 82)
                        .cardSurface(Theme.rowRadius)
                        .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                            .stroke(index == digits.count ? Theme.signal : .clear, lineWidth: 1.5))
                }
            }
            .padding(.vertical, 28)

            LazyVGrid(columns: Array(repeating: GridItem(spacing: 10), count: 3), spacing: 10) {
                ForEach(1...9, id: \.self) { number in key("\(number)") }
                Color.clear.frame(height: 1)
                key("0")
                Button { if !digits.isEmpty { digits.removeLast(); Haptics.select() } } label: {
                    Image(systemName: "delete.left")
                        .font(.system(size: 19, weight: .medium))
                        .frame(maxWidth: .infinity).frame(height: 58)
                        .foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 26)

            Spacer(minLength: 20)
        }
        .background(Theme.base.ignoresSafeArea())
        .presentationDetents([.large])
        .onChange(of: digits) { _, value in
            guard value.count == 3 else { return }
            Task {
                dismiss()
                switch mode {
                case .join: await line.join(code: value)
                case .create: await line.open(code: value, name: "\(store.prefs.displayName)'s line")
                }
            }
        }
    }

    private func character(at index: Int) -> String {
        index < digits.count ? String(Array(digits)[index]) : ""
    }

    private func key(_ digit: String) -> some View {
        Button {
            guard digits.count < 3 else { return }
            digits += digit
            Haptics.select()
        } label: {
            Text(digit)
                .font(.system(size: 24, weight: .semibold, design: .monospaced))
                .frame(maxWidth: .infinity).frame(height: 58)
                .cardSurface(14)
        }
        .buttonStyle(.plain)
    }
}
