import Foundation
import LimitMonitorCore

enum CursorFetchError: Error {
    case tokenExpired
    case http(Int)
    case network(String)
    case badResponse
    case parseFailure(keyTree: String)

    var describe: String {
        switch self {
        case .tokenExpired: return "401/403 unauthorized (token expired)"
        case .http(let code): return "HTTP \(code)"
        case .network(let message): return "network: \(message)"
        case .badResponse: return "bad/empty response"
        case .parseFailure: return "response parsed to no limits"
        }
    }
}

enum CursorUsageFetcher {
    // Same browser-like Safari UA as the codex provider (the WAF trips on
    // bot-looking user agents).
    static let userAgent = CodexUsageFetcher.userAgent

    static let endpoint: URL = {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "cursor.com"
        components.path = "/api/usage-summary"
        return components.url ?? URL(fileURLWithPath: "/dev/null")
    }()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        // The Cookie header is set manually per request; keep URLSession's own
        // cookie machinery fully out of the way.
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }()

    static func fetchSync(cookie: String) -> Result<[LimitEntry], CursorFetchError> {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("WorkosCursorSessionToken=\(cookie)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("https://cursor.com/dashboard", forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: Result<[LimitEntry], CursorFetchError> = .failure(.network("timed out"))
        let task = session.dataTask(with: request) { data, response, error in
            let value: Result<[LimitEntry], CursorFetchError>
            if let error {
                value = .failure(.network(error.localizedDescription))
            } else if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200:
                    if let data {
                        let limits = CursorUsageParser.parseLimits(data: data)
                        value = limits.isEmpty
                            ? .failure(.parseFailure(keyTree: JSONKeyTree.describe(data: data)))
                            : .success(limits)
                    } else {
                        value = .failure(.badResponse)
                    }
                case 401, 403:
                    value = .failure(.tokenExpired)
                default:
                    value = .failure(.http(http.statusCode))
                }
            } else {
                value = .failure(.badResponse)
            }
            lock.lock()
            result = value
            lock.unlock()
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 30)
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
