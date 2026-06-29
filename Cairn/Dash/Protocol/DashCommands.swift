import Foundation

/// K1G control-plane commands — Swift port of the validated Kotlin `DashCommands`,
/// cross-checked against the better-dash reference and firmware 11.63. These are
/// interoperability facts (packet layouts), not copied source.
enum DashCommands {

    // ── Auth ──────────────────────────────────────────────────────────────
    /// q3c.e — "request auth / send me your RSA public key".
    static func authRequest() -> Data {
        Data(hex: "0016000200000000020100054b314720000804000101")
    }

    /// q3c.d — RSA-encrypted (SSID ‖ AES-256 key). Ciphertext must be 128 B.
    static func authSendKey(_ ciphertext: Data) -> Data {
        precondition(ciphertext.count == 128, "q3c.d expects 128B RSA ciphertext, got \(ciphertext.count)")
        return Data(hex: "0095000200000000020100054B3147200008000080") + ciphertext
    }

    // ── Initial burst (sent right after the socket opens) ─────────────────
    static func initialBurst(hostname: String) -> [Data] {
        [
            authRequest(),
            hostnameAnnounce(hostname),
            timeSync(),
            Data(hex: "0016000200000000020100054b314720030557000155"),
            Data(hex: "0016000200000000020100054b3147200405560001aa"),
            Data(hex: "0016000200000000020100054b3147200506050001aa"),
            Data(hex: "0016000200000000020100054b3147200605170001aa"),
            Data(hex: "001d000200000000020100054b314720080a020008aa55000000000000"),
            Data(hex: "0044000a00000000020100054b3147200906080001ff060300015506040001a2060f0001aa" +
                      "0601000101054c000113052d00020000051b0001190521000132054d000132"),
        ]
    }

    /// 06 06 — time-of-day sync (hour, minute, second). The dash has no clock of
    /// its own; it shows whatever the phone last fed it, so the session re-sends
    /// this every 30 s built from the real clock.
    static func timeSync() -> Data {
        let cal = Calendar.current
        let now = Date()
        return K1GPacket.build(K1GPacket.tlv(
            0x06, 0x06,
            cal.component(.hour, from: now),
            cal.component(.minute, from: now),
            cal.component(.second, from: now)
        ))
    }

    /// Bluconnect announce — device name shown on the dash's "Connected to X" screen.
    static func hostnameAnnounce(_ hostname: String) -> Data {
        var raw = Array(hostname.utf8)
        if raw.count > 200 { raw = Array(raw[0..<200]) }
        var out = Data()
        out.append(Data(hex: "0021000200000000020100054b314720"))
        out.append(contentsOf: [0x01, 0x06, 0x0B, 0x00, UInt8((raw.count + 1) & 0xFF)])
        out.append(contentsOf: raw)
        out.append(0x00)
        out[0] = UInt8((out.count >> 8) & 0xFF)
        out[1] = UInt8(out.count & 0xFF)
        return out
    }

    // ── Navigation mode ────────────────────────────────────────────────────
    static func navContext() -> Data { Data(hex: "0016000200000000020100054B31472000052E00011E") }
    static func emptyLists() -> Data {
        Data(hex: "002A000600000000020100054B31472000052F0001000530000100053100010005320001000533000100")
    }
    /// q3c.z2 — start navigation. Send ONCE, after the route card.
    static func navStart() -> Data { Data(hex: "0016000200000000020100054B31472000068000010B") }
    static func navPlaceholder() -> Data { K1GPacket.build(K1GPacket.tlv(0x06, 0x0A, 0x00, 0x00)) }

    // ── Projection control ────────────────────────────────────────────────
    static func projectionFrame() -> Data { Data(hex: "0016000200000000020100054B314720000556000155") }
    static func projectionOn() -> Data { Data(hex: "0016000200000000020100054B314720000605000155") }
    static func projectionStop() -> Data { Data(hex: "0016000200000000020100054B3147200005560001AA") }
    static func projectionOff() -> Data { Data(hex: "0016000200000000020100054B3147200006050001AA") }

