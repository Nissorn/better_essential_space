import Foundation
import XCTest

@testable import BetterEssentialSpaceCore

/// Refresh flow against a mocked `oauth2/token` endpoint — 200 rotation and 400 rejection.
final class RefreshFlowTests: XCTestCase {
    private var keychain: KeychainStore!
    private var session: AccountSession!

    override func setUp() {
        super.setUp()
        keychain = TestSupport.testKeychain()
        session = AccountSession(
            keychain: keychain,
            urlSession: MockURLProtocol.makeSession(),
            signingKeyProvider: { "test-signing-key-456" }
        )
    }

    override func tearDown() {
        MockURLProtocol.reset()
        keychain?.delete(account: "session")
        super.tearDown()
    }

    private func storeInitialTokens(accessToken: String = TestJWT.token(
        uuid: "00000000-1111-2222-3333-444444444444",
        expiresAt: Date(timeIntervalSinceNow: 3600)
    )) throws {
        try session.storeTokens(
            TokenSet(accessToken: accessToken, idToken: nil, refreshToken: "rt_test_123", deviceSecret: nil)
        )
    }

    private static let refreshedJSON = """
    {"access_token":"new_access","refresh_token":"rt_new","id_token":"id_new","device_secret":"ds_new","expires_in":2592000,"token_type":"Bearer","scope":"openid"}
    """

    // MARK: 200

