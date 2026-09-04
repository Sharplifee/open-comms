import SwiftUI
import AVFoundation
import CoreLocation

/// Three screens and one button.
///
/// The permissions are requested in sequence from a single tap rather than
/// scattered through the app, because being asked for the microphone in the
/// middle of trying to talk to somebody is how people end up denying it.
struct OnboardingView: View {
    @EnvironmentObject private var store: Store
    @State private var step = 0
    @State private var asking = false

    private let pages = [
        ("waveform", "An open line,\nnot a phone call",
         "Start a line with your squad and just talk. No button to hold, no call to answer — say something and they hear it."),
        ("headphones", "Your music\nkeeps playing",
         "Voices come in over the top. The track steps aside while somebody is talking and comes right back when they stop."),
        ("dot.radiowaves.left.and.right", "Find who's\nalready close",
         "See who nearby has the app, so opening a line takes one tap. If the app gets shut down a normal notification brings you back — it never rings like a call.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3) { index in
                    Capsule()
                        .fill(index <= step ? Theme.signal : Theme.line)
                        .frame(height: 3)
                }
            }
            .padding(.top, 22)

            Image(systemName: pages[step].0)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.signal)
                .frame(width: 70, height: 70)
                .background(Theme.signal.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.top, 30)

            Text(pages[step].1)
                .font(.system(size: 31, weight: .bold, design: .rounded))
                .padding(.top, 24)

            Text(pages[step].2)
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(Theme.muted)
                .padding(.top, 10)

            if step == 2 {
                VStack(spacing: 9) {
                    permissionRow("Microphone", "So your squad can hear you")
                    permissionRow("Location", "To show who's nearby")
                    permissionRow("Bluetooth", "To use your AirPods")
                    permissionRow("Media & Apple Music", "To turn your music down and back up")
                    permissionRow("Local Network", "To connect voice directly when you're close")
                }
                .padding(.top, 24)
            }

            Spacer(minLength: 20)

            Button(step == 2 ? "Allow & get started" : "Continue") {
                if step < 2 { withAnimation { step += 1 } } else { requestEverything() }
            }
            .buttonStyle(PrimaryButton())
            .disabled(asking)

            if step < 2 {
                Button("Skip") { store.prefs.onboarded = true }
                    .buttonStyle(QuietButton())
                    .padding(.top, 10)
            }
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 26)
        .background(Theme.base.ignoresSafeArea())
    }

    private func permissionRow(_ title: String, _ why: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold, design: .rounded))
                Text(why).font(.system(size: 11.5, design: .rounded)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Image(systemName: "checkmark").foregroundStyle(Theme.signal).font(.system(size: 13, weight: .bold))
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .cardSurface(13)
    }

    /// One after another, not all at once — iOS only shows one system prompt
    /// at a time and silently drops the rest.
    private func requestEverything() {
        asking = true
        AVAudioApplication.requestRecordPermission { _ in
            DispatchQueue.main.async {
                NearbyEngine.shared.start()
                // Contacts is deliberately not requested. The matching feature
                // is not built — phone_hash is never set and match_contacts is
                // never called — and asking for an address book the app does
                // not use is both a review risk and the wrong thing to do.
                store.prefs.onboarded = true
                asking = false
            }
        }
    }
}

struct NameEntryView: View {
    @EnvironmentObject private var store: Store
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 44)
            Image(systemName: "person.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.signal)
                .frame(width: 70, height: 70)
                .background(Theme.signal.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            Text("What should they\ncall you?")
                .font(.system(size: 31, weight: .bold, design: .rounded))
                .padding(.top, 24)

            Text("This is the whole signup. No account, no password, no email.")
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(Theme.muted)
                .padding(.top, 10)

            TextField("Your name", text: $draft)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .focused($focused)
                .submitLabel(.done)
                .padding(16)
                .cardSurface(Theme.rowRadius)
                .padding(.top, 26)

            Spacer()

            Button("Start using open comms") {
                store.prefs.displayName = draft.trimmingCharacters(in: .whitespaces)
                Task { await Backend.shared.registerDevice(displayName: store.prefs.displayName,
                                                           phoneHash: nil,
                                                           hidden: store.prefs.visibility == .hidden) }
            }
            .buttonStyle(PrimaryButton())
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 26).padding(.bottom, 26)
        .background(Theme.base.ignoresSafeArea())
        .onAppear { focused = true }
    }
}

struct PrimaryButton: ButtonStyle {
    var hot = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16.5, weight: .bold, design: .rounded))
            .frame(maxWidth: .infinity).padding(.vertical, 19)
            .background(hot ? Theme.signal : Theme.text)
            .foregroundStyle(Theme.base)
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
