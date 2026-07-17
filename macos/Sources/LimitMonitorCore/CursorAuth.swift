import Foundation

/// Cursor dashboard-cookie assembly. The access token (a 3-segment JWT) lives
/// in Cursor's state.vscdb; the cookie is `WorkosCursorSessionToken=<sub>::<token>`
/// where `sub` is the JWT subject claim (raw `::` join, no percent encoding).
/// Tokens, subs and assembled cookies are NEVER logged or printed.
public enum CursorAuth {
    /// state.vscdb stores the value either raw or as a JSON-quoted string —
    /// strip surrounding double quotes and whitespace.
    public static func unquote(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else {
            return trimmed
        }
        return String(trimmed.dropFirst().dropLast())
    }

    public static func jwtSegmentCount(_ token: String) -> Int {
        token.split(separator: ".", omittingEmptySubsequences: false).count
    }

    /// `sub` claim of a 3-segment JWT (e.g. `google-oauth2|1234567890`);
    /// nil for garbage or wrong segment counts — never crashes.
    public static func subClaim(fromJWT token: String) -> String? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return nil }
        guard let data = JWTDecoder.base64URLDecode(String(segments[1])),
              let object = try? JSONSerialization.jsonObject(with: data),
              let claims = object as? [String: Any],
              let sub = claims["sub"] as? String, !sub.isEmpty else { return nil }
        return sub
    }

    /// Cookie value `<sub>::<token>` for a raw DB value; nil when the token is
    /// empty or its `sub` cannot be extracted.
    public static func cookieValue(fromDBValue raw: String) -> String? {
        let token = unquote(raw)
        guard !token.isEmpty, let sub = subClaim(fromJWT: token) else { return nil }
        return "\(sub)::\(token)"
    }
}
