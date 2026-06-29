import SwiftUI

@main
struct CairnApp: App {
    @StateObject private var appData = AppData()
    @StateObject private var wallpaperStore = DashWallpaperStore()
    @StateObject private var controller = DashController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appData)
                .environmentObject(wallpaperStore)
                .environmentObject(controller)
        }
    }
}
