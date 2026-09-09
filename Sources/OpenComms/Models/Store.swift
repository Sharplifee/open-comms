import Foundation
import UIKit
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

    /// Give this phone a name without asking for one.
    ///
    /// "Connor's iPhone" is what the device already calls itself and what
    /// every AirDrop sheet has shown for years, so it is both accurate and
    /// familiar. Anybody who dislikes it changes it in Audio, in one field,
    /// which is a far smaller imposition than a screen you cannot get past.
    func ensureName() {
        guard prefs.displayName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let device = UIDevice.current.name
        // "Connor's iPhone" → "Connor". The possessive is the useful half.
        let possessive = device.range(of: "'s ") ?? device.range(of: "’s ")
        let name = possessive.map { String(device[device.startIndex..<$0.lowerBound]) } ?? device
        prefs.displayName = String(name.prefix(18))
        Task {
            await Backend.shared.registerDevice(displayName: prefs.displayName, phoneHash: nil,
                                                hidden: prefs.visibility == .hidden)
        }
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
