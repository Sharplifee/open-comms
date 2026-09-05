import SwiftUI

/// Who you already know that has the app.
///
/// Before it asks for anything it says exactly what happens to the numbers,
/// because "allow contacts" with no explanation is the kind of prompt people
/// rightly refuse.
struct ContactsView: View {
    @EnvironmentObject private var line: LineManager
    @EnvironmentObject private var store: Store
    @StateObject private var matcher = ContactMatcher.shared
    @State private var search = ""
    @State private var creating = false

    private var found: [ContactMatch] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? matcher.matches : matcher.matches.filter { $0.displayName.lowercased().contains(q) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Contacts")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 14)

                switch matcher.access {
                case .granted: list
                case .denied: denied
                case .unknown: ask
                }
            }
            .padding(.bottom, 24)
        }
        .background(Theme.base.ignoresSafeArea())
        .sheet(isPresented: $creating) { CodeKeypad(mode: .create) }
        .task { await matcher.refresh() }
        .refreshable { await matcher.refresh() }
    }

    private var ask: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "person.crop.rectangle.stack")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.signal)
                .frame(width: 74, height: 74)
                .background(Theme.signal.opacity(0.12), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            Text("See who you\nalready know")
                .font(.system(size: 26, weight: .bold, design: .rounded)).padding(.top, 24)
            Text("Your numbers are hashed on the phone before anything leaves it. Only the hashes are compared, and nothing readable is ever uploaded.")
                .font(.system(size: 15, design: .rounded)).foregroundStyle(Theme.muted).padding(.top, 12)
            Button("Allow Contacts") { Task { await matcher.request() } }
                .buttonStyle(PrimaryButton(hot: true))
                .padding(.top, 26)
        }
        .padding(.horizontal, 26).padding(.top, 20)
    }

    private var denied: some View {
        StateBlock(icon: "person.crop.circle.badge.xmark", title: "Contacts is off",
                   detail: "Nothing else in the app needs it. Turn it on in Settings if you'd like to see who you know.")
            .cardSurface().padding(.horizontal, 20)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("Search contacts", text: $search)
                    .font(.system(size: 14.5, design: .rounded))
            }
            .padding(EdgeInsets(top: 12, leading: 15, bottom: 12, trailing: 15))
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line, lineWidth: 1))
            .padding(.horizontal, 20)

            Text("ON OPENCOMMS — \(found.count)")
                .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(Theme.muted)
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8)

            if matcher.working && matcher.matches.isEmpty {
                ProgressView().tint(Theme.signal).frame(maxWidth: .infinity).padding(.vertical, 24)
            } else if found.isEmpty {
                Text(search.isEmpty ? "Nobody in your contacts has the app yet" : "No match for \"\(search)\"")
                    .font(.system(size: 14, design: .rounded)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity).padding(.vertical, 22)
            } else {
                ForEach(found) { contact in
                    HStack(spacing: 13) {
                        Avatar(text: contact.initials)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(contact.displayName).font(.system(size: 15.5, weight: .bold, design: .rounded))
                            Text("Matched from contacts").font(.system(size: 12, design: .rounded))
                                .foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Button("Invite") { creating = true }
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.signal)
                            .padding(.horizontal, 13).padding(.vertical, 7)
                            .overlay(Capsule().stroke(Theme.signal, lineWidth: 1))
                    }
                    .padding(EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14))
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line, lineWidth: 1))
                    .padding(.horizontal, 20).padding(.bottom, 9)
                }
            }

            Text("HOW MATCHING WORKS")
                .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(Theme.muted)
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 3) {
                Text("Your contacts stay on your phone").font(.system(size: 15, weight: .semibold, design: .rounded))
                Text("Numbers are hashed with SHA-256 before they leave the device and only the hashes are compared.")
                    .font(.system(size: 11.5, design: .rounded)).foregroundStyle(Theme.muted)
            }
            .padding(EdgeInsets(top: 15, leading: 18, bottom: 15, trailing: 18))
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
            .padding(.horizontal, 20)
        }
    }
}
