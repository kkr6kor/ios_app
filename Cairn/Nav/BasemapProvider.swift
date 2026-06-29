import Foundation
import CoreLocation
import MapLibre

/// Renders the OpenFreeMap basemap off-screen via `MLNMapSnapshotter` (keyless,
/// no on-screen map view needed — works with the phone screen off). Throttled: a
/// new snapshot only when the camera moves enough, since each snapshot is heavy.
/// `NavRenderer` overlays the route + marker using the snapshot's own projection,
/// so they align exactly with the basemap.
final class BasemapProvider {
    // Keyless OpenFreeMap style (same maps as the Android app).
    private let styleURL = URL(string: "https://tiles.openfreemap.org/styles/liberty")!

    private let lock = NSLock()
    private var latest: MLNMapSnapshot?
    private var snapshotter: MLNMapSnapshotter?
    private var inFlight = false

    private var lastCenter: CLLocationCoordinate2D?
    private var lastHeading: Double = -999
    private var lastZoom: Double = -1

    var current: MLNMapSnapshot? { lock.lock(); defer { lock.unlock() }; return latest }

    /// Request a basemap snapshot for this camera. Call on the main thread (from the
    /// location handler). No-ops if one is in flight or the camera barely moved.
    func request(center: CLLocationCoordinate2D, zoomMeters: Double, heading: Double) {
        if inFlight { return }
        if let lc = lastCenter {
            let moved = CLLocation(latitude: lc.latitude, longitude: lc.longitude)
                .distance(from: CLLocation(latitude: center.latitude, longitude: center.longitude))
            if moved < 8, abs(heading - lastHeading) < 5, abs(zoomMeters - lastZoom) < 25 { return }
        }
        inFlight = true
        lastCenter = center; lastHeading = heading; lastZoom = zoomMeters

        let camera = MLNMapCamera(lookingAtCenter: center,
                                  acrossDistance: zoomMeters,
                                  pitch: 0,
                                  heading: heading >= 0 ? heading : 0)
        let options = MLNMapSnapshotOptions(styleURL: styleURL, camera: camera, size: DashFrame.size)
        let snapshotter = MLNMapSnapshotter(options: options)
        self.snapshotter = snapshotter
        snapshotter.start { [weak self] (snapshot: MLNMapSnapshot?, error: Error?) in
            guard let self else { return }
            if let snapshot {
                self.lock.lock(); self.latest = snapshot; self.lock.unlock()
            } else if let error {
                DiagnosticsLog.shared.log("basemap", "snapshot failed: \(error.localizedDescription)")
            }
            self.inFlight = false
        }
    }

    func clear() { lock.lock(); latest = nil; lock.unlock() }
}
