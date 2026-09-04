import SwiftUI

/// Everything adjustable, in one place, phrased as decisions rather than
/// engineering settings. Diagnostics live at the bottom instead of taking a
/// whole tab to show nine read-only rows.
struct SettingsView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var line: LineManager
    @StateObject private var nearby = NearbyEngine.shared
    @State private var blocked: [BlockedRow] = []
    @State private var confirmingWipe = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("SETTINGS")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .kerning(1.3).foregroundStyle(Theme.dim)
                    .padding(.horizontal, 22).padding(.top, 4).padding(.bottom, 18)

                label("YOUR MUSIC WHILE SOMEBODY TALKS")
                VStack(spacing: 1) {
                    ForEach(MusicBehaviour.allCases, id: \.self) { option in
                        choice(option.title, option.detail, store.prefs.music == option) {
                            store.prefs.music = option
                        }
                    }
                }
                .cardSurface().padding(.horizontal, 22)

                label("MICROPHONE")
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("How easily you trigger")
                                .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                            Text("Low means a whisper opens the line. High means you have to speak up.")
                                .font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Text("\(Int(store.prefs.thresholdDB)) dB")
                            .font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.muted)
                    }
                    Slider(value: $store.prefs.sensitivity, in: 0...1).tint(Theme.signal).padding(.top, 12)
                    Text(store.prefs.sensitivityLabel)
                        .font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.dim)
                }
                .padding(17).cardSurface(18).padding(.horizontal, 22)

                VStack(spacing: 0) {
                    toggle("Hear yourself", "A little of your own voice back in your ear",
                           $store.prefs.hearYourself)
                    Divider().overlay(Theme.line)
                    toggle("Clean up background noise", "Filters gym noise before it goes out",
                           $store.prefs.cleanUpNoise)
                }
                .cardSurface().padding(.horizontal, 22).padding(.top, 12)

                label("WHO CAN FIND YOU")
                VStack(spacing: 1) {
                    ForEach(Visibility.allCases, id: \.self) { option in
                        choice(option.title, option.detail, store.prefs.visibility == option) {
                            store.prefs.visibility = option
                            Task { await Backend.shared.setHidden(option == .hidden) }
                            if option == .hidden { nearby.stop() } else { nearby.start() }
                        }
                    }
                }
                .cardSurface().padding(.horizontal, 22)

                label("BATTERY & FEEDBACK")
                VStack(spacing: 0) {
                    toggle("Low power mode",
                           "Widens location updates and slows the radar once a line is open",
                           $store.prefs.lowPower)
                    Divider().overlay(Theme.line)
                    toggle("Sound cues",
                           "A short tone when the line opens, somebody joins, or it ends",
                           $store.prefs.soundCues)
                }
                .cardSurface().padding(.horizontal, 22)
                .onChange(of: store.prefs.lowPower) { _, on in nearby.setLowPower(on) }

                if !blocked.isEmpty {
                    label("BLOCKED — \(blocked.count)")
                    VStack(spacing: 0) {
                        ForEach(blocked) { row in
                            HStack {
                                Text(row.display_name).font(.system(size: 14.5, design: .rounded))
                                Spacer()
                                Button("Unblock") {
                                    Task {
                                        await Backend.shared.unblock(row.device_id)
                                        blocked = await Backend.shared.blocked()
                                    }
                                }
                                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.signal)
                            }
                            .padding(.horizontal, 17).padding(.vertical, 14)
                        }
                    }
                    .cardSurface().padding(.horizontal, 22)
                }

                label("ABOUT")
                VStack(spacing: 0) {
                    row("Your name", store.prefs.displayName)
                    Divider().overlay(Theme.line)
                    row("Audio route", AudioSession.shared.routeName)
                    Divider().overlay(Theme.line)
                    row("Connection", line.squad == nil ? "Idle" : "Connected · \(line.members.count)")
                    Divider().overlay(Theme.line)
                    row("Background", "audio")
                    Divider().overlay(Theme.line)
                    row("Version", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    Divider().overlay(Theme.line)
                    HStack {
                        Text("Delete everything about me")
                            .font(.system(size: 14.5, design: .rounded))
                            .foregroundStyle(Theme.danger)
                        Spacer()
                        Button("Erase") { confirmingWipe = true }
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.danger)
                    }
                    .padding(.horizontal, 17).padding(.vertical, 14)
                }
                .cardSurface().padding(.horizontal, 22)
            }
            .padding(.bottom, 30)
        }
        .background(Theme.base.ignoresSafeArea())
        .task { blocked = await Backend.shared.blocked() }
        .confirmationDialog("Delete everything?", isPresented: $confirmingWipe, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    await Backend.shared.deleteEverything()
                    store.prefs = Preferences()
                    store.saved = []
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your name, your saved squads and anything stored about this phone are removed from the server. There is no account to close.")
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.dim)
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 8)
    }

    private func choice(_ title: String, _ detail: String, _ selected: Bool,
                        _ action: @escaping () -> Void) -> some View {
        Button(action: { action(); Haptics.select() }) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark" : "")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.signal).frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14.5, weight: .semibold, design: .rounded))
                    Text(detail).font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.muted)
                }
                Spacer()
            }
            .padding(.horizontal, 17).padding(.vertical, 15)
            .background(Theme.surface)
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ title: String, _ detail: String, _ value: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14.5, weight: .semibold, design: .rounded))
                Text(detail).font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Toggle("", isOn: value).labelsHidden().tint(Theme.signal)
        }
        .padding(.horizontal, 17).padding(.vertical, 15)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 14.5, design: .rounded))
            Spacer()
            Text(value).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 17).padding(.vertical, 14)
    }
}
