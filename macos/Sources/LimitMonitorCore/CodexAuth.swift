import Foundation

/// Parsed $CODEX_HOME/auth.json. The file is NEVER written and tokens are NEVER
/// refreshed here (rotation would invalidate codex's own refresh token) or printed.
public struct CodexAuth: Equatable {
    public let accessToken: String
    public let accountID: String?
    public let lastRefresh: Date?

    public init(accessToken: String, accountID: String?, lastRefresh: Date?) {
        self.accessToken = accessToken
        self.accountID = accountID
        self.lastRefresh = lastRefresh
    }
}

public enum CodexAuthState: Equatable {
    case oauth(CodexAuth)
    case apiKeyOnly
    case invalid
}

public enum CodexAuthParser {
    public static func parse(data: Data) -> CodexAuthState {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return .invalid }
        let tokens = root["tokens"] as? [String: Any]
        guard let accessToken = tokens?["access_token"] as? String, !accessToken.isEmpty else {
            if let key = root["OPENAI_API_KEY"] as? String, !key.isEmpty { return .apiKeyOnly }
            return .invalid
        }
        var accountID = (tokens?["account_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if accountID == nil {
            let candidates = [tokens?["id_token"] as? String, accessToken].compactMap { $0 }
            for candidate in candidates {
                if let id = JWTDecoder.chatGPTAccountID(fromJWT: candidate) {
                    accountID = id
                    break
                }
            }
        }
        let lastRefresh = (root["last_refresh"] as? String).flatMap(ISODateParser.parse)
        return .oauth(CodexAuth(accessToken: accessToken, accountID: accountID, lastRefresh: lastRefresh))
    }
}

public enum JWTDecoder {
    public static func payloadClaims(fromJWT token: String) -> [String: Any]? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return nil }
        guard let data = base64URLDecode(String(segments[1])),
              let object = try? JSONSerialization.jsonObject(with: data),
              let claims = object as? [String: Any] else { return nil }
        return claims
    }

    /// `chatgpt_account_id` claim — top-level or nested under "https://api.openai.com/auth".
    public static func chatGPTAccountID(fromJWT token: String) -> String? {
        guard let claims = payloadClaims(fromJWT: token) else { return nil }
        if let id = claims["chatgpt_account_id"] as? String, !id.isEmpty { return id }
        if let nested = claims["https://api.openai.com/auth"] as? [String: Any],
           let id = nested["chatgpt_account_id"] as? String, !id.isEmpty { return id }
        return nil
    }

    static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}
