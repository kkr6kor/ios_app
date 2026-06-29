import Foundation
import Security

/// Result of feeding one incoming TLV into the auth state machine.
enum AuthEvent: Equatable {
    /// Both pubkey halves received — send this q3c.d packet now.
    case sendKey(Data)
    /// Dash confirmed (07 01 01).
    case confirmed
    /// Dash rejected (07 01 != 01) — resend authRequest if retries remain.
    case rejected
    case none
}

/// RSA-1024 + AES-256 handshake state machine, ported from the Kotlin `DashAuth`.
///
/// The dash sends modulus (07 00) and exponent (07 03) — possibly in SEPARATE
/// packets — so state accumulates across calls. The session-key packet is emitted
/// exactly once per attempt; `reset()` re-arms it after a rejection.
final class DashAuth {
    private let ssid: String
    private var modulus: Data?
    private var exponent: Data?
    private var keySent = false

    private(set) var sessionKey: Data?

    init(ssid: String) { self.ssid = ssid }

    func ingest(_ tlv: Tlv) -> AuthEvent {
        guard tlv.type == 0x07 else { return .none }
        switch tlv.sub {
        case 0x00: modulus = tlv.value
        case 0x03: exponent = tlv.value
        case 0x01: return (tlv.value.first == 0x01) ? .confirmed : .rejected
        default: return .none
        }

        if !keySent, let m = modulus, let e = exponent {
            keySent = true
            if let pkt = buildKeyPacket(modulus: m, exponent: e) {
                return .sendKey(pkt)
            }
        }
        return .none
    }

    /// Re-arm after a 07 01 != 01 rejection so the dash can re-offer its pubkey.
    func reset() {
        modulus = nil
        exponent = nil
        keySent = false
    }

    private func buildKeyPacket(modulus: Data, exponent: Data) -> Data? {
        var aes = Data(count: 32)
        let ok = aes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard ok == errSecSuccess else { return nil }
        sessionKey = aes

        var payload = Data(ssid.utf8)
        payload.append(aes)

        let der = ASN1.rsaPublicKeyDER(modulus: modulus, exponent: exponent)
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, nil),
              let cipher = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, payload as CFData, nil) as Data?
        else { return nil }

        return DashCommands.authSendKey(cipher)
    }
}

/// Minimal ASN.1 DER builder — reconstructs a PKCS#1 `RSAPublicKey` from raw
/// modulus + exponent bytes so `SecKeyCreateWithData` can ingest the dash's key.
/// (The dash sends modulus 07 00 and exponent 07 03 as raw big-endian bytes.)
enum ASN1 {
    static func rsaPublicKeyDER(modulus: Data, exponent: Data) -> Data {
        var seqBody = Data()
        seqBody.append(integer(modulus))
        seqBody.append(integer(exponent))
        return tlv(0x30, seqBody)
    }

    private static func integer(_ bytes: Data) -> Data {
        var b = [UInt8](bytes)
        while b.count > 1, b.first == 0x00 { b.removeFirst() }   // strip leading zeros
        if let first = b.first, first & 0x80 != 0 { b.insert(0x00, at: 0) } // unsigned guard
        return tlv(0x02, Data(b))
    }

    private static func tlv(_ tag: UInt8, _ body: Data) -> Data {
        var out = Data([tag])
        out.append(lengthBytes(body.count))
        out.append(body)
        return out
    }

    private static func lengthBytes(_ len: Int) -> Data {
        if len < 0x80 { return Data([UInt8(len)]) }
        var value = len
        var bytes: [UInt8] = []
        while value > 0 { bytes.insert(UInt8(value & 0xFF), at: 0); value >>= 8 }
        return Data([UInt8(0x80 | bytes.count)] + bytes)
    }
}
