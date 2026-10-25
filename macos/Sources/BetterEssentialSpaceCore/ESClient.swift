import Foundation

/// One client for the two Essential Space hosts (notes/03):
///
/// - Records host `https://essential-space.nothingtech.link/essentialSpace` — Cards
///   (Records), categories, collections. Headers: `Authorization`, `timestamp`,
///   `auth = hex(MD5(legacyAPIKey + timestamp))`.
/// - Preferences host `https://prod.essentialsearch.essential-nt.com` — user preferences.
///   Headers: `Authorization`, `X-Nothing-Account-ID` (uuid claim of the Access Token).
///
/// A 401 from either host triggers one Access Token refresh and a single retry.
public struct ESClient: Sendable {
    public enum Host {
        static let records = URL(string: "https://essential-space.nothingtech.link/essentialSpace")!
        static let preferences = URL(string: "https://prod.essentialsearch.essential-nt.com")!
    }

    public let accountSession: AccountSession
    public let urlSession: URLSession
    public let legacyKeyProvider: @Sendable () throws -> String

    public init(
        accountSession: AccountSession,
        urlSession: URLSession = .shared,
        legacyKeyProvider: @escaping @Sendable () throws -> String = { try RuntimeSecrets.legacyAPIKey() }
    ) {
        self.accountSession = accountSession
        self.urlSession = urlSession
        self.legacyKeyProvider = legacyKeyProvider
    }

    // MARK: Preferences host

    public func fetchPreferences() async throws -> Preferences {
        let (data, http) = try await perform(request: makePreferencesRequest)
        return try decode(Preferences.self, from: data, http: http)
    }

    // MARK: Records host

    public func fetchCardPage(pageNo: Int = 1, pageSize: Int = 20) async throws -> CardListPage {
        let body = CardListRequest(pageNo: pageNo, pageSize: pageSize)
        let (data, http) = try await performRecords(
            path: "storage/card/v1/list",
            httpMethod: "POST",
            body: try JSONEncoder().encode(body)
        )
        let envelope = try decode(LegacyEnvelope<CardListPage>.self, from: data, http: http)
        guard envelope.code == "00000" else {
            throw ESError.httpStatus(http.statusCode, code: envelope.code, message: envelope.msg)
        }
        guard let page = envelope.data else {
            throw ESError.invalidResponse("card list response has no data (code \(envelope.code))")
        }
        return page
    }

    public func fetchCategories() async throws -> [Category] {
        let (data, http) = try await performRecords(
            path: "storage/category/v1/list",
            httpMethod: "GET",
            body: nil
        )
        let envelope = try decode(LegacyEnvelope<[Category]>.self, from: data, http: http)
        return envelope.data ?? []
    }

    public func fetchCollections(sinceTime: Int64 = 0) async throws -> [CollectionSummary] {
        let body = CollectionListRequest(sinceTime: sinceTime)
        let (data, http) = try await performRecords(
            path: "storage/collection/v1/list",
            httpMethod: "POST",
            body: try JSONEncoder().encode(body)
        )
        let envelope = try decode(LegacyEnvelope<[CollectionSummary]>.self, from: data, http: http)
        return envelope.data ?? []
    }

    // MARK: Audio download (issue 09)

    /// One call hides the whole download chain (notes/04): the signed-URL POST
    /// with the standard legacy headers, matching the response entry by
    /// (region, gcsKey), the auth-free GCS V4 GET, and exactly ONE internal
    /// re-sign-and-retry when GCS answers 403 (expired signature — signUrls
    /// live ~1 h and are never persisted). GCS 404 (object gone) and transport
    /// failures surface as `httpStatus`/`requestFailed`.
    public func downloadAudio(for file: CardFile) async throws -> Data {
        do {
            return try await fetchAuthFree(try await signedURL(for: file))
        } catch ESError.httpStatus(403, _, _) {
            return try await fetchAuthFree(try await signedURL(for: file))
        }
    }

