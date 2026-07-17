import Foundation
import LimitMonitorCore

/// Transport result for one config-provider request. `networkError` is a short
/// sanitized localized string (URLError-code based, via `NetErrStr`) — it can
/// never echo the URL or any header, so it is safe for menu rows and --check
/// output. The producing process composes it in its own resolved language.
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
    static func fetchSync(_ resolved: ResolvedRequest, _ lang: Language) -> CustomFetchResponse {
        guard let url = URL(string: resolved.url),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return CustomFetchResponse(data: nil, httpStatus: nil, networkError: NetErrStr.badURL.text(lang))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = resolved.timeoutSeconds
        for (name, value) in resolved.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var response = CustomFetchResponse(data: nil, httpStatus: nil, networkError: NetErrStr.timeout.text(lang))
        let task = session.dataTask(with: request) { data, urlResponse, error in
            let value: CustomFetchResponse
            if let error {
                value = CustomFetchResponse(data: nil, httpStatus: nil, networkError: describe(error, lang))
            } else if let http = urlResponse as? HTTPURLResponse {
                value = CustomFetchResponse(data: data ?? Data(), httpStatus: http.statusCode, networkError: nil)
            } else {
                value = CustomFetchResponse(data: nil, httpStatus: nil, networkError: NetErrStr.emptyResponse.text(lang))
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
    private static func describe(_ error: Error, _ lang: Language) -> String {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return NetErrStr.generic.text(lang) }
        switch ns.code {
        case NSURLErrorTimedOut: return NetErrStr.timeout.text(lang)
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: return NetErrStr.notConnected.text(lang)
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return NetErrStr.hostNotFound.text(lang)
        case NSURLErrorCannotConnectToHost: return NetErrStr.hostUnreachable.text(lang)
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted: return NetErrStr.tls.text(lang)
        default: return NetErrStr.genericCode(ns.code).text(lang)
        }
    }
}
