import Foundation
import Combine

enum DashState: String { case idle, connecting, authenticating, ready, streaming, error }

/// Tripper Dash session, sequenced to match the validated Kotlin `DashSession`:
///   1. Open sockets (RX :2002 bound first).
///   2. Send initial burst on :2000 (includes q3c.e request-auth).
///   3. RX loop ingests 07 00 / 07 03 → sends q3c.d → waits for 07 01 01.
///   4. Nav entry: route-card ×4 → projectionFrame → z2 (once) → route-card.
///   5. Start RTP + 4 Hz projection HB + 1 Hz route-card/nav/media keep-alive.
/// The RX loop runs the whole time, answering auth, IDR-decoded acks, and joystick events.
final class DashSession: ObservableObject {
    @Published private(set) var state: DashState = .idle
    /// Count of dash "frame decoded" acks (09 06/04 55) — > 0 means the dash is
    /// actually decoding our stream (no "Timeout!").
    @Published private(set) var dashDecodedFrames = 0

    var onButton: ((UInt8) -> Void)?
    var onError: ((String) -> Void)?
    var destinationName = "Cairn"

    private let hostname = "Cairn"
    private let controlMode: DashSocket.ControlMode
    private let interfaceName: String?

    private static let authTimeout: TimeInterval = 15
    private static let burstPauseMs: UInt64 = 20
    private static let projHbMs: UInt64 = 250        // 4 Hz
    private static let routeCardMs: UInt64 = 1000     // 1 Hz
    private static let rxWatchdogMs: Int64 = 6000

    private let lock = NSLock()
    private var socket: DashSocket?
    private var auth: DashAuth?
    private var authConfirmed = false
    private var authRetries = 0
    private var lastRxMs: Int64 = 0
    private var loggedFirstAck = false

    // Live nav-info pushed to the dash bubble at ~1 Hz.
    private var navActive = false
    private var navManeuver = DashCommands.navManeuverContinue
    private var navPrimaryDist = 0
    private var navPrimaryUnit = DashCommands.navUnitMeters
    private var navTotalDist = 0
    private var navTotalUnit = DashCommands.navUnitMeters
    private var navEta: String?

    // Now-playing + incoming-call.
    private var npTitle: String?
    private var npAlbum = ""
    private var npArtist = ""
    private var caller: String?

    private var tasks: [Task<Void, Never>] = []
    private var sessionTask: Task<Void, Never>?

    init(controlMode: DashSocket.ControlMode = .broadcast, interfaceName: String? = nil) {
        self.controlMode = controlMode
        self.interfaceName = interfaceName
    }

    // ── Public API ────────────────────────────────────────────────────────
    func connect(ssid: String) {
        guard state == .idle || state == .error else { return }
        sessionTask = Task.detached { [weak self] in await self?.runSession(ssid: ssid) }
    }

    func startStreaming() {
        guard state == .ready else { return }
        setState(.streaming)
        startKeepAlives()
    }

    func sendRtp(_ packet: Data) { withSocket { $0.sendRtp(packet) } }

    func updateNavInfo(maneuver: Int, primaryDist: Int, primaryUnit: Int,
                       totalDist: Int, totalUnit: Int, etaHHMM: String? = nil) {
        lock.lock()
        navManeuver = maneuver; navPrimaryDist = primaryDist; navPrimaryUnit = primaryUnit
        navTotalDist = totalDist; navTotalUnit = totalUnit; navEta = etaHHMM; navActive = true
        lock.unlock()
    }

    func updateNowPlaying(title: String?, album: String, artist: String) {
        lock.lock(); npTitle = (title?.isEmpty == false) ? title : nil; npAlbum = album; npArtist = artist; lock.unlock()
    }

    func updateCall(callerName: String?) {
        lock.lock(); caller = (callerName?.isEmpty == false) ? callerName : nil; lock.unlock()
    }

    /// New destination — refresh the dash route card (figures stale until next updateNavInfo).
    func updateRouteCard(name: String) {
        destinationName = name.isEmpty ? "Cairn" : name
        lock.lock(); navActive = false; lock.unlock()
        if state == .ready || state == .streaming {
            withSocket { $0.send(self.liveRouteCard(projectionOn: true)) }
        }
    }

    func disconnect() {
        sessionTask?.cancel(); sessionTask = nil
        tasks.forEach { $0.cancel() }; tasks.removeAll()
        lock.lock(); navActive = false; lock.unlock()
        withSocket {
            $0.send(DashCommands.projectionStop())
            $0.send(DashCommands.projectionOff())
            $0.close()
        }
        lock.lock(); socket = nil; lock.unlock()
        setState(.idle)
    }

