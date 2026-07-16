import Foundation

public struct Credentials {
    public let accessToken: String
    public let expiresAt: Date?

    public init(accessToken: String, expiresAt: Date?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }

    public func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}

public enum CredentialsParser {
    public static func parse(data: Data) -> Credentials? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else { return nil }
        var expiresAt: Date?
        if let number = oauth["expiresAt"] as? NSNumber {
            expiresAt = Date(timeIntervalSince1970: number.doubleValue / 1000)
        }
        return Credentials(accessToken: token, expiresAt: expiresAt)
    }
}
