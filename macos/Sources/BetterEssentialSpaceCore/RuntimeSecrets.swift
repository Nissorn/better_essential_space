import Foundation
import Security

/// Resolves the two shared Nothing app keys.
///
/// Defaults ship in `EmbeddedKeys` (issue 06: the owner chose to publish them —
/// APK-derived values shared by every install of the official app, not personal
/// credentials). A plain-text file under `~/.better-essential-space/` overrides
/// the bundled value, so a server-side key rotation can be fixed without a new
/// build. Personal tokens never pass through here — those live in the Keychain.
public enum RuntimeSecrets {
    public static let directoryName = ".better-essential-space"
    public static let legacyAPIKeyFilename = "legacy-api-key"
    public static let accountSigningKeyFilename = "account-signing-key"
    public static let claimKeyFilename = "claim-key"

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The legacy records-host API key used to build the `auth` header (MD5 scheme).
    public static func legacyAPIKey(directory: URL = defaultDirectory) throws -> String {
        try resolve(
            directory.appendingPathComponent(legacyAPIKeyFilename),
            fallback: EmbeddedKeys.legacyAPIKey,
            missing: { path in .missingLegacyAPIKey(path) }
        )
    }

    /// The RSA-2048 public key that seals every card-write envelope (notes/04).
    /// DISK-ONLY by decision (issue 10): unlike the two app keys above there is
    /// NO `EmbeddedKeys` fallback — the claim key must never ship in the binary.
    /// A missing or empty file fails the edit loudly (missingClaimKey), as does
    /// a value that is not a readable RSA public key (invalidClaimKey). PEM
    /// wrapping is tolerated: armor lines are dropped and all whitespace
    /// stripped before the base64 is decoded.
    public static func claimKey(directory: URL = defaultDirectory) throws -> SecKey {
        let fileURL = directory.appendingPathComponent(claimKeyFilename)
        let path = fileURL.path
        let contents = FileManager.default.contents(atPath: path)
            .flatMap { String(data: $0, encoding: .utf8) }?
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
            .filter { !$0.isWhitespace }
        guard let base64 = contents, !base64.isEmpty else {
            throw ESError.missingClaimKey(path)
        }
        guard let keyData = Data(base64Encoded: base64) else {
            throw ESError.invalidClaimKey(path)
        }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        guard let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, nil) else {
            throw ESError.invalidClaimKey(path)
        }
        return key
    }

    /// The HMAC key for the `x-app-signature` header on account requests, login included.
    public static func accountSigningKey(directory: URL = defaultDirectory) throws -> String {
        try resolve(
            directory.appendingPathComponent(accountSigningKeyFilename),
            fallback: EmbeddedKeys.accountSigningKey,
            missing: { path in .missingAccountSigningKey(path) }
        )
    }

    /// Override file present → its trimmed value. An empty file throws instead of
    /// silently falling back, so a broken override stays visible. No file → the
    /// embedded default.
    private static func resolve(_ overrideFile: URL, fallback: String, missing: (String) -> ESError) throws -> String {
        guard let data = FileManager.default.contents(atPath: overrideFile.path) else {
            return fallback
        }
        guard let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else {
            throw missing(overrideFile.path)
        }
        return value
    }
}