    // ── Session ──────────────────────────────────────────────────────────
    private func runSession(ssid: String) async {
        setState(.connecting)
        let sock: DashSocket
        do {
            sock = try DashSocket(controlMode: controlMode, interfaceName: interfaceName)
        } catch {
            fail("Socket open failed: \(error)")
            return
        }
        lock.lock()
        socket = sock
        auth = DashAuth(ssid: ssid)
        authConfirmed = false; authRetries = 0; loggedFirstAck = false; lastRxMs = 0
        lock.unlock()

        startReceiveLoop(sock)
        startStatusHeartbeat(sock)

        setState(.authenticating)
        for pkt in DashCommands.initialBurst(hostname: hostname) {
            sock.send(pkt)
            try? await Task.sleep(nanoseconds: Self.burstPauseMs * 1_000_000)
        }
        DiagnosticsLog.shared.log("auth", "initial burst sent (unicast=\(controlMode == .unicast)) — waiting for 07 01 01")

        let deadline = Date().addingTimeInterval(Self.authTimeout)
        while !isAuthConfirmed(), Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard isAuthConfirmed() else {
            fail("Auth timed out — no 07 01 01 from dash. Check SSID matches '\(ssid)'.")
            return
        }

        await enterNavMode(sock)
        setState(.ready)
    }

    private func enterNavMode(_ sock: DashSocket) async {
        sock.send(DashCommands.navContext()); try? await sleep(40)
        sock.send(DashCommands.emptyLists()); try? await sleep(40)
        for i in 0..<4 {
            sock.send(DashCommands.routeCard(title: destinationName, projectionOn: false))
            try? await sleep(i < 1 ? 100 : 500)
        }
        sock.send(DashCommands.projectionFrame()); try? await sleep(60)
        sock.send(DashCommands.navPlaceholder()); try? await sleep(10)
        sock.send(DashCommands.navStart()); try? await sleep(40)            // z2, ONCE
        sock.send(DashCommands.routeCard(title: destinationName, projectionOn: true))
    }

