import SwiftUI

/// Three gates, in the order somebody meets them: the pitch, their name, then
/// the app. There is no account to make and nothing to verify.
struct RootView: View {
    @StateObject private var store = Store.shared
    @StateObject private var line = LineManager.shared

    var body: some View {
        Group {
            if !store.prefs.onboarded {
                OnboardingView()
            } else if store.prefs.displayName.isEmpty {
                NameEntryView()
            } else {
                MainTabs()
            }
        }
        .environmentObject(store)
        .environmentObject(line)
        .background(Theme.base.ignoresSafeArea())
    }
}

struct MainTabs: View {
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            LineView().tabItem { Label("Home", systemImage: "house.fill") }.tag(0)
            SquadView().tabItem { Label("Squad", systemImage: "person.2.fill") }.tag(1)
            SettingsView().tabItem { Label("Audio", systemImage: "slider.horizontal.3") }.tag(2)
            DiagView().tabItem { Label("Diag", systemImage: "gauge.with.dots.needle.bottom.50percent") }.tag(3)
        }
    }
}
