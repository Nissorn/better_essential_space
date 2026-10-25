import Foundation

/// Loads the runtime key files from `~/.better-essential-space/`.
///
/// These keys are never embedded in the repo or the binary (secrets policy, spec.md).
/// When a key file is missing the caller gets a typed `ESError` naming the expected path.
public enum RuntimeSecrets {
    public static let directoryName = ".better-essential-space"
    public static let legacyAPIKeyFilename = "legacy-api-key"
    public static let accountSigningKeyFilename = "account-signing-key"

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The legacy records-host API key used to build the `auth` header (MD5 scheme).
    public static func legacyAPIKey(directory: URL = defaultDirectory) throws -> String {
        try readTrimmed(
            directory.appendingPathComponent(legacyAPIKeyFilename),
            missing: { path in .missingLegacyAPIKey(path) }
        )
    }

    /// The HMAC key for the `x-app-signature` header on account requests (token refresh).
    public static func accountSigningKey(directory: URL = defaultDirectory) throws -> String {
        try readTrimmed(
            directory.appendingPathComponent(accountSigningKeyFilename),
            missing: { path in .missingAccountSigningKey(path) }
        )
    }

    private static func readTrimmed(_ fileURL: URL, missing: (String) -> ESError) throws -> String {
        guard let data = FileManager.default.contents(atPath: fileURL.path) else {
            throw missing(fileURL.path)
        }
        guard let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else {
            throw missing(fileURL.path)
        }
        return value
    }
}