    /// POST `storage/card/v1/files` — plaintext JSON (no write envelope) with
    /// the same three auth headers as every legacy call, strict on the code
    /// like `fetchCardPage`.
    private func signedURL(for file: CardFile) async throws -> URL {
        let body = try JSONEncoder().encode(CardFilesRequest(files: [file]))
        let (data, http) = try await performRecords(
            path: "storage/card/v1/files",
            httpMethod: "POST",
            body: body
        )
        let envelope = try decode(LegacyEnvelope<[SignedCardFileWire]>.self, from: data, http: http)
        guard envelope.code == "00000" else {
            throw ESError.httpStatus(http.statusCode, code: envelope.code, message: envelope.msg)
        }
        guard let entry = (envelope.data ?? [])
            .first(where: { $0.region == file.region && $0.gcsKey == file.gcsKey }),
              let signString = entry.signUrl,
              let signURL = URL(string: signString)
        else {
            throw ESError.invalidResponse(
                "storage/card/v1/files returned no signed URL for \(file.gcsKey ?? "?") in \(file.region ?? "?")"
            )
        }
        return signURL
    }

    /// Plain GET on a server-signed GCS URL. MUST NOT go through
    /// perform/performRecords — they attach Authorization, which GCS rejects;
    /// the V4 signature is in the URL itself.
    private func fetchAuthFree(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, http) = try await send(request)
        guard (200..<300).contains(http.statusCode) else {
            // 401 has already passed send()'s refresh passthrough; for GCS it
            // is simply a failure like any other status.
            throw ESError.httpStatus(http.statusCode, code: nil, message: String(data: data, encoding: .utf8))
        }
        return data
    }

    // MARK: Request plumbing

    /// Sends with the given Access Token; on 401 refreshes once and retries with the new
    /// token. `send` only lets 401 through as a non-2xx status, so any other failure throws.
    private func perform(request makeRequest: @Sendable (_ accessToken: String) throws -> URLRequest) async throws -> (Data, HTTPURLResponse) {
        var accessToken = try await accountSession.validAccessToken()
        for attempt in 0...1 {
            let request = try makeRequest(accessToken)
            let (data, response) = try await send(request)
            if (200..<300).contains(response.statusCode) {
                return (data, response)
            }
            if attempt == 0 {
                accessToken = try await accountSession.refresh().accessToken
                continue
            }
            break
        }
        // The refresh itself succeeded, so the session is still valid — a leftover 401
        // points at the request (e.g. a wrong legacy key), not at the tokens.
        throw ESError.hostUnauthorized("A host kept rejecting requests with a valid Access Token.")
    }

    /// Legacy-host request with the `Authorization` / `timestamp` / `auth` header scheme,
    /// plus one refresh-and-retry on 401.
    private func performRecords(path: String, httpMethod: String, body: Data?) async throws -> (Data, HTTPURLResponse) {
        let legacyAPIKey = try legacyKeyProvider()
        return try await perform { accessToken in
            var request = URLRequest(url: Host.records.appendingPathComponent(path))
            request.httpMethod = httpMethod
            if let body {
                request.httpBody = body
                request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            }
            let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(String(timestamp), forHTTPHeaderField: "timestamp")
            request.setValue(
                AuthSigning.legacyAuthHeader(apiKey: legacyAPIKey, timestampMilliseconds: timestamp),
                forHTTPHeaderField: "auth"
            )
            return request
        }
    }

    private func makePreferencesRequest(accessToken: String) throws -> URLRequest {
        guard let accountID = JWT.claims(fromToken: accessToken)?.uuid else {
            throw ESError.invalidResponse("the Access Token carries no uuid claim")
        }
        var request = URLRequest(url: Host.preferences.appendingPathComponent("preferences"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "X-Nothing-Account-ID")
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            // A superseded load cancels its URLSession work; that is control flow,
            // not a failure the user should see.
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw ESError.requestFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ESError.invalidResponse("non-HTTP response from \(request.url?.host ?? "?")")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 {
                return (data, http) // caller decides to refresh and retry
            }
            throw ESError.httpStatus(
                http.statusCode,
                code: (try? JSONDecoder().decode(LegacyEnvelope<EmptyData>.self, from: data))?.code,
                message: String(data: data, encoding: .utf8)
            )
        }
        return (data, http)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, http: HTTPURLResponse) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ESError.invalidResponse("undecodable \(type) payload (HTTP \(http.statusCode)): \(error.localizedDescription)")
        }
    }
}

/// Decoding helper for envelopes whose `data` we do not model.
private struct EmptyData: Decodable {}

/// Request body of `storage/card/v1/files` (notes/04): plaintext JSON.
private struct CardFilesRequest: Encodable {
    let files: [CardFile]
}

/// One `data` entry of the `storage/card/v1/files` response.
private struct SignedCardFileWire: Decodable {
    let region: String?
    let gcsKey: String?
    let signUrl: String?
}
