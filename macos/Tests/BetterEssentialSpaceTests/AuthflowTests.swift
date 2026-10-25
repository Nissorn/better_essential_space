import CryptoKit
import Foundation
import XCTest

@testable import BetterEssentialSpaceCore

/// AuthflowClient against mocked endpoints — the five login steps' wire shapes
/// (headers, signatures, bodies) per notes/02 §Login protocol. No live network.
final class AuthflowTests: XCTestCase {
    private var keychain: KeychainStore!
    private var client: AuthflowClient!

    static let signingKey = "test-account-key-789"
    static let deviceID = "11111111-2222-3333-4444-555555555555"

    override func setUp() {
        super.setUp()
        keychain = TestSupport.testKeychain()
        client = AuthflowClient(
            urlSessionConfiguration: MockURLProtocol.makeConfiguration(),
            keychain: keychain,
            signingKeyProvider: { Self.signingKey }
        )
    }

    override func tearDown() {
        MockURLProtocol.reset()
        keychain?.delete(account: DeviceIdentity.KeychainAccount.key)
        keychain?.delete(account: DeviceIdentity.KeychainAccount.registration)
        super.tearDown()
    }

    /// Routes the device/report step (only sent while unregistered) and lets each
    /// test hook one additional endpoint.
    private func mockDeviceReportThen(_ next: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) {
        MockURLProtocol.setHandler { request in
            guard let path = request.url?.path, !path.contains("device/report") else {
                return Self.deviceReportResponse(request)
            }
            return try next(request)
        }
    }

    /// Answers only the device/report call, for tests that register the device
    /// before installing their own step handler.
    private func mockDeviceReportOnly() {
        MockURLProtocol.setHandler { request in
            Self.deviceReportResponse(request)
        }
    }

    private static func deviceReportResponse(_ request: URLRequest) -> (HTTPURLResponse, Data) {
        MockURLProtocol.ok(
            request.url,
            json: #"{"device_id":"\#(deviceID)","next_key_rotation_at":"2026-11-23T19:53:15Z"}"#
        )
    }

    // MARK: Signing primitives

