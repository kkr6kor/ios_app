import CoreVideo
import CoreGraphics
import UIKit

/// Dash frame geometry — matches `DashEncoder` (526×300).
enum DashFrame {
    static let width = 526
    static let height = 300
    static var size: CGSize { CGSize(width: width, height: height) }
}

/// Pooled 526×300 BGRA `CVPixelBuffer`s with a draw helper. Frames are rendered
/// off-screen here and handed to VideoToolbox — no window needed, so it works with
/// the phone screen off.
///
/// The context is flipped to a top-left origin AND the UIKit drawing context is
/// pushed, so renderers must draw with **UIKit** APIs (`UIImage.draw`, `UIRectFill`,
/// `UIBezierPath`). That double-flip is the canonical recipe that produces an
/// upright frame in the pixel buffer — drawing a raw `CGImage` here would be
/// upside-down (the bug that rotated the wallpaper).
final class PixelBufferFactory {
    private var pool: CVPixelBufferPool?

    init() {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: DashFrame.width,
            kCVPixelBufferHeightKey as String: DashFrame.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
    }

    func draw(_ render: (CGContext) -> Void) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb) == kCVReturnSuccess,
              let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let ctx = CGContext(
                data: base,
                width: DashFrame.width, height: DashFrame.height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        ctx.translateBy(x: 0, y: CGFloat(DashFrame.height))
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        render(ctx)
        UIGraphicsPopContext()
        return buffer
    }
}
