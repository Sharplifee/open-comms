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
    @Published var radiusMetres: Double = 152   // 500 ft by default

    private let manager = CLLocationManager()
    private var lastWrite = Date.distantPast
    private var here: CLLocation?

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
        default: manager.startUpdatingLocation()
        }
    }

    func stop() { manager.stopUpdatingLocation() }

    /// Low power widens the filter rather than turning location off, because
    /// a radar that silently stops updating is worse than one that updates
    /// slowly — it looks the same but lies.
    func setLowPower(_ on: Bool) {
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
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .denied, .restricted: self.denied = true
            case .authorizedWhenInUse, .authorizedAlways:
                self.denied = false
                manager.startUpdatingLocation()
            default: break
            }
        }
    }
}
