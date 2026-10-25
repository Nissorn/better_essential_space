import Foundation
import XCTest

@testable import BetterEssentialSpaceCore

final class JWTTests: XCTestCase {
    func testExtractsUUIDAndExpiry() {
        let expiry = Date(timeIntervalSince1970: 1_900_000_000)
        let token = TestJWT.token(uuid: "00000000-1111-2222-3333-444444444444", expiresAt: expiry, subject: "424242")
        let claims = JWT.claims(fromToken: token)

        XCTAssertEqual(claims?.uuid, "00000000-1111-2222-3333-444444444444")
        XCTAssertEqual(claims?.subject, "424242")
        XCTAssertEqual(claims?.expiresAt, expiry)
        XCTAssertEqual(claims?.expiresSoon, false)
    }

    func testBase64URLPaddingFix() {
        // `{"a":1}` is 7 bytes -> 10 base64url chars -> needs 2 '=' of padding.
        XCTAssertEqual(JWT.base64URLDecode("eyJhIjoxfQ"), Data("{\"a\":1}".utf8))
        // 1-byte payload -> 2 chars -> needs 2 '=' of padding.
        XCTAssertEqual(JWT.base64URLDecode("eA"), Data([0x78]))
        // A 16-byte payload -> 22 chars -> needs 2 '='.
        XCTAssertEqual(JWT.base64URLDecode("AAAAAAAAAAAAAAAAAAAAAA"), Data(repeating: 0, count: 16))
    }

    func testExpiredTokenIsFlagged() {
        let token = TestJWT.token(uuid: "u", expiresAt: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(JWT.claims(fromToken: token)?.expiresSoon, true)
    }

    func testStringExponentClaimIsTolerated() {
        // exp as a JSON string instead of a number.
        let payload = #"{"uuid":"u1","exp":"1900000000"}"#
        let token = "h.\(AuthSigning.base64URLEncodeNoPad(Data(payload.utf8))).s"
        XCTAssertEqual(JWT.claims(fromToken: token)?.expiresAt, Date(timeIntervalSince1970: 1_900_000_000))
    }

    func testMalformedTokensReturnNil() {
        // "" / "abc": wrong segment count; "a.b": same; "x.y.z": payload is not JSON;
        // "aaa.%%%!!!.bbb": payload is not base64url.
        for token in ["", "abc", "a.b", "x.y.z", "aaa.%%%!!!.bbb"] {
            XCTAssertNil(JWT.claims(fromToken: token), "expected nil for \(token)")
        }
    }
}

final class TokenFileTests: XCTestCase {
    func testParsesFullTokenFile() throws {
        let json = """
        {"access_token":"at_1","id_token":"id_1","refresh_token":"rt_1","device_secret":"ds_1"}
        """
        let tokens = try TokenFile.parse(Data(json.utf8))
        XCTAssertEqual(tokens, TokenSet(accessToken: "at_1", idToken: "id_1", refreshToken: "rt_1", deviceSecret: "ds_1"))
    }

    func testParsesMinimalTokenFileAndIgnoresExtraKeys() throws {
        let json = """
        {"access_token":"at_only","expires_in":2592000,"token_type":"Bearer","scope":"openid"}
        """
        let tokens = try TokenFile.parse(Data(json.utf8))
        XCTAssertEqual(tokens.accessToken, "at_only")
        XCTAssertNil(tokens.refreshToken)
        XCTAssertNil(tokens.idToken)
        XCTAssertNil(tokens.deviceSecret)
    }

    func testEmptyOptionalFieldsBecomeNil() throws {
        let json = """
        {"access_token":"at","refresh_token":""}
        """
        let tokens = try TokenFile.parse(Data(json.utf8))
        XCTAssertNil(tokens.refreshToken)
    }

    func testMissingAccessTokenThrows() {
        XCTAssertThrowsError(try TokenFile.parse(Data(#"{"refresh_token":"rt"}"#.utf8))) { error in
            XCTAssertEqual(error as? ESError, .invalidTokenFile("access_token is missing or empty"))
        }
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try TokenFile.parse(Data("not json".utf8)))
    }
}

final class RuntimeSecretsTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("better-es-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testMissingLegacyAPIKeyThrowsTypedError() {
        XCTAssertThrowsError(try RuntimeSecrets.legacyAPIKey(directory: temporaryDirectorySafe())) { error in
            guard case let ESError.missingLegacyAPIKey(path) = error else {
                return XCTFail("expected missingLegacyAPIKey, got \(error)")
            }
            XCTAssertTrue(path.hasSuffix("legacy-api-key"), path)
        }
    }

    func testMissingAccountSigningKeyThrowsTypedError() {
        XCTAssertThrowsError(try RuntimeSecrets.accountSigningKey(directory: temporaryDirectorySafe())) { error in
            guard case let ESError.missingAccountSigningKey(path) = error else {
                return XCTFail("expected missingAccountSigningKey, got \(error)")
            }
            XCTAssertTrue(path.hasSuffix("account-signing-key"), path)
        }
    }

    func testLoadsKeyTrimmed() throws {
        let directory = try temporaryDirectory()
        try "  dummy-key-value-42 \n".data(using: .utf8)!.write(
            to: directory.appendingPathComponent(RuntimeSecrets.legacyAPIKeyFilename)
        )
        XCTAssertEqual(try RuntimeSecrets.legacyAPIKey(directory: directory), "dummy-key-value-42")
    }

    func testEmptyKeyFileThrows() throws {
        let directory = try temporaryDirectory()
        try Data("\n".utf8).write(to: directory.appendingPathComponent(RuntimeSecrets.accountSigningKeyFilename))
        XCTAssertThrowsError(try RuntimeSecrets.accountSigningKey(directory: directory))
    }

    /// Not part of RuntimeSecrets, but the same trait: typed errors carry readable messages.
    func testErrorMessagesNameTheFile() {
        let message = ESError.missingLegacyAPIKey("/Users/x/.better-essential-space/legacy-api-key").errorDescription
        XCTAssertTrue(message?.contains("legacy-api-key") == true, message ?? "")
    }

    private func temporaryDirectorySafe() -> URL {
        (try? temporaryDirectory()) ?? FileManager.default.temporaryDirectory
    }
}
