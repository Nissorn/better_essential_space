import CryptoKit
import Foundation

// MARK: - Device profile

/// The self-reported device identity sent to `account.nothing.tech` (notes/02
/// §Login protocol). Hardware fields are the A059 phone profile that the verified
/// mitmproxy recipe used; the server judges the risk gate purely on this JSON.
public struct DeviceProfile: Codable, Equatable, Sendable {
    public var identifier: String
    public var platform: String
    public var clientType: String
    public var deviceModel: String
    public var deviceBrand: String
    public var deviceHardware: String
    public var deviceBoard: String
    public var osVersion: String
    public var screenResolution: String
    public var deviceArchitecture: String
    public var deviceProcessor: String
    public var timezone: String
    public var language: String
    public var isEmulator: Bool
    public var isJailBroken: Bool
    public var isHooked: Bool
    public var isDebugMode: Bool
    public var networkType: String
    public var clientVersion: String
    /// Only set on the `device/report` body; never in the `x-device-info` header.
    public var publicKey: String?
    /// Only set on the `device/report` body (true until a device_id is registered).
    public var isFirst: Bool?

    enum CodingKeys: String, CodingKey {
        case identifier, platform
        case clientType = "client_type"
        case deviceModel = "device_model"
        case deviceBrand = "device_brand"
        case deviceHardware = "device_hardware"
        case deviceBoard = "device_board"
        case osVersion = "os_version"
        case screenResolution = "screen_resolution"
        case deviceArchitecture = "device_architecture"
        case deviceProcessor = "device_processor"
        case timezone, language
        case isEmulator = "is_emulator"
        case isJailBroken = "is_jail_broken"
        case isHooked = "is_hooked"
        case isDebugMode = "is_debug_mode"
        case networkType = "network_type"
        case clientVersion = "client_version"
        case publicKey = "public_key"
        case isFirst = "is_first"
    }

    public init(identifier: String, timezone: String, language: String) {
        self.identifier = identifier
        self.platform = "ANDROID"
        self.clientType = "APP"
        self.deviceModel = "A059"
        self.deviceBrand = "Nothing"
        self.deviceHardware = "qcom"
        self.deviceBoard = "taro"
        self.osVersion = "15"
        self.screenResolution = "1080x2400"
        self.deviceArchitecture = "arm64-v8a"
        self.deviceProcessor = "qcom"
        self.timezone = timezone
        self.language = language
        self.isEmulator = false
        self.isJailBroken = false
        self.isHooked = false
        self.isDebugMode = false
        self.networkType = "mobile"
        self.clientVersion = "17.06.02"
    }

    /// The profile with this machine's timezone and language.
    public static func current(identifier: String) -> DeviceProfile {
        DeviceProfile(
            identifier: identifier,
            timezone: TimeZone.current.identifier,
            language: Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        )
    }
}

// MARK: - Device identity (keypair + registration)

/// What the app persists per install in the Keychain: the client-generated device
/// `identifier` (UUID) and the `device_id` the account service handed back after
/// `device/report` (nil until the first successful report).
public struct DeviceRegistration: Codable, Equatable, Sendable {
    public var identifier: String
    public var deviceId: String?

    enum CodingKeys: String, CodingKey {
        case identifier
        case deviceId = "device_id"
    }
}

/// The per-install EC P-256 keypair whose public half is uploaded in `device/report`
/// and whose private half produces every `x-device-signature`. The private key is
/// stored raw (x9.63 bytes) so this stays plain `Sendable`.
public struct DeviceIdentity: Sendable {
    public let privateKeyData: Data
    public let registration: DeviceRegistration
    let keychain: KeychainStore

    public enum KeychainAccount {
        public static let key = "device-key"
        public static let registration = "device-registration"
    }

    /// Loads the persisted identity or mints a fresh one (new keypair + UUID) and
    /// persists it. Idempotent: an existing keypair is never rotated. If either
    /// Keychain half is missing both are re-minted — a lone key whose registration
    /// (or reverse) no longer matches what the server saw would only sign itself
    /// into 403s.
    public static func loadOrCreate(keychain: KeychainStore = KeychainStore()) throws -> DeviceIdentity {
        if let keyData = keychain.load(account: KeychainAccount.key),
           let registrationData = keychain.load(account: KeychainAccount.registration),
           let registration = try? JSONDecoder().decode(DeviceRegistration.self, from: registrationData),
           (try? P256.Signing.PrivateKey(x963Representation: keyData)) != nil {
            return DeviceIdentity(privateKeyData: keyData, registration: registration, keychain: keychain)
        }
        let registration = DeviceRegistration(identifier: UUID().uuidString, deviceId: nil)
        let keyData = P256.Signing.PrivateKey().x963Representation
        try keychain.save(keyData, account: KeychainAccount.key)
        try keychain.encodeAndSave(registration, account: KeychainAccount.registration)
        return DeviceIdentity(privateKeyData: keyData, registration: registration, keychain: keychain)
    }

