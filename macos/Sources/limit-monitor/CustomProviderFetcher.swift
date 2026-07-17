import Foundation
import LimitMonitorCore

/// Transport result for one config-provider request. `networkError` is a short
/// sanitized RU string (URLError-code based) — it can never echo the URL or any
/// header, so it is safe for menu rows and --check output.
struct CustomFetchResponse {
    let data: Data?
    let httpStatus: Int?
    let networkError: String?
}

enum CustomProviderFetcher {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 120
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }()

    // GET only (enforced at config parse time). The resolved headers/URL may
    // embed the key — never log or print the request.
    static func fetchSync(_ resolved: ResolvedRequest) -> CustomFetchResponse {
        guard let url = URL(string: resolved.url),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return CustomFetchResponse(data: nil, httpStatus: nil, networkError: "некорректный URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = resolved.timeoutSeconds
        for (name, value) in resolved.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var response = CustomFetchResponse(data: nil, httpStatus: nil, networkError: "таймаут")
        let task = session.dataTask(with: request) { data, urlResponse, error in
            let value: CustomFetchResponse
            if let error {
                value = CustomFetchResponse(data: nil, httpStatus: nil, networkError: describe(error))
            } else if let http = urlResponse as? HTTPURLResponse {
                value = CustomFetchResponse(data: data ?? Data(), httpStatus: http.statusCode, networkError: nil)
            } else {
                value = CustomFetchResponse(data: nil, httpStatus: nil, networkError: "пустой ответ")
            }
            lock.lock()
            response = value
            lock.unlock()
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + resolved.timeoutSeconds + 15)
        lock.lock()
        defer { lock.unlock() }
        return response
    }

    // Curated short texts only: NSError descriptions may embed the request URL,
    // which for generic providers could carry the substituted key.
    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return "сетевая ошибка" }
        switch ns.code {
        case NSURLErrorTimedOut: return "таймаут"
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: return "нет соединения"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "хост не найден"
        case NSURLErrorCannotConnectToHost: return "хост недоступен"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted: return "TLS-ошибка"
        default: return "сетевая ошибка (код \(ns.code))"
        }
    }
}
