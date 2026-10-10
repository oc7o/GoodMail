import Foundation
import JMAPKit
import MailPrivacy
import Synchronization
import Testing
@testable import GoodMailCore

/// The one-click session (D27, C22): its configuration, and what goes over the wire, through a URL protocol that
/// answers for `list.example`.
///
/// URLSession leaves cookies to its own HTTP implementation, which a URL protocol replaces, so no protocol can
/// show cookies being stored or sent; the configuration is what keeps them out, and is asserted here.
@Suite(.serialized)
struct OneClickSessionTests {
    init() {
        OneClickSessionTestsProtocol.requests.withLock { $0 = [] }
    }

    func send(_ request: URLRequest, through session: URLSession = Self.session) async throws -> HTTPURLResponse {
        try await URLSessionTransport(session: session).send(request).1
    }

    static let session = Unsubscriber.makeOneClickSession(protocolClasses: [OneClickSessionTestsProtocol.self])
    static let redirecting = URL(string: "https://list.example/unsubscribe/redirect?u=8f2a11")!

    var requests: [OneClickSessionTestsProtocol.Request] {
        OneClickSessionTestsProtocol.requests.withLock { $0 }
    }

    @Test func theSessionKeepsNothing() {
        let configuration = Unsubscriber.makeOneClickSession().configuration

        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(configuration.httpAdditionalHeaders?["User-Agent"] as? String == "Mozilla/5.0")
        #expect(configuration.httpAdditionalHeaders?["Accept-Language"] as? String == "*")
        #expect(configuration.timeoutIntervalForRequest == 30)
    }

    @Test func theRequestIsRFC8058s() async throws {
        let url = URL(string: "https://list.example/unsubscribe/one-click?u=8f2a11&l=news%20letter")!

        let response = try await send(Unsubscriber.oneClickRequest(to: url))

        #expect(response.statusCode == 200)
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://list.example/unsubscribe/one-click?u=8f2a11&l=news%20letter")
        #expect(request.headers["Content-Type"] == "application/x-www-form-urlencoded")
        #expect(request.headers["User-Agent"] == "Mozilla/5.0")
        #expect(request.headers["Accept-Language"] == "*")
        #expect(request.body == Data("List-Unsubscribe=One-Click".utf8))
        #expect(request.body.count == 26)
    }

    @Test func aRedirectComesBackAsItIs() async throws {
        let response = try await send(Unsubscriber.oneClickRequest(to: Self.redirecting))

        #expect(response.statusCode == 303)
        #expect(response.value(forHTTPHeaderField: "Location") == "https://list.example/welcome-back")
        #expect(response.value(forHTTPHeaderField: "Set-Cookie") != nil)
        #expect(requests.map(\.url.path) == ["/unsubscribe/redirect"])

        // Without the session's delegate, the same configuration follows it.
        OneClickSessionTestsProtocol.requests.withLock { $0 = [] }
        let following = URLSession(configuration: Self.session.configuration)
        #expect(try await send(Unsubscriber.oneClickRequest(to: Self.redirecting), through: following).statusCode == 200)
        #expect(requests.map(\.url.path) == ["/unsubscribe/redirect", "/welcome-back"])
    }

    @Test func noCookieOrAuthorizationGoesOut() async throws {
        _ = try await send(Unsubscriber.oneClickRequest(to: Self.redirecting))
        _ = try await send(Unsubscriber.oneClickRequest(to: URL(string: "https://list.example/unsubscribe/again")!))

        #expect(requests.count == 2)
        for request in requests {
            #expect(request.headers["Cookie"] == nil)
            #expect(request.headers["Authorization"] == nil)
        }
    }
}

/// Answers for `list.example`: a 303 with a cookie for paths ending in "/redirect", a 200 otherwise.
final class OneClickSessionTestsProtocol: URLProtocol, @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var url: URL
        var headers: [String: String]
        var body: Data
    }

    static let requests = Mutex<[Request]>([])

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host() == "list.example"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let url = request.url!
        Self.requests.withLock {
            $0.append(Request(
                method: request.httpMethod ?? "GET", url: url, headers: request.allHTTPHeaderFields ?? [:],
                body: request.httpBody ?? Self.read(request.httpBodyStream)))
        }
        if url.path.hasSuffix("/redirect") {
            let response = HTTPURLResponse(url: url, statusCode: 303, httpVersion: "HTTP/1.1", headerFields: [
                "Location": "https://list.example/welcome-back", "Set-Cookie": "session=8f2a11; Path=/; Secure",
            ])!
            // Offered to the session first; the response itself follows for when the session doesn't follow it.
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "https://list.example/welcome-back")!),
                                redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        } else {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Set-Cookie": "seen=1; Path=/; Secure",
            ])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 {
            data.append(buffer, count: count)
        }
        return data
    }
}
