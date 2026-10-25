import Foundation
import XCTest

@testable import BetterEssentialSpaceCore

/// ESClient against mocked endpoints — header construction for both hosts and the
/// auto-refresh-on-401 retry. No live network.
final class ESClientTests: XCTestCase {
    private var keychain: KeychainStore!
    private var session: AccountSession!
    private var client: ESClient!

    static let accountUUID = "00000000-1111-2222-3333-444444444444"

    override func setUp() {
        super.setUp()
        keychain = TestSupport.testKeychain()
        session = AccountSession(
            keychain: keychain,
            urlSession: MockURLProtocol.makeSession(),
            signingKeyProvider: { "test-signing-key-456" }
        )
        client = ESClient(
            accountSession: session,
            urlSession: MockURLProtocol.makeSession(),
            legacyKeyProvider: { "dummy-legacy-key" }
        )
    }

    override func tearDown() {
        MockURLProtocol.reset()
        keychain?.delete(account: "session")
        super.tearDown()
    }

    private func signIn() throws {
        try session.storeTokens(
            TokenSet(
                accessToken: TestJWT.token(uuid: Self.accountUUID, expiresAt: Date(timeIntervalSinceNow: 3600)),
                idToken: nil,
                refreshToken: "rt_old",
                deviceSecret: nil
            )
        )
    }

    // MARK: Preferences host

