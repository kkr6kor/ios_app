import Foundation
import CoreGraphics
import ImageIO
import AVFoundation
import UIKit

/// Draws the active idle wallpaper into the dash frame — Swift port of OpenDash's
/// `DashIdleRenderer`. Image / GIF / video, with the video frame-decode capped at
/// 8 fps to protect the screen-off thermal budget.
final class DashIdleRenderer {
    static let maxVideoFps: Double = 8
    private static let minVideoFrameInterval = 1.0 / maxVideoFps

    private var cachedPath: String?
    private var cachedKind: DashWallpaperKind?
    private var cachedImage: CGImage?
    private var gifSource: CGImageSource?
    private var gifFrameCount = 0
    private var gifDuration: Double = 0
    private var videoGenerator: AVAssetImageGenerator?
    private var videoDuration: Double = 0
    private var lastVideoDecode: Double = 0

    func draw(into ctx: CGContext, info: DashWallpaperInfo?) {
        // UIKit drawing (the context is flipped + pushed by PixelBufferFactory).
        UIColor(white: 0.05, alpha: 1).setFill()
        UIRectFill(CGRect(origin: .zero, size: DashFrame.size))
        guard let info else { return }
        switch info.kind {
        case .image: drawImage(ctx, info)
        case .gif: drawGif(ctx, info)
        case .video: drawVideo(ctx, info)
        }
    }

    func release() {
        cachedImage = nil; gifSource = nil; videoGenerator = nil
        cachedPath = nil; cachedKind = nil
    }

    // ── Image (pre-rendered 526×300 PNG) ─────────────────────────────────────
    private func drawImage(_ ctx: CGContext, _ info: DashWallpaperInfo) {
        if cachedPath != info.path || cachedKind != .image {
            cachedImage = UIImage(contentsOfFile: info.path)?.cgImage
            cachedPath = info.path; cachedKind = .image
        }
        if let img = cachedImage {
            UIImage(cgImage: img).draw(in: CGRect(origin: .zero, size: DashFrame.size))
        }
    }

    // ── GIF (animated via ImageIO) ───────────────────────────────────────────
    private func drawGif(_ ctx: CGContext, _ info: DashWallpaperInfo) {
        if cachedPath != info.path || cachedKind != .gif {
            gifSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: info.path) as CFURL, nil)
            gifFrameCount = gifSource.map { CGImageSourceGetCount($0) } ?? 0
            gifDuration = max(0.1, Double(gifFrameCount) * 0.1)
            cachedPath = info.path; cachedKind = .gif
        }
        guard let src = gifSource, gifFrameCount > 0 else { return }
        let t = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: gifDuration) / gifDuration
        let index = min(gifFrameCount - 1, Int(t * Double(gifFrameCount)))
        if let frame = CGImageSourceCreateImageAtIndex(src, index, nil) {
            drawScaled(frame, ctx, info)
        }
    }

    // ── Video (frame-at-time via AVAssetImageGenerator, capped 8 fps) ─────────
    private func drawVideo(_ ctx: CGContext, _ info: DashWallpaperInfo) {
        if cachedPath != info.path || cachedKind != .video {
            let asset = AVURLAsset(url: URL(fileURLWithPath: info.path))
            let gen = AVAssetImageGenerator(asset: asset)
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 8)
            gen.maximumSize = DashFrame.size
            videoGenerator = gen
            videoDuration = max(1.0, CMTimeGetSeconds(asset.duration))
            cachedPath = info.path; cachedKind = .video
            cachedImage = nil
        }
        let now = ProcessInfo.processInfo.systemUptime
        if cachedImage == nil || now - lastVideoDecode >= Self.minVideoFrameInterval {
            lastVideoDecode = now
            let t = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: videoDuration)
            if let gen = videoGenerator,
               let frame = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) {
                cachedImage = frame
            }
        }
        if let img = cachedImage { drawScaled(img, ctx, info) }
    }

    private func drawScaled(_ image: CGImage, _ ctx: CGContext, _ info: DashWallpaperInfo) {
        let rect = WallpaperLayout.rect(srcW: CGFloat(image.width), srcH: CGFloat(image.height),
                                        dst: DashFrame.size, fit: info.fit,
                                        h: info.horizontalBias, v: info.verticalBias)
        UIImage(cgImage: image).draw(in: rect)
    }
}
