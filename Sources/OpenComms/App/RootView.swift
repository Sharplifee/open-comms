import SwiftUI

/// The app, immediately. No welcome screens, no name gate, nothing to agree
/// to before anything works.
///
/// There was a three-screen pitch and a forced name entry in front of this.
/// Neither earned its place: the pitch explained an app somebody had already
/// chosen to install, and the name is a label on a voice line that can be
/// filled in from the device and changed later in a second. Permissions are
/// asked for at the moment they are needed — tapping the mic asks for the
/// mic — which is both better for the person and what iOS actually wants.
struct RootView: View {
    @StateObject private var store = Store.shared
    @StateObject private var line = LineManager.shared

    var body: some View {
        MainTabs()
            .environmentObject(store)
            .environmentObject(line)
            .background(Theme.base.ignoresSafeArea())
            .task { store.ensureName() }
    }
}

struct MainTabs: View {
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            HomeView().tabItem { Label("Home", systemImage: "house.fill") }.tag(0)
            SquadView().tabItem { Label("Squad", systemImage: "person.2.fill") }.tag(1)
            ContactsView().tabItem { Label("Contacts", systemImage: "person.crop.circle.fill") }.tag(2)
            AudioView().tabItem { Label("Audio", systemImage: "slider.horizontal.3") }.tag(3)
            DiagView().tabItem { Label("Diag", systemImage: "gauge.with.dots.needle.bottom.50percent") }.tag(4)
        }
        .tint(Theme.signal)
    }
}