    func testFetchPreferencesSendsBearerAndAccountIDHeaders() async throws {
        try signIn()
        let capturedRequest = Locked<URLRequest?>(nil)
        MockURLProtocol.setHandler { request in
            capturedRequest.set(request)
            return MockURLProtocol.ok(
                request.url,
                json: #"{"userId":"user-7","useMemory":true,"hasAgreedToTerms":true,"updatedAt":"2026-10-01T00:00:00Z"}"#
            )
        }

        let preferences = try await client.fetchPreferences()
        XCTAssertEqual(preferences, Preferences(userId: "user-7", useMemory: true, hasAgreedToTerms: true, updatedAt: "2026-10-01T00:00:00Z"))

        let request = try XCTUnwrap(capturedRequest.get())
        XCTAssertEqual(request.url?.absoluteString, "https://prod.essentialsearch.essential-nt.com/preferences")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(session.storedTokens()?.accessToken ?? "")")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Nothing-Account-ID"), Self.accountUUID)
    }

    // MARK: Records host

    func testFetchCardPageSendsLegacyAuthHeadersAndDecodesFixture() async throws {
        try signIn()
        let fixture = try Data(
            contentsOf: XCTUnwrap(Bundle.module.url(forResource: "CardListRedacted", withExtension: "json", subdirectory: "Fixtures"))
        )
        let capturedRequest = Locked<URLRequest?>(nil)
        MockURLProtocol.setHandler { request in
            capturedRequest.set(request)
            return MockURLProtocol.ok(request.url, json: String(decoding: fixture, as: UTF8.self))
        }

        let page = try await client.fetchCardPage(pageNo: 2, pageSize: 5)
        XCTAssertEqual(page.pageData.count, 3)

        let request = try XCTUnwrap(capturedRequest.get())
        XCTAssertEqual(request.url?.absoluteString, "https://essential-space.nothingtech.link/essentialSpace/storage/card/v1/list")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=UTF-8")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(session.storedTokens()?.accessToken ?? "")")

        // auth header matches the formula, recomputed from the request's own timestamp.
        let timestamp = try XCTUnwrap(request.value(forHTTPHeaderField: "timestamp"))
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "auth"),
            AuthSigning.legacyAuthHeader(apiKey: "dummy-legacy-key", timestampMilliseconds: Int64(timestamp) ?? -1)
        )

        let body = try XCTUnwrap(String(data: request.bodyStreamData ?? request.httpBody ?? Data(), encoding: .utf8))
        let bodyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        XCTAssertEqual(bodyObject as? [String: Int], ["page_no": 2, "page_size": 5, "sinceTime": 0])
    }

    func testFetchCollectionsPostsSinceTimeZero() async throws {
        try signIn()
        let capturedRequest = Locked<URLRequest?>(nil)
        MockURLProtocol.setHandler { request in
            capturedRequest.set(request)
            return MockURLProtocol.ok(
                request.url,
                json: #"{"code":"00000","msg":"success","data":[{"collectionId":"70000000-0000-4000-8000-00000000000a","collectionName":"Synthetic Collection","count":2,"clientUpdateTime":2,"clientCreateTime":1}]}"#
            )
        }

        let collections = try await client.fetchCollections()
        XCTAssertEqual(collections, [
            CollectionSummary(
                collectionId: "70000000-0000-4000-8000-00000000000a",
                name: "Synthetic Collection",
                count: 2,
                clientCreateTime: 1,
                clientUpdateTime: 2
            )
        ])

        let request = try XCTUnwrap(capturedRequest.get())
        XCTAssertEqual(request.url?.absoluteString, "https://essential-space.nothingtech.link/essentialSpace/storage/collection/v1/list")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "auth"))
        XCTAssertNotNil(request.value(forHTTPHeaderField: "timestamp"))
        let body = try XCTUnwrap(String(data: request.bodyStreamData ?? request.httpBody ?? Data(), encoding: .utf8))
        XCTAssertEqual(body, #"{"sinceTime":0}"#)
    }

    func testFetchCardPageWithoutLegacyKeyFailsWithTypedError() async throws {
        try signIn()
        let keylessClient = ESClient(
            accountSession: session,
            urlSession: MockURLProtocol.makeSession(),
            legacyKeyProvider: { throw ESError.missingLegacyAPIKey("/Users/x/.better-essential-space/legacy-api-key") }
        )
        MockURLProtocol.setHandler { _ in
            XCTFail("no request may leave without the legacy key")
            return MockURLProtocol.error(nil, status: 500, json: "{}")
        }
        do {
            _ = try await keylessClient.fetchCardPage()
            XCTFail("expected missingLegacyAPIKey")
        } catch {
            guard case ESError.missingLegacyAPIKey = error else {
                return XCTFail("expected missingLegacyAPIKey, got \(error)")
            }
        }
    }

    func testEnvelopeErrorCodeSurfacesAsHTTPError() async throws {
        try signIn()
        MockURLProtocol.setHandler { request in
            MockURLProtocol.ok(request.url, json: #"{"code":"200001","msg":"Auth failed. Without auth","data":null}"#)
        }
        do {
            _ = try await client.fetchCardPage()
            XCTFail("expected httpStatus")
        } catch {
            // The envelope's code arrives with HTTP 200 — it must still surface as an error.
            XCTAssertEqual(
                error as? ESError,
                .httpStatus(200, code: "200001", message: "Auth failed. Without auth")
            )
        }
    }

    // MARK: Auto-refresh on 401

    func testStill401AfterRefreshIsHostUnauthorizedNotSessionExpiry() async throws {
        try signIn()
        MockURLProtocol.setHandler { request in
            let url = request.url?.absoluteString ?? ""
            if url == AccountSession.accountTokenURL.absoluteString {
                return MockURLProtocol.ok(
                    request.url,
                    json: #"{"access_token":"\#(TestJWT.token(uuid: Self.accountUUID, expiresAt: Date(timeIntervalSinceNow: 3600)))","refresh_token":"rt_new"}"#
                )
            }
            // Records host keeps rejecting even the fresh token (e.g. a wrong legacy key).
            return MockURLProtocol.error(request.url, status: 401, json: #"{"code":"200001","msg":"Auth failed. Without auth"}"#)
        }

        do {
            _ = try await client.fetchCardPage()
            XCTFail("expected hostUnauthorized")
        } catch {
            guard case ESError.hostUnauthorized = error else {
                return XCTFail("expected hostUnauthorized, got \(error)")
            }
        }
        // The refresh succeeded, so the session must survive for the next attempt.
        XCTAssertNotNil(session.storedTokens())
    }

    func testCardList401RefreshesAccessTokenAndRetries() async throws {
        try signIn()
        let fixture = try Data(
            contentsOf: XCTUnwrap(Bundle.module.url(forResource: "CardListRedacted", withExtension: "json", subdirectory: "Fixtures"))
        )
        let count = Locked(0)
        let secondRequest = Locked<URLRequest?>(nil)
        MockURLProtocol.setHandler { request in
            switch request.url?.host {
            case "account.nothing.tech":
                return MockURLProtocol.ok(
                    request.url,
                    json: #"{"access_token":"\#(TestJWT.token(uuid: Self.accountUUID, expiresAt: Date(timeIntervalSinceNow: 3600)))","refresh_token":"rt_rotated"}"#
                )
            default:
                let n = count.with { counter in
                    counter += 1
                    return counter
                }
                if n == 1 {
                    return MockURLProtocol.error(request.url, status: 401, json: #"{"code":"200001","msg":"Auth failed"}"#)
                }
                secondRequest.set(request)
                return MockURLProtocol.ok(request.url, json: String(decoding: fixture, as: UTF8.self))
            }
        }

        let page = try await client.fetchCardPage()
        XCTAssertEqual(count.get(), 2)
        XCTAssertEqual(page.pageData.count, 3)
        XCTAssertEqual(secondRequest.get()?.value(forHTTPHeaderField: "Authorization"), "Bearer \(session.storedTokens()?.accessToken ?? "")")
        XCTAssertEqual(session.storedTokens()?.refreshToken, "rt_rotated")
    }

    func testCategoriesAndCollectionsDecode() async throws {
        try signIn()
        MockURLProtocol.setHandler { request in
            if request.url?.path.contains("category") == true {
                return MockURLProtocol.ok(request.url, json: #"{"code":"00000","msg":"success","data":[{"categoryId":"recording","count":12}]}"#)
            }
            return MockURLProtocol.ok(request.url, json: #"{"code":"00000","msg":"success","data":[]}"#)
        }
        let categories = try await client.fetchCategories()
        XCTAssertEqual(categories, [Category(categoryId: "recording", count: 12)])
        let collections = try await client.fetchCollections()
        XCTAssertEqual(collections, [])
    }

    // MARK: Audio download (issue 09)

    private static let audioFile = CardFile(
        region: "asia-south1",
        gcsKey: "audioRequest/db41be7278059497304a7a408a6c303d/10000000-0000-4000-8000-000000000001/20000000-0000-4000-8000-000000000001.aac"
    )

    private func cardFilesFixtureJSON() throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "CardFilesRedacted", withExtension: "json", subdirectory: "Fixtures")
        )
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    private func signURLFromFixture() throws -> URL {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try cardFilesFixtureJSON().utf8)) as? [String: Any]
        )
        let entry = try XCTUnwrap((object["data"] as? [[String: Any]])?.first)
        return try XCTUnwrap(URL(string: try XCTUnwrap(entry["signUrl"] as? String)))
    }

    func testDownloadAudioSignsThenFetchesWithoutAuthHeaders() async throws {
        try signIn()
        let fixture = try cardFilesFixtureJSON()
        let expectedSignURL = try signURLFromFixture()
        let signRequest = Locked<URLRequest?>(nil)
        let gcsRequest = Locked<URLRequest?>(nil)
        let audioBytes = Data("synthetic-mp4-bytes".utf8)
        MockURLProtocol.setHandler { request in
            if request.url?.path.contains("storage/card/v1/files") == true {
                signRequest.set(request)
                return MockURLProtocol.ok(request.url, json: fixture)
            }
            gcsRequest.set(request)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "video/mp4"])!,
                audioBytes
            )
        }

        let data = try await client.downloadAudio(for: Self.audioFile)
        XCTAssertEqual(data, audioBytes)

        // The sign POST carries the three legacy auth headers and the exact body.
        let post = try XCTUnwrap(signRequest.get())
        XCTAssertEqual(post.url?.absoluteString, "https://essential-space.nothingtech.link/essentialSpace/storage/card/v1/files")
        XCTAssertEqual(post.httpMethod, "POST")
        XCTAssertEqual(post.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=UTF-8")
        XCTAssertEqual(post.value(forHTTPHeaderField: "Authorization"), "Bearer \(session.storedTokens()?.accessToken ?? "")")
        let timestamp = try XCTUnwrap(post.value(forHTTPHeaderField: "timestamp"))
        XCTAssertEqual(
            post.value(forHTTPHeaderField: "auth"),
            AuthSigning.legacyAuthHeader(apiKey: "dummy-legacy-key", timestampMilliseconds: Int64(timestamp) ?? -1)
        )
        let body = try XCTUnwrap(String(data: post.bodyStreamData ?? Data(), encoding: .utf8))
        let bodyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        XCTAssertEqual(
            bodyObject as? [String: [[String: String]]],
            ["files": [["region": "asia-south1", "gcsKey": Self.audioFile.gcsKey!]]]
        )

        // The GCS GET carries NO Authorization/timestamp/auth — the V4 signature is in the URL.
        let get = try XCTUnwrap(gcsRequest.get())
        XCTAssertEqual(get.url, expectedSignURL)
        XCTAssertEqual(get.httpMethod, "GET")
        XCTAssertNil(get.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(get.value(forHTTPHeaderField: "timestamp"))
        XCTAssertNil(get.value(forHTTPHeaderField: "auth"))
    }

    func testDownloadAudioReSignsOnceOnGCS403() async throws {
        try signIn()
        let fixture = try cardFilesFixtureJSON()
        let signCount = Locked(0)
        let gcsCount = Locked(0)
        MockURLProtocol.setHandler { request in
            if request.url?.path.contains("storage/card/v1/files") == true {
                signCount.with { $0 += 1 }
                return MockURLProtocol.ok(request.url, json: fixture)
            }
            let n = gcsCount.with { $0 += 1; return $0 }
            if n == 1 {
                return MockURLProtocol.error(request.url, status: 403, json: #"<?xml version="1.0"?><Error><Code>AccessDenied</Code></Error>"#)
            }
            return MockURLProtocol.ok(request.url, json: String(decoding: Data("after-resign".utf8), as: UTF8.self))
        }

        let data = try await client.downloadAudio(for: Self.audioFile)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "after-resign")
        XCTAssertEqual(signCount.get(), 2, "an expired signature triggers exactly one re-sign")
        XCTAssertEqual(gcsCount.get(), 2)
    }

    func testDownloadAudioGCS404SurfacesAsHTTPStatus() async throws {
        try signIn()
        let fixture = try cardFilesFixtureJSON()
        MockURLProtocol.setHandler { request in
            if request.url?.path.contains("storage/card/v1/files") == true {
                return MockURLProtocol.ok(request.url, json: fixture)
            }
            return MockURLProtocol.error(request.url, status: 404, json: #"<?xml version="1.0"?><Error><Code>NoSuchKey</Code></Error>"#)
        }

        do {
            _ = try await client.downloadAudio(for: Self.audioFile)
            XCTFail("expected httpStatus 404")
        } catch {
            guard case ESError.httpStatus(404, _, _) = error else {
                return XCTFail("expected httpStatus(404), got \(error)")
            }
        }
    }

    func testDownloadAudioSignEndpointIsStrictOnEnvelopeCode() async throws {
        try signIn()
        MockURLProtocol.setHandler { request in
            if request.url?.path.contains("storage/card/v1/files") == true {
                return MockURLProtocol.ok(request.url, json: #"{"code":"200001","msg":"Auth failed","data":null}"#)
            }
            return MockURLProtocol.ok(request.url, json: "")
        }
        do {
            _ = try await client.downloadAudio(for: Self.audioFile)
            XCTFail("expected httpStatus")
        } catch {
            XCTAssertEqual(error as? ESError, .httpStatus(200, code: "200001", message: "Auth failed"))
        }
    }
}
