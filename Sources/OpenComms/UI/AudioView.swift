import SwiftUI

/// Every control on this screen changes something, and the thing it changes
/// is named in the code beside it. The old app shipped five of these that
/// moved and did nothing; the CI audit fails the build if that happens again.
struct AudioView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var line: LineManager
    @StateObject private var nearby = NearbyEngine.shared
    @FocusState private var editingName: Bool
    @State private var blocked: [BlockedRow] = []
    @State private var confirmingWipe = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Audio")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 6)

                section("VOICE")
                card {
                    slider("Intercom volume", "\(Int(store.prefs.theirVolume * 100))%",
                           "How loud everyone else comes through", $store.prefs.theirVolume)
                        .onChange(of: store.prefs.theirVolume) { _, _ in line.applyChosenVolume() }
                    divider
                    slider("Self monitor", "\(Int(store.prefs.selfMonitor * 100))%",
                           "Hear your own voice while you talk. Headphones only.", $store.prefs.selfMonitor)
                        .onChange(of: store.prefs.selfMonitor) { _, _ in line.applySelfMonitor() }
                }

                section("MEDIA DUCKING")
                card {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(MusicBehaviour.allCases, id: \.self) { option in
                            choice(option.title, option.detail, store.prefs.music == option) {
                                store.prefs.music = option
                                line.applyMusicPolicy()
                            }
                        }
                    }
                    if store.prefs.music == .turnDown {
                        divider
                        slider("Duck amount", "\(Int(store.prefs.duckAmount * 100))%",
                               "How far your music drops when someone speaks", $store.prefs.duckAmount)
                            .onChange(of: store.prefs.duckAmount) { _, _ in line.applyMusicPolicy() }
                        divider
                        toggle("Auto pause", "Pause the track entirely if the talking runs long", $store.prefs.autoPause)
                            .onChange(of: store.prefs.autoPause) { _, _ in line.applyMusicPolicy() }
                        if store.prefs.autoPause {
                            divider
                            stepper("Pause after", "\(store.prefs.pauseAfter)s", $store.prefs.pauseAfter, 3...30)
                                .onChange(of: store.prefs.pauseAfter) { _, _ in line.applyMusicPolicy() }
                        }
                    }
                    if store.prefs.music != .leaveAlone {
                        divider
                        toggle("Auto rewind", "Jump back after a conversation so you don't miss anything", $store.prefs.autoRewind)
                            .onChange(of: store.prefs.autoRewind) { _, _ in line.applyMusicPolicy() }
                        if store.prefs.autoRewind {
                            divider
                            stepper("Rewind seconds", "\(store.prefs.rewindSeconds)s", $store.prefs.rewindSeconds, 2...60)
                                .onChange(of: store.prefs.rewindSeconds) { _, _ in line.applyMusicPolicy() }
                        }
                    }
                }

                section("AUDIO QUALITY")
                card {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Noise suppression").font(.system(size: 15, weight: .semibold, design: .rounded))
                        Text(store.prefs.noise.detail)
                            .font(.system(size: 11.5, design: .rounded)).foregroundStyle(Theme.muted).padding(.top, 3)
                        HStack(spacing: 0) {
                            ForEach(NoiseSuppression.allCases, id: \.self) { level in
                                Button(level.title) { store.prefs.noise = level; line.applyNoiseSetting() }
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                                    .background(store.prefs.noise == level ? Theme.raised : .clear,
                                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    .foregroundStyle(Theme.text)
                            }
                        }
                        .padding(3)
                        .background(Theme.base.opacity(0.5), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .padding(.top, 12)
                    }
                    .padding(EdgeInsets(top: 15, leading: 18, bottom: 15, trailing: 18))
                    divider
                    slider("How easily you trigger", "\(Int(store.prefs.thresholdDB)) dB · \(store.prefs.sensitivityLabel)",
                           "Low means a whisper opens the line. High means you have to speak up.", $store.prefs.sensitivity)
                        .onChange(of: store.prefs.sensitivity) { _, _ in line.applySensitivity() }
                }

                section("BATTERY & FEEDBACK")
                card {
                    toggle("Low power mode", "Widens location updates and slows the radar once you're on a line", $store.prefs.lowPower)
                        .onChange(of: store.prefs.lowPower) { _, on in nearby.setLowPower(on) }
                    divider
                    toggle("Sound cues", "A short tone when someone joins, leaves or the line ends — for when the phone's in your pocket",
                           $store.prefs.soundCues)
                }

                section("WHO CAN FIND YOU")
                card {
                    VStack(spacing: 1) {
                        ForEach(Visibility.allCases, id: \.self) { option in
                            choice(option.title, option.detail, store.prefs.visibility == option) {
                                store.prefs.visibility = option
                                Task { await Backend.shared.setHidden(option == .hidden) }
                                if option == .hidden { nearby.stop() } else { nearby.start() }
                            }
                        }
                    }
                }

                if !blocked.isEmpty {
                    section("BLOCKED — \(blocked.count)")
                    card {
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
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.text)
                                .padding(.horizontal, 13).padding(.vertical, 7)
                                .background(Theme.raised, in: Capsule())
                            }
                            .padding(.horizontal, 17).padding(.vertical, 14)
                            if row.id != blocked.last?.id { divider }
                        }
                    }
                }

                section("ADVANCED")
                card {
                    row("Live input level", line.micLive ? "\(Int(store.prefs.thresholdDB)) dB" : "—",
                        "Real-time mic reading for calibrating sensitivity", accent: line.micLive)
                    divider
                    row("Audio buffer", "5 ms", "Lower is less latency, higher is more stable")
                    divider
                    row("Sample rate", "48 kHz", "Broadcast grade")
                }

                section("ABOUT")
                card {
                    nameRow
                    divider
                    row("Audio route", AudioSession.shared.routeName, nil)
                    divider
                    row("Connection", line.squad == nil ? "Idle" : "Connected · \(line.members.count)", nil)
                    divider
                    row("Version", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0", nil)
                    divider
                    HStack {
                        Text("Delete everything about me")
                            .font(.system(size: 14.5, design: .rounded)).foregroundStyle(Theme.danger)
                        Spacer()
                        Button("Erase") { confirmingWipe = true }
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundStyle(Theme.danger)
                    }
                    .padding(.horizontal, 17).padding(.vertical, 14)
                }
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

    // MARK: - Pieces

    private var divider: some View { Divider().overlay(Theme.line) }

    private func section(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(Theme.muted)
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .cardSurface()
            .padding(.horizontal, 20)
    }

    private func slider(_ title: String, _ value: String, _ detail: String, _ binding: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
                Text(value).font(.system(size: 14, design: .monospaced)).foregroundStyle(Theme.muted)
            }
            Text(detail).font(.system(size: 11.5, design: .rounded)).foregroundStyle(Theme.muted).padding(.top, 3)
            Slider(value: binding, in: 0...1).tint(Theme.signal).padding(.top, 13)
        }
        .padding(EdgeInsets(top: 15, leading: 18, bottom: 15, trailing: 18))
    }

    private func stepper(_ title: String, _ value: String, _ binding: Binding<Int>, _ range: ClosedRange<Int>) -> some View {
        HStack {
            Text(title).font(.system(size: 15, weight: .semibold, design: .rounded))
            Spacer()
            Text(value).font(.system(size: 14, design: .monospaced)).foregroundStyle(Theme.muted)
            Stepper("", value: binding, in: range).labelsHidden()
        }
        .padding(EdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18))
    }

    private func toggle(_ title: String, _ detail: String, _ binding: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(detail).font(.system(size: 11.5, design: .rounded)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Toggle("", isOn: binding).labelsHidden().tint(Theme.signal)
        }
        .padding(EdgeInsets(top: 15, leading: 18, bottom: 15, trailing: 18))
    }

    private func choice(_ title: String, _ detail: String, _ selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Text(selected ? "✓" : " ").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.signal).frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14.5, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text)
                    Text(detail).font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
            }
            .padding(EdgeInsets(top: 15, leading: 17, bottom: 15, trailing: 17))
        }
        .buttonStyle(.plain)
    }

    private func row(_ title: String, _ value: String, _ detail: String?, accent: Bool = false) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold, design: .rounded))
                if let detail { Text(detail).font(.system(size: 11.5, design: .rounded)).foregroundStyle(Theme.muted) }
            }
            Spacer()
            Text(value).font(.system(size: 14, design: .monospaced)).foregroundStyle(accent ? Theme.signal : Theme.muted)
        }
        .padding(EdgeInsets(top: 15, leading: 18, bottom: 15, trailing: 18))
    }

    private var nameRow: some View {
        HStack {
            Text("Your name").font(.system(size: 15, weight: .semibold, design: .rounded))
            Spacer()
            TextField("Your name", text: $store.prefs.displayName)
                .font(.system(size: 14, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .submitLabel(.done)
                .focused($editingName)
                .onSubmit { pushName() }
        }
        .padding(EdgeInsets(top: 15, leading: 18, bottom: 15, trailing: 18))
        .onChange(of: editingName) { _, nowEditing in if !nowEditing { pushName() } }
    }

    private func pushName() {
        let trimmed = store.prefs.displayName.trimmingCharacters(in: .whitespaces)
        store.prefs.displayName = trimmed.isEmpty ? "Someone" : trimmed
        let name = store.prefs.displayName
        Task {
            await Backend.shared.registerDevice(displayName: name, phoneHash: nil,
                                                hidden: store.prefs.visibility == .hidden)
        }
    }
}
