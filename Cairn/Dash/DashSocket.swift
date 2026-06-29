import Foundation
import Darwin

/// UDP sockets for the Tripper Dash, matching the validated Kotlin `DashSocket`:
///   TX  – bound to :2000, SO_BROADCAST, sends to 192.168.1.255:2000 (broadcast)
///         or 192.168.1.1:2000 (unicast — Phase 1b test path).
///   RX  – bound to :2002. Opened BEFORE the first TX so it catches the early
///         pubkey reply and avoids ICMP port-unreachable confusing the dash.
///   RTP – ephemeral, sends H.264 to 192.168.1.1:5000.
///
/// POSIX sockets (Darwin) are used rather than Network.framework because we need a
/// fixed local port, SO_BROADCAST, and optional `IP_BOUND_IF` interface pinning —
/// all awkward with NWConnection. `IP_BOUND_IF` is the iOS analogue of Android's
/// per-network socket binding: it forces traffic out the dash Wi-Fi while cellular
/// stays the default route.
final class DashSocket {
    static let dashIP = "192.168.1.1"
    static let broadcastIP = "192.168.1.255"
    static let ctrlPort: UInt16 = 2000
    static let rxPort: UInt16 = 2002
    static let rtpPort: UInt16 = 5000
    private static let recvTimeoutMs: Int32 = 500
    private static let bufSize = 65535

    enum ControlMode { case broadcast, unicast }

    enum SocketError: Error { case create(String), bind(String), option(String) }

    private let controlMode: ControlMode
    private let txFD: Int32
    private let rxFD: Int32
    private let rtpFD: Int32

    private var seq: Int32 = 0
    private let seqLock = NSLock()

    init(controlMode: ControlMode = .broadcast, interfaceName: String? = nil) throws {
        self.controlMode = controlMode

        txFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        rxFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        rtpFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard txFD >= 0, rxFD >= 0, rtpFD >= 0 else {
            throw SocketError.create("socket() failed: \(String(cString: strerror(errno)))")
        }

        try Self.setReuse(txFD)
        try Self.setBroadcast(txFD)
        try Self.bind(txFD, port: Self.ctrlPort)

        try Self.setReuse(rxFD)
        try Self.setRecvTimeout(rxFD, ms: Self.recvTimeoutMs)
        try Self.bind(rxFD, port: Self.rxPort)

        if let iface = interfaceName {
            let idx = if_nametoindex(iface)
            if idx != 0 {
                var scope = Int32(idx)
                setsockopt(txFD, IPPROTO_IP, IP_BOUND_IF, &scope, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(rxFD, IPPROTO_IP, IP_BOUND_IF, &scope, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(rtpFD, IPPROTO_IP, IP_BOUND_IF, &scope, socklen_t(MemoryLayout<Int32>.size))
            }
        }
    }

    /// Send a K1G control packet (rolling seq patched here, like the Kotlin `send`).
    func send(_ data: Data) {
        let s = nextSeq()
        let pkt = K1GPacket.patchSeq(data, seq: s)
        let host = controlMode == .broadcast ? Self.broadcastIP : Self.dashIP
        sendTo(txFD, data: pkt, host: host, port: Self.ctrlPort)
    }

    func sendRtp(_ data: Data) {
        sendTo(rtpFD, data: data, host: Self.dashIP, port: Self.rtpPort)
    }

    /// Blocks up to `recvTimeoutMs`; returns nil on timeout, throws on a real socket error.
    func receive() throws -> Data? {
        var buf = [UInt8](repeating: 0, count: Self.bufSize)
        let n = recv(rxFD, &buf, Self.bufSize, 0)
        if n < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK { return nil }   // timeout
            throw SocketError.option("recv failed: \(String(cString: strerror(errno)))")
        }
        return Data(buf[0..<n])
    }

    func close() {
        Darwin.close(txFD)
        Darwin.close(rxFD)
        Darwin.close(rtpFD)
    }

    // ── helpers ──────────────────────────────────────────────────────────
    private func nextSeq() -> Int {
        seqLock.lock(); defer { seqLock.unlock() }
        let v = seq
        seq = (seq + 1) & 0xFF
        return Int(v)
    }

    private func sendTo(_ fd: Int32, data: Data, host: String, port: UInt16) {
        var addr = Self.makeSockaddrIn(host: host, port: port)
        _ = data.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) { aptr in
                aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, raw.baseAddress, data.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private static func makeSockaddrIn(host: String, port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(host)
        return addr
    }

    private static func bind(_ fd: Int32, port: UInt16) throws {
        var addr = makeSockaddrIn(host: "0.0.0.0", port: port)
        let r = withUnsafePointer(to: &addr) { aptr in
            aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if r != 0 { throw SocketError.bind("bind(:\(port)) failed: \(String(cString: strerror(errno)))") }
    }

    private static func setReuse(_ fd: Int32) throws {
        var on: Int32 = 1
        if setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size)) != 0 {
            throw SocketError.option("SO_REUSEADDR failed")
        }
    }

    private static func setBroadcast(_ fd: Int32) throws {
        var on: Int32 = 1
        if setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size)) != 0 {
            throw SocketError.option("SO_BROADCAST failed")
        }
    }

    private static func setRecvTimeout(_ fd: Int32, ms: Int32) throws {
        var tv = timeval(tv_sec: Int(ms / 1000), tv_usec: Int32((ms % 1000) * 1000))
        if setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size)) != 0 {
            throw SocketError.option("SO_RCVTIMEO failed")
        }
    }
}
