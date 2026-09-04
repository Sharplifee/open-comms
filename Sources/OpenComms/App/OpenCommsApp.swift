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
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .tint(Theme.signal)
        }
    }
}
