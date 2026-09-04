import SwiftUI

/// The screen the app opens on.
///
/// Closed, the only question is whether to open a line and with whom, so the
/// state and the button come first and the radar sits inside the nearby card
/// as its own header — one card, one range control, picture above names.
/// There is no level meter here, because there is nothing to meter.
///
/// Open, the question flips to who is talking, so the ribbon carries the crew
/// and the mic becomes the largest target on the screen.
struct LineView: View {
    @EnvironmentObject private var line: LineManager
    @EnvironmentObject private var store: Store
    @StateObject private var nearby = NearbyEngine.shared
    @StateObject private var net = Reachability.shared

    @State private var showKeypad = false
    @State private var creating = false
    @State private var leaving = false
    @State private var pickingFocus = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                masthead
                banners
                if case .open = line.phase { openLine } else { closedLine }
            }
            .padding(.bottom, 24)
        }
        .background(Theme.base.ignoresSafeArea())
        .sheet(isPresented: $showKeypad) { CodeKeypad(mode: .join) }
        .sheet(isPresented: $creating) { CodeKeypad(mode: .create) }
        .confirmationDialog("Leave this line?", isPresented: $leaving, titleVisibility: .visible) {
            Button("End for everyone", role: .destructive) { Task { await line.endForEveryone() } }
            Button("Just leave") { Task { await line.leave() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can step off on your own, or close it for everyone on it.")
        }
        .overlay { if case .opening = line.phase { ConnectingOverlay() } }
        .overlay { if line.focusSecondsLeft > 0 { FocusOverlay() } }
        .confirmationDialog("Focus for how long?", isPresented: $pickingFocus, titleVisibility: .visible) {
            ForEach(FocusLength.allCases) { length in
                Button(length.title) { line.startFocus(length) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nobody comes through until it's over, or until you cancel.")
        }
        .alert("Couldn't open the line", isPresented: failureBinding) {
            Button("OK") { line.dismissFailure() }
        } message: {
            if case .failed(let why) = line.phase { Text(why) }
        }
    }

    private var failureBinding: Binding<Bool> {
        Binding(get: { if case .failed = line.phase { return true }; return false },
                set: { if !$0 { line.dismissFailure() } })
    }

    private var masthead: some View {
        HStack {
            Text("OPEN COMMS")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .kerning(1.3)
                .foregroundStyle(Theme.dim)
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(Theme.signal).frame(width: 6, height: 6)
                Text(line.squad == nil ? AudioSession.shared.routeName : "Connected · \(line.elapsed)")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Theme.muted)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 22).padding(.top, 4).padding(.bottom, 18)
    }

    /// Rendered once, in one place. The previous app drew these from three
    /// different views and showed the same warning twice.
    @ViewBuilder private var banners: some View {
        if !net.online {
            Banner(icon: "wifi.slash", title: "No connection",
                   detail: "You can't open or join a line until you're back online.")
        }
        if let message = line.banner {
            Banner(icon: "exclamationmark.triangle.fill", title: message, detail: nil)
        }
    }

    // MARK: - Closed

    private var closedLine: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("The line is closed")
                .font(.system(size: 31, weight: .bold, design: .rounded))
            Text("Open it and your squad hears you the second you talk. Your music keeps playing underneath.")
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(Theme.muted)
                .padding(.top, 9)

            Button("Open the line") { creating = true }
                .buttonStyle(PrimaryButton())
                .padding(.top, 20)
                .disabled(!net.online)

            Button("Have a code? Join instead") { showKeypad = true }
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity)
                .padding(.top, 13)
                .disabled(!net.online)

            if !store.saved.isEmpty { savedSquads }
            nearbyCard
            visibilitySwitches
            micCheck
        }
        .padding(.horizontal, 22)
    }

    private var savedSquads: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("YOUR SQUADS")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.dim)
                .padding(.horizontal, 17).padding(.top, 14).padding(.bottom, 8)
            ForEach(store.saved) { squad in
                Button {
                    Task { await line.join(code: squad.code) }
                } label: {
                    HStack(spacing: 13) {
                        Avatar(text: squad.code)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(squad.name).font(.system(size: 15, weight: .semibold, design: .rounded))
                            Text("Same code every time")
                                .font(.system(size: 12.5, design: .rounded)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Text(squad.code)
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.horizontal, 17).padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            }
        }
        .cardSurface()
        .padding(.top, 26)
    }

    private var nearbyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Nearby").font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
                Menu {
                    ForEach([30.5, 76.2, 152.4, 402.3, 1609.3], id: \.self) { metres in
                        Button(rangeLabel(metres)) { nearby.radiusMetres = metres }
                    }
                } label: {
                    Text(rangeLabel(nearby.radiusMetres))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Theme.raised).clipShape(Capsule())
                }
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 4)

            if nearby.denied {
                StateBlock(icon: "location.slash",
                           title: "Location is off",
                           detail: "The radar needs location. You can still open a line and share the code.")
            } else {
                RadarStrip(people: nearby.people, radius: nearby.radiusMetres)
                Divider().overlay(Theme.line)
                if nearby.people.isEmpty {
                    Text("Nobody nearby right now. Widen the range, or share a code with someone.")
                        .font(.system(size: 13.5, design: .rounded))
                        .foregroundStyle(Theme.muted)
                        .padding(18)
                } else {
                    ForEach(nearby.people) { person in
                        HStack(spacing: 13) {
                            Avatar(text: person.initials)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(person.displayName).font(.system(size: 15, weight: .semibold, design: .rounded))
                                Text("Tap to open a line").font(.system(size: 12.5, design: .rounded))
                                    .foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Text("\(person.distanceText) · \(person.bearingText)")
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundStyle(Theme.muted)
                        }
                        .padding(.horizontal, 18).padding(.vertical, 13)
                    }
                }
            }
        }
        .cardSurface()
        .padding(.top, 26)
    }

    /// Two switches over one value. People reach for "hide me" and "keep this
    /// off the radar" as separate thoughts, but they are the same question, so
    /// both write to visibility rather than drifting apart.
    private var visibilitySwitches: some View {
        HStack(spacing: 11) {
            switchTile(title: "GHOST MODE",
                       detail: "Hide from nearby entirely",
                       isOn: $store.prefs.ghostMode)
            switchTile(title: "PRIVATE",
                       detail: "Stay off the radar, lines by code",
                       isOn: $store.prefs.privateLine)
        }
        .padding(.top, 12)
        .onChange(of: store.prefs.visibility) { _, option in
            Task { await Backend.shared.setHidden(option == .hidden) }
            if option == .hidden { nearby.stop() } else { nearby.start() }
        }
    }

    private func switchTile(title: String, detail: String, isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded)).kerning(0.6)
            Text(detail)
                .font(.system(size: 10.5, design: .rounded))
                .foregroundStyle(Theme.muted)
                .padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(Theme.signal)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardSurface(Theme.rowRadius)
    }

    private var micCheck: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Mic check").font(.system(size: 13.5, weight: .semibold, design: .rounded))
                Text("You trigger the line at \(Int(store.prefs.thresholdDB)) dB · \(store.prefs.sensitivityLabel)")
                    .font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.muted)
            }
            Spacer()
        }
        .padding(16)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line, lineWidth: 1))
        .padding(.top, 16)
    }

    private func rangeLabel(_ metres: Double) -> String {
        metres < 400 ? "\(Int(metres * 3.28084)) ft" : String(format: "%.2g mi", metres / 1609.34)
    }

    // MARK: - Open

    private var openLine: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(headline)
                .font(.system(size: 31, weight: .bold, design: .rounded))
                .foregroundStyle(line.micLive && line.members.first(where: \.isSelf)?.isSpeaking == true
                                 ? Theme.signal : Theme.text)
            Text(subhead)
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(Theme.muted)
                .padding(.top, 9)

            Ribbon(level: line.level, members: line.members, live: line.micLive)
                .padding(.top, 19)

            HStack {
                Text(line.micLive ? "Sending" : "Listening")
                Spacer()
                Text("\(Int(store.prefs.thresholdDB)) dB triggers you")
            }
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(Theme.dim)

            Button(line.micLive ? "Mute me" : "Unmute me") { line.setMic(!line.micLive) }
                .buttonStyle(PrimaryButton(hot: line.micLive))
                .padding(.top, 20)
                .accessibilityLabel(line.micLive ? "Microphone live. Tap to mute." : "Microphone muted. Tap to unmute.")

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("How loud they are").font(.system(size: 14.5, weight: .semibold, design: .rounded))
                    Spacer()
                    Text("\(Int(store.prefs.theirVolume * 100))%")
                        .font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.muted)
                }
                Slider(value: $store.prefs.theirVolume, in: 0...1)
                    .tint(Theme.signal)
                    .onChange(of: store.prefs.theirVolume) { _, value in
                        for member in line.members where !member.isSelf {
                            line.setVolume(value, for: member)
                        }
                    }
            }
            .padding(17)
            .cardSurface(18)
            .padding(.top, 16)

            if let squad = line.squad {
                HStack(spacing: 12) {
                    Text("Code").font(.system(size: 12.5, design: .rounded)).foregroundStyle(Theme.muted)
                    Text(squad.code)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .kerning(4)
                    ShareLink(item: "Join my line on open comms — code \(squad.code)") {
                        Text("Share").font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    }
                    Spacer()
                }
                .padding(.top, 18)
            }

            // Focus and Mute All sit beside the exit because all three are
            // things you reach for mid-set without looking: silence them for a
            // stretch, silence them until you say otherwise, or get off.
            HStack(spacing: 11) {
                controlTile(title: line.focusSecondsLeft > 0 ? "\(line.focusSecondsLeft)s" : "Focus",
                            symbol: "scope",
                            active: line.focusSecondsLeft > 0) {
                    if line.focusSecondsLeft > 0 { line.endFocus() } else { pickingFocus = true }
                }
                controlTile(title: line.mutedEveryone ? "Unmute all" : "Mute all",
                            symbol: line.mutedEveryone ? "speaker.wave.2.fill" : "speaker.slash.fill",
                            active: line.mutedEveryone) {
                    line.setMuteEveryone(!line.mutedEveryone)
                }
            }
            .padding(.top, 18)

            Button("Leave the line") { leaving = true }
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.danger)
                .frame(maxWidth: .infinity).padding(.vertical, 18)
                .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                    .stroke(Theme.danger.opacity(0.32), lineWidth: 1))
                .padding(.top, 20)
        }
        .padding(.horizontal, 22)
    }

    private func controlTile(title: String, symbol: String, active: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 15)
            .foregroundStyle(active ? Theme.signal : Theme.text)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .stroke(active ? Theme.signal : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var headline: String {
        if line.micLive, line.members.first(where: \.isSelf)?.isSpeaking == true { return "You're on" }
        if let talker = line.talker { return "\(talker.displayName) is talking" }
        return "The line is open"
    }

    private var subhead: String {
        line.micLive
            ? "\(line.members.count) on the line. Talk and you go through automatically."
            : "You're muted. Nobody can hear you until you unmute."
    }
}
