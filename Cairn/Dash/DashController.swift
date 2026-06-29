import Foundation
import Combine
import CoreLocation

/// App-level orchestrator shared across screens: owns the dash session, projection
/// engine, navigation engine, GPS, voice, and call observer, and wires them together.
final class DashController: ObservableObject {
    let session = DashSession(controlMode: .unicast)
    let nav = NavEngine()
    let location = LocationProvider()
    let voice = VoiceManager()

    private let callObserver = CallObserver()
    private let navRenderer = NavRenderer()
    private let basemap = BasemapProvider()
    private var engine: ProjectionEngine?

    @Published var lastError: String?
    @Published var stats: (frames: Int, packets: Int) = (0, 0)

    private var cancellables = Set<AnyCancellable>()
    private var destination: CLLocationCoordinate2D?
    private var destinationName = "Cairn"

    var connState: DashState { session.state }
    var dashDecoded: Int { session.dashDecodedFrames }

    init() {
        navRenderer.basemap = basemap

        // Forward nested ObservableObject changes so views observing the controller refresh.
        session.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        nav.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)

        session.onError = { [weak self] in self?.lastError = $0 }
        session.onButton = { [weak self] in self?.handleButton($0) }
        callObserver.onCall = { [weak self] in self?.session.updateCall(callerName: $0) }

        // Auto-start projection the moment auth succeeds (avoids the dash decoder watchdog).
        session.$state.sink { [weak self] state in
            guard let self else { return }
            if state == .ready, self.engine == nil {
                self.project(self.nav.isNavigating ? .navigation : .testPattern)
            }
        }.store(in: &cancellables)

        // GPS → nav engine → dash nav-info + renderer.
        location.onUpdate = { [weak self] loc in
            guard let self else { return }
            self.nav.update(location: loc)
            self.navRenderer.update(
                coords: self.nav.routeCoordinates,
                center: loc.coordinate,
                course: loc.course,
                instruction: self.nav.instruction,
                distanceToTurnM: self.nav.distanceToTurnM,
                eta: self.nav.etaHHMM)
            if self.nav.isNavigating {
                self.basemap.request(center: loc.coordinate, zoomMeters: self.navRenderer.zoom, heading: loc.course)
            }
        }
        nav.onNavInfo = { [weak self] mv, pd, pu, td, tu, eta in
            self?.session.updateNavInfo(maneuver: mv, primaryDist: pd, primaryUnit: pu,
                                        totalDist: td, totalUnit: tu, etaHHMM: eta)
        }
        nav.onSpeak = { [weak self] in self?.voice.announce($0) }
        nav.onReroute = { [weak self] from in self?.reroute(from: from) }
    }

    // ── Connection ───────────────────────────────────────────────────────────
    func connect(ssid: String) {
        lastError = nil
        session.connect(ssid: ssid)
    }

    func disconnect() {
        engine?.stop(); engine = nil
        session.disconnect()
    }

    func project(_ mode: ProjectionEngine.Mode) {
        let e = engine ?? ProjectionEngine(session: session)
        e.navRenderer = navRenderer
        e.mode = mode
        e.wallpaper = currentWallpaper
        if engine == nil { e.start() }
        engine = e
    }

    /// Set by the view layer so projection can pick the active wallpaper.
    var currentWallpaper: DashWallpaperInfo?

    func currentStats() -> (frames: Int, packets: Int) { engine?.stats() ?? (0, 0) }

    // ── Navigation ─────────────────────────────────────────────────────────────
    func startNavigation(to dest: CLLocationCoordinate2D, name: String) {
        destination = dest
        destinationName = name
        location.requestAuthorization()
        location.start()
        session.destinationName = name
        Task { await fetchAndStart(from: location.location?.coordinate, to: dest) }
    }

    func stopNavigation() {
        nav.stop()
        engine?.mode = .wallpaper
    }

    private func reroute(from: CLLocationCoordinate2D) {
        guard let dest = destination else { return }
        Task { await fetchAndStart(from: from, to: dest) }
    }

    private func fetchAndStart(from: CLLocationCoordinate2D?, to: CLLocationCoordinate2D) async {
        guard let from else {
            await MainActor.run { self.lastError = "Waiting for GPS fix…" }
            return
        }
        do {
            let route = try await OSRMRouter.route(from: from, to: to)
            await MainActor.run {
                self.nav.setRoute(route)
                self.session.updateRouteCard(name: self.destinationName)
                if self.engine != nil { self.engine?.mode = .navigation }
                else if self.session.state == .ready { self.project(.navigation) }
                DiagnosticsLog.shared.log("nav", "route: \(Int(route.totalDistanceM))m, \(route.steps.count) steps")
            }
        } catch {
            await MainActor.run { self.lastError = "Routing failed: \(error)" }
        }
    }

    // ── Joystick (09 00) → zoom. Codes are unverified; refine from a dash capture. ──
    private func handleButton(_ code: UInt8) {
        switch code {
        case DashCommands.btn05, DashCommands.btn09: navRenderer.adjustZoom(0.8)  // zoom in
        case DashCommands.btn06, DashCommands.btn0A: navRenderer.adjustZoom(1.25) // zoom out
        default: break
        }
    }
}