    func testRefresh200BuildsSignedRequestAndPersistsRotatedTokens() async throws {
        try storeInitialTokens()
        let capturedRequest = Locked<URLRequest?>(nil)

        MockURLProtocol.setHandler { request in
            capturedRequest.set(request)
            return MockURLProtocol.ok(request.url, json: Self.refreshedJSON)
        }

        let tokens = try await session.refresh()
        XCTAssertEqual(tokens.accessToken, "new_access")
        XCTAssertEqual(session.storedTokens()?.refreshToken, "rt_new")
        XCTAssertEqual(session.storedTokens()?.deviceSecret, "ds_new")

        let request = try XCTUnwrap(capturedRequest.get())
        XCTAssertEqual(request.url?.absoluteString, "https://account.nothing.tech/api/v2/oauth2/token")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let body = try XCTUnwrap(String(data: request.bodyStreamData ?? request.httpBody ?? Data(), encoding: .utf8))
        XCTAssertEqual(body, "grant_type=refresh_token&client_id=account-app-native&refresh_token=rt_test_123")

        // Independently recompute the signature from the captured nonce/timestamp.
        let nonce = try XCTUnwrap(request.value(forHTTPHeaderField: "x-nonce"))
        let timestamp = try XCTUnwrap(request.value(forHTTPHeaderField: "x-timestamp"))
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "x-app-signature"),
            AuthSigning.appSignature(
                body: Data(body.utf8),
                nonce: nonce,
                path: "/api/v2/oauth2/token",
                timestampMilliseconds: Int64(timestamp) ?? -1,
                apiKey: "test-signing-key-456"
            )
        )
    }

    func testRefresh200KeepsOldSecretsWhenServerDoesNotRotate() async throws {
        try storeInitialTokens()
        MockURLProtocol.setHandler { request in
            MockURLProtocol.ok(request.url, json: #"{"access_token":"new_access","expires_in":100}"#)
        }
        let tokens = try await session.refresh()
        XCTAssertEqual(tokens.refreshToken, "rt_test_123")
        XCTAssertEqual(session.storedTokens()?.refreshToken, "rt_test_123")
    }

    // MARK: 400

    func testRefresh400ThrowsSessionExpiredAndKeepsOldTokens() async throws {
        try storeInitialTokens()
        MockURLProtocol.setHandler { request in
            MockURLProtocol.error(
                request.url,
                status: 400,
                json: #"{"error":"invalid_grant","error_description":"refresh token expired"}"#
            )
        }

        do {
            _ = try await session.refresh()
            XCTFail("expected sessionExpired")
        } catch {
            guard case ESError.sessionExpired = error else {
                return XCTFail("expected sessionExpired, got \(error)")
            }
        }
        XCTAssertNotNil(session.storedTokens()?.accessToken)
        XCTAssertEqual(session.storedTokens()?.refreshToken, "rt_test_123")
    }

    // MARK: guards

    func testConcurrentRefreshesShareOneFlight() async throws {
        try storeInitialTokens()
        let requests = Locked(0)
        MockURLProtocol.setHandler { request in
            requests.with { $0 += 1 }
            // Hold the flight open so the second caller must join it, not start its own.
            Thread.sleep(forTimeInterval: 0.15)
            return MockURLProtocol.ok(request.url, json: #"{"access_token":"at_shared","refresh_token":"rt_shared"}"#)
        }

        let accountSession = try XCTUnwrap(session)
        async let first: TokenSet = accountSession.refresh()
        try await Task.sleep(nanoseconds: 50_000_000)
        async let second: TokenSet = accountSession.refresh()
        let (a, b) = try await (first, second)

        XCTAssertEqual(a.accessToken, "at_shared")
        XCTAssertEqual(b.accessToken, "at_shared")
        XCTAssertEqual(requests.get(), 1, "concurrent callers must share one refresh exchange")
        XCTAssertEqual(session.storedTokens()?.refreshToken, "rt_shared")
    }

    func testRefreshNetworkFailureSurfacesRequestFailedAndKeepsTokens() async throws {
        try storeInitialTokens()
        MockURLProtocol.setHandler { _ in
            throw URLError(.notConnectedToInternet)
        }

        do {
            _ = try await session.refresh()
            XCTFail("expected requestFailed")
        } catch {
            guard case ESError.requestFailed = error else {
                return XCTFail("expected requestFailed, got \(error)")
            }
        }
        XCTAssertEqual(session.storedTokens()?.refreshToken, "rt_test_123", "a network failure must not touch stored tokens")
    }

    func testRefreshWithoutRefreshTokenFailsOffline() async throws {
        try session.storeTokens(TokenSet(accessToken: "at", idToken: nil, refreshToken: nil, deviceSecret: nil))
        MockURLProtocol.setHandler { _ in
            XCTFail("no network call may happen without a Refresh Token")
            return MockURLProtocol.error(nil, status: 500, json: "{}")
        }
        do {
            _ = try await session.refresh()
            XCTFail("expected sessionExpired")
        } catch {
            guard case ESError.sessionExpired = error else {
                return XCTFail("expected sessionExpired, got \(error)")
            }
        }
    }

    func testRefreshWithMissingSigningKeyFailsWithTypedError() async throws {
        let failingKeySession = AccountSession(
            keychain: keychain,
            urlSession: MockURLProtocol.makeSession(),
            signingKeyProvider: { throw ESError.missingAccountSigningKey("/Users/x/.better-essential-space/account-signing-key") }
        )
        try failingKeySession.storeTokens(
            TokenSet(accessToken: "at", idToken: nil, refreshToken: "rt", deviceSecret: nil)
        )
        do {
            _ = try await failingKeySession.refresh()
            XCTFail("expected missingAccountSigningKey")
        } catch {
            guard case ESError.missingAccountSigningKey = error else {
                return XCTFail("expected missingAccountSigningKey, got \(error)")
            }
        }
    }

    func testValidAccessTokenRefreshesExpiredTokenProactively() async throws {
        try storeInitialTokens(
            accessToken: TestJWT.token(uuid: "u", expiresAt: Date(timeIntervalSinceNow: -10))
        )
        MockURLProtocol.setHandler { request in
            MockURLProtocol.ok(request.url, json: Self.refreshedJSON)
        }
        let token = try await session.validAccessToken()
        XCTAssertEqual(token, "new_access")
    }

    func testValidAccessTokenReturnsValidTokenWithoutNetwork() async throws {
        try storeInitialTokens() // expires in an hour
        MockURLProtocol.setHandler { _ in
            XCTFail("a still-valid Access Token must not trigger a refresh")
            return MockURLProtocol.error(nil, status: 500, json: "{}")
        }
        let token = try await session.validAccessToken()
        XCTAssertEqual(token, session.storedTokens()?.accessToken)
    }
}
