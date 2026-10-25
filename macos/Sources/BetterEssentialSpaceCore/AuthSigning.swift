import CryptoKit
import Foundation

/// Request-signing primitives verified against live captures (notes/02 §Request signing,
/// notes/03 §Header rules).
public enum AuthSigning {
    /// Hex MD5 of the UTF-8 bytes. The legacy records host's `auth` header is
    /// `hex(MD5(legacyAPIKey + timestamp))` (`NothingApiManager.b` interceptor).
    public static func hexMD5(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The legacy records host `auth` header value for a given point in time.
    public static func legacyAuthHeader(apiKey: String, timestampMilliseconds: Int64) -> String {
        hexMD5(apiKey + String(timestampMilliseconds))
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Percent-encoding with only RFC 3986 unreserved characters (`A–Z a–z 0–9 - . _ ~`)
    /// left literal — Python `urllib.parse.quote(s, safe="")` semantics. Foundation's
    /// `addingPercentEncoding(withAllowedCharacters: .init())` encodes letters too, so this
    /// is implemented explicitly.
    public static func percentEncodeAll(_ string: String) -> String {
        let unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        let allowed = CharacterSet(charactersIn: unreserved)
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    /// The `x-app-signature` header for `account.nothing.tech/api` requests:
    ///
    /// ```
    /// payload  = "body=" + sha256_hex(body)
    ///          + "&nonce=" + nonce
    ///          + "&path=" + percentEncodeAll(path)
    ///          + "&timestamp=" + timestamp_ms
    ///          + "&apiKey=" + apiKey
    /// signature = base64url_nopad(HMAC-SHA256(payload, key: apiKey))
    /// ```
    public static func appSignature(body: Data, nonce: String, path: String, timestampMilliseconds: Int64, apiKey: String) -> String {
        let payload =
            "body=" + sha256Hex(body)
            + "&nonce=" + nonce
            + "&path=" + percentEncodeAll(path)
            + "&timestamp=" + String(timestampMilliseconds)
            + "&apiKey=" + apiKey
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: Data(payload.utf8),
            using: SymmetricKey(data: Data(apiKey.utf8))
        )
        return base64URLEncodeNoPad(Data(authenticationCode))
    }

    public static func base64URLEncodeNoPad(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The string covered by `x-device-signature` (notes/02 §Request signing):
    /// `"<epoch ms>." + <raw request body>`. No hash, no nonce, no path — verified
    /// byte-for-byte against the live login capture.
    public static func deviceSignaturePayload(timestampMilliseconds: Int64, body: Data) -> String {
        String(timestampMilliseconds) + "." + String(decoding: body, as: UTF8.self)
    }

    /// `x-device-signature` for a device-bound request: ECDSA P-256 over the payload,
    /// IEEE P1363 `r||s` (64 bytes — what CryptoKit's `rawRepresentation` already is),
    /// base64url alphabet **with** `=` padding (Dart `base64Url.encode` semantics).
    public static func deviceSignature(
        privateKey: P256.Signing.PrivateKey,
        body: Data,
        timestampMilliseconds: Int64
    ) throws -> String {
        let payload = deviceSignaturePayload(timestampMilliseconds: timestampMilliseconds, body: body)
        let signature = try privateKey.signature(for: Data(payload.utf8))
        return signature.rawRepresentation.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }
}
