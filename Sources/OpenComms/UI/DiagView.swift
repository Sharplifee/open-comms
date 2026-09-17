import SwiftUI

/// What the app can actually see about itself.
///
/// Every row here is read from a live source rather than stored, because the
/// entire point is answering "why is this not working" at the moment it is not
/// working. A diagnostics screen that shows a cached value is worse than none.
struct DiagView: View {
    @EnvironmentObject private var line: LineManager
    @EnvironmentObject private var store: Store
    @ObservedObject private var net = Reachability.shared
    @ObservedObject private var nearby = NearbyEngine.shared
    @ObservedObject private var peers = PeerDiscovery.shared
    @ObservedObject private var check = SoundCheck.shared
    @State private var copied = false
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Diagnostics")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .padding(.horizontal, 22).padding(.top, 4).padding(.bottom, 18)

                VStack(spacing: 11) {
                    row("Audio route", AudioSession.shared.routeName, .good)
                    row("Microphone", line.micLive ? "Live" : "Muted", line.micLive ? .good : .idle)
                    row("Location", nearby.denied ? "Denied" : "Granted", nearby.denied ? .bad : .good)
                    row("Network", net.online ? "Online" : "Offline", net.online ? .good : .bad)
                    row("Line", connectionText, line.squad == nil ? .idle : .good)
                    row("On the line", "\(line.members.count)", line.members.isEmpty ? .idle : .good)
                    // The four facts that separate "they can't hear me" from
                    // "I can't hear them". All of these were available during
                    // the one-way failure and none were on screen.
                    row("Incoming audio", incoming, incomingHealth)
                    row("Nearby", nearby.denied ? "—" : "\(nearby.people.count) in range", .good)
                    row("Right here", peers.running ? "\(peers.peers.count) over Bluetooth/Wi-Fi" : "Not running",
                        peers.running ? .good : .idle)
                    row("Session", AudioSession.shared.liveDescription, .good)
                    row("Mic in use", AudioSession.shared.inputName, .good)
                    row("Incoming audio",
                        line.squad == nil ? "—"
                            : "\(line.incomingTracks.playing) of \(line.incomingTracks.subscribed) playing",
                        line.squad == nil ? .idle
                            : line.incomingTracks.playing > 0 ? .good : .bad)
                    row("Their volume", "\(Int(store.prefs.theirVolume * 100))%",
                        store.prefs.theirVolume > 0.05 ? .good : .bad)
                    row("Background", "audio", .good)
                    row("Wake on push", "standard · tap to rejoin", .good)
                    row("Version", version, .good)
                }
                .padding(.horizontal, 22)

                // The first thing to reach for when somebody says they heard
                // nothing, because "I heard nothing" covers five different
                // faults and this tells them apart in ten seconds.
                Button(check.running ? "Checking…" : "Sound check") {
                    Task { await check.run() }
                }
                .buttonStyle(PrimaryButton(hot: true))
                .disabled(check.running)
                .padding(.horizontal, 22).padding(.top, 16)

                if !check.lines.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(check.lines.enumerated()), id: \.offset) { _, entry in
                            Text(entry)
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundStyle(entry.hasPrefix("⚠︎") ? Theme.danger : Theme.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button("Copy this") {
                            UIPasteboard.general.string = check.lines.joined(separator: "\n")
                            Haptics.tap(.light)
                        }
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.signal)
                        .padding(.top, 4)
                    }
                    .padding(16)
                    .cardSurface()
                    .padding(.horizontal, 22).padding(.top, 12)
                }

                Button("Play a test tone") { AudioProbe.shared.play(); Haptics.tap(.light) }
                    .buttonStyle(PrimaryButton(hot: true))
                    .padding(.horizontal, 22).padding(.top, 16)

                Text("Two short notes through whatever you're listening on. Hear them and playback is fine, so any silence is coming from the other end.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Theme.dim)
                    .padding(.horizontal, 24).padding(.top, 8)

                HStack(spacing: 11) {
                    Button("Force reconnect") { Task { await reconnect() } }
                        .buttonStyle(PrimaryButton())
                    Button(copied ? "Copied" : "Copy") { copy() }
                        .buttonStyle(PrimaryButton())
                }
                .padding(.horizontal, 22).padding(.top, 16)

                Text("Force reconnect leaves the line and opens the same code again. Everybody else stays where they are.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Theme.dim)
                    .padding(.horizontal, 24).padding(.top, 12)
            }
            .padding(.bottom, 28)
        }
        .background(Theme.base.ignoresSafeArea())
        .onReceive(tick) { now = $0 }
    }

    private enum Health { case good, idle, bad
        var colour: Color {
            switch self {
            case .good: return Theme.signal
            case .idle: return Theme.muted
            case .bad:  return Theme.danger
            }
        }
    }

    private func row(_ title: String, _ value: String, _ health: Health) -> some View {
        HStack(spacing: 11) {
            Circle().fill(health.colour).frame(width: 8, height: 8)
            Text(title).font(.system(size: 15, weight: .semibold, design: .rounded))
            Spacer()
            Text(value)
                .font(.system(size: 13.5, design: .monospaced))
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .cardSurface(Theme.rowRadius)
    }

    /// Reads as a sentence rather than four counters, because the person
    /// looking at it is trying to answer one question.
    private var incoming: String {
        guard line.squad != nil else { return "—" }
        let r = line.incomingReport
        if r.tracks == 0 { return "nothing published" }
        if r.subscribed == 0 { return "\(r.tracks) sent, none subscribed" }
        if r.muted == r.tracks { return "all muted at source" }
        if r.audible == 0 { return "subscribed, silenced here" }
        return "\(r.audible) of \(r.tracks) audible"
    }

    private var incomingHealth: Health {
        guard line.squad != nil else { return .idle }
        let r = line.incomingReport
        if r.tracks == 0 || r.subscribed == 0 { return .bad }
        return r.audible > 0 ? .good : .bad
    }

    private var connectionText: String {
        guard let squad = line.squad else { return "None" }
        return "\(squad.code) · \(line.elapsed)"
    }

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    /// Rejoining by code rather than poking the socket, because the failure
    /// this is here to clear is usually a room the phone thinks it is in and
    /// isn't. Anything subtler needs the server's view, not the client's.
    private func reconnect() async {
        guard let code = line.squad?.code else { return }
        await line.leave()
        await line.join(code: code)
    }

    private func copy() {
        UIPasteboard.general.string = """
        OpenComms \(version)
        route: \(AudioSession.shared.routeName)
        mic: \(line.micLive ? "live" : "muted")
        location: \(nearby.denied ? "denied" : "granted")
        network: \(net.online ? "online" : "offline")
        line: \(connectionText)
        members: \(line.members.count)
        nearby: \(nearby.people.count)
        incoming: \(incoming)
        session: \(AudioSession.shared.liveDescription)
        mic in: \(AudioSession.shared.inputName)
        incoming: \(line.incomingTracks.playing)/\(line.incomingTracks.subscribed)
        right here: \(peers.running ? String(peers.peers.count) : "not running")
        visibility: \(store.prefs.visibility.rawValue)
        """
        copied = true
        Haptics.tap(.light)
        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
    }
}
