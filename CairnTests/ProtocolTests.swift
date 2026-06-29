import XCTest
@testable import Cairn

final class HexEncodingTests: XCTestCase {
    func testRoundTrip() {
        XCTAssertEqual(Data(hex: "4b314720").hexCompact, "4b314720")
        XCTAssertEqual(Data(hex: "4b314720").hexString, "4B 31 47 20")
        XCTAssertEqual(Data(hex: "00 16"), Data([0x00, 0x16]))
    }
}

final class K1GPacketTests: XCTestCase {
    func testBuildSetsLengthAndSegCount() {
        let pkt = K1GPacket.build()                       // header-only, segCount = 1
        XCTAssertEqual(pkt.count, 17)
        XCTAssertEqual(Int(pkt[0]) << 8 | Int(pkt[1]), pkt.count)   // outer_len
        XCTAssertEqual(Int(pkt[2]) << 8 | Int(pkt[3]), 1)           // seg_count
        XCTAssertEqual(Array(pkt[8..<12]), [0x02, 0x01, 0x00, 0x05])  // flags
        XCTAssertEqual(Array(pkt[12..<16]), [0x4B, 0x31, 0x47, 0x20]) // "K1G "
        XCTAssertEqual(pkt[16], 0x00)                               // seq placeholder
    }

    func testBuildWithTlv() {
        let pkt = K1GPacket.build(K1GPacket.tlv(0x06, 0x06, 1, 2, 3))
        XCTAssertEqual(Int(pkt[0]) << 8 | Int(pkt[1]), pkt.count)
        XCTAssertEqual(Int(pkt[2]) << 8 | Int(pkt[3]), 2)          // 1 + 1 tlv
        // TLV at offset 17: type, sub, len(2), value(3)
        XCTAssertEqual(Array(pkt[17..<23]), [0x06, 0x06, 0x00, 0x03, 0x01, 0x02])
    }

    func testPatchSeq() {
        let pkt = K1GPacket.build()
        let patched = K1GPacket.patchSeq(pkt, seq: 0x2A)
        XCTAssertEqual(patched[16], 0x2A)
        XCTAssertEqual(Int(patched[0]) << 8 | Int(patched[1]), patched.count)
    }

    func testParseIncoming() {
        // incoming format: outer_len, seg_count, 4 ignored, then TLVs from offset 8
        // one TLV: 07 01 0001 01  (auth-confirm)
        let data = Data(hex: "000D00010000000007010001" + "01")
        let tlvs = K1GPacket.parseIncoming(data)
        XCTAssertEqual(tlvs.count, 1)
        XCTAssertEqual(tlvs[0].type, 0x07)
        XCTAssertEqual(tlvs[0].sub, 0x01)
        XCTAssertEqual(tlvs[0].value, Data([0x01]))
    }
}

final class DashCommandsTests: XCTestCase {
    func testAuthRequestKnownBytes() {
        XCTAssertEqual(DashCommands.authRequest(),
                       Data(hex: "0016000200000000020100054b314720000804000101"))
    }

    func testAuthSendKeyShape() {
        let cipher = Data(repeating: 0xAB, count: 128)
        let pkt = DashCommands.authSendKey(cipher)
        XCTAssertEqual(pkt.count, 149)                 // 21-byte prefix + 128 ciphertext
        XCTAssertEqual(pkt.suffix(128), cipher)
    }

    func testActiveNavPacketLengthHeader() {
        let pkt = DashCommands.activeNavPacket()
        XCTAssertEqual(Int(pkt[0]) << 8 | Int(pkt[1]), pkt.count)
    }

    func testRouteCardCarriesTitleAndLength() {
        let pkt = DashCommands.routeCard(title: "Manali", projectionOn: true)
        XCTAssertEqual(Int(pkt[0]) << 8 | Int(pkt[1]), pkt.count)
        XCTAssertNotNil(pkt.range(of: Data("Manali".utf8)))
    }
}

final class RtpPacketizerTests: XCTestCase {
    func testSinglePacketHeader() {
        var packets: [Data] = []
        let p = RtpPacketizer(seedSeq: 0, seedSsrc: 0x1122_3344, seedTsBase: 0) { packets.append($0) }
        let nal = Data([0x65] + Array(repeating: 0x00, count: 50))
        p.packetize(nal: nal, endOfAU: true, wallClockMs: 0)

        XCTAssertEqual(packets.count, 1)
        let pkt = packets[0]
        XCTAssertEqual(pkt[0], 0x80)                          // version 2
        XCTAssertEqual(pkt[1], 0x80 | 96)                    // marker + PT 96
        XCTAssertEqual(Int(pkt[2]) << 8 | Int(pkt[3]), 0)    // seq
        XCTAssertEqual(Array(pkt[8..<12]), [0x11, 0x22, 0x33, 0x44]) // ssrc
        XCTAssertEqual(pkt.suffix(nal.count), nal)            // payload
    }

    func testFuAFragmentation() {
        var packets: [Data] = []
        let p = RtpPacketizer(seedSeq: 0, seedSsrc: 0, seedTsBase: 0) { packets.append($0) }
        let nal = Data([0x65] + Array(repeating: 0xFF, count: 1499))  // 1500 B > 1380
        p.packetize(nal: nal, endOfAU: true, wallClockMs: 0)

        XCTAssertEqual(packets.count, 2)
        // FU indicator = (0x65 & 0xE0) | 28 = 0x7C
        XCTAssertEqual(packets[0][12], 0x7C)
        XCTAssertEqual(packets[1][12], 0x7C)
        XCTAssertEqual(packets[0][13], 0x80 | 5)             // first fragment, type 5
        XCTAssertEqual(packets[1][13], 0x40 | 5)             // last fragment, type 5
        XCTAssertEqual(packets[0][1] & 0x80, 0)             // no marker on first
        XCTAssertEqual(packets[1][1] & 0x80, 0x80)          // marker on last
    }
}

