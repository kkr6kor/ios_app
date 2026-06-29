import Foundation

/// RFC 6184 H.264 RTP packetizer tuned for the Tripper Dash. Ported from the
/// validated Kotlin `RtpPacketizer`.
///
/// Rules enforced (from better-dash analysis):
///  - NO STAP-A (type 24) — dash rejects aggregation packets
///  - FU-A (type 28) fragmentation for NALs larger than `maxPayload`
///  - Marker bit only on the LAST RTP packet of each access unit
///  - 90 kHz RTP clock
///  - Max payload 1380 bytes (avoids IP fragmentation on 192.168.1.x)
final class RtpPacketizer {
    private static let maxPayload = 1380
    private static let payloadType = 96

    private let onPacket: (Data) -> Void

    private var seq: Int
    private let ssrc: UInt32
    private let tsBase: UInt64

    /// `seedSeq`/`seedSsrc`/`seedTsBase` are injectable so unit tests are deterministic;
    /// production passes nil and gets randomized values like the Kotlin original.
    init(seedSeq: Int? = nil,
         seedSsrc: UInt32? = nil,
         seedTsBase: UInt64? = nil,
         onPacket: @escaping (Data) -> Void) {
        self.onPacket = onPacket
        self.seq = seedSeq ?? Int.random(in: 0...0xFFFF)
        self.ssrc = seedSsrc ?? UInt32.random(in: 0...UInt32.max)
        self.tsBase = (seedTsBase ?? UInt64.random(in: 0...UInt64.max)) & 0xFFFF_FFFF
    }

    /// Packetize a single NAL unit (raw, no start code).
    /// - Parameter endOfAU: true if this is the last NAL in the access unit (sets marker bit).
    func packetize(nal: Data, endOfAU: Bool, wallClockMs: Int64) {
        let ts = (tsBase &+ UInt64(wallClockMs) &* 90) & 0xFFFF_FFFF
        if nal.count <= Self.maxPayload {
            emit(payload: nal, marker: endOfAU, ts: ts)
        } else {
            fuA(nal: nal, endOfAU: endOfAU, ts: ts)
        }
    }

    private func fuA(nal: Data, endOfAU: Bool, ts: UInt64) {
        let bytes = [UInt8](nal)
        let nalType = Int(bytes[0]) & 0x1F
        let fuInd = UInt8((Int(bytes[0]) & 0xE0) | 28)
        var offset = 1
        var isFirst = true
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let chunkLen = min(Self.maxPayload - 2, remaining)
            let isLast = chunkLen >= remaining

            let fuHeader = UInt8((isFirst ? 0x80 : 0) | (isLast ? 0x40 : 0) | nalType)

            var payload = Data(capacity: 2 + chunkLen)
            payload.append(fuInd)
            payload.append(fuHeader)
            payload.append(contentsOf: bytes[offset..<(offset + chunkLen)])

            emit(payload: payload, marker: isLast && endOfAU, ts: ts)
            offset += chunkLen
            isFirst = false
        }
    }

    private func emit(payload: Data, marker: Bool, ts: UInt64) {
        var pkt = Data(capacity: 12 + payload.count)
        pkt.append(0x80)
        pkt.append(UInt8((marker ? 0x80 : 0x00) | (Self.payloadType & 0x7F)))
        pkt.append(UInt8((seq >> 8) & 0xFF))
        pkt.append(UInt8(seq & 0xFF))
        pkt.append(UInt8((ts >> 24) & 0xFF))
        pkt.append(UInt8((ts >> 16) & 0xFF))
        pkt.append(UInt8((ts >> 8) & 0xFF))
        pkt.append(UInt8(ts & 0xFF))
        pkt.append(UInt8((ssrc >> 24) & 0xFF))
        pkt.append(UInt8((ssrc >> 16) & 0xFF))
        pkt.append(UInt8((ssrc >> 8) & 0xFF))
        pkt.append(UInt8(ssrc & 0xFF))
        pkt.append(payload)
        seq = (seq + 1) & 0xFFFF
        onPacket(pkt)
    }
}
