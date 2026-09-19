import SwiftUI

/// The settings worth reaching from a court, without leaving the court.
///
/// Every one of these already lives in Audio, and this does NOT duplicate any
/// of them — it binds to the same stored values and calls the same apply
/// functions, so a change here and a change there are the same change. What it
/// does is answer a different question: Audio is "configure the app", this is
/// "something is wrong right now and I am standing on a court".
///
/// So it carries the five that get touched mid-session and nothing else. The
/// rest stay in Audio, one tab away, where there is time to read them.
struct CourtSetup: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var line: LineManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    group("HOW LOUD THEY ARE") {
                        slider("Their volume", "\(Int(store.prefs.theirVolume * 100))%",
                               "Everything coming from the other end.",
                               $store.prefs.theirVolume)
                            .onChange(of: store.prefs.theirVolume) { _, _ in line.applyChosenVolume() }
                    }

                    group("HOW EASILY YOU OPEN") {
                        slider("Sensitivity",
                               "\(Int(store.prefs.thresholdDB)) dB · \(store.prefs.sensitivityLabel)",
                               "Left for a quiet indoor court, right for wind and a ball machine.",
                               $store.prefs.sensitivity)
                            .onChange(of: store.prefs.sensitivity) { _, _ in line.applySensitivity() }
                    }

                    group("YOUR MUSIC") {
                        ForEach(MusicBehaviour.allCases, id: \.self) { option in
                            choice(option.title, option.detail, store.prefs.music == option) {
                                store.prefs.music = option
                                line.applyMusicPolicy()
                            }
                        }
                    }

                    group("MICROPHONE") {
                        toggle("Use Bluetooth headset mic",
                               "Only affects Bluetooth. Their mic costs you full-quality sound in both ears while the line is open; in a car or on wired headphones the near mic is used anyway.",
                               $store.prefs.useHeadsetMic)
                            .onChange(of: store.prefs.useHeadsetMic) { _, _ in line.applyMicSource() }
                    }

                    group("CUES") {
                        toggle("Sound cues",
                               "A short tone when somebody joins, leaves, or the session ends.",
                               $store.prefs.soundCues)
                    }

                    Text("Everything else — self monitor, ducking depth, noise, visibility, blocked people — is in the Audio tab.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Theme.dim)
                        .padding(.horizontal, 22).padding(.top, 18)
                }
                .padding(.bottom, 30)
            }
            .background(Theme.base.ignoresSafeArea())
            .navigationTitle("Session setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .tint(Theme.signal)
    }

    // MARK: - Pieces

    /// One rhythm for every block, so nothing reads as more important than it
    /// is just because it happened to get more air around it.
    private func group<Content: View>(_ title: String,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11.5, weight: .bold, design: .rounded)).kerning(1.4)
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 22).padding(.bottom, 8)
            VStack(spacing: 1) { content() }
                .background(Theme.line)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                .padding(.horizontal, 20)
        }
        .padding(.top, 20)
    }

    private func slider(_ title: String, _ value: String, _ detail: String,
                        _ binding: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
                Text(value).font(.system(size: 13.5, design: .monospaced)).foregroundStyle(Theme.muted)
            }
            Text(detail).font(.system(size: 11.5, design: .rounded)).foregroundStyle(Theme.muted)
                .padding(.top, 3).fixedSize(horizontal: false, vertical: true)
            Slider(value: binding, in: 0...1).tint(Theme.signal).padding(.top, 12)
        }
        .padding(EdgeInsets(top: 15, leading: 18, bottom: 15, trailing: 18))
        .background(Theme.surface)
    }

    private func toggle(_ title: String, _ detail: String, _ binding: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(detail).font(.system(size: 11.5, design: .rounded)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: binding).labelsHidden().tint(Theme.signal)
        }
        .padding(EdgeInsets(top: 15, leading: 18, bottom: 15, trailing: 18))
        .background(Theme.surface)
    }

    private func choice(_ title: String, _ detail: String, _ selected: Bool,
                        _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Theme.signal : Theme.muted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.text)
                    Text(detail).font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
            }
            .padding(EdgeInsets(top: 15, leading: 17, bottom: 15, trailing: 17))
            .background(Theme.surface)
        }
        .buttonStyle(.plain)
    }
}
