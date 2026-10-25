import CryptoKit
import Foundation
import XCTest

@testable import BetterEssentialSpaceCore

/// Signing primitives against expected values computed independently with Python
/// (hashlib/hmac/base64/urllib) — never with the Swift implementations under test.
final class AuthHeaderSigningTests: XCTestCase {
    // hashlib.md5(b"test-legacy-key-1231760000000000").hexdigest()
    func testLegacyAuthHeaderVectorOne() {
        XCTAssertEqual(
            AuthSigning.legacyAuthHeader(apiKey: "test-legacy-key-123", timestampMilliseconds: 1_760_000_000_000),
            "264dac7774205cba00a976d3f0073327"
        )
    }

    // hashlib.md5(b"another-dummy-key1699999999999").hexdigest()
    func testLegacyAuthHeaderVectorTwo() {
        XCTAssertEqual(
            AuthSigning.legacyAuthHeader(apiKey: "another-dummy-key", timestampMilliseconds: 1_699_999_999_999),
            "2439ae13946748c64e8b869581000015"
        )
    }

    // hashlib.sha256(b"abc").hexdigest() / hashlib.sha256(b"").hexdigest()
    func testSHA256HexVectors() {
        XCTAssertEqual(
            AuthSigning.sha256Hex(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            AuthSigning.sha256Hex(Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    // urllib.parse.quote(s, safe="") keeps unreserved chars literal, encodes the rest.
    func testPercentEncodingMatchesPythonQuoteSafeEmpty() {
        XCTAssertEqual(
            AuthSigning.percentEncodeAll("/api/v2/oauth2/token"),
            "%2Fapi%2Fv2%2Foauth2%2Ftoken"
        )
        XCTAssertEqual(AuthSigning.percentEncodeAll("a b+c~d"), "a%20b%2Bc~d")
        XCTAssertEqual(AuthSigning.percentEncodeAll("AZaz09-._~"), "AZaz09-._~")
    }

    // Base64url without padding.
    func testBase64URLNoPad() {
        XCTAssertEqual(AuthSigning.base64URLEncodeNoPad(Data([0xfb, 0xff, 0xfe])), "-__-" )
        XCTAssertEqual(AuthSigning.base64URLEncodeNoPad(Data([0x00])), "AA")
    }

    /// Full x-app-signature vector, all inputs fixed:
    /// key "test-signing-key-456", body "grant_type=refresh_token&client_id=account-app-native&refresh_token=rt_test_123",
    /// nonce 11111111-2222-3333-4444-555555555555, path /api/v2/oauth2/token, ts 1760000000001.
    /// Python reference:
    /// payload = "body=814a4397e4276e3e91d728b9975977b097ef893f63f36bced9170f7918ac60c9
    ///            &nonce=11111111-2222-3333-4444-555555555555
    ///            &path=%2Fapi%2Fv2%2Foauth2%2Ftoken
    ///            &timestamp=1760000000001
    ///            &apiKey=test-signing-key-456"
    /// signature = base64.urlsafe_b64encode(hmac_sha256(payload, key)).rstrip("=")
    func testAppSignatureVector() {
        let body = "grant_type=refresh_token&client_id=account-app-native&refresh_token=rt_test_123"
        XCTAssertEqual(
            AuthSigning.appSignature(
                body: Data(body.utf8),
                nonce: "11111111-2222-3333-4444-555555555555",
                path: "/api/v2/oauth2/token",
                timestampMilliseconds: 1_760_000_000_001,
                apiKey: "test-signing-key-456"
            ),
            "X-a6DTvsjVNXcyNeNm0OuBYQQHHXNgFEBzMOakBEyEk"
        )
    }

    /// The signature is sensitive to every payload component.
    func testAppSignatureChangesWithInputs() {
        let base = AuthSigning.appSignature(
            body: Data("body".utf8),
            nonce: "n1",
            path: "/p",
            timestampMilliseconds: 1,
            apiKey: "k"
        )
        XCTAssertNotEqual(base, AuthSigning.appSignature(body: Data("body2".utf8), nonce: "n1", path: "/p", timestampMilliseconds: 1, apiKey: "k"))
        XCTAssertNotEqual(base, AuthSigning.appSignature(body: Data("body".utf8), nonce: "n2", path: "/p", timestampMilliseconds: 1, apiKey: "k"))
        XCTAssertNotEqual(base, AuthSigning.appSignature(body: Data("body".utf8), nonce: "n1", path: "/p2", timestampMilliseconds: 1, apiKey: "k"))
        XCTAssertNotEqual(base, AuthSigning.appSignature(body: Data("body".utf8), nonce: "n1", path: "/p", timestampMilliseconds: 2, apiKey: "k"))
        XCTAssertNotEqual(base, AuthSigning.appSignature(body: Data("body".utf8), nonce: "n1", path: "/p", timestampMilliseconds: 1, apiKey: "k2"))
    }
}
