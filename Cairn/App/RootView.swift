import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            DashControlView()
                .tabItem { Label("Dash", systemImage: "gauge.with.dots.needle.bottom.50percent") }
            NavView()
                .tabItem { Label("Navigate", systemImage: "location.north.line") }
            WallpaperView()
                .tabItem { Label("Wallpaper", systemImage: "photo.on.rectangle") }
            GarageView()
                .tabItem { Label("Garage", systemImage: "wrench.and.screwdriver") }
            FuelView()
                .tabItem { Label("Fuel", systemImage: "fuelpump") }
            ExpensesView()
                .tabItem { Label("Expenses", systemImage: "indianrupeesign.circle") }
            RidesView()
                .tabItem { Label("Rides", systemImage: "map") }
            KeepAliveView()
                .tabItem { Label("Keep-Alive", systemImage: "bolt.heart") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
            LogsView()
                .tabItem { Label("Logs", systemImage: "doc.plaintext") }
        }
    }
}

/// Connect to the dash, run the K1G handshake, and project. Free-team path: join the
/// RE_ dash manually in iOS Settings, type its SSID, unicast control.
struct DashControlView: View {
    @EnvironmentObject var controller: DashController
    @EnvironmentObject var wallpaperStore: DashWallpaperStore
    @AppStorage("dashSSID") private var ssid: String = "RE_"
    @State private var stats = (frames: 0, packets: 0)
    private let statsTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            Form {
                Section("Step 1 · Join the dash Wi-Fi") {
                    Text("In iOS Settings ▸ Wi-Fi, join your dash's RE_ network "
                         + "(password 12345678), then return here.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Step 2 · Dash SSID") {
                    TextField("RE_XXXXXX", text: $ssid)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Type the exact SSID — the dash validates it inside the encrypted handshake.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Step 3 · Connect (K1G, unicast)") {
                    LabeledContent("State", value: controller.connState.rawValue)
                    if let e = controller.lastError { Text(e).foregroundStyle(.red).font(.caption) }
                    Button("Connect + authenticate") { controller.connect(ssid: ssid) }
                        .disabled(ssid.isEmpty || controller.connState == .connecting || controller.connState == .authenticating)
                    Button("Disconnect", role: .destructive) { controller.disconnect() }
                }

                if controller.connState == .ready || controller.connState == .streaming {
                    Section("Step 4 · Project (auto-starts on connect)") {
                        Button("Project test pattern") { controller.project(.testPattern) }
                        Button("Project wallpaper") {
                            controller.currentWallpaper = wallpaperStore.current
                            controller.project(.wallpaper)
                        }
                        .disabled(wallpaperStore.current == nil)
                    }
                    Section("Stream diagnostics") {
                        LabeledContent("Frames encoded", value: "\(stats.frames)")
                        LabeledContent("RTP packets sent", value: "\(stats.packets)")
                        LabeledContent("Dash decoded", value: "\(controller.dashDecoded)")
                        if controller.dashDecoded == 0 && stats.packets > 20 {
                            Text("Sending video but the dash hasn't acked a frame — check Logs for the SPS line.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
            .navigationTitle("Cairn")
            .onReceive(statsTimer) { _ in stats = controller.currentStats() }
        }
    }
}

/// Phase 1a spike — prove the app keeps ticking with the screen off.
struct KeepAliveView: View {
    @StateObject private var keepAlive = BackgroundKeepAlive()

    var body: some View {
        NavigationStack {
            Form {
                Section("Background keep-alive spike") {
                    LabeledContent("Location auth", value: keepAlive.authStatus)
                    LabeledContent("Running", value: keepAlive.isRunning ? "yes" : "no")
                    LabeledContent("Ticks", value: "\(keepAlive.tickCount)")
                    LabeledContent("Last tick", value: keepAlive.lastTick)
                }
                Section {
                    Button("Request Always authorization") { keepAlive.requestAuthorization() }
                    Button(keepAlive.isRunning ? "Stop" : "Start") {
                        keepAlive.isRunning ? keepAlive.stop() : keepAlive.start()
                    }
                }
                Section {
                    Text("Start, then lock the phone for 30+ minutes. If the tick count keeps rising, "
                         + "background streaming with the screen off is viable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Keep-Alive")
        }
    }
}

struct LogsView: View {
    @State private var entries: [String] = []
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List(Array(entries.enumerated().reversed()), id: \.offset) { _, line in
                Text(line).font(.system(.caption, design: .monospaced))
            }
            .navigationTitle("Logs")
            .onReceive(timer) { _ in entries = DiagnosticsLog.shared.entries }
        }
    }
}