    /// The public key as SPKI DER base64 — exactly the `public_key` field the
    /// service expects (26-byte ASN.1 header + the 65-byte `0x04 || X || Y` point).
    public var publicKeySPKIBase64: String {
        get throws {
            let key = try P256.Signing.PrivateKey(x963Representation: privateKeyData)
            let spkiHeader = Data([
                0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06,
                0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
            ])
            return (spkiHeader + key.publicKey.x963Representation).base64EncodedString()
        }
    }

    public var privateKey: P256.Signing.PrivateKey {
        get throws {
            try P256.Signing.PrivateKey(x963Representation: privateKeyData)
        }
    }

    public var registeredDeviceId: String? { registration.deviceId }

    /// Returns a copy with the server-assigned `device_id`, persisted to the Keychain.
    public func registered(_ deviceId: String) throws -> DeviceIdentity {
        var updated = registration
        updated.deviceId = deviceId
        try keychain.encodeAndSave(updated, account: KeychainAccount.registration)
        return DeviceIdentity(privateKeyData: privateKeyData, registration: updated, keychain: keychain)
    }
}

private extension KeychainStore {
    func encodeAndSave(_ value: some Encodable, account: String) throws {
        try save(try JSONEncoder().encode(value), account: account)
    }
}

// MARK: - Authflow steps

/// The OTP challenge returned by `authflow/login` for an untrusted device.
public struct OTPChallenge: Equatable, Sendable {
    public let stateToken: String
    public let maskedDestination: String
}

/// What `authflow/login` asks for: an OTP on an untrusted device, or nothing at
/// all on a device the account already trusts (then the session id is right there).
public enum LoginStep: Equatable, Sendable {
    case otp(OTPChallenge)
    case finished(sessionID: String)
}

struct DeviceReportResponse: Decodable {
    let deviceId: String
    let nextKeyRotationAt: String?

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case nextKeyRotationAt = "next_key_rotation_at"
    }
}

struct AuthflowStateResponse: Decodable {
    struct Action: Decodable {
        struct ActionData: Decodable {
            let maskedDestination: String?
            let sessionId: String?

            enum CodingKeys: String, CodingKey {
                case maskedDestination = "masked_destination"
                case sessionId = "session_id"
            }
        }

        let type: String
        let data: ActionData?
    }

    let stateToken: String?
    let action: Action?

    enum CodingKeys: String, CodingKey {
        case stateToken = "state_token"
        case action
    }
}

/// Native email + password + OTP login against `account.nothing.tech`
/// (notes/02 §Login protocol): device/report → authflow/login → OTP →
/// oauth2/authorize (PKCE code from the 302) → oauth2/token.
public struct AuthflowClient: Sendable {
    public static let baseURL = URL(string: "https://account.nothing.tech/api")!
    public static let clientID = "account-app-native"
    public static let redirectURI = "nothing-account-app://oauth2/callback"
    public static let scopes = "openid profile email offline_access"
    public static let userAgent = "Dart/3.9 (dart:io)"

    public let urlSession: URLSession
    public let keychain: KeychainStore
    public let signingKeyProvider: @Sendable () throws -> String

    public init(
        urlSessionConfiguration: URLSessionConfiguration = .ephemeral,
        keychain: KeychainStore = KeychainStore(),
        signingKeyProvider: @escaping @Sendable () throws -> String = { try RuntimeSecrets.accountSigningKey() }
    ) {
        self.urlSession = URLSession(
            configuration: urlSessionConfiguration,
            delegate: RedirectStopper.shared,
            delegateQueue: nil
        )
        self.keychain = keychain
        self.signingKeyProvider = signingKeyProvider
    }

    // MARK: Steps

    /// Reports the device profile (uploading the public key) when this install has
    /// no `device_id` yet. Returns the identity every later step signs with.
    @discardableResult
    public func ensureDeviceRegistered() async throws -> DeviceIdentity {
        let identity = try DeviceIdentity.loadOrCreate(keychain: keychain)
        guard identity.registeredDeviceId == nil else { return identity }

        var profile = DeviceProfile.current(identifier: identity.registration.identifier)
        profile.publicKey = try identity.publicKeySPKIBase64
        profile.isFirst = true
        let body = try encodeJSON(profile)
        let request = try makeRequest(
            path: "/v2/device/report",
            body: body,
            device: nil,
            identifier: identity.registration.identifier
        )

        let (data, http) = try await send(request)
        let report = try decode(DeviceReportResponse.self, from: data, http: http)
        return try identity.registered(report.deviceId)
    }

