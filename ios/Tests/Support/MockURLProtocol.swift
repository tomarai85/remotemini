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

    /// Sprint 2: when non-zero, `startLoading()` schedules its response
    /// asynchronously after this delay instead of delivering it inline, giving a
    /// test room to call `Task.cancel()` on an in-flight fetch before the response
    /// would otherwise land. This fixture normally resolves synchronously (faster
    /// than any real round trip), so without a delay a cancellation test would be
    /// racing wall-clock scheduling order -- the kind of non-deterministic test this
    /// repo treats as measuring nothing (`method_calibrate_test_runtime_before_blaming_code`
    /// in project memory).
    ///
    /// This schedules on a background queue rather than blocking the thread
    /// `startLoading()` runs on: an earlier version of this fixture used a
    /// `DispatchSemaphore.wait()` there instead, which -- because `startLoading()`/
    /// `stopLoading()` run on a queue the whole URL-loading system shares, not one
    /// private to this session -- left that shared queue wedged after the blocked
    /// call unblocked, and every `MockURLProtocol`-backed request made afterward in
    /// the same test process silently fell through to real networking and timed out
    /// against the `.invalid` host instead of ever reaching `startLoading()` again
    /// (reproduced 2026-08-05: the four alphabetically-last `SessionsClientTests`
    /// cases each failed at ~30s, exactly `BackendSession.requestTimeout`, only when
    /// run after the blocking version of this test). Scheduling instead of blocking
    /// never occupies that shared queue, so it cannot repeat that failure mode.
    static var deliveryDelay: TimeInterval = 0
    private var wasCancelledBeforeDelivery = false

    /// When set, the next `startLoading()` fails with exactly this error instead of
    /// consuming `stubQueue` or falling back to `.cannotConnectToHost`. Consumed
    /// (cleared) after one use, same as `stubQueue.removeFirst()`. Sprint 2 needs
    /// this to deterministically produce `URLError(.cancelled)` for
    /// `SessionsClientTests` -- asserting the `catch let urlError as URLError where
    /// .cancelled` arm in isolation, with no timing dependency at all.
    static var injectedError: URLError?

    static func reset() {
        stubQueue = []
        requestedURLs = []
        lastRequestHeaders = nil
        deliveryDelay = 0
        injectedError = nil
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

        if Self.deliveryDelay > 0 {
            let delay = Self.deliveryDelay
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.deliver(url: url)
            }
            return
        }
        deliver(url: url)
    }

    private func deliver(url: URL) {
        if wasCancelledBeforeDelivery {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        if let injected = Self.injectedError {
            Self.injectedError = nil
            client?.urlProtocol(self, didFailWithError: injected)
            return
        }

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

    override func stopLoading() {
        // Called by `URLSession` when the owning `URLSessionTask` is cancelled.
        // Nothing to unblock (delivery is scheduled, never blocked) -- this just
        // records that a still-pending `deliver(url:)` should report cancellation
        // instead of the stubbed response, in case it fires anyway before the test
        // (or `URLSession`) has moved on.
        wasCancelledBeforeDelivery = true
    }
}