    // ── Frame-decoded acknowledgements ────────────────────────────────────
    static func frameDecodedIdr() -> Data { Data(hex: "0016000200000000020100054B314720000611000155") }
    static func frameDecodedP() -> Data { Data(hex: "0016000200000000020100054B314720000612000155") }

    // ── Button / event acknowledgement ────────────────────────────────────
    static func buttonAck(_ code: UInt8) -> Data {
        K1GPacket.build(K1GPacket.tlv(0x06, 0x80, Int(code)))
    }

    static let btn05: UInt8 = 0x05
    static let btn06: UInt8 = 0x06
    static let btn07: UInt8 = 0x07
    static let btn09: UInt8 = 0x09
    static let btn0A: UInt8 = 0x0A
    static let btn22: UInt8 = 0x22

    // ── 1 Hz status heartbeat (0049, fixed temp) ──────────────────────────
    private static let hb0049 = Data(hex:
        "0049000b00000000020100054b3147200006080001050610000139060300015506040001a2060f0001aa" +
        "0601000101054c000113052d00020000051b0001190521000132054d000132")

    /// d.run() heartbeat — on-wire temp byte = °C + 40.
    static func heartbeat(tempC: Int = 25) -> Data {
        var pkt = [UInt8](hb0049)
        if let i = indexOf(pkt, [0x06, 0x10, 0x00, 0x01]), i + 4 < pkt.count {
            pkt[i + 4] = UInt8((tempC + 40) & 0xFF)
        }
        return Data(pkt)
    }

    // ── Route card (0x007E) ───────────────────────────────────────────────
    private static let navTemplate = Data(hex:
        "007e001100000000020100054b31472025050100145461696c6c65206465204d617320647520477200" +
        "050200013c050300013405050002000a05060001300507000130050800043033303305540001300509" +
        "0002004f0546000110050a000155050c000104050b0006303031303030055500012006050001aa060d0001aa")

    private static let navParts: (prefix: Data, suffix: Data) = {
        let t = [UInt8](navTemplate)
        guard let magic = indexOf(t, [0x4b, 0x31, 0x47, 0x20]) else { return (Data(), Data()) }
        let seqOff = magic + 4
        let titleLen = (Int(t[seqOff + 3]) << 8) | Int(t[seqOff + 4])
        let prefix = Data(t[0..<seqOff])
        let suffix = Data(t[(seqOff + 5 + titleLen)...])
        return (prefix, suffix)
    }()

    /// Full 0x007E route card. Must be sent BEFORE z2, then re-sent at ~1 Hz while
    /// streaming or the dash tears the decoder down after ~15 s. Live values overwrite
    /// the template's captured French-route figures.
    static func routeCard(title: String,
                          projectionOn: Bool = false,
                          maneuver: Int? = nil,
                          primaryUnit: Int? = nil,
                          totalDist: Int? = nil,
                          totalUnit: Int? = nil,
                          etaHHMM: String? = nil) -> Data {
        var rt = Array(title.utf8)
        if rt.count > 60 { rt = Array(rt[0..<60]) }
        rt.append(0x00)

        var out = Data()
        out.append(navParts.prefix)
        out.append(0x00)                                   // seq, patched at send
        out.append(contentsOf: [0x05, 0x01])
        out.append(UInt8((rt.count >> 8) & 0xFF))
        out.append(UInt8(rt.count & 0xFF))
        out.append(contentsOf: rt)
        out.append(navParts.suffix)

        var bytes = [UInt8](out)
        func patch1(_ t: Int, _ s: Int, _ v: Int) {
            if let m = indexOf(bytes, [UInt8(t), UInt8(s), 0x00, 0x01], fromEnd: true), m + 4 < bytes.count {
                bytes[m + 4] = UInt8(v & 0xFF)
            }
        }
        func patch2(_ t: Int, _ s: Int, _ v: Int) {
            if let m = indexOf(bytes, [UInt8(t), UInt8(s), 0x00, 0x02], fromEnd: true), m + 5 < bytes.count {
                bytes[m + 4] = UInt8((v >> 8) & 0xFF)
                bytes[m + 5] = UInt8(v & 0xFF)
            }
        }
        patch1(0x06, 0x05, projectionOn ? 0x55 : 0xAA)
        if let it = maneuver { patch1(0x05, 0x02, it) }
        if let it = primaryUnit { patch1(0x05, 0x06, it) }
        patch2(0x05, 0x09, totalDist ?? 0)
        patch2(0x05, 0x05, 0)                              // stale secondary distance → 0
        if let it = totalUnit { patch1(0x05, 0x46, it) }
        if let eta = etaHHMM, eta.count == 4,
           let m = indexOf(bytes, [0x05, 0x08, 0x00, 0x04], fromEnd: true), m + 8 < bytes.count {
            let chars = Array(eta.utf8)
            for i in 0..<4 { bytes[m + 4 + i] = chars[i] }
        }
        bytes[0] = UInt8((bytes.count >> 8) & 0xFF)
        bytes[1] = UInt8(bytes.count & 0xFF)
        return Data(bytes)
    }

