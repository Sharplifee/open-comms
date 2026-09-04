import Foundation

/// Every value the app needs to reach its own backend.
///
/// These are public by design. The Supabase anon key can only reach the
/// database through SECURITY DEFINER functions, and the LiveKit token is
/// minted server side, so neither grants a stranger anything a normal user of
/// the app does not already have.
enum Config {
    static let supabaseURL = "https://tbgcinfhgskcjoevfkea.supabase.co"
    static let supabaseAnonKey = Bundle.infoValue("SUPABASE_ANON_KEY")
    static let livekitURL = "wss://felix-qis9squs.livekit.cloud"
    static let sentryDSN = Bundle.infoValue("SENTRY_DSN")

    /// Rooms are namespaced so this app can share a LiveKit project with
    /// others and never land two squads in one room.
    static func room(for squadID: String) -> String { "opencomms-\(squadID)" }
}

extension Bundle {
    static func infoValue(_ key: String) -> String {
        (main.object(forInfoDictionaryKey: key) as? String) ?? ""
    }
}
