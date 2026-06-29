import Foundation
import CoreGraphics
import UIKit

/// Animated test pattern for Phase 1d — proves the off-screen render → VideoToolbox
/// → RTP → dash pipeline end to end. Uses UIKit drawing (the context is flipped +
/// pushed by `PixelBufferFactory`).
final class TestPatternRenderer {
    func draw(into ctx: CGContext, ptsMs: Int64) {
        UIColor(red: 0.04, green: 0.05, blue: 0.06, alpha: 1).setFill()
        UIRectFill(CGRect(origin: .zero, size: DashFrame.size))

        let t = Double(ptsMs) / 1000.0
        // Sweeping box proves frames are advancing.
        let x = (sin(t) * 0.5 + 0.5) * Double(DashFrame.width - 64)
        UIColor(red: 0.96, green: 0.7, blue: 0.12, alpha: 1).setFill()
        UIRectFill(CGRect(x: x, y: Double(DashFrame.height) / 2 - 24, width: 64, height: 48))

        // 1 Hz progress bar at the top.
        let frac = t.truncatingRemainder(dividingBy: 1.0)
        UIColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1).setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: Double(DashFrame.width) * frac, height: 8))
    }
}
