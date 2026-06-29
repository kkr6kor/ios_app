import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// PHPicker wrapper (multi-select up to 5) returning images and gif/video file URLs —
/// the iOS analogue of OpenDash's `saveManyFromUris`.
struct PhotoPicker: UIViewControllerRepresentable {
    var selectionLimit = 5
    var onPicked: (_ images: [UIImage], _ media: [(URL, DashWallpaperKind)]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = selectionLimit
        config.filter = .any(of: [.images, .videos])
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoPicker
        init(_ parent: PhotoPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            let group = DispatchGroup()
            let lock = NSLock()
            var images: [UIImage] = []
            var media: [(URL, DashWallpaperKind)] = []

            for result in results {
                let provider = result.itemProvider
                if provider.hasItemConformingToTypeIdentifier(UTType.gif.identifier) {
                    group.enter()
                    provider.loadFileRepresentation(forTypeIdentifier: UTType.gif.identifier) { url, _ in
                        if let url, let copied = Self.copyToTemp(url) { lock.lock(); media.append((copied, .gif)); lock.unlock() }
                        group.leave()
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                    group.enter()
                    provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                        if let url, let copied = Self.copyToTemp(url) { lock.lock(); media.append((copied, .video)); lock.unlock() }
                        group.leave()
                    }
                } else if provider.canLoadObject(ofClass: UIImage.self) {
                    group.enter()
                    provider.loadObject(ofClass: UIImage.self) { object, _ in
                        if let image = object as? UIImage { lock.lock(); images.append(image); lock.unlock() }
                        group.leave()
                    }
                }
            }
            group.notify(queue: .main) { self.parent.onPicked(images, media) }
        }

        // loadFileRepresentation hands back a temp URL valid only inside the closure — copy now.
        static func copyToTemp(_ url: URL) -> URL? {
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "_" + url.lastPathComponent)
            do { try FileManager.default.copyItem(at: url, to: dest); return dest } catch { return nil }
        }
    }
}
