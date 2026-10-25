import Foundation

/// The token set of a signed-in Nothing Account.
/// `accessToken` is required; the others are kept when present (refresh responses rotate them).
public struct TokenSet: Codable, Equatable, Sendable {
    public var accessToken: String
    public var idToken: String?
    public var refreshToken: String?
    public var deviceSecret: String?

    public enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case idToken = "id_token"
        case refreshToken = "refresh_token"
        case deviceSecret = "device_secret"
    }
}

public enum TokenFile {
    /// Parses the token-import JSON (shape of `secrets/es_token.json`):
    /// `{"access_token": ..., "id_token": ..., "refresh_token": ..., "device_secret": ...}`.
    /// `access_token` is required; extra keys are ignored.
    public static func parse(_ data: Data) throws -> TokenSet {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ESError.invalidTokenFile("not valid JSON")
        }
        guard let accessToken = object["access_token"] as? String, !accessToken.isEmpty else {
            throw ESError.invalidTokenFile("access_token is missing or empty")
        }
        return TokenSet(
            accessToken: accessToken,
            idToken: optionalString(object["id_token"]),
            refreshToken: optionalString(object["refresh_token"]),
            deviceSecret: optionalString(object["device_secret"])
        )
    }

    public static func parse(contentsOf url: URL) throws -> TokenSet {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw ESError.invalidTokenFile("could not read \(url.lastPathComponent)")
        }
        return try parse(data)
    }

    private static func optionalString(_ raw: Any?) -> String? {
        guard let string = raw as? String, !string.isEmpty else { return nil }
        return string
    }
}
