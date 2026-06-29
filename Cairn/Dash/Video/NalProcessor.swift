import Foundation

/// Splits Annex-B H.264 into individual NAL units, handles the dash-specific IDR
/// bundling requirement, and filters NAL types the dash rejects (SEI, AUD).
/// Ported from the validated Kotlin `NalProcessor`.
///
/// Dash-specific rules (from better-dash analysis):
///  - SPS (type 7) and PPS (type 8): cache, do NOT send raw
///  - IDR (type 5): prepend cached SPS + PPS with Annex-B start codes, send bundle
///  - SEI (type 6) and AUD (type 9): discard
///  - All other slices (types 1–4, 10–12): send as-is
final class NalProcessor {
    private static let startCode4: [UInt8] = [0, 0, 0, 1]

    private let onNal: (Data, Bool) -> Void

    private var sps: Data?
    private var pps: Data?
    private var loggedParams = false

    init(onNal: @escaping (Data, Bool) -> Void) {
        self.onNal = onNal
    }

    func process(_ annexB: Data) {
        for nal in split(annexB) where !nal.isEmpty {
            let type = Int(nal[nal.startIndex]) & 0x1F
            switch type {
            case 7:
                let normalized = normalizeSpsForDash(nal)
                if sps != normalized {
                    DiagnosticsLog.shared.log("video", "SPS raw=\(nal.hexString) → dash=\(normalized.hexString)")
                }
                sps = normalized
            case 8:
                if pps != nal { DiagnosticsLog.shared.log("video", "PPS=\(nal.hexString)") }
                pps = nal
            case 5: emitIdr(nal)
            case 6, 9: break // SEI, AUD — discard
            default:
                if (1...4).contains(type) || (10...12).contains(type) {
                    onNal(nal, false)
                }
            }
        }
    }

    /// The Tripper firmware whitelists the stock phone's SPS shape (67 42 00 29…)
    /// before it will leave the loading state ("Timeout!" otherwise). VideoToolbox
    /// emits Baseline (0x42) but with its own constraint byte and a level chosen for
    /// 526×300 (often lower than 0x29). Force the full `42 00 29` profile/constraint/
    /// level prefix the dash expects — a decoder accepts a higher declared level, and
    /// these bytes don't affect slice-header parsing, so this is safe.
    private func normalizeSpsForDash(_ sps: Data) -> Data {
        var b = [UInt8](sps)
        if b.count >= 4, (Int(b[0]) & 0x1F) == 7, b[1] == 0x42 {
            b[2] = 0x00   // constraint flags
            b[3] = 0x29   // level 4.1 — the shape the dash whitelists
            return Data(b)
        }
        return sps
    }

    private func emitIdr(_ idr: Data) {
        if let s = sps, let p = pps {
            var bundle = Data()
            bundle.append(s)
            bundle.append(contentsOf: Self.startCode4)
            bundle.append(p)
            bundle.append(contentsOf: Self.startCode4)
            bundle.append(idr)
            onNal(bundle, true)
        } else {
            // IDR with no SPS/PPS cached — dash will not decode, but pass it through.
            onNal(idr, true)
        }
    }

    /// Split Annex-B stream on 4-byte (0x00000001) or 3-byte (0x000001) start codes.
    private func split(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var nals: [Data] = []
        var start = -1
        var i = 0
        while i < bytes.count {
            let sc4 = i + 3 < bytes.count &&
                bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 0 && bytes[i + 3] == 1
            let sc3 = !sc4 && i + 2 < bytes.count &&
                bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1
            if sc4 {
                if start >= 0 { nals.append(Data(bytes[start..<i])) }
                start = i + 4; i += 4
            } else if sc3 {
                if start >= 0 { nals.append(Data(bytes[start..<i])) }
                start = i + 3; i += 3
            } else {
                i += 1
            }
        }
        if start >= 0 && start < bytes.count { nals.append(Data(bytes[start..<bytes.count])) }
        return nals
    }
}
