import SwiftUI

/// Everyone on the line, and what you can do about each of them.
///
/// Turning somebody down only changes what you hear — they still hear you.
/// That is stated on screen, because a mute that silently cut both ways would
/// be a nasty surprise mid-conversation.
struct SquadView: View {
    @EnvironmentObject private var line: LineManager
    @EnvironmentObject private var store: Store
    @State private var reporting: Member?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("SQUAD")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .kerning(1.3).foregroundStyle(Theme.dim)
                    .padding(.horizontal, 22).padding(.top, 4).padding(.bottom, 18)

                if line.squad == nil {
                    StateBlock(icon: "person.2.slash",
                               title: "No line open",
                               detail: "Open one from the Line tab and everyone on it shows up here.")
                        .cardSurface().padding(.horizontal, 22)
                } else {
                    VStack(spacing: 0) {
                        ForEach(line.members) { member in
                            memberRow(member)
                            if member.deviceID != line.members.last?.deviceID {
                                Divider().overlay(Theme.line)
                            }
                        }
                    }
                    .cardSurface().padding(.horizontal, 22)

                    Button("Save this squad") {
                        if let squad = line.squad { store.remember(squad) }
                        Haptics.tap(.light)
                    }
                    .buttonStyle(QuietButton())
                    .padding(.horizontal, 22).padding(.top, 14)

                    Text("Turning somebody down only changes what you hear. They still hear you.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Theme.dim)
                        .padding(.horizontal, 24).padding(.top, 16)
                }
            }
            .padding(.bottom, 24)
        }
        .background(Theme.base.ignoresSafeArea())
        .confirmationDialog("Block and report?", isPresented: reportBinding, titleVisibility: .visible) {
            Button("Harassment", role: .destructive) { report("harassment") }
            Button("Abusive language", role: .destructive) { report("abuse") }
            Button("Someone I don't know", role: .destructive) { report("stranger") }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They're removed from this line, can't hear you or find you again, and the report goes to review.")
        }
    }

    private var reportBinding: Binding<Bool> {
        Binding(get: { reporting != nil }, set: { if !$0 { reporting = nil } })
    }

    private func report(_ reason: String) {
        guard let member = reporting else { return }
        Task { await line.blockAndReport(member, reason: reason) }
        reporting = nil
    }

    private func memberRow(_ member: Member) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 13) {
                Avatar(text: member.initials, live: member.isSpeaking && !member.mutedForMe)
                VStack(alignment: .leading, spacing: 2) {
                    Text(member.isSelf ? "\(member.displayName) · you" : member.displayName)
                        .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                    Text(status(member))
                        .font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.muted)
                }
                Spacer()
                if !member.isSelf {
                    Slider(value: Binding(
                        get: { member.volume },
                        set: { line.setVolume($0, for: member) }), in: 0...1)
                        .tint(Theme.signal).frame(width: 88)
                }
            }

            if !member.isSelf {
                HStack {
                    Toggle("I hear them", isOn: Binding(
                        get: { !member.mutedForMe },
                        set: { line.setMuted(!$0, for: member) }))
                        .font(.system(size: 13.5, design: .rounded))
                        .tint(Theme.signal)
                }
                Button("Block and report \(member.displayName)") { reporting = member }
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.danger)
            }
        }
        .padding(.horizontal, 17).padding(.vertical, 15)
    }

    private func status(_ member: Member) -> String {
        if member.isSelf { return line.micLive ? "Your mic is live" : "You're muted" }
        if member.mutedForMe { return "Muted for you" }
        return member.isSpeaking ? "Talking now" : "Listening"
    }
}
