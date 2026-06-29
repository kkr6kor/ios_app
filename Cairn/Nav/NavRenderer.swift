import Foundation
import CoreLocation
import CoreGraphics
import UIKit
import MapLibre

/// Draws the heading-up navigation view onto the dash frame: the MapLibre basemap
/// (when available) with the route polyline, position chevron, next instruction,
/// distance-to-turn and ETA overlaid. Falls back to a line-only view (own
/// equirectangular projection) when there's no basemap snapshot yet / offline.
/// Thread-safe; updated from the location handler, drawn from the projection loop.
final class NavRenderer {
    weak var basemap: BasemapProvider?

    private let lock = NSLock()
    private var coords: [CLLocationCoordinate2D] = []
    private var center: CLLocationCoordinate2D?
    private var course: Double = -1            // < 0 → north-up
    private var zoomMeters: Double = 350       // metres across the frame width
    private var instruction = ""
    private var distanceToTurnM = 0
    private var etaHHMM = ""

    var zoom: Double { lock.lock(); defer { lock.unlock() }; return zoomMeters }

    func update(coords: [CLLocationCoordinate2D], center: CLLocationCoordinate2D?, course: Double,
                instruction: String, distanceToTurnM: Int, eta: String) {
        lock.lock()
        self.coords = coords; self.center = center; self.course = course
        self.instruction = instruction; self.distanceToTurnM = distanceToTurnM; self.etaHHMM = eta
        lock.unlock()
    }

    func adjustZoom(_ factor: Double) {
        lock.lock(); zoomMeters = min(4000, max(80, zoomMeters * factor)); lock.unlock()
    }

    func draw(into ctx: CGContext, ptsMs: Int64) {
        lock.lock()
        let coords = self.coords, center = self.center, course = self.course, zoom = self.zoomMeters
        let instr = self.instruction, dToTurn = self.distanceToTurnM, eta = self.etaHHMM
        lock.unlock()

        let cx = Double(DashFrame.width) / 2
        let cy = Double(DashFrame.height) / 2
        let snapshot = basemap?.current

        if let snapshot {
            // Basemap + overlays aligned via the snapshot's own projection.
            snapshot.image.draw(in: CGRect(origin: .zero, size: DashFrame.size))
            if !coords.isEmpty { strokeRoute(coords) { snapshot.point(for: $0) } }
            let markerPoint = center.map { snapshot.point(for: $0) } ?? CGPoint(x: cx, y: cy)
            drawMarker(at: markerPoint, course: course)
        } else {
            // Fallback: line-only heading-up view.
            UIColor(red: 0.07, green: 0.09, blue: 0.10, alpha: 1).setFill()
            UIRectFill(CGRect(origin: .zero, size: DashFrame.size))
            if let center, !coords.isEmpty {
                let pxPerM = Double(DashFrame.width) / zoom
                let mPerLat = 111_320.0
                let mPerLon = 111_320.0 * cos(center.latitude * .pi / 180)
                let phi = course >= 0 ? course * .pi / 180 : 0
                strokeRoute(coords) { c in
                    let east = (c.longitude - center.longitude) * mPerLon
                    let north = (c.latitude - center.latitude) * mPerLat
                    let rx = east * cos(phi) - north * sin(phi)
                    let ry = east * sin(phi) + north * cos(phi)
                    return CGPoint(x: cx + rx * pxPerM, y: cy - ry * pxPerM)
                }
                drawMarker(at: CGPoint(x: cx, y: cy), course: -1)
            }
        }

        drawText(instr.isEmpty ? "—" : instr, at: CGPoint(x: 12, y: 8), size: 22, color: .white)
        let sub = (dToTurn > 0 ? "\(Self.formatDist(dToTurn))   " : "")
            + (eta.isEmpty ? "" : "ETA \(Self.prettyEta(eta))")
        drawText(sub, at: CGPoint(x: 12, y: Double(DashFrame.height) - 30), size: 17, color: .lightGray)
    }

    private func strokeRoute(_ coords: [CLLocationCoordinate2D], project: (CLLocationCoordinate2D) -> CGPoint) {
        let path = UIBezierPath()
        for (i, c) in coords.enumerated() {
            let p = project(c)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.lineWidth = 6; path.lineJoinStyle = .round; path.lineCapStyle = .round
        UIColor(red: 0.2, green: 0.7, blue: 1.0, alpha: 1).setStroke()
        path.stroke()
    }

    private func drawMarker(at p: CGPoint, course: Double) {
        let marker = UIBezierPath()
        marker.move(to: CGPoint(x: p.x, y: p.y - 14))
        marker.addLine(to: CGPoint(x: p.x - 9, y: p.y + 10))
        marker.addLine(to: CGPoint(x: p.x + 9, y: p.y + 10))
        marker.close()
        UIColor.systemYellow.setFill(); marker.fill()
    }

    private func drawText(_ text: String, at point: CGPoint, size: CGFloat, color: UIColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: color,
        ]
        let maxWidth = Double(DashFrame.width) - point.x - 12
        (text as NSString).draw(with: CGRect(x: point.x, y: point.y, width: maxWidth, height: size + 6),
                                options: .usesLineFragmentOrigin, attributes: attrs, context: nil)
    }

    private static func formatDist(_ m: Int) -> String {
        m < 1000 ? "\(m) m" : String(format: "%.1f km", Double(m) / 1000)
    }

    private static func prettyEta(_ hhmm: String) -> String {
        guard hhmm.count == 4 else { return hhmm }
        let i = hhmm.index(hhmm.startIndex, offsetBy: 2)
        return "\(hhmm[..<i]):\(hhmm[i...])"
    }
}
