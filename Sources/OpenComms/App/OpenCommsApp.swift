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
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .tint(Theme.signal)
        }
    }
}
