import Foundation
import XCTest

@testable import BetterEssentialSpaceCore

/// URLProtocol mock — the only network used by tests. No request ever leaves the process.
final class MockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    static func setHandler(_ handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        handler = nil
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return configuration
    }

    static func makeSession() -> URLSession {
        URLSession(configuration: makeConfiguration())
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let currentHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
        MockURLProtocol.lock.lock()
        currentHandler = MockURLProtocol.handler
        MockURLProtocol.lock.unlock()

        guard let currentHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try currentHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension MockURLProtocol {
    static func ok(_ url: URL?, json: String) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(url: url ?? URL(string: "https://mock.test")!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!,
            Data(json.utf8)
        )
    }

    static func error(_ url: URL?, status: Int, json: String) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(url: url ?? URL(string: "https://mock.test")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!,
            Data(json.utf8)
        )
    }
}

/// Mutable state that tests capture inside `@Sendable` mock handlers.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    func with<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

extension URLRequest {
    /// URLProtocol exposes the body via a stream, not `httpBody`.
    var bodyStreamData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Test JWT builder — signs nothing, just shapes a three-segment token with the wanted claims.
enum TestJWT {
    static func token(uuid: String? = nil, expiresAt: Date? = nil, subject: String? = nil) -> String {
        var claims: [String: Any] = [:]
        if let uuid { claims["uuid"] = uuid }
        if let expiresAt { claims["exp"] = Int(expiresAt.timeIntervalSince1970) }
        if let subject { claims["sub"] = subject }

        let headerData = (try? JSONSerialization.data(withJSONObject: ["alg": "HS256", "typ": "JWT"])) ?? Data()
        let payloadData = (try? JSONSerialization.data(withJSONObject: claims)) ?? Data()
        return [
            JWT.base64URLEncodeNoPad(headerData),
            JWT.base64URLEncodeNoPad(payloadData),
            "test-signature",
        ].joined(separator: ".")
    }
}

extension JWT {
    static func base64URLEncodeNoPad(_ data: Data) -> String {
        AuthSigning.base64URLEncodeNoPad(data)
    }
}

enum TestSupport {
    /// Fresh Keychain service per test run so tests never touch the real session item.
    static func testKeychain(file: StaticString = #filePath, line: UInt = #line) -> KeychainStore {
        KeychainStore(service: "com.nissorn.betteressentialspace.tests.\(UUID().uuidString)")
    }
}
