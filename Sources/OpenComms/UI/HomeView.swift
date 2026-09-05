import SwiftUI

/// Home, in the order the design puts things: header with theme and route
/// pills, the radar card, the mic card, saved squads, the nearby list, the
/// ghost and private tiles, then Start and Join. In a session the radar goes
/// live, the code and member grid take over, and Focus / Mute All / End sit
/// at the bottom.
struct HomeView: View {
    @EnvironmentObject private var line: LineManager
    @EnvironmentObject private var store: Store
    @StateObject private var nearby = NearbyEngine.shared
    @StateObject private var net = Reachability.shared

    @State private var showKeypad = false
    @State private var creating = false
    @State private var leaving = false
    @State private var pickingFocus = false
    @State private var showRange = false
    @State private var expanded: String?
    @State private var reporting: Member?
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                banners
                if case .open = line.phase { session } else { home }
            }
            .padding(.bottom, 24)
        }
        .background(Theme.base.ignoresSafeArea())
        .sheet(isPresented: $showKeypad) { CodeKeypad(mode: .join) }
        .sheet(isPresented: $creating) { CodeKeypad(mode: .create) }
        .confirmationDialog("End this session?", isPresented: $leaving, titleVisibility: .visible) {
            Button("End for Everyone", role: .destructive) { Task { await line.endForEveryone() } }
            Button("Leave Session") { Task { await line.leave() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can leave on your own, or close the line for everyone in it.")
        }
        .confirmationDialog("Focus for how long?", isPresented: $pickingFocus, titleVisibility: .visible) {
            ForEach(FocusLength.allCases) { length in Button(length.title) { line.startFocus(length) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nobody comes through until it's over, or until you cancel.")
        }
        .confirmationDialog("Block and report?", isPresented: Binding(get: { reporting != nil },
                                                                     set: { if !$0 { reporting = nil } }),
                            titleVisibility: .visible) {
            Button("Block and report", role: .destructive) {
                if let member = reporting { Task { await line.blockAndReport(member, reason: "reported from line") } }
                reporting = nil
            }
            Button("Cancel", role: .cancel) { reporting = nil }
        } message: {
            Text("They're removed from this line, can't hear you or find you again, and the report goes to review.")
        }
        .overlay { if line.focusSecondsLeft > 0 { FocusOverlay() } }
        .alert("Couldn't open the line", isPresented: failureBinding) {
            Button("OK") { line.dismissFailure() }
        } message: { if case .failed(let why) = line.phase { Text(why) } }
        .onAppear { line.startListeningOnly() }
        .onDisappear { line.stopListeningOnly() }
        .onChange(of: store.prefs.radiusIndex) { _, _ in nearby.rangeChanged() }
        .onChange(of: store.prefs.sensitivity) { _, _ in line.applySensitivity() }
        .onChange(of: store.prefs.theirVolume) { _, _ in line.applyChosenVolume() }
        .onChange(of: store.prefs.visibility) { _, option in
            Task { await Backend.shared.setHidden(option == .hidden) }
            if option == .hidden { nearby.stop() } else { nearby.start() }
        }
    }

    private var failureBinding: Binding<Bool> {
        Binding(get: { if case .failed = line.phase { return true }; return false },
                set: { if !$0 { line.dismissFailure() } })
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("OpenComms").font(.system(size: 26, weight: .bold, design: .rounded))
            Spacer()
            HStack(spacing: 8) {
                Button(store.prefs.lightTheme ? "Light" : "Dark") {
                    store.prefs.lightTheme.toggle()
                    Theme.light = store.prefs.lightTheme
                    Haptics.tap(.light)
                }
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.signal)
                .padding(.horizontal, 13).padding(.vertical, 7)
                .overlay(Capsule().stroke(Theme.signal, lineWidth: 1))

                HStack(spacing: 5) {
                    Circle().fill(AudioSession.shared.onSpeaker ? Theme.muted : Theme.signal).frame(width: 7, height: 7)
                    Text(AudioSession.shared.routeName).lineLimit(1)
                }
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .padding(.horizontal, 13).padding(.vertical, 7)
                .background(Theme.raised, in: Capsule())
            }
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 14)
    }

    @ViewBuilder private var banners: some View {
        if !net.online {
            Banner(icon: "wifi.slash", title: "No connection",
                   detail: "You can't open or join a line until you're back online. Anything you set here is saved.")
        }
        if let message = line.banner {
            Banner(icon: "exclamationmark.triangle.fill", title: message, detail: nil)
        }
    }

    // MARK: - Home (no session)

    private var home: some View {
        VStack(alignment: .leading, spacing: 0) {
            if nearby.denied {
                StateBlock(icon: "location.slash", title: "Location is off",
                           detail: "The radar and the nearby list need location. You can still open a line and share the code.")
                    .padding(.horizontal, 20)
            } else {
                RadarCard(title: "Nearby Radar", subtitle: "Live · \(nearby.people.count) nearby",
                          people: nearby.people, radiusIndex: $store.prefs.radiusIndex, showRange: $showRange)
                    .padding(.horizontal, 20)
            }

            MicCard(detector: line.detector, live: line.micLive, onLine: false,
                    sensitivity: $store.prefs.sensitivity) { line.setMic(!line.micLive) }
                .padding(.horizontal, 20).padding(.top, 14)

            if !store.saved.isEmpty {
                listHead("Your squads", "\(store.saved.count)")
                ForEach(store.saved) { squad in
                    Button { Task { await line.join(code: squad.code) } } label: {
                        personRow(initials: String(squad.name.prefix(2)).uppercased(),
                                  name: squad.name, meta: "\(squad.code) · same code every time")
                    }
                    .buttonStyle(.plain)
                }
            }

            listHead("Nearby", nearby.denied ? "—" : "\(nearby.people.count) people", dot: true)
            if nearby.denied {
                EmptyView()
            } else if nearby.people.isEmpty {
                Text(store.prefs.visibility == .hidden ? "You're hidden — nobody can see you" : "Nobody nearby with OpenComms")
                    .font(.system(size: 14, design: .rounded)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity).padding(.top, 22)
                Text(store.prefs.visibility == .hidden ? "Turn ghost mode off to appear again" : "Adjust range or check back later")
                    .font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.muted.opacity(0.75))
                    .frame(maxWidth: .infinity).padding(.top, 5).padding(.bottom, 4)
            } else {
                ForEach(nearby.people) { person in
                    Button { creating = true } label: {
                        personRow(initials: person.initials, name: person.displayName,
                                  meta: "\(person.distanceText) · \(person.bearingText)")
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 11) {
                switchTile("GHOST MODE", "Hide from nearby and contacts", $store.prefs.ghostMode)
                switchTile("PRIVATE SESSION", "Keep it off discovery", $store.prefs.privateLine)
            }
            .padding(.horizontal, 20).padding(.top, 6)

            Button("Start a Session") { creating = true }
                .buttonStyle(PrimaryButton(hot: true))
                .padding(.horizontal, 20).padding(.top, 16)
                .disabled(!net.online)
            Button("Join") { showKeypad = true }
                .buttonStyle(QuietButton())
                .padding(.horizontal, 20).padding(.top, 10)
                .disabled(!net.online)
        }
    }

    // MARK: - Session

    private var session: some View {
        VStack(alignment: .leading, spacing: 0) {
            if nearby.denied {
                StateBlock(icon: "location.slash", title: "Radar is off",
                           detail: "Location was turned off, so the live radar stopped. The line itself is unaffected.")
                    .padding(.horizontal, 20)
            } else {
                RadarCard(title: "Live Radar",
                          subtitle: "Live · \(line.members.count) members · \(line.elapsed)",
                          people: nearby.people, radiusIndex: $store.prefs.radiusIndex, showRange: $showRange)
                    .padding(.horizontal, 20)
            }

            if line.connecting {
                // A hairline, not a wall. The line is already usable — this
                // only says the last of the handshake is still landing.
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini).tint(Theme.signal)
                    Text("Connecting audio").font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.muted)
                    Spacer()
                }
                .padding(.horizontal, 22).padding(.bottom, 8)
                .transition(.opacity)
            }

            if let squad = line.squad {
                HStack(spacing: 14) {
                    Spacer()
                    Text(squad.code)
                        .font(.system(size: 44, weight: .bold, design: .monospaced)).kerning(6)
                        .foregroundStyle(Theme.signal)
                    Button {
                        UIPasteboard.general.string = squad.code
                        copied = true; Haptics.tap(.light)
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    } label: { iconButton(copied ? "checkmark" : "doc.on.doc") }
                    ShareLink(item: "Join my line on OpenComms — code \(squad.code)") {
                        iconButton("square.and.arrow.up")
                    }
                    Spacer()
                }
                .padding(.top, 6)
                Text("\(line.members.count) of 8 connected\(store.prefs.visibility != .visible ? " · private" : "")")
                    .font(.system(size: 13, design: .rounded)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity).padding(.top, 6).padding(.bottom, 16)
            }

            LazyVGrid(columns: [GridItem(spacing: 11), GridItem(spacing: 11)], spacing: 11) {
                ForEach(line.members) { member in memberTile(member) }
            }
            .padding(.horizontal, 20)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("INTERCOM VOLUME").font(.system(size: 11.5, weight: .bold, design: .rounded)).kerning(1)
                        .foregroundStyle(Theme.muted)
                    Spacer()
                    Text(line.mutedEveryone ? "MUTED" : "\(Int(store.prefs.theirVolume * 100))%")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                }
                Slider(value: $store.prefs.theirVolume, in: 0...1).tint(Theme.signal)
            }
            .padding(EdgeInsets(top: 16, leading: 18, bottom: 14, trailing: 18))
            .cardSurface()
            .padding(.horizontal, 20).padding(.top, 14)

            MicCard(detector: line.detector, live: line.micLive, onLine: true,
                    sensitivity: $store.prefs.sensitivity) { line.setMic(!line.micLive) }
                .padding(.horizontal, 20).padding(.top, 14)

            HStack(spacing: 11) {
                trio(line.focusSecondsLeft > 0 ? "\(line.focusSecondsLeft)s" : "Focus", "scope",
                     active: line.focusSecondsLeft > 0) {
                    if line.focusSecondsLeft > 0 { line.endFocus() } else { pickingFocus = true }
                }
                trio(line.mutedEveryone ? "Unmute All" : "Mute All",
                     line.mutedEveryone ? "speaker.wave.2.fill" : "speaker.slash.fill",
                     active: line.mutedEveryone) { line.setMuteEveryone(!line.mutedEveryone) }
                trio("End", "phone.down.fill", danger: true) { leaving = true }
            }
            .padding(.horizontal, 20).padding(.top, 4)

            Text("Tap a member card for full controls")
                .font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.muted.opacity(0.75))
                .frame(maxWidth: .infinity).padding(.top, 14)
        }
    }

    private func memberTile(_ member: Member) -> some View {
        let open = expanded == member.deviceID && !member.isSelf
        return VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                Text(member.initials)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .frame(width: 66, height: 66)
                    .background(member.isSpeaking ? Theme.signal.opacity(0.14) : Theme.raised,
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Image(systemName: member.mutedForMe ? "speaker.slash.fill" : "mic.fill")
                    .font(.system(size: 11))
                    .frame(width: 26, height: 26)
                    .background(Theme.base, in: Circle())
                    .offset(x: 4, y: 4)
            }
            .padding(.bottom, 12)
            HStack(spacing: 7) {
                Text(member.displayName).font(.system(size: 14.5, weight: .bold, design: .rounded))
                if member.isSelf {
                    Text("YOU").font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Theme.signal, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(Theme.onSignal)
                }
            }
            if open {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("THEIR VOLUME").font(.system(size: 10.5, design: .rounded)).foregroundStyle(Theme.muted)
                        Spacer()
                        Text("\(Int(member.volume * 100))%").font(.system(size: 10.5, weight: .bold, design: .rounded))
                    }
                    Slider(value: Binding(get: { member.volume },
                                          set: { line.setVolume($0, for: member) }), in: 0...1)
                        .tint(Theme.signal)
                    HStack {
                        Text("I hear them").font(.system(size: 11, design: .rounded))
                        Spacer()
                        Toggle("", isOn: Binding(get: { !member.mutedForMe },
                                                 set: { line.setMuted(!$0, for: member) }))
                            .labelsHidden().tint(Theme.signal)
                    }
                    Button("Block and report \(member.displayName)") { reporting = member }
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.danger)
                        .padding(.top, 4)
                }
                .padding(.top, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(EdgeInsets(top: 18, leading: 12, bottom: 18, trailing: 12))
        .frame(maxWidth: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(member.isSpeaking ? Theme.signal : Theme.line, lineWidth: 1))
        .opacity(member.mutedForMe ? 0.45 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !member.isSelf else { return }
            withAnimation { expanded = open ? nil : member.deviceID }
        }
    }

    // MARK: - Bits

    private func listHead(_ title: String, _ count: String, dot: Bool = false) -> some View {
        HStack(spacing: 8) {
            if dot { Circle().fill(Theme.signal).frame(width: 7, height: 7) }
            Text(title).font(.system(size: 19, weight: .bold, design: .rounded))
            Text(count).font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(Theme.muted)
            Spacer()
        }
        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 10)
    }

    private func personRow(initials: String, name: String, meta: String) -> some View {
        HStack(spacing: 13) {
            Avatar(text: initials)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 15.5, weight: .bold, design: .rounded))
                Text(meta).font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
        }
        .padding(EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14))
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line, lineWidth: 1))
        .padding(.horizontal, 20).padding(.bottom, 9)
    }

    private func switchTile(_ title: String, _ detail: String, _ isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 11, weight: .bold, design: .rounded)).kerning(0.6)
            Text(detail).font(.system(size: 10.5, design: .rounded)).foregroundStyle(Theme.muted)
                .padding(.top, 4).fixedSize(horizontal: false, vertical: true)
            Toggle("", isOn: isOn).labelsHidden().tint(Theme.signal).padding(.top, 11)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }

    private func iconButton(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 16))
            .frame(width: 44, height: 44)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .foregroundStyle(Theme.text)
    }

    private func trio(_ title: String, _ symbol: String, active: Bool = false, danger: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 17))
                Text(title).font(.system(size: 12, weight: .bold, design: .rounded))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 15)
            .foregroundStyle(danger ? Theme.danger : active ? Theme.signal : Theme.text)
            .background(danger ? Theme.danger.opacity(0.13) : Theme.surface,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(danger ? Theme.danger.opacity(0.3) : active ? Theme.signal : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
