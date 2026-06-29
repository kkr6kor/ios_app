import Foundation

/// Media kind for a dash wallpaper slot — mirrors OpenDash's `DashWallpaperKind`.
enum DashWallpaperKind: String, Codable { case image, gif, video }

/// How the media is fit to the 526×300 dash — mirrors `DashWallpaperFit`.
enum DashWallpaperFit: String, Codable, CaseIterable {
    case crop, fitHeight, fitWidth
    var label: String {
        switch self {
        case .crop: return "Crop"
        case .fitHeight: return "Fit height"
        case .fitWidth: return "Fit width"
        }
    }
}

/// One wallpaper slot — mirrors `DashWallpaperInfo`.
struct DashWallpaperInfo: Codable, Identifiable, Equatable {
    var slot: Int
    var path: String          // absolute file path (rendered PNG for images, source for gif/video)
    var kind: DashWallpaperKind
    var horizontalBias: Float
    var verticalBias: Float
    var fit: DashWallpaperFit
    var id: Int { slot }
}
