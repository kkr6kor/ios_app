import Foundation
import CommonCrypto

/// AES-256-CBC/PKCS7 — used to decrypt the dash's `0F` vehicle-secure telemetry
/// (instrument-cluster data) under the session key. Mirrors the Kotlin
/// `aesDecryptCbc` helper: the blob is `[iv(16) ‖ ciphertext]`.
enum AESCBC {
    static func decrypt(ivAndCiphertext: Data, key: Data) -> Data? {
        guard ivAndCiphertext.count > 16, key.count == kCCKeySizeAES256 else { return nil }
        let iv = ivAndCiphertext.prefix(16)
        let ciphertext = ivAndCiphertext.suffix(from: ivAndCiphertext.startIndex + 16)

        var out = Data(count: ciphertext.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            ciphertext.withUnsafeBytes { ctPtr in
                iv.withUnsafeBytes { ivPtr in
                    key.withUnsafeBytes { keyPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            ctPtr.baseAddress, ciphertext.count,
                            outPtr.baseAddress, outCapacity,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == Int32(kCCSuccess) else { return nil }
        out.removeSubrange(moved..<out.count)
        return out
    }

    /// Encrypt helper — handy for the off-bike DashEmulator to synthesize `0F` telemetry.
    static func encrypt(plaintext: Data, key: Data, iv: Data) -> Data? {
        guard key.count == kCCKeySizeAES256, iv.count == 16 else { return nil }
        var out = Data(count: plaintext.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            plaintext.withUnsafeBytes { ptPtr in
                iv.withUnsafeBytes { ivPtr in
                    key.withUnsafeBytes { keyPtr in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            ptPtr.baseAddress, plaintext.count,
                            outPtr.baseAddress, outCapacity,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == Int32(kCCSuccess) else { return nil }
        out.removeSubrange(moved..<out.count)
        return iv + out
    }
}
