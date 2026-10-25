import Foundation

/// Owns the Nothing Account session: token storage in the Keychain, Access Token validation
/// via JWT claims, and Refresh Token rotation via `oauth2/token`.
///
/// Stateless across calls — tokens are read from the Keychain on demand, so instances are
/// `Sendable` and every part of the app observes the same persisted session.
public struct AccountSession: Sendable {
    public static let accountTokenURL = URL(string: "https://account.nothing.tech/api/v2/oauth2/token")!
    public static let tokenPath = "/api/v2/oauth2/token"
    public static let clientID = "account-app-native"

    /// How many seconds before the Access Token's `exp` we proactively refresh.
    public static let refreshSkew: TimeInterval = 120

    public let keychain: KeychainStore
    public let urlSession: URLSession
    public let signingKeyProvider: @Sendable () throws -> String

    public init(
        keychain: KeychainStore = KeychainStore(),
        urlSession: URLSession = .shared,
        signingKeyProvider: @escaping @Sendable () throws -> String = { try RuntimeSecrets.accountSigningKey() }
    ) {
        self.keychain = keychain
        self.urlSession = urlSession
        self.signingKeyProvider = signingKeyProvider
    }

    // MARK: Token storage (Keychain round-trip)

    public var isSignedIn: Bool { storedTokens() != nil }

    /// The persisted token set, if one was imported.
    public func storedTokens() -> TokenSet? {
        guard let data = keychain.load(account: Self.tokenAccount) else { return nil }
        return try? JSONDecoder().decode(TokenSet.self, from: data)
    }

    @discardableResult
    public func storeTokens(_ tokens: TokenSet) throws -> TokenSet {
        let data = try JSONEncoder().encode(tokens)
        try keychain.save(data, account: Self.tokenAccount)
        return tokens
    }

    public func importTokenFile(at url: URL) throws -> TokenSet {
        try storeTokens(TokenFile.parse(contentsOf: url))
    }

    public func clearTokens() {
        keychain.delete(account: Self.tokenAccount)
    }

    /// Claims of the currently stored Access Token, if decodable.
    public var claims: JWTClaims? {
        storedTokens().flatMap { JWT.claims(fromToken: $0.accessToken) }
    }

    // MARK: Access Token with refresh

    /// A valid Access Token, refreshing first when the stored one is missing claims,
    /// expired, or about to expire.
    public func validAccessToken() async throws -> String {
        guard let tokens = storedTokens() else { throw ESError.notSignedIn }
        if let claims = JWT.claims(fromToken: tokens.accessToken),
           let expiresAt = claims.expiresAt,
           expiresAt.timeIntervalSinceNow > Self.refreshSkew
        {
            return tokens.accessToken
        }
        return try await refresh().accessToken
    }

    /// Exchanges the Refresh Token for a new token set and persists it.
    /// Concurrent callers share one flight (per Keychain service): the refresh
    /// token grant must not run twice in parallel with the same token.
    @discardableResult
    public func refresh() async throws -> TokenSet {
        try await RefreshFlight.shared.run(key: keychain.service) { [self] in
            try await performRefresh()
        }
    }

    private func performRefresh() async throws -> TokenSet {
        guard let tokens = storedTokens() else { throw ESError.notSignedIn }
        guard let refreshToken = tokens.refreshToken, !refreshToken.isEmpty else {
            throw ESError.sessionExpired("The imported token file has no Refresh Token.")
        }
        let apiKey = try signingKeyProvider()

        let body = "grant_type=refresh_token"
            + "&client_id=\(Self.clientID)"
            + "&refresh_token=\(AuthSigning.percentEncodeAll(refreshToken))"
        let bodyData = Data(body.utf8)
        let nonce = UUID().uuidString
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)

        var request = URLRequest(url: Self.accountTokenURL)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(nonce, forHTTPHeaderField: "x-nonce")
        request.setValue(String(timestamp), forHTTPHeaderField: "x-timestamp")
        request.setValue(
            AuthSigning.appSignature(
                body: bodyData,
                nonce: nonce,
                path: Self.tokenPath,
                timestampMilliseconds: timestamp,
                apiKey: apiKey
            ),
            forHTTPHeaderField: "x-app-signature"
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw ESError.requestFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ESError.invalidResponse("token endpoint returned a non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 400 || http.statusCode == 401 {
                throw ESError.sessionExpired(
                    "The account service rejected the Refresh Token (HTTP \(http.statusCode))."
                )
            }
            throw ESError.httpStatus(
                http.statusCode,
                code: nil,
                message: String(data: data, encoding: .utf8)
            )
        }

        // The refresh response carries the same fields as the import file; keep the old
        // Refresh Token / Device Secret when the server does not rotate them.
        var refreshed = try TokenFile.parse(data)
        if refreshed.refreshToken == nil { refreshed.refreshToken = tokens.refreshToken }
        if refreshed.deviceSecret == nil { refreshed.deviceSecret = tokens.deviceSecret }
        return try storeTokens(refreshed)
    }

    private static let tokenAccount = "session"
}

/// Coalesces concurrent refreshes with the same in-flight task, keyed by Keychain
/// service so isolated test sessions never share a flight.
private actor RefreshFlight {
    static let shared = RefreshFlight()
    private var inFlight: [String: Task<TokenSet, Error>] = [:]

    func run(key: String, operation: @escaping @Sendable () async throws -> TokenSet) async throws -> TokenSet {
        if let existing = inFlight[key] {
            return try await existing.value
        }
        let task = Task { try await operation() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }
}
