import Foundation

/// Hex helpers mirroring NorthStar/OpenDash's `String.hexToBytes()` and the
/// debug hex dumps used across the dash link layer.
extension Data {
    /// Build a `Data` from a hex string. Spaces are ignored, so both
    /// `"0016000200..."` and `"00 16 00 02 ..."` parse identically.
    init(hex: String) {
        let clean = hex.replacingOccurrences(of: " ", with: "")
        var bytes = [UInt8]()
        bytes.reserveCapacity(clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex, let next = clean.index(index, offsetBy: 2, limitedBy: clean.endIndex) {
            if let byte = UInt8(clean[index..<next], radix: 16) {
                bytes.append(byte)
            }
            index = next
        }
        self = Data(bytes)
    }

    /// Space-separated upper-case hex, used in protocol-capture logging.
    var hexString: String { map { String(format: "%02X", $0) }.joined(separator: " ") }

    /// Compact lower-case hex (no separators).
    var hexCompact: String { map { String(format: "%02x", $0) }.joined() }
}