    func testDeviceSignatureMatchesCrackedFormula() throws {
        let key = P256.Signing.PrivateKey()
        let body = Data(#"{"input":{"identification":"email"}}"#.utf8)
        let timestamp: Int64 = 1_792_897_529_492

        let signature = try AuthSigning.deviceSignature(privateKey: key, body: body, timestampMilliseconds: timestamp)

        XCTAssertEqual(AuthSigning.deviceSignaturePayload(timestampMilliseconds: timestamp, body: body), "1792897529492." + String(decoding: body, as: UTF8.self))
        XCTAssertEqual(signature.count, 88)
        XCTAssertTrue(signature.hasSuffix("=="))
        let raw = Data(base64Encoded: signature.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"))!
        XCTAssertEqual(raw.count, 64)
        let ecdsa = try P256.Signing.ECDSASignature(rawRepresentation: raw)
        let payload = Data(AuthSigning.deviceSignaturePayload(timestampMilliseconds: timestamp, body: body).utf8)
        XCTAssertTrue(key.publicKey.isValidSignature(ecdsa, for: payload))
    }

    // MARK: Step 1 — device/report

    func testDeviceReportRegistersDeviceAndSignsHeaders() async throws {
        let captured = Locked<URLRequest?>(nil)
        mockDeviceReportThen { request in
            XCTFail("no request may follow the device report: \(request.url?.path ?? "?")")
            return MockURLProtocol.error(request.url, status: 500, json: "{}")
        }
        MockURLProtocol.setHandler { request in
            captured.set(request)
            return MockURLProtocol.ok(
                request.url,
                json: #"{"device_id":"\#(Self.deviceID)","next_key_rotation_at":"2026-11-23T19:53:15Z"}"#
            )
        }

        let identity = try await client.ensureDeviceRegistered()
        XCTAssertEqual(identity.registeredDeviceId, Self.deviceID)

        // Persisted: a fresh load keeps the same key and the device_id, and does
        // not re-report (the handler now fails every call).
        let reloaded = try DeviceIdentity.loadOrCreate(keychain: keychain)
        XCTAssertEqual(reloaded.registeredDeviceId, Self.deviceID)
        XCTAssertEqual(try reloaded.publicKeySPKIBase64, try identity.publicKeySPKIBase64)
        let again = try await client.ensureDeviceRegistered()
        XCTAssertEqual(again.registeredDeviceId, Self.deviceID)

        let request = try XCTUnwrap(captured.get())
        XCTAssertEqual(request.url?.absoluteString, "https://account.nothing.tech/api/v2/device/report")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Dart/3.9 (dart:io)")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-device-signature"))

        let timestamp = try XCTUnwrap(request.value(forHTTPHeaderField: "x-timestamp"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-request-timestamp"), timestamp)
        let body = try XCTUnwrap(request.bodyStreamData)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "x-app-signature"),
            AuthSigning.appSignature(
                body: body,
                nonce: try XCTUnwrap(request.value(forHTTPHeaderField: "x-nonce")),
                path: "/api/v2/device/report",
                timestampMilliseconds: Int64(timestamp) ?? -1,
                apiKey: Self.signingKey
            )
        )

        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(report["device_model"] as? String, "A059")
        XCTAssertEqual(report["is_emulator"] as? Bool, false)
        XCTAssertEqual(report["is_first"] as? Bool, true)
        let spki = try XCTUnwrap(Data(base64Encoded: report["public_key"] as? String ?? ""))
        XCTAssertEqual(spki.count, 91)
        XCTAssertEqual(Array(spki.prefix(2)), [0x30, 0x59])

        let headerJSON = try XCTUnwrap(request.value(forHTTPHeaderField: "x-device-info")).data(using: .utf8)
            .flatMap { Data(base64Encoded: $0) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertEqual(headerJSON?["device_model"] as? String, "A059")
        XCTAssertNil(headerJSON?["public_key"], "x-device-info must not carry the public key")
        XCTAssertEqual(headerJSON?["identifier"] as? String, report["identifier"] as? String)
    }

    // MARK: Step 2 — authflow/login

    func testStartLoginSendsCredentialsAndReturnsChallenge() async throws {
        let captured = Locked<URLRequest?>(nil)
        mockDeviceReportThen { request in
            captured.set(request)
            return MockURLProtocol.ok(
                request.url,
                json: #"{"state_token":"statetoken_1","action":{"type":"verify","data":{"channel":"email","masked_destination":"use****@example.com","is_device_trusted":false}}}"#
            )
        }

        let challenge: OTPChallenge
        switch try await client.startLogin(email: "user@example.com", password: "hunter2") {
        case .otp(let otpChallenge):
            challenge = otpChallenge
        case .finished:
            return XCTFail("an untrusted device must be challenged with an OTP")
        }
        XCTAssertEqual(challenge.stateToken, "statetoken_1")
        XCTAssertEqual(challenge.maskedDestination, "use****@example.com")

        let request = try XCTUnwrap(captured.get())
        XCTAssertEqual(request.url?.absoluteString, "https://account.nothing.tech/api/v2/authflow/login")
        let body = try XCTUnwrap(request.bodyStreamData)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let input = try XCTUnwrap(json["input"] as? [String: Any])
        XCTAssertEqual(input["identification"] as? String, "email")
        XCTAssertEqual(input["login_id"] as? String, "user@example.com")
        XCTAssertEqual(input["password"] as? String, "hunter2")

        XCTAssertEqual(request.value(forHTTPHeaderField: "x-device-id"), Self.deviceID)
        try verifyDeviceSignature(of: request, body: body)
    }

    func testStartLoginFinishesDirectlyOnTrustedDevice() async throws {
        mockDeviceReportThen { request in
            MockURLProtocol.ok(
                request.url,
                json: #"{"action":{"type":"finished","data":{"session_id":"sess_trusted","type":"redirect_url"}}}"#
            )
        }

        let step = try await client.startLogin(email: "user@example.com", password: "hunter2")
        XCTAssertEqual(step, .finished(sessionID: "sess_trusted"))
    }

    func testStartLoginSurfacesHTTPError() async throws {
        mockDeviceReportThen { request in
            MockURLProtocol.error(request.url, status: 403, json: #"{"message":"Device is an emulator"}"#)
        }

        do {
            _ = try await client.startLogin(email: "user@example.com", password: "hunter2")
            XCTFail("expected a thrown error")
        } catch let error as ESError {
            XCTAssertEqual(error, .httpStatus(403, code: nil, message: #"{"message":"Device is an emulator"}"#))
        }
    }

    // MARK: Step 3 — OTP

    func testSubmitOTPReturnsSessionID() async throws {
        mockDeviceReportOnly()
        _ = try await client.ensureDeviceRegistered()
        let captured = Locked<URLRequest?>(nil)
        MockURLProtocol.setHandler { request in
            captured.set(request)
            return MockURLProtocol.ok(
                request.url,
                json: #"{"state_token":"statetoken_1","action":{"type":"finished","data":{"session_id":"sess_1","type":"redirect_url"}}}"#
            )
        }

        let sessionID = try await client.submitOTP("738392", stateToken: "statetoken_1")
        XCTAssertEqual(sessionID, "sess_1")

        let request = try XCTUnwrap(captured.get())
        XCTAssertEqual(request.url?.absoluteString, "https://account.nothing.tech/api/v2/authflow/login/state/input")
        let body = try XCTUnwrap(request.bodyStreamData)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["state_token"] as? String, "statetoken_1")
        XCTAssertEqual((json["input"] as? [String: Any])?["code"] as? String, "738392")
        try verifyDeviceSignature(of: request, body: body)
    }

    func testSubmitOTPRejectsNonFinishedAction() async throws {
        mockDeviceReportOnly()
        _ = try await client.ensureDeviceRegistered()
        MockURLProtocol.setHandler { request in
            MockURLProtocol.ok(request.url, json: #"{"state_token":"statetoken_1","action":{"type":"verify","data":{"masked_destination":"use****@example.com"}}}"#)
        }

        do {
            _ = try await client.submitOTP("000000", stateToken: "statetoken_1")
            XCTFail("expected a thrown error")
        } catch let error as ESError {
            guard case .invalidResponse = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    // MARK: Steps 4 + 5 — authorize + token

    func testCompleteLoginRunsPKCEAuthorizeAndTokenExchange() async throws {
        mockDeviceReportOnly()
        _ = try await client.ensureDeviceRegistered()
        let authorize = Locked<URLRequest?>(nil)
        let token = Locked<URLRequest?>(nil)
        MockURLProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            if path.contains("authorize"), let url = request.url {
                authorize.set(request)
                let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "state" }?.value
                return (
                    HTTPURLResponse(
                        url: url,
                        statusCode: 302,
                        httpVersion: "HTTP/1.1",
                        headerFields: [
                            "Location": "nothing-account-app://oauth2/callback?code=AUTHCODE123&state=\(state ?? "")",
                        ]
                    )!,
                    Data()
                )
            }
            token.set(request)
            return MockURLProtocol.ok(
                request.url,
                json: #"{"access_token":"at_new","refresh_token":"rt_new","id_token":"it_new","device_secret":"ds_new","token_type":"Bearer","expires_in":2591999}"#
            )
        }

        let tokens = try await client.completeLogin(sessionID: "sess_1")
        XCTAssertEqual(tokens, TokenSet(accessToken: "at_new", idToken: "it_new", refreshToken: "rt_new", deviceSecret: "ds_new"))

        // authorize: full PKCE query, IdP session headers, no device signature (302 not followed).
        let authorizeRequest = try XCTUnwrap(authorize.get())
        var components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(authorizeRequest.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/api/v2/oauth2/authorize")
        let query = try XCTUnwrap(components.queryItems)
        func param(_ name: String) -> String {
            query.first { $0.name == name }?.value ?? ""
        }
        XCTAssertEqual(param("response_type"), "code")
        XCTAssertEqual(param("client_id"), "account-app-native")
        XCTAssertEqual(param("redirect_uri"), "nothing-account-app://oauth2/callback")
        XCTAssertEqual(param("scope"), "openid+profile+email+offline_access", "wire format uses +, like the captured client")
        XCTAssertEqual(param("code_challenge_method"), "S256")
        XCTAssertEqual(param("code_challenge").count, 43)
        XCTAssertEqual(param("state").count, 43)
        XCTAssertEqual(authorizeRequest.httpMethod, "GET")
        XCTAssertEqual(authorizeRequest.value(forHTTPHeaderField: "x-idp-session"), "sess_1")
        XCTAssertEqual(authorizeRequest.value(forHTTPHeaderField: "x-device-id"), Self.deviceID)
        XCTAssertNil(authorizeRequest.value(forHTTPHeaderField: "x-device-signature"))
        XCTAssertEqual(
            authorizeRequest.value(forHTTPHeaderField: "x-app-signature"),
            AuthSigning.appSignature(
                body: Data(),
                nonce: try XCTUnwrap(authorizeRequest.value(forHTTPHeaderField: "x-nonce")),
                path: "/api/v2/oauth2/authorize" + (components.percentEncodedQuery.map { "?" + $0 } ?? ""),
                timestampMilliseconds: Int64(authorizeRequest.value(forHTTPHeaderField: "x-timestamp") ?? "") ?? -1,
                apiKey: Self.signingKey
            )
        )

        // token: form fields, PKCE pair consistency, token set parsed.
        let tokenRequest = try XCTUnwrap(token.get())
        XCTAssertEqual(tokenRequest.url?.absoluteString, "https://account.nothing.tech/api/v2/oauth2/token")
        XCTAssertEqual(tokenRequest.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let form = try XCTUnwrap(String(data: tokenRequest.bodyStreamData ?? Data(), encoding: .utf8))
        let fields = form.split(separator: "&").reduce(into: [String: String]()) { result, pair in
            let kv = pair.split(separator: "=", maxSplits: 1)
            result[String(kv[0])] = (kv.count > 1 ? String(kv[1]) : "").removingPercentEncoding ?? ""
        }
        func field(_ name: String) -> String {
            fields[name] ?? ""
        }
        XCTAssertEqual(field("grant_type"), "authorization_code")
        XCTAssertEqual(field("client_id"), "account-app-native")
        XCTAssertEqual(field("code"), "AUTHCODE123")
        XCTAssertEqual(field("redirect_uri"), "nothing-account-app://oauth2/callback")
        XCTAssertEqual(field("code_verifier").count, 43)
        XCTAssertEqual(
            field("code_challenge_method"), "", "no challenge field on the token call"
        )
        let verifier = field("code_verifier")
        XCTAssertEqual(
            AuthSigning.base64URLEncodeNoPad(Data(CryptoKit.SHA256.hash(data: Data(verifier.utf8)))),
            param("code_challenge"),
            "code_verifier must hash to the authorize call's code_challenge"
        )
        let deviceInfo = try XCTUnwrap(Data(base64Encoded: field("x_device_info")))
        let deviceInfoJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: deviceInfo) as? [String: Any])
        XCTAssertEqual(deviceInfoJSON["device_model"] as? String, "A059")
        try verifyDeviceSignature(of: tokenRequest, body: tokenRequest.bodyStreamData ?? Data())
    }

    func testCompleteLoginRejectsStateMismatch() async throws {
        mockDeviceReportOnly()
        _ = try await client.ensureDeviceRegistered()
        MockURLProtocol.setHandler { request in
            (
                HTTPURLResponse(
                    url: request.url ?? URL(string: "https://mock.test")!,
                    statusCode: 302,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Location": "nothing-account-app://oauth2/callback?code=AUTHCODE123&state=tampered",
                    ]
                )!,
                Data()
            )
        }

        do {
            _ = try await client.completeLogin(sessionID: "sess_1")
            XCTFail("expected a thrown error")
        } catch let error as ESError {
            guard case .invalidResponse = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    // MARK: Helpers

    /// Verifies the captured request's `x-device-signature` against the identity's
    /// own public key (the one device/report uploaded in this test's Keychain).
    private func verifyDeviceSignature(of request: URLRequest, body: Data) throws {
        let identity = try DeviceIdentity.loadOrCreate(keychain: keychain)
        let spki = try XCTUnwrap(Data(base64Encoded: try identity.publicKeySPKIBase64))
        let publicKey = try P256.Signing.PublicKey(x963Representation: spki.suffix(65))
        let signature = try P256.Signing.ECDSASignature(
            rawRepresentation: Data(
                base64Encoded: try XCTUnwrap(request.value(forHTTPHeaderField: "x-device-signature"))
                    .replacingOccurrences(of: "-", with: "+")
                    .replacingOccurrences(of: "_", with: "/")
            )!
        )
        let timestamp = try XCTUnwrap(request.value(forHTTPHeaderField: "x-timestamp"))
        let payload = AuthSigning.deviceSignaturePayload(timestampMilliseconds: Int64(timestamp) ?? -1, body: body)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: Data(payload.utf8)), "device signature must verify")
    }
}
