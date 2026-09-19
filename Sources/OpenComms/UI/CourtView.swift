import SwiftUI

/// Court mode: a coaching session, not a scoreboard.
///
/// Coaching happens at forty feet with a ball machine running. The coach ends
/// up shouting the same eight phrases all afternoon, the player hears half of
/// them, and both lose the thread — and the player cannot answer without
/// walking to the net. So this screen is built around one idea: say the thing
/// once, quietly, and have it arrive.
///
/// A tap sends words that are spoken into the other person's ear, felt as a
/// buzz, and written large on their screen. The line stays open underneath for
/// everything longer than three words, which is what a voice is for.
struct CourtView: View {
    @EnvironmentObject private var line: LineManager
    @EnvironmentObject private var store: Store
    @ObservedObject private var peers = PeerDiscovery.shared

    @State private var creating = false
    @State private var showKeypad = false
    @State private var leaving = false
    @State private var flash: String?
    @State private var setup = false

    var body: some View {
        ZStack {
            CourtBackdrop()
            ScrollView {
                VStack(spacing: 0) {
                    if line.squad == nil {
                        openStrip
                    } else {
                        knocks
                        roleSwitch
                        if store.prefs.courtRole == .coach { coachDeck } else { playerDeck }
                        micStrip
                        Button("Leave the session") { leaving = true }
                            .buttonStyle(QuietButton())
                            .padding(.horizontal, 20).padding(.top, 16)
                    }
                }
                .padding(.bottom, 28)
            }
            // The header is pinned OUTSIDE the scroll view.
            //
            // It used to be the first row of scrolling content, inside a
            // ZStack whose backdrop ignores the safe area — which made the
            // whole stack full-bleed and dragged the header up under the
            // Dynamic Island. The title collided with the clock and "Exit
            // court" sat half beneath the status bar where it could not be
            // tapped, so court mode was a room with no door.
            //
            // safeAreaInset keeps it below the island on every device, above
            // the content, and always reachable.
            .safeAreaInset(edge: .top, spacing: 0) { header }
            if let flash { cueFlash(flash) }
        }
        .background(Theme.base.ignoresSafeArea())
        .sheet(isPresented: $creating) { CodeKeypad(mode: .create) }
        .sheet(isPresented: $showKeypad) { CodeKeypad(mode: .join) }
        .sheet(isPresented: $setup) { CourtSetup().environmentObject(store).environmentObject(line) }
        .confirmationDialog("Leave this session?", isPresented: $leaving, titleVisibility: .visible) {
            Button("End for both", role: .destructive) { Task { await line.endForEveryone() } }
            Button("Just leave") { Task { await line.leave() } }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: line.lastCue?.at) { _, _ in
            guard let text = line.lastCue?.text else { return }
            withAnimation(.spring(duration: 0.22)) { flash = text }
            Task {
                try? await Task.sleep(for: .seconds(2.4))
                withAnimation { flash = nil }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("COURT").font(.system(size: 12, weight: .bold, design: .rounded)).kerning(2)
                    .foregroundStyle(Theme.signal)
                Text(line.squad == nil ? "No session open" : "With \(otherName)")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
            }
            Spacer()
            Button { setup = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 44, height: 44)
                    .background(Theme.raised.opacity(0.95), in: Circle())
                    .overlay(Circle().stroke(Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Session setup")

            Button {
                withAnimation(.easeInOut(duration: 0.18)) { store.prefs.courtMode = false }
                line.applyCourtRole()
                Haptics.tap(.light)
            } label: {
                Label("Exit court", systemImage: "chevron.backward")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 16)
                    // 44 points tall, which is the smallest thing a thumb
                    // finds reliably — the old one was 28 and half-covered.
                    .frame(height: 44)
                    .background(Theme.raised.opacity(0.95), in: Capsule())
                    .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 14)
        .background(
            // Content scrolls underneath, so the header needs something to sit
            // on or the words stack on each other.
            LinearGradient(colors: [Theme.base, Theme.base.opacity(0.92), Theme.base.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private var otherName: String {
        line.members.first(where: { !$0.isSelf })?.displayName ?? "your player"
    }

    /// Which end you are on. It changes what is on the glass and nothing else —
    /// both people hear each other exactly the same way either way.
    private var roleSwitch: some View {
        HStack(spacing: 0) {
            ForEach(CourtRole.allCases) { role in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { store.prefs.courtRole = role }
                    line.applyCourtRole()
                    Haptics.select()
                } label: {
                    Text(role.title)
                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .foregroundStyle(store.prefs.courtRole == role ? Theme.onSignal : Theme.text)
                        .background(store.prefs.courtRole == role ? Theme.signal : .clear,
                                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 20)
    }

    // MARK: - Coach

    private var coachDeck: some View {
        VStack(alignment: .leading, spacing: 18) {
            deck("CORRECTIONS", CoachCue.allCases.filter(\.isTechnical)) { cue in
                line.speak(cue.spoken)
            }
            deck("THE SESSION", CoachCue.allCases.filter { !$0.isTechnical }) { cue in
                line.speak(cue.spoken)
            }
            Text("Say anything longer out loud — they can hear you the whole time.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 22)
        }
        .padding(.top, 22)
    }

    private func deck(_ title: String, _ cues: [CoachCue], action: @escaping (CoachCue) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 11, weight: .bold, design: .rounded)).kerning(1.5)
                .foregroundStyle(Theme.muted).padding(.horizontal, 22)
            LazyVGrid(columns: Array(repeating: GridItem(spacing: 10), count: 3), spacing: 10) {
                ForEach(cues) { cue in
                    Button { action(cue) } label: {
                        VStack(spacing: 6) {
                            Image(systemName: cue.symbol).font(.system(size: 16, weight: .semibold))
                            Text(cue.label).font(.system(size: 12, weight: .bold, design: .rounded))
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                        .foregroundStyle(Theme.text)
                        .background(Theme.surface.opacity(0.92),
                                    in: RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                            .stroke(Theme.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Player

    /// The player's phone is in a bag by the net post, so this screen assumes
    /// it will barely be looked at. It says the one thing worth knowing —
    /// whether the coach can hear you — in type readable from arm's length,
    /// keeps the last cue on screen, and offers five replies for the moments
    /// you are actually at the bench.
    private var playerDeck: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Text(line.micLive ? "COACH CAN HEAR YOU" : "YOU'RE MUTED")
                    .font(.system(size: 13, weight: .bold, design: .rounded)).kerning(1.5)
                    .foregroundStyle(line.micLive ? Theme.signal : Theme.muted)
                Text(line.lastCue?.text ?? "Just play — everything they say lands in your ear.")
                    .font(.system(size: line.lastCue == nil ? 17 : 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, minHeight: 92)
            }
            .padding(.horizontal, 18).padding(.vertical, 20)
            .background(Theme.surface.opacity(0.92),
                        in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .stroke(Theme.line, lineWidth: 1))
            .padding(.horizontal, 20)

            VStack(alignment: .leading, spacing: 10) {
                Text("SAY BACK").font(.system(size: 11, weight: .bold, design: .rounded)).kerning(1.5)
                    .foregroundStyle(Theme.muted).padding(.horizontal, 22)
                LazyVGrid(columns: Array(repeating: GridItem(spacing: 10), count: 3), spacing: 10) {
                    ForEach(PlayerReply.allCases) { reply in
                        Button { line.speak(reply.spoken) } label: {
                            VStack(spacing: 6) {
                                Image(systemName: reply.symbol).font(.system(size: 16, weight: .semibold))
                                Text(reply.label).font(.system(size: 12, weight: .bold, design: .rounded))
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 15)
                            .foregroundStyle(Theme.text)
                            .background(Theme.surface.opacity(0.92),
                                        in: RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                                .stroke(Theme.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.top, 20)
    }

    private func cueFlash(_ text: String) -> some View {
        VStack(spacing: 12) {
            Text(text.uppercased())
                .font(.system(size: 40, weight: .bold, design: .rounded)).kerning(0.5)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 30)
        }
        .foregroundStyle(Theme.onSignal)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.signal.opacity(0.95).ignoresSafeArea())
        .transition(.opacity)
        .allowsHitTesting(false)
        .accessibilityLabel(text)
    }

    /// Somebody asking to get onto a public session.
    ///
    /// A coach running an open group needs this exactly as much as anybody on
    /// the Home screen does — more, since a public session is how a clinic or
    /// a squad practice gets people on without reading a code across a court.
    private var knocks: some View {
        ForEach(line.knocking) { request in
            HStack(spacing: 12) {
                Avatar(text: String(request.display_name.prefix(2)).uppercased())
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.display_name).font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("wants to join").font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("No") { Task { await line.answer(request, grant: false) } }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                Button("Let in") { Task { await line.answer(request, grant: true) } }
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.onSignal)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Theme.signal, in: Capsule())
            }
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
            .background(Theme.surface.opacity(0.94),
                        in: RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .stroke(Theme.signal, lineWidth: 1))
            .padding(.horizontal, 20).padding(.top, 12)
        }
    }

    // MARK: - Mic and opening

    private var micStrip: some View {
        HStack(spacing: 14) {
            Button { line.setMic(!line.micLive) } label: {
                Image(systemName: line.micLive ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(line.micLive ? Theme.onSignal : Theme.text)
                    .frame(width: 56, height: 56)
                    .background(line.micLive ? Theme.signal : Theme.raised, in: Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(line.micLive ? "They can hear you" : "You're muted")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Text(line.micLive ? "Talk normally — it opens at \(Int(store.prefs.thresholdDB)) dB"
                                  : "Tap to come back on")
                    .font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.muted)
            }
            Spacer()
        }
        .padding(16)
        .background(Theme.surface.opacity(0.92),
                    in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .padding(.horizontal, 20).padding(.top, 22)
    }

    private var openStrip: some View {
        VStack(spacing: 12) {
            if let peer = peers.peers.first {
                Button {
                    Task {
                        for _ in 0..<6 {
                            let code = String(format: "%03d", Int.random(in: 100...999))
                            peers.invite(peer, toCode: code)
                            await line.open(code: code, name: peer.displayName)
                            if line.squad != nil || line.lastOutcome != .taken { return }
                        }
                    }
                } label: {
                    HStack {
                        Avatar(text: peer.initials)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.displayName).font(.system(size: 15.5, weight: .bold, design: .rounded))
                            Text("Right here — tap to open the session")
                                .font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.signal)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .background(Theme.surface.opacity(0.92),
                                in: RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                        .stroke(Theme.signal.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 0) {
                ForEach([false, true], id: \.self) { isPublic in
                    Button {
                        store.prefs.publicLine = isPublic
                        Haptics.select()
                    } label: {
                        VStack(spacing: 2) {
                            Text(isPublic ? "Open group" : "Just us")
                                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                            Text(isPublic ? "Anyone nearby can ask" : "Code only")
                                .font(.system(size: 10.5, design: .rounded))
                                .foregroundStyle(store.prefs.publicLine == isPublic
                                                 ? Theme.onSignal.opacity(0.8) : Theme.muted)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .foregroundStyle(store.prefs.publicLine == isPublic ? Theme.onSignal : Theme.text)
                        .background(store.prefs.publicLine == isPublic ? Theme.signal : .clear,
                                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Theme.surface.opacity(0.92),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Button("Open a session") { creating = true }.buttonStyle(PrimaryButton(hot: true))
            Button("Join with a code") { showKeypad = true }.buttonStyle(QuietButton())
            Text("Open it once at the start. Nobody touches a phone again until you're done.")
                .font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center).padding(.top, 4)
        }
        .padding(.horizontal, 20).padding(.top, 22)
    }
}

/// The stadium behind everything, rotating.
///
/// Four courts, and which one you get depends on the day — the same session on
/// consecutive afternoons does not look identical, and nobody had to choose.
/// It cross-fades on appear rather than cutting, and it is dimmed hard: the
/// photograph is atmosphere, and every word on top of it has to stay readable
/// in direct sun.
struct CourtBackdrop: View {
    /// Sunset first, because it is the one Connor picked and the one the
    /// palette was built against — the sky carries the signal yellow and the
    /// court carries the green.
    private static let courts = ["CourtSunset", "CourtGrass", "CourtClay", "CourtDusk", "CourtNight"]

    /// Rotates by day, then by which half of the day you opened it — so it
    /// changes, but never mid-session while somebody is looking at it.
    @State private var name: String = {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        let hour = Calendar.current.component(.hour, from: Date())
        return courts[(day * 2 + hour / 12) % courts.count]
    }()
    @State private var shown = false

    var body: some View {
        ZStack {
            Theme.base
            Image(name)
                .resizable()
                .scaledToFill()
                .opacity(shown ? 1 : 0)
                .overlay(
                    // Two layers: a flat dim for legibility, and a gradient
                    // that goes heavier at the bottom where the controls are
                    // and lighter at the top where the sky earns its place.
                    LinearGradient(colors: [Theme.base.opacity(0.62), Theme.base.opacity(0.88)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .animation(.easeOut(duration: 0.5), value: shown)
        }
        .ignoresSafeArea()
        .onAppear { shown = true }
        .accessibilityHidden(true)
    }
}