    /// Step 1 for the user: email + password. An untrusted device gets an OTP
    /// challenge (`action.type == "verify"`); an already-trusted device finishes
    /// immediately (`action.type == "finished"` with the session id).
    public func startLogin(email: String, password: String) async throws -> LoginStep {
        let identity = try await ensureDeviceRegistered()
        struct LoginRequest: Encodable {
            struct Input: Encodable {
                let identification = "email"
                let loginId: String
                let password: String

                enum CodingKeys: String, CodingKey {
                    case identification
                    case loginId = "login_id"
                    case password
                }
            }

            let input: Input
        }
        let body = try encodeJSON(LoginRequest(input: .init(loginId: email, password: password)))
        let request = try makeRequest(
            path: "/v2/authflow/login",
            body: body,
            device: identity,
            identifier: identity.registration.identifier
        )

        let (data, http) = try await send(request)
        let state = try decode(AuthflowStateResponse.self, from: data, http: http)
        guard let action = state.action else {
            throw ESError.invalidResponse("authflow/login returned no action")
        }
        switch action.type {
        case "verify":
            guard let stateToken = state.stateToken,
                  let masked = action.data?.maskedDestination
            else {
                throw ESError.invalidResponse("authflow/login verify action lacks state token or destination")
            }
            return .otp(OTPChallenge(stateToken: stateToken, maskedDestination: masked))
        case "finished":
            guard let sessionID = action.data?.sessionId else {
                throw ESError.invalidResponse("authflow/login finished action lacks a session id")
            }
            return .finished(sessionID: sessionID)
        default:
            throw ESError.invalidResponse("authflow/login asked for an unsupported action (\(action.type))")
        }
    }

    /// Step 2: the emailed code. On success the flow is `finished` and the
    /// returned `session_id` (starts with `sess_`) authorizes the OAuth code.
    public func submitOTP(_ code: String, stateToken: String) async throws -> String {
        let identity = try await ensureDeviceRegistered()
        struct InputRequest: Encodable {
            struct Input: Encodable {
                let code: String
            }

            let stateToken: String
            let input: Input

            enum CodingKeys: String, CodingKey {
                case stateToken = "state_token"
                case input
            }
        }
        let body = try encodeJSON(InputRequest(stateToken: stateToken, input: .init(code: code)))
        let request = try makeRequest(
            path: "/v2/authflow/login/state/input",
            body: body,
            device: identity,
            identifier: identity.registration.identifier
        )

        let (data, http) = try await send(request)
        let state = try decode(AuthflowStateResponse.self, from: data, http: http)
        guard state.action?.type == "finished", let sessionID = state.action?.data?.sessionId else {
            throw ESError.invalidResponse(
                "the OTP was not accepted (action \(state.action?.type ?? "none"))"
            )
        }
        return sessionID
    }

    /// Steps 3 + 4: PKCE authorize with the IdP session (code parsed from the 302
    /// Location, never followed) and the authorization-code exchange.
    public func completeLogin(sessionID: String) async throws -> TokenSet {
        let identity = try await ensureDeviceRegistered()
        let pkce = PKCE()
        let request = try makeRequest(
            path: authorizePath(pkce: pkce),
            body: nil,
            device: identity,
            identifier: identity.registration.identifier,
            deviceSignature: false,
            extraHeaders: [
                "x-idp-session": sessionID,
            ]
        )

        let (_, http) = try await send(request, allow3xx: true)
        guard http.statusCode == 302,
              let location = http.value(forHTTPHeaderField: "Location")
        else {
            throw ESError.invalidResponse("authorize did not redirect (HTTP \(http.statusCode))")
        }
        let code = try pkce.code(fromRedirectLocation: location)

        let profile = DeviceProfile.current(identifier: identity.registration.identifier)
        let form =
            "grant_type=authorization_code"
            + "&client_id=\(Self.clientID)"
            + "&code=\(AuthSigning.percentEncodeAll(code))"
            + "&redirect_uri=\(AuthSigning.percentEncodeAll(Self.redirectURI))"
            + "&code_verifier=\(AuthSigning.percentEncodeAll(pkce.verifier))"
            + "&x_device_info=\(AuthSigning.percentEncodeAll(try encodeJSON(profile).base64EncodedString()))"
        let tokenRequest = try makeRequest(
            path: "/v2/oauth2/token",
            body: Data(form.utf8),
            contentType: "application/x-www-form-urlencoded",
            device: identity,
            identifier: identity.registration.identifier
        )

        let (data, http2) = try await send(tokenRequest)
        do {
            return try TokenFile.parse(data)
        } catch {
            throw ESError.invalidResponse("token exchange (HTTP \(http2.statusCode)): \(error.localizedDescription)")
        }
    }

