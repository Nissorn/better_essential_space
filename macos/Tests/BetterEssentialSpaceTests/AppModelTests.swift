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
    private var cacheURL: URL!

    nonisolated static let accountUUID = "00000000-1111-2222-3333-444444444444"
    nonisolated static let deviceID = "aaaa0000-0000-4000-8000-000000000000"

    /// One card cross-referenced to the route's Collection (70000000-…-00a);
    /// `count` on the server side says 0, so the local cross-ref must win.
    nonisolated static let collectedCardPageJSON = """
    {"code":"00000","msg":"success","data":{"page_no":1,"page_size":20,"hasNextPage":false,"page_data":[{"cardId":"10000000-0000-4000-8000-000000000009","client_request_response":"{\\"cards\\":{\\"card_id\\":\\"10000000-0000-4000-8000-000000000009\\",\\"title\\":\\"Collected Record\\",\\"summary\\":null,\\"type\\":\\"RECORDING\\",\\"create_time\\":1700000000000,\\"update_time\\":1700000000001},\\"card_resources\\":[],\\"card_collection_cross_ref\\":[{\\"collection_id\\":\\"70000000-0000-4000-8000-00000000000a\\"}]}","clientCreateTime":1700000000000,"clientUpdateTime":1700000000001}]}}
    """

    override func setUp() {
        super.setUp()
        keychain = TestSupport.testKeychain()
        // Tests never touch the user's real Application Support cache.
        cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-cache-\(UUID().uuidString).json")
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
            ),
            cacheURL: cacheURL
        )
    }

    override func tearDown() {
        MockURLProtocol.reset()
        keychain?.delete(account: "session")
        keychain?.delete(account: DeviceIdentity.KeychainAccount.key)
        keychain?.delete(account: DeviceIdentity.KeychainAccount.registration)
        try? FileManager.default.removeItem(at: cacheURL)
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
        if url.contains("collection/v1/list") {
            return MockURLProtocol.ok(
                request.url,
                json: #"{"code":"00000","msg":"success","data":[{"collectionId":"70000000-0000-4000-8000-00000000000a","collectionName":"Conference Collection","count":0,"clientUpdateTime":1,"clientCreateTime":2}]}"#
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

    func testCollectionsLoadAndLocalCountBeatsStaleServerCount() async throws {
        MockURLProtocol.setHandler { request in
            if request.url?.absoluteString.contains("card/v1/list") == true {
                return MockURLProtocol.ok(request.url, json: Self.collectedCardPageJSON)
            }
            return Self.route(request, otpAction: "finished", tokenStatus: 200)
        }

        await model.logIn(email: "user@example.com", password: "hunter2")
        XCTAssertEqual(model.phase, .ready)

        for _ in 0..<100 where model.collections.isEmpty || model.records.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(model.collections.map(\.name), ["Conference Collection"])
        XCTAssertEqual(model.records.count, 1)
        // The server reported count:0; the loaded card's cross-ref is the truth.
        XCTAssertEqual(model.recordCount(in: try XCTUnwrap(model.collections.first)), 1)
        XCTAssertEqual(model.filteredRecords(collectionID: "70000000-0000-4000-8000-00000000000a").count, 1)
        XCTAssertEqual(model.filteredRecords(collectionID: nil).count, 1)
        XCTAssertEqual(model.filteredRecords(collectionID: "unknown-collection").count, 0)
        XCTAssertEqual(model.collectionNames(for: try XCTUnwrap(model.records.first)), ["Conference Collection"])
    }

    // MARK: Offline cache + search (issue 09)

    nonisolated private static func fixtureRecord() throws -> Record {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "CardListRedacted", withExtension: "json", subdirectory: "Fixtures")
        )
        let envelope = try JSONDecoder().decode(LegacyEnvelope<CardListPage>.self, from: Data(contentsOf: url))
        return try XCTUnwrap(try envelope.data?.pageData.map { try Record(card: $0) }.first)
    }

    func testBootstrapShowsCachedSnapshotInstantly() throws {
        try RecordCache.save(
            CachedSnapshot(
                accountUUID: Self.accountUUID,
                savedAt: Date(timeIntervalSince1970: 1_700_000_000),
                records: [try Self.fixtureRecord()],
                collections: []
            ),
            to: cacheURL
        )
        try model.accountSession.storeTokens(
            TokenSet(
                accessToken: TestJWT.token(uuid: Self.accountUUID, expiresAt: Date(timeIntervalSinceNow: 3600)),
                idToken: nil,
                refreshToken: "rt",
                deviceSecret: nil
            )
        )

        model.bootstrap()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.records.count, 1, "the snapshot shows before any network round-trip")
    }

    func testSnapshotOfAnotherAccountIsIgnored() throws {
        try RecordCache.save(
            CachedSnapshot(
                accountUUID: "someone-else",
                savedAt: Date(timeIntervalSince1970: 1_700_000_000),
                records: [try Self.fixtureRecord()],
                collections: []
            ),
            to: cacheURL
        )
        try model.accountSession.storeTokens(
            TokenSet(
                accessToken: TestJWT.token(uuid: Self.accountUUID, expiresAt: Date(timeIntervalSinceNow: 3600)),
                idToken: nil,
                refreshToken: "rt",
                deviceSecret: nil
            )
        )

        model.bootstrap()
        XCTAssertTrue(model.records.isEmpty, "a snapshot must never leak across accounts")
    }

    func testLoadAllPersistsSnapshotAndSignOutWipesIt() async throws {
        MockURLProtocol.setHandler { request in
            Self.route(request, otpAction: "finished", tokenStatus: 200)
        }
        await model.logIn(email: "user@example.com", password: "hunter2")
        for _ in 0..<100 where model.collections.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: cacheURL.path),
            "loadAll persists the snapshot"
        )

        model.signOut()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cacheURL.path),
            "sign-out wipes the snapshot from disk"
        )
        XCTAssertTrue(model.records.isEmpty)
    }

    func testVisibleRecordsCombinesCollectionFilterAndSearch() async throws {
        MockURLProtocol.setHandler { request in
            if request.url?.absoluteString.contains("card/v1/list") == true {
                return MockURLProtocol.ok(request.url, json: Self.collectedCardPageJSON)
            }
            return Self.route(request, otpAction: "finished", tokenStatus: 200)
        }
        await model.logIn(email: "user@example.com", password: "hunter2")
        for _ in 0..<100 where model.records.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let collection = "70000000-0000-4000-8000-00000000000a"
        XCTAssertEqual(model.visibleRecords(collectionID: collection, searchQuery: "collected").count, 1)
        XCTAssertEqual(model.visibleRecords(collectionID: collection, searchQuery: "COLLECTED").count, 1, "case-insensitive")
        XCTAssertEqual(model.visibleRecords(collectionID: collection, searchQuery: "nothing-matches").count, 0)
        XCTAssertEqual(model.visibleRecords(collectionID: "other-collection", searchQuery: "collected").count, 0)
        XCTAssertEqual(model.visibleRecords(collectionID: nil, searchQuery: "   ").count, 1, "whitespace-only query = no filter")
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
