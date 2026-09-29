import SwiftUI
import Sentry

@main
struct OpenCommsApp: App {
    init() {
        if !Config.sentryDSN.isEmpty {
            SentrySDK.start { options in
                options.dsn = Config.sentryDSN
                options.tracesSampleRate = 0.2
            }
        }
        // Low power was only applied when the switch was touched, so it was
        // forgotten on every launch: the setting read "on" and the radar kept
        // running at full rate. Apply the saved value at startup.
        NearbyEngine.shared.setLowPower(Store.shared.prefs.lowPower)

        // Re-register on every launch. registerDevice was called exactly once,
        // at name entry, so the row was never refreshed afterwards: a name set
        // before that call existed, or a row removed by "Delete my data" while
        // the app kept running, left the device permanently unknown to the
        // server — and an unknown device is invisible on everybody's radar.
        // It is an upsert, so this is cheap and idempotent.
        let prefs = Store.shared.prefs
        Theme.skin = prefs.skin
        if !prefs.displayName.isEmpty {
            Task {
                await Backend.shared.registerDevice(displayName: prefs.displayName,
                                                    phoneHash: nil,
                                                    hidden: prefs.visibility == .hidden)
            }
        }
    }

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .tint(Theme.signal)
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back from the background is the single most likely moment
            // to find a line that is open on screen and dead underneath. iOS
            // can drop the socket while the app is suspended and deliver
            // nothing about it, so the app looks for itself instead of
            // trusting an event that may never arrive.
            guard phase == .active else { return }
            LineManager.shared.recoverIfDropped()
        }
    }
}
