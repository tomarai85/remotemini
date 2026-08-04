import Foundation
@testable import RemoteMini // for `BackendSession` -- this fixture now hands back the real type

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

    /// A real `BackendSession` -- same type, same initializer, same
    /// `RedirectRefusingDelegate` as production -- whose transport is this stub
    /// instead of the network. Used by every network-layer test in Sprint 1
    /// (`HealthzClientTests`, `SessionsAuthProbeTests`).
    ///
    /// This used to return a bare delegate-less `URLSession`, which meant those
    /// suites exercised a session shaped *unlike* the one production uses, and N5
    /// (redirect refusal) was never on the path they tested. Changed 2026-08-05 with
    /// the client initializers; `BackendSession` no longer accepts a foreign session,
    /// so the fixture cannot re-introduce that difference even by accident.
    ///
    /// Redirect *behavior* is still asserted in `RedirectRefusalTests` by calling the
    /// delegate method directly rather than driving a 3xx through this stub -- see
    /// that file for why that stays the tighter unit under test.
    static func makeSession() -> BackendSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return BackendSession(configuration: configuration)
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
