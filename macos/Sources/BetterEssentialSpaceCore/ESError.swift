import Foundation

/// Typed errors surfaced by the client. Every case carries a user-presentable message;
/// the missing-key cases name the exact runtime file the app needs.
public enum ESError: Error, Equatable {
    case notSignedIn
    case sessionExpired(String)
    /// A content host still answered 401 after a successful token refresh. The
    /// stored session is fine (only the token endpoint can rule it expired) — the
    /// classic cause is a wrong legacy API key file, not a dead session.
    case hostUnauthorized(String)
    case missingLegacyAPIKey(String)
    case missingAccountSigningKey(String)
    case keychainFailure(OSStatus)
    case invalidTokenFile(String)
    case invalidResponse(String)
    case httpStatus(Int, code: String?, message: String?)
    case requestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "No Access Token found. Import a token file to sign in."
        case .sessionExpired(let reason):
            return "Session expired. \(reason) Import a fresh token file to continue."
        case .hostUnauthorized(let reason):
            return "Still unauthorized (401) after refreshing the Access Token — the session was kept. \(reason)"
        case .missingLegacyAPIKey(let path):
            return "Missing legacy API key file at \(path). Records cannot be fetched without it. See macos/README.md."
        case .missingAccountSigningKey(let path):
            return "Missing account signing key file at \(path). Token refresh needs it for the x-app-signature header. See macos/README.md."
        case .keychainFailure(let status):
            return "Keychain error (OSStatus \(status))."
        case .invalidTokenFile(let detail):
            return "Invalid token file: \(detail)"
        case .invalidResponse(let detail):
            return "Unexpected response from Essential Space: \(detail)"
        case .httpStatus(let status, let code, let message):
            let detail = [code, message].compactMap { $0 }.joined(separator: " — ")
            return "Essential Space request failed (HTTP \(status)\(detail.isEmpty ? "" : ": \(detail)"))."
        case .requestFailed(let detail):
            return "Network request failed: \(detail)"
        }
    }
}
