import Contacts
import CryptoKit
import Foundation

/// Which of your contacts already have the app.
///
/// Only hashes leave the phone. The server cannot recover a number from one,
/// and cannot be used to enumerate anybody, because you can only ask about
/// hashes you already hold — which means you already had the number.
///
/// Your own number is the one thing iOS will not tell an app, so it is asked
/// for once and hashed the same way; without it nobody can find you, only
/// you them.
@MainActor
final class ContactMatcher: ObservableObject {
    static let shared = ContactMatcher()

    enum Access { case unknown, granted, denied }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var matches: [ContactMatch] = []
    @Published private(set) var working = false

    private let store = CNContactStore()

    private init() {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: access = .granted
        case .denied, .restricted: access = .denied
        default: access = .unknown
        }
    }

    func request() async {
        let granted = (try? await store.requestAccess(for: .contacts)) ?? false
        access = granted ? .granted : .denied
        if granted { await refresh() }
    }

    /// Read every number, hash it, ask the server which hashes it knows.
    func refresh() async {
        guard access == .granted, !working else { return }
        working = true
        defer { working = false }

        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var hashToName: [String: String] = [:]

        try? store.enumerateContacts(with: request) { contact, _ in
            let name = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }.joined(separator: " ")
            for number in contact.phoneNumbers {
                let hash = ContactMatcher.hash(phone: number.value.stringValue)
                hashToName[hash] = name.isEmpty ? "Someone" : name
            }
        }
        guard !hashToName.isEmpty else { matches = []; return }

        let rows = await Backend.shared.matchContacts(hashes: Array(hashToName.keys))
        matches = rows.map {
            ContactMatch(phoneHash: $0.phone_hash,
                         // Their name from YOUR address book wins over whatever
                         // they typed into the app, because that is who they
                         // are to you.
                         displayName: hashToName[$0.phone_hash] ?? $0.display_name)
        }
        .sorted { $0.displayName < $1.displayName }
    }

    /// E.164-ish normalisation so the same number typed two ways hashes the
    /// same: digits only, and a bare ten-digit number is assumed +1.
    static func hash(phone: String) -> String {
        let digits = phone.filter(\.isNumber)
        let e164 = digits.count == 10 ? "+1\(digits)" : "+\(digits)"
        return SHA256.hash(data: Data(e164.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct ContactMatch: Identifiable, Equatable {
    var id: String { phoneHash }
    let phoneHash: String
    let displayName: String
    var initials: String { String(displayName.prefix(2)).uppercased() }
}
