import Foundation
import LimitMonitorCore

enum FetchError: Error {
    case tokenExpired
    case http(Int)
    case network(String)
    case badResponse

    var describe: String {
        switch self {
        case .tokenExpired: return "401 unauthorized (token expired)"
        case .http(let code): return "HTTP \(code)"
        case .network(let message): return "network: \(message)"
        case .badResponse: return "bad/empty response"
        }
    }
}

enum UsageFetcher {
    static let endpoint: URL = {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.anthropic.com"
        components.path = "/api/oauth/usage"
        return components.url ?? URL(fileURLWithPath: "/dev/null")
    }()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        return URLSession(configuration: config)
    }()

    static func fetch(token: String, completion: @escaping (Result<[LimitEntry], FetchError>) -> Void) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(.network(error.localizedDescription)))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(.badResponse))
                return
            }
            if http.statusCode == 401 {
                completion(.failure(.tokenExpired))
                return
            }
            guard http.statusCode == 200, let data else {
                completion(.failure(.http(http.statusCode)))
                return
            }
            let limits = UsageParser.parseLimits(data: data)
            guard !limits.isEmpty else {
                completion(.failure(.badResponse))
                return
            }
            completion(.success(limits))
        }
        task.resume()
    }

    static func fetchSync(token: String) -> Result<[LimitEntry], FetchError> {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: Result<[LimitEntry], FetchError> = .failure(.network("timed out"))
        fetch(token: token) { value in
            lock.lock()
            result = value
            lock.unlock()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 30)
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
