import Foundation

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
