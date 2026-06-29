import Foundation
import CoreLocation

/// Routing via the public OSRM demo server (keyless). Mirrors the Kotlin `Router`.
/// The plan moves this off the demo server later; fine for development.
enum OSRMRouter {
    enum RouteError: Error { case badURL, http(Int), noRoute }

    static func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> NavRoute {
        let s = "https://router.project-osrm.org/route/v1/driving/"
            + "\(from.longitude),\(from.latitude);\(to.longitude),\(to.latitude)"
            + "?overview=full&geometries=geojson&steps=true"
        guard let url = URL(string: s) else { throw RouteError.badURL }

        let (data, resp) = try await URLSession.shared.data(from: url)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw RouteError.http(http.statusCode) }

        let decoded = try JSONDecoder().decode(OSRMResponse.self, from: data)
        guard let r = decoded.routes.first else { throw RouteError.noRoute }

        let coords = r.geometry.coordinates.compactMap { pair -> CLLocationCoordinate2D? in
            guard pair.count == 2 else { return nil }
            return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
        }
        var steps: [NavStep] = []
        for leg in r.legs {
            for st in leg.steps where st.maneuver.location.count == 2 {
                steps.append(NavStep(
                    location: CLLocationCoordinate2D(latitude: st.maneuver.location[1], longitude: st.maneuver.location[0]),
                    type: st.maneuver.type,
                    modifier: st.maneuver.modifier ?? "",
                    name: st.name,
                    distanceM: st.distance))
            }
        }
        return NavRoute(coordinates: coords, steps: steps, totalDistanceM: r.distance, totalDurationS: r.duration)
    }
}

private struct OSRMResponse: Codable {
    let routes: [Route]
    struct Route: Codable {
        let distance: Double
        let duration: Double
        let geometry: Geometry
        let legs: [Leg]
    }
    struct Geometry: Codable { let coordinates: [[Double]] }
    struct Leg: Codable { let steps: [Step] }
    struct Step: Codable { let distance: Double; let name: String; let maneuver: Maneuver }
    struct Maneuver: Codable { let location: [Double]; let type: String; let modifier: String? }
}
