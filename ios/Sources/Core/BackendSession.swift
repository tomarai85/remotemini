import Foundation

/// Shared HTTP plumbing for every rc-backend request (spec §3-1, §3-7/N5).
///
/// Redirects are refused outright rather than "followed with the header
/// reattached": `URLSession` strips `Authorization` on a cross-origin redirect by
/// design, and re-attaching it by hand would mean this client decides on its own to
/// send the bearer key to wherever a `Location` header points. A 3xx from this
/// backend is never something the client should chase automatically -- it is either
/// a misconfiguration or something worth surfacing as an unexpected response (spec:
/// "3xx が来たら想定外の応答に分類").
///
/// ## Why clients take this type and not a bare `URLSession`
///
/// This initializer takes a *configuration*, never a delegate: it installs
/// `RedirectRefusingDelegate` itself. So possessing a `BackendSession` IS the proof
/// that N5 holds for every request made through it -- the compiler enforces what a
/// default argument only suggested.
///
/// The shape being replaced (2026-08-05, Sprint 1 evaluator Finding 1) was
/// `init(session: URLSession = BackendSession.shared.session)` on each client. That
/// made redirect refusal a *default*, not a constraint: any call site could pass a
/// plain `URLSession` and silently lose N5. The Sprint 1 tests were themselves that
/// call site -- `MockURLProtocol.makeSession()` returned a delegate-less session, so
/// `HealthzClientTests`/`SessionsAuthProbeTests` never exercised redirect refusal
/// even once, while `RedirectRefusalTests` proved only that *this* type wires the
/// delegate. Both halves were green and the gap between them was invisible.
final class BackendSession {
    static let shared = BackendSession()

    /// Spec §3-1: the server holds long-poll requests up to `POLL_MAX_WAIT_MS`
    /// (20s, `POLL_MAX_WAIT_MS` in `server.mjs`). The client timeout must exceed that or a normal
    /// "nothing happened" 200 reads as a network error. Applied to every request
    /// (not only poll) so there is one timeout value to keep in sync with the
    /// server constant, not two call sites that can drift apart.
    static let requestTimeout: TimeInterval = 30

    let session: URLSession

    init(configuration: URLSessionConfiguration = .default) {
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        self.session = URLSession(configuration: configuration, delegate: RedirectRefusingDelegate(), delegateQueue: nil)
    }

    /// The one call clients make. Kept here rather than having each client reach for
    /// `.session` so that "which session did this request actually go through" has a
    /// single answer, greppable in one place.
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

/// Internal (not `private`) so `RedirectRefusalTests` can exercise this delegate's
/// method directly via `@testable import` -- testing the redirect refusal itself
/// does not require standing up real (or mocked) networking, only calling the
/// delegate method with a synthetic response and observing the completion handler.
final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil) // N5: do not follow. The 3xx response itself becomes the task's result.
    }
}
