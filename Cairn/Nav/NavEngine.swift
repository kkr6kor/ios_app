import Foundation
import CoreLocation

/// Turn-by-turn engine — mirrors the Kotlin nav core. Given the current location it
/// computes distance-to-turn, remaining distance, ETA, the active instruction, and
/// off-route detection (→ reroute). Feeds the dash via `onNavInfo` and speaks via
/// `onSpeak`.
final class NavEngine: ObservableObject {
    @Published private(set) var instruction = ""
    @Published private(set) var distanceToTurnM = 0
    @Published private(set) var remainingM = 0
    @Published private(set) var etaHHMM = ""
    @Published private(set) var isNavigating = false

    private(set) var routeCoordinates: [CLLocationCoordinate2D] = []

    /// (maneuverGlyph, primaryDist, primaryUnit, totalDist, totalUnit, etaHHMM) for the dash.
    var onNavInfo: ((Int, Int, Int, Int, Int, String) -> Void)?
    var onReroute: ((CLLocationCoordinate2D) -> Void)?
    var onSpeak: ((String) -> Void)?

    private var route: NavRoute?
    private var cumDist: [Double] = []     // cumulative metres at each route vertex
    private var stepCum: [Double] = []     // cumulative metres at each step's maneuver
    private var offRouteCount = 0
    private var lastSpokenStep = -1

    private static let offRouteThresholdM = 50.0
    private static let offRouteStrikes = 3
    private static let speakWithinM = 250.0

    func setRoute(_ r: NavRoute) {
        route = r
        routeCoordinates = r.coordinates
        cumDist = Self.cumulative(r.coordinates)
        stepCum = r.steps.map { Self.cumulativeAt($0.location, coords: r.coordinates, cum: cumDist) }
        offRouteCount = 0
        lastSpokenStep = -1
        isNavigating = true
    }

    func stop() {
        route = nil; routeCoordinates = []; cumDist = []; stepCum = []
        isNavigating = false; instruction = ""; distanceToTurnM = 0; remainingM = 0; etaHHMM = ""
    }

    func update(location: CLLocation) {
        guard let route, !route.coordinates.isEmpty else { return }

        let (nearestIdx, distToRoute) = nearest(location.coordinate)
        let traveled = cumDist[nearestIdx]

        if distToRoute > Self.offRouteThresholdM {
            offRouteCount += 1
            if offRouteCount >= Self.offRouteStrikes {
                offRouteCount = 0
                DiagnosticsLog.shared.log("nav", "off-route (\(Int(distToRoute))m) → reroute")
                onReroute?(location.coordinate)
            }
        } else {
            offRouteCount = 0
        }

        let remaining = max(0, route.totalDistanceM - traveled)
        remainingM = Int(remaining)

        var nextIdx = stepCum.firstIndex { $0 > traveled + 5 } ?? (route.steps.count - 1)
        nextIdx = min(max(nextIdx, 0), max(route.steps.count - 1, 0))
        let step = route.steps.isEmpty ? nil : route.steps[nextIdx]
        let dToTurn = step != nil ? max(0, stepCum[nextIdx] - traveled) : 0
        distanceToTurnM = Int(dToTurn)
        instruction = step?.instruction ?? "Continue"

        let frac = route.totalDistanceM > 0 ? remaining / route.totalDistanceM : 0
        let eta = Date().addingTimeInterval(route.totalDurationS * frac)
        etaHHMM = Self.hhmm(eta)

        if let step, nextIdx != lastSpokenStep, dToTurn < Self.speakWithinM {
            lastSpokenStep = nextIdx
            onSpeak?(step.instruction)
        }

        let (pv, pu) = Self.dashUnit(dToTurn)
        let (tv, tu) = Self.dashUnit(remaining)
        onNavInfo?(ManeuverGlyph.code(type: step?.type ?? "continue", modifier: step?.modifier ?? ""),
                   pv, pu, tv, tu, etaHHMM)
    }

    // ── helpers ──────────────────────────────────────────────────────────────
    private func nearest(_ c: CLLocationCoordinate2D) -> (index: Int, distance: Double) {
        let here = CLLocation(latitude: c.latitude, longitude: c.longitude)
        var bestIdx = 0
        var bestDist = Double.greatestFiniteMagnitude
        for (i, coord) in routeCoordinates.enumerated() {
            let d = here.distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
            if d < bestDist { bestDist = d; bestIdx = i }
        }
        return (bestIdx, bestDist)
    }

    private static func cumulative(_ coords: [CLLocationCoordinate2D]) -> [Double] {
        var cum = [Double](repeating: 0, count: coords.count)
        for i in 1..<max(coords.count, 1) where coords.count > 1 {
            let a = CLLocation(latitude: coords[i - 1].latitude, longitude: coords[i - 1].longitude)
            let b = CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude)
            cum[i] = cum[i - 1] + a.distance(from: b)
        }
        return cum
    }

    private static func cumulativeAt(_ point: CLLocationCoordinate2D, coords: [CLLocationCoordinate2D], cum: [Double]) -> Double {
        let here = CLLocation(latitude: point.latitude, longitude: point.longitude)
        var bestIdx = 0
        var bestDist = Double.greatestFiniteMagnitude
        for (i, coord) in coords.enumerated() {
            let d = here.distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
            if d < bestDist { bestDist = d; bestIdx = i }
        }
        return cum.isEmpty ? 0 : cum[bestIdx]
    }

    /// metres → (value, dash unit). < 1 km in metres, else km×10.
    private static func dashUnit(_ meters: Double) -> (Int, Int) {
        if meters < 1000 { return (Int(meters), DashCommands.navUnitMeters) }
        return (Int(meters / 100), DashCommands.navUnitKmTenths)
    }

    private static func hhmm(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HHmm"; return f.string(from: date)
    }
}
