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
    /// Same shape as `requestedURLs` -- appended once per request, never overwritten
    /// in place. Added 2026-08-05: until this existed, nothing in this tree recorded
    /// which HTTP method a request actually used, so `SessionsClient` (or any other
    /// client) could have its `"GET"` silently rewritten to `"POST"` and all existing
    /// suites would stay green -- a request-shape mutation with no test able to see it.
    static var requestedMethods: [String] = []
    /// The third request-shape dimension, added for Sprint 5's send path: what the
    /// request actually carried. `nil` for a request with no body (every GET in this
    /// tree).
    ///
    /// **Read from `httpBodyStream`, never `httpBody`.** This is the landmine in this
    /// fixture and the reason this comment is long. `URLSession` converts an outgoing
    /// request's `httpBody` into `httpBodyStream` before the request reaches a
    /// `URLProtocol` subclass, so `request.httpBody` here is `nil` for EVERY request,
    /// including the POSTs that plainly set it. A naive implementation of this field
    /// would therefore record `nil` forever, every assertion built on it would compare
    /// `nil == nil`, and the suite would report a body-shape guard it does not have --
    /// which is worse than having no guard, because it stops anyone from adding one.
    static var requestedBodies: [Data?] = []
    /// The fourth request-shape dimension, added 2026-08-06 for the timeout split.
    /// Same reason `requestedMethods` exists: until this field existed, nothing in
    /// this tree recorded how long a request was willing to wait, so every client
    /// could have its `timeoutInterval` line deleted and all 362 tests would stay
    /// green -- the guard would be documented and unwatched, which this repo has
    /// measured to mean it silently reverts.
    ///
    /// Recording it here (rather than asserting on the `URLRequest` a client builds,
    /// which would only prove the client *set* a field) is also what makes the
    /// assertion non-vacuous: `URLSession` is what decides whether a per-request
    /// value beats `URLSessionConfiguration.timeoutIntervalForRequest`, and a value
    /// observed at this layer is one that survived that decision.
    static var requestedTimeouts: [TimeInterval] = []
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
    /// cases each failed at ~30s, exactly `BackendSession.pollTimeout` (named
    /// `requestTimeout` at the time, before the 2026-08-06 split), only when
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
        requestedMethods = []
        requestedBodies = []
        requestedTimeouts = []
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
    /// ★`appBuild` を差せる(2026-08-31)。既定は `nil` = **版を名乗らない** ——
    ///   既存の 700 本余りが「header はこれだけ」と測っている所へ、fixture が勝手に
    ///   1本増やすと、其の主張の意味が静かに変わる。名乗りを測りたい検査だけが差す。
    static func makeSession(appBuild: String? = nil) -> BackendSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return BackendSession(configuration: configuration, appBuild: appBuild)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.requestedURLs.append(url)
        // `URLRequest.httpMethod` is `String?`, but every client in this tree sets it
        // explicitly before dispatch -- a `nil` here would itself be a finding (a
        // request that forgot to set a method), so it is recorded as `"<nil>"`
        // rather than silently defaulted to "GET", which would hide that finding.
        Self.requestedMethods.append(request.httpMethod ?? "<nil>")
        Self.requestedBodies.append(Self.readBody(of: request))
        Self.requestedTimeouts.append(request.timeoutInterval)
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

    /// Drains the outgoing body. `httpBody` is checked first anyway -- not because it
    /// is ever populated here today, but because a future direct-`URLProtocol` test
    /// that never goes through `URLSession` would populate it, and silently returning
    /// `nil` for such a request would be the same invisible-hole failure this field
    /// exists to close.
    private static func readBody(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            // `read < 0` is a stream error and `read == 0` is end-of-stream; both must
            // break rather than spin, since `hasBytesAvailable` can stay true on a
            // stream that will never produce another byte.
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
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
