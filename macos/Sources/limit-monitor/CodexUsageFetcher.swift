import Foundation
import LimitMonitorCore

enum CodexFetchError: Error {
    case tokenExpired
    case http(Int)
    case network(String)
    case badResponse
    case parseFailure(keyTree: String)

    var describe: String {
        switch self {
        case .tokenExpired: return "401 unauthorized (token expired)"
        case .http(let code): return "HTTP \(code)"
        case .network(let message): return "network: \(message)"
        case .badResponse: return "bad/empty response"
        case .parseFailure: return "response parsed to no limits"
        }
    }
}

struct CodexFetchOutcome {
    let result: Result<[LimitEntry], CodexFetchError>
    let endpoint: String
}

enum CodexUsageFetcher {
    // WAF trips on bot-looking user agents — send a browser-like Safari UA.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"

    static let primaryEndpoint = endpoint(path: "/backend-api/wham/usage")
    static let fallbackEndpoint = endpoint(path: "/backend-api/codex/usage")

    private static func endpoint(path: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "chatgpt.com"
        components.path = path
        return components.url ?? URL(fileURLWithPath: "/dev/null")
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        return URLSession(configuration: config)
    }()

    private enum RawResult {
        case data(Data)
        case fallbackEligible(Int)
        case error(CodexFetchError)
    }

    static func fetchSync(auth: CodexAuth, now: Date = Date()) -> CodexFetchOutcome {
        let first = requestSync(url: primaryEndpoint, auth: auth)
        if case .fallbackEligible = first {
            let second = requestSync(url: fallbackEndpoint, auth: auth)
            return outcome(second, endpoint: fallbackEndpoint, now: now)
        }
        return outcome(first, endpoint: primaryEndpoint, now: now)
    }

    private static func outcome(_ raw: RawResult, endpoint: URL, now: Date) -> CodexFetchOutcome {
        let result: Result<[LimitEntry], CodexFetchError>
        switch raw {
        case .error(let error):
            result = .failure(error)
        case .fallbackEligible(let code):
            result = .failure(.http(code))
        case .data(let data):
            let limits = CodexUsageParser.parseLimits(data: data, now: now)
            result = limits.isEmpty
                ? .failure(.parseFailure(keyTree: JSONKeyTree.describe(data: data)))
                : .success(limits)
        }
        return CodexFetchOutcome(result: result, endpoint: endpoint.absoluteString)
    }

    private static func requestSync(url: URL, auth: CodexAuth) -> RawResult {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = auth.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var raw: RawResult = .error(.network("timed out"))
        let task = session.dataTask(with: request) { data, response, error in
            let value: RawResult
            if let error {
                value = .error(.network(error.localizedDescription))
            } else if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200:
                    value = data.map { .data($0) } ?? .error(.badResponse)
                case 401:
                    value = .error(.tokenExpired)
                case 400, 404:
                    value = .fallbackEligible(http.statusCode)
                default:
                    value = .error(.http(http.statusCode))
                }
            } else {
                value = .error(.badResponse)
            }
            lock.lock()
            raw = value
            lock.unlock()
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 30)
        lock.lock()
        defer { lock.unlock() }
        return raw
    }
}
