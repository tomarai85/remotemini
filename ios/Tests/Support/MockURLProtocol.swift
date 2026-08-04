import Foundation

/// Minimal request/response stub for `URLSession`-based tests. Registered per-test
/// via a `URLSessionConfiguration` whose `protocolClasses` includes this class -- no
/// real network traffic occurs, and no host (real or fake-but-real-looking) is ever
/// contacted. Every test using this fixture points at an RFC 2606 reserved
/// `.invalid` TLD anyway, so even a wiring mistake could not reach a live server.
final class MockURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let headers: [String: String]
        let body: Data

        init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
        }
    }

    static var stubQueue: [Stub] = []
    static var requestedURLs: [URL] = []
    static var lastRequestHeaders: [String: String]?

    static func reset() {
        stubQueue = []
        requestedURLs = []
        lastRequestHeaders = nil
    }

    /// A bare `URLSession` with no delegate, backed by this stub protocol -- used by
    /// every network-layer test in Sprint 1 (`HealthzClientTests`,
    /// `SessionsAuthProbeTests`). Redirect behavior is tested separately in
    /// `RedirectRefusalTests` by exercising `BackendSession`'s delegate directly,
    /// not through this stub -- see that file for why.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.requestedURLs.append(url)
        Self.lastRequestHeaders = request.allHTTPHeaderFields

        guard !Self.stubQueue.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let stub = Self.stubQueue.removeFirst()
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
