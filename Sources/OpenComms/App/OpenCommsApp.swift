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
        if !prefs.displayName.isEmpty {
            Task {
                await Backend.shared.registerDevice(displayName: prefs.displayName,
                                                    phoneHash: nil,
                                                    hidden: prefs.visibility == .hidden)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .tint(Theme.signal)
        }
    }
}
