import Foundation

/// Typed errors surfaced by the client. Every case carries a user-presentable message;
/// the missing-key cases fire when a key override file exists but is empty — an
/// absent file falls back to the bundled key (RuntimeSecrets).
public enum ESError: Error, Equatable {
    case notSignedIn
    case sessionExpired(String)
    /// A content host still answered 401 after a successful token refresh. The
    /// stored session is fine (only the token endpoint can rule it expired) — the
    /// classic cause is a wrong legacy API key file, not a dead session.
    case hostUnauthorized(String)
    case missingLegacyAPIKey(String)
    case missingAccountSigningKey(String)
    /// The disk-only claim key that card writes need is absent or empty. Unlike
    /// the two app keys there is no bundled fallback (issue 10).
    case missingClaimKey(String)
    /// The claim-key file exists but does not contain a readable RSA public key.
    case invalidClaimKey(String)
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
            return "The legacy API key override at \(path) is empty. Delete the file to use the bundled key, or write the new records-host key into it."
        case .missingAccountSigningKey(let path):
            return "The account signing key override at \(path) is empty. Delete the file to use the bundled key, or write the new key into it."
        case .missingClaimKey(let path):
            return "The claim key at \(path) is missing or empty. Editing a Record needs it — save the RSA claim key (base64, PEM wrapping tolerated) into that file."
        case .invalidClaimKey(let path):
            return "The claim key at \(path) is not a readable RSA public key. Replace the file's contents with the base64 claim-key value."
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
