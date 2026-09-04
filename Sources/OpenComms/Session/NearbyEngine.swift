import CoreLocation
import Combine

/// Who is close enough to talk to.
///
/// Location is only ever used to answer one question — how far away is this
/// person right now — so the app stores a position and never a history, keeps
/// it while-in-use only, and shows distance and bearing rather than an
/// address. Reverse geocoding produced a street-level record of everywhere
/// somebody had been, for a field nothing ever read.
@MainActor
final class NearbyEngine: NSObject, ObservableObject {
    static let shared = NearbyEngine()

    @Published private(set) var people: [NearbyPerson] = []
    @Published private(set) var denied = false
    @Published var radiusMetres: Double = 152 {  // 500 ft by default
        // Widening the range and waiting eight seconds to find out whether it
        // helped reads as the control not working.
        didSet { Task { await refresh() } }
    }

    private let manager = CLLocationManager()
    private var lastWrite = Date.distantPast
    private var here: CLLocation?
    private var poll: Task<Void, Never>?
    private var lowPower = false

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        guard Store.shared.prefs.visibility != .hidden else { return }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: denied = true
        default:
            manager.startUpdatingLocation()
            startPolling()
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        poll?.cancel(); poll = nil
        people = []
    }

    /// Ask the server who else is here.
    ///
    /// Writing your own position and never asking about anybody else's is
    /// what this engine did before: `people` was published, the radar and the
    /// list read it, and nothing ever filled it. So the radar was always
    /// empty and the empty state was the only state anyone ever saw.
    private func startPolling() {
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let gap = await self?.lowPower == true ? 20 : 8
                try? await Task.sleep(for: .seconds(gap))
            }
        }
    }

    func refresh() async {
        guard let fix = here, Store.shared.prefs.visibility != .hidden else { return }
        let rows = await Backend.shared.nearby(lat: fix.coordinate.latitude,
                                               lon: fix.coordinate.longitude,
                                               radius: radiusMetres)
        people = rows.map {
            NearbyPerson(id: $0.device_id, displayName: $0.display_name,
                         metres: $0.metres, bearing: $0.bearing)
        }
    }

    /// Low power widens the filter rather than turning location off, because
    /// a radar that silently stops updating is worse than one that updates
    /// slowly — it looks the same but lies.
    func setLowPower(_ on: Bool) {
        lowPower = on
        manager.distanceFilter = on ? 25 : 5
    }

    private func bearing(from: CLLocation, to: CLLocation) -> Double {
        let lat1 = from.coordinate.latitude * .pi / 180
        let lat2 = to.coordinate.latitude * .pi / 180
        let dLon = (to.coordinate.longitude - from.coordinate.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return atan2(y, x)
    }
}

extension NearbyEngine: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { return }
        // A reading that vague says nothing useful about who is in the room.
        guard fix.horizontalAccuracy > 0, fix.horizontalAccuracy < 200 else { return }
        Task { @MainActor in
            self.here = fix
            guard Date().timeIntervalSince(self.lastWrite) > 8 else { return }
            self.lastWrite = Date()
            await Backend.shared.updateLocation(lat: fix.coordinate.latitude,
                                                lon: fix.coordinate.longitude)
            await self.refresh()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .denied, .restricted: self.denied = true
            case .authorizedWhenInUse, .authorizedAlways:
                self.denied = false
                manager.startUpdatingLocation()
                self.startPolling()
            default: break
            }
        }
    }
}
