import Foundation
import XCTest

@testable import BetterEssentialSpaceCore
@testable import BetterEssentialSpace

/// The login state machine in AppModel — idle → working → otp → ready, and the
/// error paths — against mocked Authflow/ES endpoints. No live network.
@MainActor
final class AppModelTests: XCTestCase {
    private var keychain: KeychainStore!
    private var model: AppModel!

    nonisolated static let accountUUID = "00000000-1111-2222-3333-444444444444"
    nonisolated static let deviceID = "aaaa0000-0000-4000-8000-000000000000"

    override func setUp() {
        super.setUp()
        keychain = TestSupport.testKeychain()
        MockURLProtocol.setHandler { request in
            Self.route(request, otpAction: "verify", tokenStatus: 200)
        }
        let session = AccountSession(
            keychain: keychain,
            urlSession: MockURLProtocol.makeSession(),
            signingKeyProvider: { "dummy-signing-key" }
        )
        model = AppModel(
            accountSession: session,
            authflow: AuthflowClient(
                urlSessionConfiguration: MockURLProtocol.makeConfiguration(),
                keychain: keychain,
                signingKeyProvider: { "dummy-signing-key" }
            ),
            client: ESClient(
                accountSession: session,
                urlSession: MockURLProtocol.makeSession(),
                legacyKeyProvider: { "dummy-legacy-key" }
            )
        )
    }

    override func tearDown() {
        MockURLProtocol.reset()
        keychain?.delete(account: "session")
        keychain?.delete(account: DeviceIdentity.KeychainAccount.key)
        keychain?.delete(account: DeviceIdentity.KeychainAccount.registration)
        super.tearDown()
    }

    // MARK: Routing

    /// Serves the whole login + content surface. `otpAction` changes what
    /// authflow/login asks for; `tokenStatus` can break the last step.
    nonisolated private static func route(
        _ request: URLRequest,
        otpAction: String,
        tokenStatus: Int
    ) -> (HTTPURLResponse, Data) {
        let url = request.url?.absoluteString ?? ""
        let host = request.url?.host ?? ""
        if url.contains("device/report") {
            return MockURLProtocol.ok(request.url, json: #"{"device_id":"\#(deviceID)"}"#)
        }
        if url.contains("authflow/login/state/input") {
            return MockURLProtocol.ok(
                request.url,
                json: #"{"action":{"type":"finished","data":{"session_id":"sess_1"}}}"#
            )
        }
        if url.contains("authflow/login") {
            if otpAction == "finished" {
                return MockURLProtocol.ok(
                    request.url,
                    json: #"{"action":{"type":"finished","data":{"session_id":"sess_trusted"}}}"#
                )
            }
            return MockURLProtocol.ok(
                request.url,
                json: #"{"state_token":"statetoken_1","action":{"type":"verify","data":{"masked_destination":"use****@example.com"}}}"#
            )
        }
        if url.contains("oauth2/authorize"), let requestURL = request.url {
            let state = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "state" }?.value
            return (
                HTTPURLResponse(
                    url: requestURL, statusCode: 302, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "nothing-account-app://oauth2/callback?code=CODE1&state=\(state ?? "")"]
                )!,
                Data()
            )
        }
        if url.contains("oauth2/token") {
            if tokenStatus != 200 {
                return MockURLProtocol.error(request.url, status: tokenStatus, json: #"{"message":"exchange failed"}"#)
            }
            return MockURLProtocol.ok(
                request.url,
                json: #"{"access_token":"\#(TestJWT.token(uuid: accountUUID, expiresAt: Date(timeIntervalSinceNow: 3600)))","refresh_token":"rt_new","device_secret":"ds_new"}"#
            )
        }
        if host == "essential-space.nothingtech.link" {
            return MockURLProtocol.ok(
                request.url,
                json: #"{"code":"00000","msg":"success","data":{"page_no":1,"page_size":20,"hasNextPage":false,"page_data":[]}}"#
            )
        }
        return MockURLProtocol.ok(
            request.url,
            json: #"{"userId":"u1","useMemory":true,"hasAgreedToTerms":true,"updatedAt":"2026-10-25T00:00:00Z"}"#
        )
    }

    // MARK: Tests

    func testFullLoginReachesReadyAndLoadsContent() async throws {
        model.bootstrap()
        XCTAssertEqual(model.phase, .needsToken(nil))

        await model.logIn(email: "user@example.com", password: "hunter2")
        XCTAssertEqual(model.loginStage, .otp(maskedEmail: "use****@example.com"))

        await model.submitOTP("738392")
        XCTAssertEqual(model.loginStage, .idle)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.sessionOverview?.accountUUID, Self.accountUUID)
        XCTAssertEqual(model.sessionOverview?.hasRefreshToken, true)

        for _ in 0..<100 where model.preferences == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(model.preferences, "content loads once the phase turns ready")
        XCTAssertNil(model.lastError)
    }

    func testTrustedDeviceLoginSkipsOTPEntirely() async throws {
        model.bootstrap()
        MockURLProtocol.setHandler { request in
            Self.route(request, otpAction: "finished", tokenStatus: 200)
        }

        await model.logIn(email: "user@example.com", password: "hunter2")
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.loginStage, .idle)
    }

    func testWrongOTPReturnsToOTPStageWithError() async throws {
        model.bootstrap()
        MockURLProtocol.setHandler { request in
            var response = Self.route(request, otpAction: "verify", tokenStatus: 200)
            if request.url?.absoluteString.contains("state/input") == true {
                response = MockURLProtocol.error(request.url, status: 400, json: #"{"message":"code incorrect"}"#)
            }
            return response
        }

        await model.logIn(email: "user@example.com", password: "hunter2")
        await model.submitOTP("000000")
        XCTAssertEqual(model.loginStage, .otp(maskedEmail: "use****@example.com"))
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(model.phase, .needsToken(nil), "a wrong OTP must not sign anyone in")
    }

    func testFailureAfterAcceptedOTPRestartsTheForm() async throws {
        model.bootstrap()
        MockURLProtocol.setHandler { request in
            Self.route(request, otpAction: "verify", tokenStatus: 500)
        }

        await model.logIn(email: "user@example.com", password: "hunter2")
        await model.submitOTP("738392")
        // The OTP was accepted but the token exchange failed: no consumed state
        // token may be left behind, so the form restarts instead of dead-ending.
        XCTAssertEqual(model.loginStage, .idle)
        XCTAssertNotNil(model.lastError)
        XCTAssertFalse(model.accountSession.isSignedIn)
    }

    func testCancelLoginReturnsToCredentialsForm() async throws {
        model.bootstrap()
        await model.logIn(email: "user@example.com", password: "hunter2")
        model.cancelLogin()
        XCTAssertEqual(model.loginStage, .idle)
    }
}
