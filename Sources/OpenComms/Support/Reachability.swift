import Network
import Combine

/// Knowing the phone is offline lets the app say so plainly, instead of
/// making somebody watch a spinner for ten seconds to learn the same thing.
@MainActor
final class Reachability: ObservableObject {
    static let shared = Reachability()
    @Published private(set) var online = true

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.online = (path.status == .satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "opencomms.reachability"))
    }
}
