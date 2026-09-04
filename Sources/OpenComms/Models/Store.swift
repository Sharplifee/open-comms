import Foundation
import Combine

/// Preferences and saved squads, kept on the phone and mirrored to iCloud so a
/// new device does not start from nothing.
@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var prefs = Preferences() { didSet { persist(prefs, key: prefsKey) } }
    @Published var saved: [SavedSquad] = [] { didSet { persist(saved, key: savedKey) } }

    private let prefsKey = "opencomms.preferences.v1"
    private let savedKey = "opencomms.saved.v1"

    private init() {
        prefs = load(Preferences.self, key: prefsKey) ?? Preferences()
        saved = load([SavedSquad].self, key: savedKey) ?? []
    }

    func remember(_ squad: Squad) {
        var list = saved.filter { $0.code != squad.code }
        list.insert(SavedSquad(code: squad.code, name: squad.name, lastUsed: Date()), at: 0)
        saved = Array(list.prefix(6))
    }

    func forget(_ code: String) { saved.removeAll { $0.code == code } }

    private func persist<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
        NSUbiquitousKeyValueStore.default.set(data, forKey: key)
    }

    private func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key)
                ?? NSUbiquitousKeyValueStore.default.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
