import SwiftUI

/// Court mode. Not a skin — a different app for a different job.
///
/// On a doubles court the radar is meaningless: your partner is eight feet
/// away and you can see them. What you cannot do is talk to them without the
/// other pair hearing, or agree a poach without a hand behind your back, or
/// remember the score after a long game. So this screen throws away the
/// discovery half of the app and gives the space to the three things that are
/// actually hard on court: the score, the silent signal, and the line itself.
///
/// Everything underneath is the same app. Same line, same codes, same audio
/// settings, same people. Only what is on the glass changes.
struct CourtView: View {
    @EnvironmentObject private var line: LineManager
    @EnvironmentObject private var store: Store
    @ObservedObject private var peers = PeerDiscovery.shared

    @State private var creating = false
    @State private var showKeypad = false
    @State private var leaving = false
    @State private var flash: PartnerSignal?

    var body: some View {
        ZStack {
            CourtBackdrop()
            ScrollView {
                VStack(spacing: 0) {
                    header
                    scoreboard
                    if line.squad != nil {
                        signals
                        courtDiagram
                        micStrip
                        Button("Leave the line") { leaving = true }
                            .buttonStyle(QuietButton())
                            .padding(.horizontal, 20).padding(.top, 16)
                    } else {
                        openStrip
                    }
                }
                .padding(.bottom, 28)
            }
            if let flash { signalFlash(flash) }
        }
        .background(Theme.base.ignoresSafeArea())
        .sheet(isPresented: $creating) { CodeKeypad(mode: .create) }
        .sheet(isPresented: $showKeypad) { CodeKeypad(mode: .join) }
        .confirmationDialog("Leave this line?", isPresented: $leaving, titleVisibility: .visible) {
            Button("End for both", role: .destructive) { Task { await line.endForEveryone() } }
            Button("Just leave") { Task { await line.leave() } }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: line.lastSignal?.at) { _, _ in
            guard let signal = line.lastSignal?.signal else { return }
            withAnimation(.spring(duration: 0.25)) { flash = signal }
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation { flash = nil }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("COURT").font(.system(size: 12, weight: .bold, design: .rounded)).kerning(2)
                    .foregroundStyle(Theme.signal)
                Text(line.squad == nil ? "No line open" : "On the line with \(partnerName)")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { store.prefs.courtMode = false }
                Haptics.tap(.light)
            } label: {
                Text("Exit court")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 13).padding(.vertical, 7)
                    .background(Theme.raised.opacity(0.85), in: Capsule())
            }
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 16)
    }

    private var partnerName: String {
        line.members.first(where: { !$0.isSelf })?.displayName ?? "your partner"
    }

    // MARK: - Scoreboard

    /// The scoreboard reads like the one on the wall: sets, games, points,
    /// server marked with a ball. Tapping a side adds a point to it, because
    /// on court you have one hand free and about a second to do it.
    private var scoreboard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sideColumn(0, "US")
                Rectangle().fill(Theme.line).frame(width: 1)
                sideColumn(1, "THEM")
            }
            .frame(height: 132)

            HStack(spacing: 18) {
                Button {
                    line.score.undoPoint(line.score.points[0] >= line.score.points[1] ? 0 : 1)
                    line.shareScore(); Haptics.select()
                } label: { smallControl("Undo point", "arrow.uturn.backward") }

                Button {
                    line.score.server = 1 - line.score.server
                    line.shareScore(); Haptics.select()
                } label: { smallControl("Change server", "arrow.left.arrow.right") }

                Button {
                    line.score.reset(); line.shareScore(); Haptics.tap()
                } label: { smallControl("New match", "arrow.counterclockwise") }
            }
            .padding(.vertical, 14)
        }
        .background(Theme.surface.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .stroke(Theme.line, lineWidth: 1))
        .padding(.horizontal, 20)
    }

    private func sideColumn(_ side: Int, _ title: String) -> some View {
        Button {
            line.score.point(to: side)
            line.shareScore()
            Haptics.tap()
        } label: {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    if line.score.server == side {
                        Circle().fill(Theme.signal).frame(width: 8, height: 8)
                    }
                    Text(title).font(.system(size: 11, weight: .bold, design: .rounded)).kerning(1.5)
                        .foregroundStyle(Theme.muted)
                }
                Text(line.score.display(side))
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
                Text("\(line.score.sets[side]) · \(line.score.games[side])")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func smallControl(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
            Text(title).font(.system(size: 10, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(Theme.muted)
    }

    // MARK: - Signals

    /// The reason this mode exists. One tap, and it arrives in your partner's
    /// ear and on their wrist — no hand behind the back, and nothing for the
    /// other pair to read.
    private var signals: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SIGNAL YOUR PARTNER")
                .font(.system(size: 11, weight: .bold, design: .rounded)).kerning(1.5)
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 20)

            LazyVGrid(columns: Array(repeating: GridItem(spacing: 10), count: 3), spacing: 10) {
                ForEach(PartnerSignal.allCases.filter(\.isPreServe)) { signal in
                    Button { line.send(signal) } label: { signalTile(signal) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)

            HStack(spacing: 10) {
                ForEach(PartnerSignal.allCases.filter { !$0.isPreServe }) { signal in
                    Button { line.send(signal) } label: { signalTile(signal, wide: true) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.top, 20)
    }

    private func signalTile(_ signal: PartnerSignal, wide: Bool = false) -> some View {
        VStack(spacing: 6) {
            Image(systemName: signal.symbol).font(.system(size: 17, weight: .semibold))
            Text(signal.label).font(.system(size: 12, weight: .bold, design: .rounded))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, wide ? 16 : 14)
        .foregroundStyle(wide ? Theme.onSignal : Theme.text)
        .background(wide ? Theme.signal : Theme.surface.opacity(0.92),
                    in: RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
            .stroke(wide ? .clear : Theme.line, lineWidth: 1))
    }

    private func signalFlash(_ signal: PartnerSignal) -> some View {
        VStack(spacing: 10) {
            Image(systemName: signal.symbol).font(.system(size: 44, weight: .bold))
            Text(signal.label.uppercased())
                .font(.system(size: 30, weight: .bold, design: .rounded)).kerning(1)
        }
        .foregroundStyle(Theme.onSignal)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.signal.opacity(0.94).ignoresSafeArea())
        .transition(.opacity)
        .allowsHitTesting(false)
        .accessibilityLabel("Partner signalled \(signal.label)")
    }

    // MARK: - Court diagram

    /// Which side you are standing on, for the moment somebody forgets whether
    /// they are serving from deuce or ad. Tap to swap.
    private var courtDiagram: some View {
        Button {
            line.score.onDeuceSide.toggle(); line.shareScore(); Haptics.select()
        } label: {
            VStack(spacing: 8) {
                Canvas { context, size in
                    let w = size.width, h = size.height
                    let court = CGRect(x: w * 0.12, y: 6, width: w * 0.76, height: h - 12)
                    context.stroke(Path(court), with: .color(Theme.line), lineWidth: 1.5)
                    // service line and centre line: enough court to read at a
                    // glance, not a diagram of the rulebook
                    var lines = Path()
                    lines.move(to: CGPoint(x: court.minX, y: court.midY))
                    lines.addLine(to: CGPoint(x: court.maxX, y: court.midY))
                    lines.move(to: CGPoint(x: court.midX, y: court.minY))
                    lines.addLine(to: CGPoint(x: court.midX, y: court.midY))
                    context.stroke(lines, with: .color(Theme.line.opacity(0.8)), lineWidth: 1)

                    let box = line.score.onDeuceSide
                        ? CGRect(x: court.midX, y: court.minY, width: court.width / 2, height: court.height / 2)
                        : CGRect(x: court.minX, y: court.minY, width: court.width / 2, height: court.height / 2)
                    context.fill(Path(box), with: .color(Theme.signal.opacity(0.22)))
                }
                .frame(height: 96)

                Text(line.score.onDeuceSide ? "You're on the deuce side" : "You're on the ad side")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.vertical, 14)
            .background(Theme.surface.opacity(0.92),
                        in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .stroke(Theme.line, lineWidth: 1))
            .padding(.horizontal, 20).padding(.top, 20)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Mic and opening

    /// One line, one control. The full meter lives in Audio; on court you only
    /// need to know whether you are open and be able to close it fast.
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
        .padding(.horizontal, 20).padding(.top, 20)
    }

    private var openStrip: some View {
        VStack(spacing: 12) {
            if let peer = peers.peers.first {
                Button {
                    let code = String(format: "%03d", Int.random(in: 100...999))
                    peers.invite(peer, toCode: code)
                    Task { await line.open(code: code, name: peer.displayName) }
                } label: {
                    HStack {
                        Avatar(text: peer.initials)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.displayName).font(.system(size: 15.5, weight: .bold, design: .rounded))
                            Text("Right here — tap to open the line")
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
            Button("Open a line") { creating = true }.buttonStyle(PrimaryButton(hot: true))
            Button("Join with a code") { showKeypad = true }.buttonStyle(QuietButton())
        }
        .padding(.horizontal, 20).padding(.top, 22)
    }
}

/// The stadium behind everything.
///
/// Drawn rather than photographed: a photograph of a real venue is somebody
/// else's property, and a court that is drawn scales to every screen and tints
/// itself with the skin. Drop an image named "CourtBackdrop" into the asset
/// catalogue and it is used instead — the shape below is what shows until
/// then.
struct CourtBackdrop: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                if UIImage(named: "CourtBackdrop") != nil {
                    Image("CourtBackdrop")
                        .resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .overlay(Theme.base.opacity(0.72))
                } else {
                    LinearGradient(colors: [Theme.base, Theme.surface, Theme.base],
                                   startPoint: .top, endPoint: .bottom)
                    Canvas { context, size in
                        // A show court seen from the far corner: the bowl, the
                        // lit surface, the lines converging. Enough to feel
                        // like a stadium at a glance and quiet enough to read
                        // a scoreboard over.
                        let w = size.width, h = size.height
                        var bowl = Path()
                        bowl.move(to: CGPoint(x: 0, y: h * 0.18))
                        bowl.addQuadCurve(to: CGPoint(x: w, y: h * 0.18),
                                          control: CGPoint(x: w / 2, y: -h * 0.06))
                        bowl.addLine(to: CGPoint(x: w, y: 0))
                        bowl.addLine(to: CGPoint(x: 0, y: 0))
                        bowl.closeSubpath()
                        context.fill(bowl, with: .color(Theme.raised.opacity(0.55)))

                        var surface = Path()
                        surface.move(to: CGPoint(x: w * 0.18, y: h * 0.30))
                        surface.addLine(to: CGPoint(x: w * 0.82, y: h * 0.30))
                        surface.addLine(to: CGPoint(x: w * 1.12, y: h * 0.92))
                        surface.addLine(to: CGPoint(x: -w * 0.12, y: h * 0.92))
                        surface.closeSubpath()
                        context.fill(surface, with: .color(Theme.signal.opacity(0.05)))
                        context.stroke(surface, with: .color(Theme.line.opacity(0.45)), lineWidth: 1)

                        var service = Path()
                        service.move(to: CGPoint(x: w * 0.08, y: h * 0.66))
                        service.addLine(to: CGPoint(x: w * 0.92, y: h * 0.66))
                        service.move(to: CGPoint(x: w * 0.5, y: h * 0.30))
                        service.addLine(to: CGPoint(x: w * 0.5, y: h * 0.92))
                        context.stroke(service, with: .color(Theme.line.opacity(0.35)), lineWidth: 1)
                    }
                }
            }
            .ignoresSafeArea()
        }
    }
}
