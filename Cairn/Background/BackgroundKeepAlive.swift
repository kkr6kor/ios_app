import Foundation
import CoreLocation

/// **Phase 1a — the project's load-bearing spike.**
///
/// iOS suspends a normal app seconds after the screen locks. Cairn must keep
/// encoding H.264 + pumping UDP for hours with the screen off. Because Cairn is a
/// navigation app, it can legitimately claim the **Location background mode**:
/// continuous Core Location updates keep the process unsuspended, and VideoToolbox
/// + sockets keep running.
///
/// This class proves it: with `Always` authorization and background location on, a
/// 1 Hz timer logs a timestamp. Lock the phone, wait 30+ minutes, and confirm the
/// ticks never stop. If they stop, the whole architecture needs rethinking — so
/// this is validated before anything else.
final class BackgroundKeepAlive: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var isRunning = false
    @Published private(set) var tickCount = 0
    @Published private(set) var lastTick = "—"
    @Published private(set) var authStatus = "unknown"

    private let manager = CLLocationManager()
    private var timer: DispatchSourceTimer?
    private let iso = ISO8601DateFormatter()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.distanceFilter = kCLDistanceFilterNone
        updateAuthString()
    }

    func requestAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    func start() {
        guard !isRunning else { return }
        // Must be set AFTER the location background mode is in Info.plist, else it throws.
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        isRunning = true

        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now(), repeating: 1.0)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let stamp = self.iso.string(from: Date())
            DiagnosticsLog.shared.log("keepalive", "tick \(stamp)")
            DispatchQueue.main.async {
                self.tickCount += 1
                self.lastTick = stamp
            }
        }
        t.resume()
        timer = t
        DiagnosticsLog.shared.log("keepalive", "started")
    }

    func stop() {
        timer?.cancel(); timer = nil
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        isRunning = false
        DiagnosticsLog.shared.log("keepalive", "stopped")
    }

    // CLLocationManagerDelegate
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updateAuthString()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Updates received simply confirm the radio is alive; the tick timer is the spike's metric.
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DiagnosticsLog.shared.log("keepalive", "location error: \(error.localizedDescription)")
    }

    private func updateAuthString() {
        let s: String
        switch manager.authorizationStatus {
        case .notDetermined: s = "notDetermined"
        case .restricted: s = "restricted"
        case .denied: s = "denied"
        case .authorizedAlways: s = "authorizedAlways"
        case .authorizedWhenInUse: s = "authorizedWhenInUse"
        @unknown default: s = "unknown"
        }
        DispatchQueue.main.async { self.authStatus = s }
    }
}
