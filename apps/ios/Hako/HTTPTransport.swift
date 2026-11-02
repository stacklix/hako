import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Shared policy for credential-bearing requests. Vendor protocols stay in child apps.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum HTTPTransport {
    static let shared = makeSession()

    static func makeSession(requestTimeout: TimeInterval = 60, resourceTimeout: TimeInterval = 604800) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        return URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }
}
