import Foundation
import CoreLocation

/// Continuous GPS for navigation. Uses background location (the same mode that keeps
/// the app alive with the screen off), best-for-navigation accuracy, and reports
/// each fix to `onUpdate` (consumed by `NavEngine`).
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var location: CLLocation?
    @Published private(set) var authStatus: CLAuthorizationStatus = .notDetermined

    var onUpdate: ((CLLocation) -> Void)?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.distanceFilter = kCLDistanceFilterNone
        authStatus = manager.authorizationStatus
    }

    func requestAuthorization() { manager.requestAlwaysAuthorization() }

    func start() {
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        location = loc
        onUpdate?(loc)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authStatus = manager.authorizationStatus
    }
}
