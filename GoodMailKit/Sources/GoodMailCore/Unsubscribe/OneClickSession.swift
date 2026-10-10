import Foundation
import MailPrivacy

extension Unsubscriber {
    /// What every one-click request says about the client: what any browser says (D27).
    nonisolated static let oneClickHeaders = ["User-Agent": "Mozilla/5.0", "Accept-Language": "*"]
    nonisolated static let oneClickTimeout: TimeInterval = 30

    /// The session for one-click requests (D27), shared with nothing: ephemeral, with no cookie storage, credential
    /// storage or cache, so the list learns nothing about the user beyond the IP address. Redirects come back as
    /// the 3xx response, unfollowed.
    ///
    /// - Parameter protocolClasses: For tests only, to answer requests without a network.
    public nonisolated static func makeOneClickSession(protocolClasses: [AnyClass] = []) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = oneClickTimeout
        configuration.httpAdditionalHeaders = oneClickHeaders
        if !protocolClasses.isEmpty {
            configuration.protocolClasses = protocolClasses + (configuration.protocolClasses ?? [])
        }
        return URLSession(configuration: configuration, delegate: OneClickRedirectRefusal(), delegateQueue: nil)
    }

    /// RFC 8058 §3.1: a POST of `List-Unsubscribe=One-Click` to the URL exactly as the list gave it.
    nonisolated static func oneClickRequest(to url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: oneClickTimeout)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        // Set here as well as on the session, so that they hold for any transport.
        for (name, value) in oneClickHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(ListUnsubscribe.oneClickBody.utf8)
        return request
    }
}

/// Leaves every redirect unfollowed. A session-level delegate, which `URLSession.data(for:)` consults too.
private final class OneClickRedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
