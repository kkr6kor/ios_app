import Foundation
import UIKit

/// Manages up to 5 idle-dash wallpaper slots — Swift port of OpenDash's
/// `DashWallpaperStore`. Images are pre-rendered to a 526×300 PNG at save time;
/// GIF/video keep their source file and render frames at draw time.
final class DashWallpaperStore: ObservableObject {
    static let maxSlots = 5

    @Published private(set) var infos: [DashWallpaperInfo] = []
    @Published private(set) var activeSlot: Int = 0

    private let defaults = UserDefaults.standard
    private let metaKey = "dash_wallpaper_meta"
    private let activeKey = "dash_wallpaper_active"

    init() { load() }

    var current: DashWallpaperInfo? {
        infos.first { $0.slot == activeSlot } ?? infos.first
    }

    // ── Mutations ──────────────────────────────────────────────────────────
    func addImage(_ image: UIImage, fit: DashWallpaperFit = .crop, h: Float = 0, v: Float = 0) {
        let slot = firstEmptySlot() ?? activeSlot
        // Keep the source so crop/fit can be re-rendered later.
        if let src = image.pngData() { try? src.write(to: sourceURL(slot, ext: "png")) }
        guard let rendered = renderImage(image, fit: fit, h: h, v: v),
              let data = rendered.pngData() else { return }
        try? data.write(to: renderURL(slot))
        upsert(DashWallpaperInfo(slot: slot, path: renderURL(slot).path, kind: .image,
                                 horizontalBias: h, verticalBias: v, fit: fit))
        setActive(slot)
    }

    func addMedia(url: URL, kind: DashWallpaperKind) {
        let slot = firstEmptySlot() ?? activeSlot
        let ext = url.pathExtension.isEmpty ? (kind == .gif ? "gif" : "mp4") : url.pathExtension
        let dest = sourceURL(slot, ext: ext)
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.copyItem(at: url, to: dest) } catch { return }
        upsert(DashWallpaperInfo(slot: slot, path: dest.path, kind: kind,
                                 horizontalBias: 0, verticalBias: 0, fit: .crop))
        setActive(slot)
    }

    func updateCurrentOptions(h: Float, v: Float, fit: DashWallpaperFit) {
        guard let idx = infos.firstIndex(where: { $0.slot == activeSlot }) else { return }
        var info = infos[idx]
        info.horizontalBias = h; info.verticalBias = v; info.fit = fit
        // Re-bake the crop for images from the kept source.
        if info.kind == .image,
           let src = UIImage(contentsOfFile: sourceURL(info.slot, ext: "png").path),
           let rendered = renderImage(src, fit: fit, h: h, v: v),
           let data = rendered.pngData() {
            try? data.write(to: renderURL(info.slot))
            ThumbnailCache.shared.invalidate(renderURL(info.slot).path)
        }
        infos[idx] = info
        persist()
    }

    func setActive(_ slot: Int) { activeSlot = slot; persist() }

    func cycle(_ delta: Int) {
        guard !infos.isEmpty else { return }
        let idx = infos.firstIndex { $0.slot == activeSlot } ?? 0
        let next = ((idx + delta) % infos.count + infos.count) % infos.count
        setActive(infos[next].slot)
    }

    func delete(slot: Int) {
        try? FileManager.default.removeItem(at: renderURL(slot))
        ["png", "gif", "mp4", "mov", "webm"].forEach { try? FileManager.default.removeItem(at: sourceURL(slot, ext: $0)) }
        infos.removeAll { $0.slot == slot }
        if activeSlot == slot { activeSlot = infos.first?.slot ?? 0 }
        persist()
    }

    func clear() {
        try? FileManager.default.removeItem(at: dir)
        infos.removeAll(); activeSlot = 0
        persist()
    }

    // ── Storage ────────────────────────────────────────────────────────────
    private var dir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = docs.appendingPathComponent("dash_wallpaper", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func renderURL(_ slot: Int) -> URL { dir.appendingPathComponent("render_\(slot).png") }
    private func sourceURL(_ slot: Int, ext: String) -> URL { dir.appendingPathComponent("source_\(slot).\(ext)") }

    private func firstEmptySlot() -> Int? {
        (0..<Self.maxSlots).first { slot in !infos.contains { $0.slot == slot } }
    }

    private func upsert(_ info: DashWallpaperInfo) {
        if let i = infos.firstIndex(where: { $0.slot == info.slot }) { infos[i] = info }
        else { infos.append(info) }
        infos.sort { $0.slot < $1.slot }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(infos) { defaults.set(data, forKey: metaKey) }
        defaults.set(activeSlot, forKey: activeKey)
    }

    private func load() {
        if let data = defaults.data(forKey: metaKey),
           let decoded = try? JSONDecoder().decode([DashWallpaperInfo].self, from: data) {
            infos = decoded.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        activeSlot = defaults.integer(forKey: activeKey)
    }

    // ── Image render ─────────────────────────────────────────────────────────
    private func renderImage(_ image: UIImage, fit: DashWallpaperFit, h: Float, v: Float) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(size: DashFrame.size)
        return renderer.image { ctx in
            UIColor(white: 0.05, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: DashFrame.size))
            let rect = WallpaperLayout.rect(srcW: image.size.width, srcH: image.size.height,
                                            dst: DashFrame.size, fit: fit, h: h, v: v)
            image.draw(in: rect)
        }
    }
}

/// Shared crop/fit math (mirrors OpenDash's cropToDash/fitToDash), top-left origin.
enum WallpaperLayout {
    static func rect(srcW: CGFloat, srcH: CGFloat, dst: CGSize,
                     fit: DashWallpaperFit, h: Float, v: Float) -> CGRect {
        guard srcW > 0, srcH > 0 else { return CGRect(origin: .zero, size: dst) }
        let scale: CGFloat
        switch fit {
        case .crop: scale = max(dst.width / srcW, dst.height / srcH)
        case .fitHeight: scale = dst.height / srcH
        case .fitWidth: scale = dst.width / srcW
        }
        let dw = srcW * scale, dh = srcH * scale
        let extraX = dw - dst.width, extraY = dh - dst.height
        let hb = CGFloat(max(-1, min(1, h))), vb = CGFloat(max(-1, min(1, v)))
        let ox = -extraX / 2 - extraX / 2 * hb
        let oy = -extraY / 2 - extraY / 2 * vb
        return CGRect(x: ox, y: oy, width: dw, height: dh)
    }
}