    // MARK: Request plumbing

    private func authorizePath(pkce: PKCE) -> String {
        "/v2/oauth2/authorize?"
            + "response_type=code"
            + "&client_id=\(Self.clientID)"
            + "&redirect_uri=\(AuthSigning.percentEncodeAll(Self.redirectURI))"
            + "&scope=\(Self.scopes.replacingOccurrences(of: " ", with: "+"))"
            + "&state=\(pkce.state)"
            + "&code_challenge_method=S256"
            + "&code_challenge=\(pkce.challenge)"
    }

    /// Builds a signed request. `path` is relative to `/api` (e.g. `/v2/authflow/login`)
    /// and may carry a query string; the signatures cover the full server path
    /// (`/api/v2/…`). Every call carries the app HMAC signature and `x-device-info`;
    /// when `device` is set the device-bound extras (`x-device-signature`,
    /// `x-device-id`) ride along too.
    private func makeRequest(
        path: String,
        body: Data?,
        contentType: String = "application/json",
        device: DeviceIdentity?,
        identifier: String,
        deviceSignature: Bool = true,
        extraHeaders: [String: String] = [:]
    ) throws -> URLRequest {
        guard var request = URL(string: Self.baseURL.absoluteString + path).map({ URLRequest(url: $0) }) else {
            throw ESError.invalidResponse("unbuildable request URL for \(path)")
        }
        let apiKey = try signingKeyProvider()
        let nonce = UUID().uuidString
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let signPath = "/api" + path

        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.setValue(nonce, forHTTPHeaderField: "x-nonce")
        request.setValue(String(timestamp), forHTTPHeaderField: "x-timestamp")
        request.setValue(String(timestamp), forHTTPHeaderField: "x-request-timestamp")
        request.setValue(
            AuthSigning.appSignature(
                body: body ?? Data(),
                nonce: nonce,
                path: signPath,
                timestampMilliseconds: timestamp,
                apiKey: apiKey
            ),
            forHTTPHeaderField: "x-app-signature"
        )
        request.setValue(
            try encodeJSON(DeviceProfile.current(identifier: identifier)).base64EncodedString(),
            forHTTPHeaderField: "x-device-info"
        )
        if let device {
            if deviceSignature {
                request.setValue(
                    try AuthSigning.deviceSignature(
                        privateKey: device.privateKey,
                        body: body ?? Data(),
                        timestampMilliseconds: timestamp
                    ),
                    forHTTPHeaderField: "x-device-signature"
                )
            }
            request.setValue(device.registeredDeviceId ?? "", forHTTPHeaderField: "x-device-id")
        }
        for (field, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    private func send(_ request: URLRequest, allow3xx: Bool = false) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw ESError.requestFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ESError.invalidResponse("non-HTTP response from \(request.url?.host ?? "?")")
        }
        guard (200..<300).contains(http.statusCode) || (allow3xx && http.statusCode == 302) else {
            throw ESError.httpStatus(http.statusCode, code: nil, message: String(data: data, encoding: .utf8))
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

    private func encodeJSON(_ value: some Encodable) throws -> Data {
        try JSONEncoder().encode(value)
    }
}

/// PKCE pair + state, generated exactly like the captured client: 32 random bytes
/// base64url-no-pad (43 chars, RFC 7636 unreserved) for verifier and state,
/// challenge = base64url-no-pad(SHA-256(verifier)).
struct PKCE {
    let verifier: String
    let state: String
    let challenge: String

    init() {
        verifier = Self.randomToken()
        state = Self.randomToken()
        challenge = AuthSigning.base64URLEncodeNoPad(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// Extracts and validates `code` from the `nothing-account-app://oauth2/callback`
    /// redirect Location, checking the echoed `state` against ours.
    func code(fromRedirectLocation location: String) throws -> String {
        guard let url = URL(string: location),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else {
            throw ESError.invalidResponse("undecodable authorize redirect: \(location)")
        }
        guard items.first(where: { $0.name == "state" })?.value == state else {
            throw ESError.invalidResponse("authorize redirect state mismatch")
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw ESError.invalidResponse("authorize redirect carries no code")
        }
        return code
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return AuthSigning.base64URLEncodeNoPad(Data(bytes))
    }
}

/// Keeps `oauth2/authorize`'s 302 from being followed into the custom URL scheme.
final class RedirectStopper: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = RedirectStopper()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
