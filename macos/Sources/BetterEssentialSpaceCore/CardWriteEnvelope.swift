import CommonCrypto
import Foundation
import Security

/// One card-write envelope (notes/04): a fresh 32-byte AES key per request,
/// the deviceId sealed with it, and the same key RSA-wrapped for the server.
/// The encryption is contractual, not cryptographic — the claimKey is a PUBLIC
/// key and only the deviceId and a size string are ever covered — so the only
/// goal is matching the phone client's wire format exactly.
///
/// Internal by design: the envelope never leaks past `ESClient.updateCard`.
struct WriteEnvelope: Sendable {
    /// Wire `payload`: base64(AES-256-ECB-PKCS7(deviceId)).
    let devicePayload: String
    /// Wire `cipherKey`: base64(RSA-PKCS1v15(base64(aesKey))) — the RSA covers
    /// the base64 STRING of the key, not its raw bytes (notes/04).
    let cipherKey: String
    let aesKey: Data

    static func randomAESKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: kCCKeySizeAES256)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    /// `aesKey` is injectable so tests can pin the fixed openssl-verified key;
    /// production callers take the fresh-random default.
    static func make(deviceId: String, claimKey: SecKey, aesKey: Data = WriteEnvelope.randomAESKey()) throws -> WriteEnvelope {
        guard aesKey.count == kCCKeySizeAES256 else {
            throw ESError.invalidResponse("write-envelope AES key must be 32 bytes (got \(aesKey.count))")
        }
        let keyString = Data(aesKey.base64EncodedString().utf8)
        guard let cipher = SecKeyCreateEncryptedData(claimKey, .rsaEncryptionPKCS1, keyString as CFData, nil) as Data? else {
            throw ESError.invalidResponse("the claim key cannot seal the write envelope")
        }
        return WriteEnvelope(
            devicePayload: try AES256ECB.seal(deviceId, key: aesKey),
            cipherKey: cipher.base64EncodedString(),
            aesKey: aesKey
        )
    }

    /// base64(AES(plaintext)) under this envelope's key — the per-card
    /// `String(size)` payload. The same `cipherKey` rides on every card entry.
    func sealed(_ plaintext: String) throws -> String {
        try AES256ECB.seal(plaintext, key: aesKey)
    }
}

/// AES-256-ECB with PKCS7 padding — the default of Java's `Cipher.getInstance("AES")`
/// that the phone client encrypts these fields with. Deterministic, so fixed-key
/// test vectors cross-check against openssl.
enum AES256ECB {
    static func seal(_ plaintext: String, key: Data) throws -> String {
        guard key.count == kCCKeySizeAES256 else {
            throw ESError.invalidResponse("AES-256 seal called with a \(key.count)-byte key")
        }
        let input = Data(plaintext.utf8)
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var encryptedCount = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, keyBytes.count,
                        nil,
                        inputBytes.baseAddress, inputBytes.count,
                        outputBytes.baseAddress, outputBytes.count,
                        &encryptedCount
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw ESError.invalidResponse("AES-256-ECB seal failed (CCCrypt status \(status))")
        }
        return output.prefix(encryptedCount).base64EncodedString()
    }
}
