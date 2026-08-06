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
    /// (20s, `POLL_MAX_WAIT_MS` in `server.mjs`). The client timeout must exceed that
    /// or a normal "nothing happened" 200 reads as a network error.
    ///
    /// Mirrors the server constant rather than restating 30 by hand, so the two
    /// numbers cannot drift apart -- that non-drift property is the reason the
    /// original shape used ONE timeout for every request, and splitting the timeouts
    /// below keeps it rather than trading it away.
    static let serverPollMaxWait: TimeInterval = 20
    static let pollTimeout: TimeInterval = serverPollMaxWait + 10

    /// Everything the user is *staring at a blank screen* for (REQUIREMENTS §5-6,
    /// measured 2026-08-06).
    ///
    /// Why this is not `pollTimeout`: until this split, one 30s value covered every
    /// request, so a network that accepts a connection and then never answers -- a
    /// hotel/airport captive portal, or a tailnet peer asleep, i.e. precisely the
    /// 移動中 case this app exists for -- left the Conversation and List screens
    /// showing a bare `ProgressView` for a full 30 seconds before offering 再試行.
    /// That is RC 却下理由 1 (「connecting」で作業が止まる) reproduced in this app.
    ///
    /// 8s is sized off measured payloads, not guessed: `/api/sessions` is the largest
    /// read at ~30 KB (41 conversations) and `/history?limit=50` runs 14 B - 2.6 KB,
    /// with server-side work of 1-5 ms and 38-65 ms respectively. A round trip over
    /// the tailnet measured 10.6 ms on a warm connection and 45-52 ms on a new one.
    /// 8s is therefore ~2 orders of magnitude of headroom on a working link, and only
    /// a link that is silent -- not merely slow -- reaches it.
    ///
    /// Reads only. Re-issuing a read is free, which is what makes a shorter give-up
    /// window strictly better here.
    static let interactiveTimeout: TimeInterval = 8

    /// Sends and interrupts keep the long timeout, deliberately.
    ///
    /// `POST /api/sessions/<id>/messages` carries **no idempotency key** (checked
    /// 2026-08-06: `server.mjs` has no dedup/nonce on that path -- it resolves a pane
    /// and calls `injector.send`). So a client that gives up while the request is
    /// still in flight cannot know whether the text was injected, and a retry types
    /// it into Claude's composer twice. Shortening this would widen exactly that
    /// window. The blank-screen complaint this split fixes is a *read* problem
    /// anyway: a send happens on an already-loaded screen that has the reachability
    /// banner, not behind a spinner.
    ///
    /// The real fix for the write side is an idempotency key on the server, which is
    /// a backend change outside v1's four items -- recorded rather than smuggled in.
    static let writeTimeout: TimeInterval = pollTimeout

    let session: URLSession

    init(configuration: URLSessionConfiguration = .default) {
        // The session-wide default stays the LONGEST of the three. A client that
        // forgets to set a per-request value therefore behaves exactly as this tree
        // did before the split -- the failure mode of forgetting is "no improvement,"
        // never "a working request now times out."
        //
        // That fallback is measured, not assumed (2026-08-06, plain Swift against an
        // unroutable address): a request that sets nothing still *reads* 60.0 from
        // `URLRequest.timeoutInterval`, but under a session whose configuration says
        // 3s it fails at 3.02s with `URLError` -1001 -- so the configuration governs
        // when the request stays silent, and the request governs when it speaks
        // (5s -> 5.03s, 2s -> 2.01s under the same 30s configuration).
        //
        // The consequence for tests: `MockURLProtocol.requestedTimeouts` records the
        // request's DECLARED value (60 for a bare request), not the effective one.
        // `RequestTimeoutTests` says so in its own header rather than implying the
        // suite proves enforcement -- enforcement is what the measurement above is for.
        configuration.timeoutIntervalForRequest = Self.pollTimeout
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
