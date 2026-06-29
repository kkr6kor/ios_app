import Foundation
import CoreVideo

/// Ties the streaming pipeline together: off-screen render → VideoToolbox encode →
/// NAL processing → RTP → UDP, plus the dash keep-alives via `DashSession`. This is
/// what holds the dash connection open — without a video stream the dash drops the
/// session ("Timeout!") after a few seconds.
final class ProjectionEngine {
    enum Mode { case testPattern, wallpaper, navigation }

    private let session: DashSession
    private let encoder: DashEncoder
    private let nal: NalProcessor
    private let rtp: RtpPacketizer
    private let factory = PixelBufferFactory()
    private let idle = DashIdleRenderer()
    private let test = TestPatternRenderer()

    var mode: Mode = .testPattern
    var wallpaper: DashWallpaperInfo?
    var navRenderer: NavRenderer?

    private var loop: Task<Void, Never>?
    private let startMs = Int64(Date().timeIntervalSince1970 * 1000)

    private let statsLock = NSLock()
    private var framesEncoded = 0

    init(session: DashSession) {
        self.session = session
        let counter = Counter()
        self.counter = counter
        let rtp = RtpPacketizer { [weak session] pkt in
            session?.sendRtp(pkt)
            counter.bumpPackets()
        }
        self.rtp = rtp
        let nal = NalProcessor { data, endOfAU in
            rtp.packetize(nal: data, endOfAU: endOfAU,
                          wallClockMs: Int64(Date().timeIntervalSince1970 * 1000))
        }
        self.nal = nal
        self.encoder = DashEncoder { data, _ in nal.process(data) }
    }

    /// Thread-safe packet counter shared with the RTP sink closure.
    final class Counter {
        private let lock = NSLock()
        private var packets = 0
        func bumpPackets() { lock.lock(); packets += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return packets }
    }
    private let counter: Counter

    func stats() -> (frames: Int, packets: Int) {
        statsLock.lock(); let f = framesEncoded; statsLock.unlock()
        return (f, counter.value)
    }

    func start() {
        encoder.prepare()
        session.startStreaming()
        loop = Task.detached { [weak self] in await self?.run() }
        DiagnosticsLog.shared.log("projection", "started (\(mode))")
    }

    func stop() {
        loop?.cancel(); loop = nil
        encoder.release()
        idle.release()
        DiagnosticsLog.shared.log("projection", "stopped")
    }

    private func run() async {
        var tick = 0
        while !Task.isCancelled {
            let pts = Int64(Date().timeIntervalSince1970 * 1000) - startMs
            let buffer = factory.draw { ctx in
                switch self.mode {
                case .testPattern: self.test.draw(into: ctx, ptsMs: pts)
                case .wallpaper: self.idle.draw(into: ctx, info: self.wallpaper)
                case .navigation: self.navRenderer?.draw(into: ctx, ptsMs: pts)
                }
            }
            if let buffer {
                encoder.encode(pixelBuffer: buffer, ptsMs: pts)
                statsLock.lock(); framesEncoded += 1; statsLock.unlock()
            }
            tick += 1
            if tick % 8 == 0 {   // ~2 s
                let s = stats()
                DiagnosticsLog.shared.log("projection",
                    "frames=\(s.frames) rtp=\(s.packets) dashDecoded=\(session.dashDecodedFrames)")
            }
            try? await Task.sleep(nanoseconds: 250_000_000)   // 4 fps
        }
    }
}
