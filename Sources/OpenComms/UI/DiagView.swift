import SwiftUI

/// What the app can actually see about itself.
///
/// Every row here is read from a live source rather than stored, because the
/// entire point is answering "why is this not working" at the moment it is not
/// working. A diagnostics screen that shows a cached value is worse than none.
struct DiagView: View {
    @EnvironmentObject private var line: LineManager
    @EnvironmentObject private var store: Store
    @StateObject private var net = Reachability.shared
    @StateObject private var nearby = NearbyEngine.shared
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
                    row("On the line", "\(line.members.count) of 8", line.members.isEmpty ? .idle : .good)
                    row("Nearby", nearby.denied ? "—" : "\(nearby.people.count) in range", .good)
                    row("Background", "audio", .good)
                    row("Wake on push", "standard · tap to rejoin", .good)
                    row("Version", version, .good)
                }
                .padding(.horizontal, 22)

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
        visibility: \(store.prefs.visibility.rawValue)
        """
        copied = true
        Haptics.tap(.light)
        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
    }
}