    private func startReceiveLoop(_ sock: DashSocket) {
        let t = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let pkt: Data?
                do { pkt = try sock.receive() }
                catch {
                    self.onError?("Lost connection to dash")
                    break
                }
                guard let pkt else { continue }
                self.lock.lock(); self.lastRxMs = Self.nowMs(); self.lock.unlock()
                self.dispatchIncoming(pkt, sock)
            }
        }
        tasks.append(t)
    }

    private func dispatchIncoming(_ pkt: Data, _ sock: DashSocket) {
        for tlv in K1GPacket.parseIncoming(pkt) {
            // ── Auth (07 xx) ──
            if tlv.type == 0x07 {
                lock.lock(); let ev = auth?.ingest(tlv); lock.unlock()
                switch ev {
                case .sendKey(let p): sock.send(p)
                case .confirmed: lock.lock(); authConfirmed = true; lock.unlock()
                case .rejected:
                    lock.lock(); authRetries += 1; let r = authRetries; auth?.reset(); lock.unlock()
                    if r <= 5 { sock.send(DashCommands.authRequest()) }
                default: break
                }
                continue
            }
            // ── 09 06 55: per-IDR frame-decoded notify → q3c.L2 ──
            if tlv.type == 0x09, tlv.sub == 0x06, tlv.value.first == 0x55 {
                lock.lock(); let first = !loggedFirstAck; loggedFirstAck = true; lock.unlock()
                if first { DiagnosticsLog.shared.log("dash", "DECODED first IDR (09 06 55) — video accepted ✓") }
                bumpDecoded()
                sock.send(DashCommands.frameDecodedIdr()); continue
            }
            // ── 09 04 55: P-frame decoded → q3c.K2 ──
            if tlv.type == 0x09, tlv.sub == 0x04, tlv.value.first == 0x55 {
                bumpDecoded()
                sock.send(DashCommands.frameDecodedP()); continue
            }
            // ── 09 00: button / joystick event → echo ack + notify UI ──
            if tlv.type == 0x09, tlv.sub == 0x00, let btn = tlv.value.last {
                sock.send(DashCommands.buttonAck(btn))
                DispatchQueue.main.async { self.onButton?(btn) }
                continue
            }
            // ── 0F: AES-256-CBC encrypted telemetry (decrypt with session key) ──
            if tlv.type == 0x0F {
                lock.lock(); let key = auth?.sessionKey; lock.unlock()
                if let key, let plain = AESCBC.decrypt(ivAndCiphertext: tlv.value, key: key) {
                    DiagnosticsLog.shared.log("telemetry", "0F sub=\(tlv.sub) dec=\(plain.hexString)")
                }
                continue
            }
        }
    }

    private func startStatusHeartbeat(_ sock: DashSocket) {
        let t = Task.detached { [weak self] in
            guard let self else { return }
            var n = 0
            while !Task.isCancelled {
                sock.send(DashCommands.heartbeat())
                if n % 30 == 0 { sock.send(DashCommands.timeSync()) }
                n += 1
                if self.state == .streaming, self.didLogFirstAck() {
                    let last = self.lastRx()
                    if last > 0, Self.nowMs() - last > Self.rxWatchdogMs {
                        self.fail("Dash stopped responding — connection lost"); break
                    }
                }
                try? await self.sleep(1000)
            }
        }
        tasks.append(t)
    }

    private func startKeepAlives() {
        // Projection heartbeat — 4 Hz.
        tasks.append(Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.state == .streaming {
                self.withSocket { $0.send(DashCommands.projectionFrame()) }
                try? await self.sleep(Self.projHbMs)
            }
        })
        // Route-card keep-alive — 1 Hz.
        tasks.append(Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.state == .streaming {
                self.withSocket { $0.send(self.liveRouteCard(projectionOn: true)) }
                try? await self.sleep(Self.routeCardMs)
            }
        })
        // Nav-info — 1 Hz (only while guiding).
        tasks.append(Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.state == .streaming {
                if self.navIsActive() {
                    let (mv, pd, pu, td, tu) = self.navFigures()
                    self.withSocket {
                        $0.send(DashCommands.activeNavPacket(maneuver: mv, primaryDist: pd,
                                                             primaryUnit: pu, totalDist: td, totalUnit: tu))
                    }
                }
                try? await self.sleep(Self.routeCardMs)
            }
        })
        // Media + call — 1 Hz.
        tasks.append(Task.detached { [weak self] in
            guard let self else { return }
            var prevCaller: String?
            while !Task.isCancelled, self.state == .streaming {
                let c = self.currentCaller()
                if let c { self.withSocket { $0.send(DashCommands.callNotify(c)) } }
                else if prevCaller != nil { self.withSocket { $0.send(DashCommands.callClear()) } }
                prevCaller = c
                if let np = self.currentNowPlaying() {
                    self.withSocket { $0.send(DashCommands.nowPlaying(title: np.0, album: np.1, artist: np.2)) }
                }
                try? await self.sleep(Self.routeCardMs)
            }
        })
    }

    private func liveRouteCard(projectionOn: Bool) -> Data {
        lock.lock(); defer { lock.unlock() }
        if navActive {
            return DashCommands.routeCard(title: destinationName, projectionOn: projectionOn,
                                          maneuver: navManeuver, primaryUnit: navPrimaryUnit,
                                          totalDist: navTotalDist, totalUnit: navTotalUnit, etaHHMM: navEta)
        }
        return DashCommands.routeCard(title: destinationName, projectionOn: projectionOn)
    }

    // ── small synchronized accessors ───────────────────────────────────────
    private func isAuthConfirmed() -> Bool { lock.lock(); defer { lock.unlock() }; return authConfirmed }
    private func didLogFirstAck() -> Bool { lock.lock(); defer { lock.unlock() }; return loggedFirstAck }
    private func lastRx() -> Int64 { lock.lock(); defer { lock.unlock() }; return lastRxMs }
    private func navIsActive() -> Bool { lock.lock(); defer { lock.unlock() }; return navActive }
    private func navFigures() -> (Int, Int, Int, Int, Int) {
        lock.lock(); defer { lock.unlock() }
        return (navManeuver, navPrimaryDist, navPrimaryUnit, navTotalDist, navTotalUnit)
    }
    private func currentCaller() -> String? { lock.lock(); defer { lock.unlock() }; return caller }
    private func currentNowPlaying() -> (String, String, String)? {
        lock.lock(); defer { lock.unlock() }
        guard let t = npTitle else { return nil }
        return (t, npAlbum, npArtist)
    }

    private func withSocket(_ body: (DashSocket) -> Void) {
        lock.lock(); let s = socket; lock.unlock()
        if let s { body(s) }
    }

    private func setState(_ s: DashState) {
        DispatchQueue.main.async { self.state = s }
        DiagnosticsLog.shared.log("session", "state → \(s.rawValue)")
    }

    private func bumpDecoded() { DispatchQueue.main.async { self.dashDecodedFrames += 1 } }

    private func fail(_ msg: String) {
        tasks.forEach { $0.cancel() }
        withSocket { $0.close() }
        lock.lock(); socket = nil; lock.unlock()
        setState(.error)
        DispatchQueue.main.async { self.onError?(msg) }
        DiagnosticsLog.shared.log("error", msg)
    }

    private func sleep(_ ms: UInt64) async throws { try await Task.sleep(nanoseconds: ms * 1_000_000) }
    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
