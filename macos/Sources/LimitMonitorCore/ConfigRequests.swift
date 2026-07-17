import Foundation

/// Fully resolved request descriptor for the shell layer to execute. Header
/// values may embed the key — never log or print a ResolvedRequest.
public struct ResolvedRequest: Equatable {
    public var url: String
    public var headers: [String: String]
    public var timeoutSeconds: Double

    public init(url: String, headers: [String: String], timeoutSeconds: Double = 15) {
        self.url = url
        self.headers = headers
        self.timeoutSeconds = timeoutSeconds
    }
}

public enum ConfigRequestBuilder {
    /// `${KEY}` placeholder substitution (URL and header values).
    public static func substitute(_ template: String, key: String) -> String {
        template.replacingOccurrences(of: "${KEY}", with: key)
    }

    /// The primary request of a provider. openrouter's /credits fallback is a
    /// separate descriptor (`openRouterCredits`).
    public static func primary(for provider: ConfiguredProvider, key: String) -> ResolvedRequest? {
        switch provider.kind {
        case .openrouter:
            return ResolvedRequest(
                url: "https://openrouter.ai/api/v1/key",
                headers: bearer(key)
            )
        case .deepseek:
            return ResolvedRequest(
                url: "https://api.deepseek.com/user/balance",
                headers: bearer(key)
            )
        case .moonshot:
            let base = provider.host == .cn ? "https://api.moonshot.cn" : "https://api.moonshot.ai"
            return ResolvedRequest(url: base + "/v1/users/me/balance", headers: bearer(key))
        case .zhipu:
            let base = provider.host == .cn ? "https://open.bigmodel.cn" : "https://api.z.ai"
            return ResolvedRequest(
                url: base + "/api/monitor/usage/quota/limit",
                // Official plugin sends the RAW key without "Bearer".
                headers: [
                    "Authorization": key,
                    "Accept": "application/json",
                    "Accept-Language": "en-US,en",
                ]
            )
        case .siliconflow, .novita, .genericHTTP:
            guard let request = provider.request else { return nil }
            var headers: [String: String] = [:]
            for (name, value) in request.headers {
                headers[name] = substitute(value, key: key)
            }
            return ResolvedRequest(
                url: substitute(request.url, key: key),
                headers: headers,
                timeoutSeconds: request.timeoutSeconds
            )
        }
    }

    public static func openRouterCredits(key: String) -> ResolvedRequest {
        ResolvedRequest(url: "https://openrouter.ai/api/v1/credits", headers: bearer(key))
    }

    /// --check step-log form of a URL template: the query may carry a literal
    /// key the user hardcoded instead of `${KEY}` (`?api_key=sk-…`), so
    /// everything after the first `?` collapses to `?…` — scheme+host+path
    /// suffice for debugging. Never applies to sent requests.
    public static func redactedDisplayURL(_ template: String) -> String {
        guard let mark = template.firstIndex(of: "?") else { return template }
        return String(template[..<mark]) + "?…"
    }

    private static func bearer(_ key: String) -> [String: String] {
        ["Authorization": "Bearer \(key)", "Accept": "application/json"]
    }
}
