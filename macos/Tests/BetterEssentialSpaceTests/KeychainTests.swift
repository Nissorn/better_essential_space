import Foundation
import XCTest

@testable import BetterEssentialSpaceCore

final class KeychainTests: XCTestCase {
    /// Token import -> Keychain -> load round-trip, on an isolated test service.
    func testTokenRoundTripThroughKeychain() throws {
        let keychain = TestSupport.testKeychain()
        let session = AccountSession(
            keychain: keychain,
            urlSession: MockURLProtocol.makeSession(),
            signingKeyProvider: { "dummy-signing-key" }
        )
        XCTAssertFalse(session.isSignedIn)
        XCTAssertNil(session.storedTokens())

        let tokens = TokenSet(accessToken: "at", idToken: nil, refreshToken: "rt", deviceSecret: nil)
        try session.storeTokens(tokens)

        XCTAssertTrue(session.isSignedIn)
        XCTAssertEqual(session.storedTokens(), tokens)

        session.clearTokens()
        XCTAssertFalse(session.isSignedIn)
        XCTAssertNil(session.storedTokens())
    }

    func testStoreOverwritesPreviousTokens() throws {
        let keychain = TestSupport.testKeychain()
        try keychain.save(Data("first".utf8), account: "session")
        try keychain.save(Data("second".utf8), account: "session")
        XCTAssertEqual(keychain.load(account: "session"), Data("second".utf8))
        keychain.delete(account: "session")
        XCTAssertNil(keychain.load(account: "session"))
    }
}
