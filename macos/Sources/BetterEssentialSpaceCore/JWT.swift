import Foundation

/// Claims of an Access Token JWT that the client cares about.
public struct JWTClaims: Equatable, Sendable {
    /// Nothing Account uuid (`X-Nothing-Account-ID` on the preferences host).
    public let uuid: String?
    /// Expiry of the Access Token.
    public let expiresAt: Date?
    public let subject: String?

    public var expiresSoon: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 120
    }
}

public enum JWT {
    /// Parses the payload segment of a JWT. Signature is not verified (the server does that);
    /// this only reads claims.
    public static func claims(fromToken token: String) -> JWTClaims? {
        let segments = token.split(separator: ".").map(String.init)
        guard segments.count == 3,
              let payloadData = base64URLDecode(segments[1]),
              let object = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any]
        else { return nil }

        let uuid = object["uuid"] as? String
        let subject = object["sub"] as? String
        return JWTClaims(uuid: uuid, expiresAt: dateValue(object["exp"]), subject: subject)
    }

    /// Base64url decoding with the padding fix (JWT segments are unpadded).
    public static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64 += "="
        }
        return Data(base64Encoded: base64)
    }

    private static func dateValue(_ raw: Any?) -> Date? {
        if let number = raw as? NSNumber {
            Date(timeIntervalSince1970: number.doubleValue)
        } else if let string = raw as? String, let seconds = Double(string) {
            Date(timeIntervalSince1970: seconds)
        } else {
            nil
        }
    }
}
