import Foundation

/// One TLV segment: `(type:1)(sub:1)(len:2be)(value:len)`.
struct Tlv: Equatable {
    let type: Int
    let sub: Int
    let value: Data

    init(type: Int, sub: Int, value: Data = Data()) {
        self.type = type
        self.sub = sub
        self.value = value
    }
}

/// K1G packet format — ported verbatim from the validated Kotlin implementation
/// (cross-checked against the open-source better-dash reference and traffic on
/// firmware 11.63).
///
/// OUTGOING (app → dash), big-endian:
///   [0:2]  outer_len   – total packet size including this field
///   [2:4]  seg_count   – 1 (fixed header segment) + N TLV segments
///   [4:8]  zeros
///   [8:10] flags       – always 0x02 0x01
///   [10:12] const      – always 0x00 0x05
///   [12:16] magic      – "K1G " (0x4B 0x31 0x47 0x20)
///   [16]   seq         – rolling 0–255, patched at send time (see `patchSeq`)
///   [17+]  TLV entries
///
/// INCOMING (dash → app) uses a SHORTER header — segments start at offset 8.
enum K1GPacket {
    static let magic: [UInt8] = [0x4B, 0x31, 0x47, 0x20] // "K1G "

    private static let fixed: [UInt8] = [
        0x00, 0x00, 0x00, 0x00,        // reserved
        0x02, 0x01, 0x00, 0x05,        // flags
        0x4B, 0x31, 0x47, 0x20,        // "K1G "
    ]

    /// Build an outgoing packet. The seq byte is left 0x00 — `patchSeq` sets it at send time.
    static func build(_ tlvs: [Tlv]) -> Data {
        let segCount = 1 + tlvs.count

        var out = Data()
        out.append(0); out.append(0)                                  // outer_len placeholder
        out.append(UInt8((segCount >> 8) & 0xFF))
        out.append(UInt8(segCount & 0xFF))
        out.append(contentsOf: fixed)
        out.append(0)                                                 // seq placeholder
        for tlv in tlvs {
            out.append(UInt8(tlv.type & 0xFF))
            out.append(UInt8(tlv.sub & 0xFF))
            out.append(UInt8((tlv.value.count >> 8) & 0xFF))
            out.append(UInt8(tlv.value.count & 0xFF))
            out.append(tlv.value)
        }

        out[0] = UInt8((out.count >> 8) & 0xFF)
        out[1] = UInt8(out.count & 0xFF)
        return out
    }

    static func build(_ tlvs: Tlv...) -> Data { build(tlvs) }

    /// Patch the rolling seq byte (right after "K1G ") and fix outer_len. Returns a copy.
    static func patchSeq(_ pkt: Data, seq: Int) -> Data {
        var out = pkt
        if let k = indexOfMagic(out), k + 4 < out.count {
            out[out.startIndex + k + 4] = UInt8(seq & 0xFF)
        }
        out[out.startIndex + 0] = UInt8((out.count >> 8) & 0xFF)
        out[out.startIndex + 1] = UInt8(out.count & 0xFF)
        return out
    }

    static func tlv(_ type: Int, _ sub: Int, _ values: Int...) -> Tlv {
        Tlv(type: type, sub: sub, value: Data(values.map { UInt8($0 & 0xFF) }))
    }

    static func tlv(_ type: Int, _ sub: Int, value: Data) -> Tlv {
        Tlv(type: type, sub: sub, value: value)
    }

    /// Parse a dash → app packet. Segments start at offset 8.
    static func parseIncoming(_ data: Data) -> [Tlv] {
        var tlvs: [Tlv] = []
        guard data.count >= 8 else { return tlvs }
        let bytes = [UInt8](data)
        let segCount = (Int(bytes[2]) << 8) | Int(bytes[3])
        var i = 8
        var n = 0
        while n < segCount && i + 4 <= bytes.count {
            let type = Int(bytes[i])
            let sub = Int(bytes[i + 1])
            let len = (Int(bytes[i + 2]) << 8) | Int(bytes[i + 3])
            i += 4
            let end = min(i + len, bytes.count)
            tlvs.append(Tlv(type: type, sub: sub, value: Data(bytes[i..<end])))
            i = end
            n += 1
        }
        return tlvs
    }

    private static func indexOfMagic(_ data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4) {
            if bytes[i] == magic[0], bytes[i + 1] == magic[1],
               bytes[i + 2] == magic[2], bytes[i + 3] == magic[3] {
                return i
            }
        }
        return nil
    }
}