    // ── Active navigation info (0x007E-family, ~1 Hz while guiding) ───────
    static let navManeuverContinue = 0x0B
    static let navUnitKmTenths = 0x10   // distance field = km × 10
    static let navUnitMeters = 0x30
    private static let navHdr = "00000000020100054B31472000"

    static func activeNavPacket(maneuver: Int = navManeuverContinue,
                                primaryDist: Int = 500,
                                primaryUnit: Int = navUnitMeters,
                                totalDist: Int = 500,
                                totalUnit: Int = navUnitMeters,
                                projectionOn: Bool = true) -> Data {
        func u16(_ v: Int) -> String { String(format: "%04X", v & 0xFFFF) }
        func u8(_ v: Int) -> String { String(format: "%02X", v & 0xFF) }
        var tlvs = ""
        tlvs += "05020001" + u8(maneuver)       // primary maneuver
        tlvs += "05040002" + u16(primaryDist)   // primary distance
        tlvs += "05060001" + u8(primaryUnit)    // primary unit
        tlvs += "05090002" + u16(totalDist)     // total distance
        tlvs += "05460001" + u8(totalUnit)      // total unit
        tlvs += "050A000155"                     // decimal separator = '.'
        tlvs += "06050001" + (projectionOn ? "55" : "AA")
        tlvs += "060D0001AA"                     // decimal format off

        let segCount = 8 + 1
        let innerHex = String(format: "%04X", segCount) + navHdr + tlvs
        let innerBytes = innerHex.count / 2
        let outerLen = innerBytes + 2
        return Data(hex: String(format: "%04X", outerLen) + innerHex)
    }

    // ── Media now-playing (05 0d) + telephony (05 22) ─────────────────────
    private static let mediaFieldMax = 20

    private static func mediaField(_ s: String) -> Data {
        Data((s.count > mediaFieldMax ? String(s.prefix(mediaFieldMax)) : s).utf8)
    }

    static func nowPlaying(title: String, album: String, artist: String) -> Data {
        var out = Data()
        out.append(mediaField(title)); out.append(0x00)
        out.append(mediaField(album)); out.append(0x00)
        out.append(mediaField(artist))
        return K1GPacket.build(K1GPacket.tlv(0x05, 0x0D, value: out))
    }

    static func callNotify(_ callerName: String) -> Data {
        var v = mediaField(callerName); v.append(0x00)
        return K1GPacket.build(K1GPacket.tlv(0x05, 0x22, value: v))
    }

    static func callClear() -> Data {
        K1GPacket.build(K1GPacket.tlv(0x05, 0x22, value: Data([0x00])))
    }

    // ── helpers ────────────────────────────────────────────────────────────
    private static func indexOf(_ haystack: [UInt8], _ needle: [UInt8], fromEnd: Bool = false) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        let last = haystack.count - needle.count
        let positions: [Int] = fromEnd ? Array(stride(from: last, through: 0, by: -1)) : Array(0...last)
        for i in positions {
            var match = true
            for j in 0..<needle.count where haystack[i + j] != needle[j] { match = false; break }
            if match { return i }
        }
        return nil
    }
}