final class NalProcessorTests: XCTestCase {
    func testIdrBundlingAndSpsRewrite() {
        var emitted: [(Data, Bool)] = []
        let np = NalProcessor { emitted.append(($0, $1)) }
        let sc: [UInt8] = [0, 0, 0, 1]
        let sps: [UInt8] = [0x67, 0x42, 0xC0, 0x29, 0x00]   // constraint byte 0xC0 → should rewrite to 0x00
        let pps: [UInt8] = [0x68, 0xAA, 0xBB]
        let idr: [UInt8] = [0x65, 0x01, 0x02, 0x03]
        np.process(Data(sc + sps + sc + pps + sc + idr))

        XCTAssertEqual(emitted.count, 1)
        XCTAssertTrue(emitted[0].1)                           // isKeyframe
        let bundle = [UInt8](emitted[0].0)
        XCTAssertEqual(Array(bundle.prefix(5)), [0x67, 0x42, 0x00, 0x29, 0x00]) // rewritten SPS leads
    }

    func testSeiAndAudDropped_SlicePassthrough() {
        var emitted: [(Data, Bool)] = []
        let np = NalProcessor { emitted.append(($0, $1)) }
        let sc: [UInt8] = [0, 0, 0, 1]
        let sei: [UInt8] = [0x06, 0x01]   // type 6 → drop
        let aud: [UInt8] = [0x09, 0x10]   // type 9 → drop
        let slice: [UInt8] = [0x41, 0xAA] // type 1 → passthrough
        np.process(Data(sc + sei + sc + aud + sc + slice))

        XCTAssertEqual(emitted.count, 1)
        XCTAssertFalse(emitted[0].1)
        XCTAssertEqual([UInt8](emitted[0].0), slice)
    }
}

final class AESCBCTests: XCTestCase {
    func testRoundTrip() {
        let key = Data((0..<32).map { UInt8($0) })
        let iv = Data((0..<16).map { UInt8($0) })
        let plaintext = Data("hello tripper dash".utf8)
        guard let blob = AESCBC.encrypt(plaintext: plaintext, key: key, iv: iv) else {
            return XCTFail("encrypt failed")
        }
        XCTAssertEqual(AESCBC.decrypt(ivAndCiphertext: blob, key: key), plaintext)
    }
}

final class DashAuthTests: XCTestCase {
    func testConfirmAndReject() {
        let auth = DashAuth(ssid: "RE_TEST")
        XCTAssertEqual(auth.ingest(Tlv(type: 0x07, sub: 0x01, value: Data([0x01]))), .confirmed)
        XCTAssertEqual(auth.ingest(Tlv(type: 0x07, sub: 0x01, value: Data([0x00]))), .rejected)
        XCTAssertEqual(auth.ingest(Tlv(type: 0x05, sub: 0x00, value: Data())), .none)
    }

    /// End-to-end RSA path: generate a 1024-bit key, feed its modulus/exponent as the
    /// dash would (07 00 / 07 03), and assert we produce a valid 128-byte q3c.d packet.
    func testKeyPacketFromGeneratedRsaKey() throws {
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 1024,
        ]
        var err: Unmanaged<CFError>?
        guard let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &err),
              let pub = SecKeyCopyPublicKey(priv),
              let der = SecKeyCopyExternalRepresentation(pub, &err) as Data? else {
            throw XCTSkip("RSA key generation unavailable in this environment")
        }
        guard let (modulus, exponent) = Self.parseRSAPublicKey(der) else {
            return XCTFail("could not parse PKCS#1 public key")
        }

        let auth = DashAuth(ssid: "RE_TEST")
        XCTAssertEqual(auth.ingest(Tlv(type: 0x07, sub: 0x00, value: modulus)), .none)
        let event = auth.ingest(Tlv(type: 0x07, sub: 0x03, value: exponent))
        guard case .sendKey(let packet) = event else {
            return XCTFail("expected sendKey, got \(event)")
        }
        XCTAssertEqual(packet.count, 149)            // 21-byte prefix + 128-byte RSA ciphertext
        XCTAssertEqual(auth.sessionKey?.count, 32)   // AES-256 session key generated
    }

    // Minimal PKCS#1 RSAPublicKey DER parser: SEQUENCE { INTEGER modulus, INTEGER exponent }.
    private static func parseRSAPublicKey(_ der: Data) -> (Data, Data)? {
        let b = [UInt8](der)
        var i = 0
        guard i < b.count, b[i] == 0x30 else { return nil }; i += 1
        _ = readLen(b, &i)                                   // skip SEQUENCE length
        guard i < b.count, b[i] == 0x02 else { return nil }; i += 1
        let mLen = readLen(b, &i)
        guard i + mLen <= b.count else { return nil }
        let modulus = Data(b[i..<i + mLen]); i += mLen
        guard i < b.count, b[i] == 0x02 else { return nil }; i += 1
        let eLen = readLen(b, &i)
        guard i + eLen <= b.count else { return nil }
        let exponent = Data(b[i..<i + eLen])
        return (modulus, exponent)
    }

    private static func readLen(_ b: [UInt8], _ i: inout Int) -> Int {
        let first = b[i]; i += 1
        if first < 0x80 { return Int(first) }
        let n = Int(first & 0x7F)
        var len = 0
        for _ in 0..<n { len = (len << 8) | Int(b[i]); i += 1 }
        return len
    }
}
