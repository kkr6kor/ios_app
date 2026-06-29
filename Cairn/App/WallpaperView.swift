import SwiftUI
import ImageIO

struct WallpaperView: View {
    @EnvironmentObject var store: DashWallpaperStore
    @State private var showPicker = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showPicker = true } label: { Label("Add photos / videos", systemImage: "plus") }
                        .disabled(store.infos.count >= DashWallpaperStore.maxSlots)
                    Text("Up to \(DashWallpaperStore.maxSlots) idle wallpapers. While the dash is idle the bike "
                         + "joystick (media ◀ ▶) cycles them. Shown via the Dash tab's “Project wallpaper”.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if store.infos.isEmpty {
                    Section { Text("No wallpapers yet.").foregroundStyle(.secondary) }
                } else {
                    Section("Gallery") {
                        ForEach(store.infos) { info in
                            WallpaperRow(info: info, isActive: info.slot == store.activeSlot)
                                .contentShape(Rectangle())
                                .onTapGesture { store.setActive(info.slot) }
                                .swipeActions {
                                    Button("Delete", role: .destructive) { store.delete(slot: info.slot) }
                                }
                        }
                    }
                    if let active = store.current {
                        Section("Fit — slot \(active.slot)") {
                            Picker("Fit", selection: fitBinding(active)) {
                                ForEach(DashWallpaperFit.allCases, id: \.self) { Text($0.label).tag($0) }
                            }.pickerStyle(.segmented)
                            if active.fit == .crop {
                                BiasSlider(title: "Horizontal", value: hBinding(active))
                                BiasSlider(title: "Vertical", value: vBinding(active))
                            }
                        }
                    }
                }
            }
            .navigationTitle("Wallpaper")
            .sheet(isPresented: $showPicker) {
                PhotoPicker { images, media in
                    images.forEach { store.addImage($0) }
                    media.forEach { store.addMedia(url: $0.0, kind: $0.1) }
                }
            }
        }
    }

    private func fitBinding(_ i: DashWallpaperInfo) -> Binding<DashWallpaperFit> {
        Binding(get: { i.fit }, set: { store.updateCurrentOptions(h: i.horizontalBias, v: i.verticalBias, fit: $0) })
    }
    private func hBinding(_ i: DashWallpaperInfo) -> Binding<Float> {
        Binding(get: { i.horizontalBias }, set: { store.updateCurrentOptions(h: $0, v: i.verticalBias, fit: i.fit) })
    }
    private func vBinding(_ i: DashWallpaperInfo) -> Binding<Float> {
        Binding(get: { i.verticalBias }, set: { store.updateCurrentOptions(h: i.horizontalBias, v: $0, fit: i.fit) })
    }
}

struct BiasSlider: View {
    let title: String
    @Binding var value: Float
    var body: some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Slider(value: $value, in: -1...1)
        }
    }
}

struct WallpaperRow: View {
    let info: DashWallpaperInfo
    let isActive: Bool
    var body: some View {
        HStack {
            thumbnail
                .frame(width: 70, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading) {
                Text("Slot \(info.slot) · \(info.kind.rawValue)")
                Text(info.fit.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isActive { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if info.kind == .image, let img = ThumbnailCache.shared.thumbnail(for: info.path) {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            ZStack {
                Color.gray.opacity(0.3)
                Image(systemName: info.kind == .video ? "video.fill" : "photo.fill")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Caches downsampled wallpaper thumbnails so SwiftUI list redraws don't re-decode
/// the full PNG every frame (a source of lag and memory churn).
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()

    func thumbnail(for path: String) -> UIImage? {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        let url = URL(fileURLWithPath: path)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 160,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
        else { return nil }
        let image = UIImage(cgImage: cg)
        cache.setObject(image, forKey: path as NSString)
        return image
    }

    func invalidate(_ path: String) { cache.removeObject(forKey: path as NSString) }
}
