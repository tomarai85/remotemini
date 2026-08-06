import Foundation

/// One long-poll round trip + local retry pacing, owned exclusively by the
/// Conversation screen that displays it (brief §2-b: one `PollLoop` per displayed
/// Conversation screen). An `actor` -- the first in this codebase -- because its
/// mutable state (`cursor`, `attempt`, `resyncEpoch`) is written from inside `step()`
/// while `cancel()`/`resetForResync()` can be called from `@MainActor` code (the
/// View's teardown, a manual "read again" tap) at the same time `step()` may already
/// be awaiting a network response; actor isolation is what makes that safe without a
/// hand-rolled lock.
///
/// Deliberately does **not** own `UnreadableMeter`, `live`, `screen`, or
/// `display.choice` -- those are display state and stay on the `@MainActor`
/// `ConversationViewModel`, matching the codebase's existing split between "who owns
/// the network" and "who owns what's on screen." `step()` hands back a `StepResult`
/// per round trip; the caller decides what to do with it. This mirrors
/// `ConversationViewModel.load()`/`applyInitial(_:)`: the async fetch and the
/// synchronous state application are two different functions so tests can drive the
/// second one directly without racing a real network call (see `PollLoopTests`,
/// which calls `step()` against a stub `PollFetching` and inspects the returned
/// `StepResult` -- no real sleeping, no real actor-hop timing to fight).
///
/// ## Backoff wiring (judgment call -- not fully pinned down by the brief)
///
/// Ported from `rc-backend/src/app.html`'s `pollLoop` (the browser reference client,
/// and the only other caller of `Backoff.nextAttempt`/`Backoff.ms` in this repo):
/// `openedAt` is stamped immediately before firing each request (not once per
/// retry-loop iteration), and `nextAttempt` is called ONLY on a transport failure,
/// using *that failed request's own* start/finish times -- a long-poll that was held
/// open by the server for most of its 20s before dropping reads as "a healthy
/// connection just closed" (`Backoff.nextAttempt`'s `healthy` branch, reset toward
/// attempt 1); an instant failure reads as "never reached the server at all" (climb
/// the ladder). On success (any 200 that also decodes and reads, OR one that doesn't)
/// `attempt` resets to 0 directly, matching `app.html`'s own `attempt = 0` on its
/// success path.
///
/// **One deliberate divergence from `app.html`**: that reference client's `catch`
/// block also catches `readablePoll(d)` returning false (`app.html`, `pollLoop`:
/// `throw new Error("配信の形が読めません")` inside the same `try` the fetch itself is
/// in), which routes an unreadable-but-200 response through the *same*
/// `attempt`/backoff counter as a genuine network failure. Brief §3-a is explicit
/// that the phone client must not do this -- see `UnreadableMeter`'s own type doc.
/// `PollLoop.step` follows the brief, not `app.html`, at this one point: `.unreadable`
/// never touches `attempt` or `cursor`, only the caller's `UnreadableMeter`. This is a
/// discovered discrepancy between the two reference implementations, recorded in
/// `progress.md` -- not something silently reconciled by copying `app.html`'s
/// behavior into the port.
actor PollLoop {
    /// What one `step()` call produced, and what the caller should feed back in on
    /// the next call.
    struct StepResult: Equatable {
        enum Kind: Equatable {
            case readable(PollResponse)
            /// §2-a steps 2-4: JSON parse failed, `ReadablePoll.check` rejected the
            /// tree, or the typed decode failed. Cursor was NOT advanced.
            case unreadable
            case unauthorized
            /// The conversation is gone (404 + `SESSION_NOT_FOUND`). Terminal: unlike
            /// every other non-success kind here, no amount of retrying reaches a
            /// different answer, so the drive loop stops rather than backing off.
            case sessionNotFound
            case unreachable
        }
        let kind: Kind
        /// The `wait` value the caller should pass to the NEXT `step()` call. `0`
        /// after `more == true` (§2-a step 7: drain the backlog before idling again);
        /// `20000` (the server's own `POLL_MAX_WAIT_MS` ceiling) otherwise --
        /// including after `.unreadable`, which relies on the server's own long-poll
        /// hold for pacing rather than an additional local sleep (no local backoff is
        /// invented for that path; see the type doc's judgment-call note).
        let nextWaitMs: Int
        /// Local pacing delay (ms) the caller should sleep before the NEXT `step()`
        /// call, on top of whatever the server itself held the connection for.
        /// Non-zero only for `.unreachable` (`Backoff` climbing the ladder); `0` for
        /// every other kind.
        let localBackoffMs: Int
    }

    private let client: PollFetching
    private let baseURL: URL
    private let apiKey: String
    private let sessionID: String

    private var cursor: PollCursor
    private var attempt = 0
    private var isCancelled = false
    /// Bumped by `resetForResync()`. `step()` captures this at the start of a round
    /// trip and only commits the response's cursor if it is unchanged when the
    /// response comes back -- guards against a resync (gap-triggered, N4, or the
    /// stage-2 auto-recovery) landing WHILE an older `step()` is still in flight and
    /// that older call clobbering the fresh empty cursor with a stale one once its
    /// own (now-superseded) response arrives. Same shape as `app.html`'s own
    /// `conv.gen` generation guard, ported for the same reason: a stale in-flight
    /// response must not be allowed to overwrite state a newer action already reset.
    private var resyncEpoch = 0

    init(
        client: PollFetching = PollClient(),
        baseURL: URL,
        apiKey: String,
        sessionID: String,
        initialCursor: PollCursor = .empty
    ) {
        self.client = client
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.sessionID = sessionID
        self.cursor = initialCursor
    }

    /// §2-b: called from the View's teardown (`@MainActor`) while `step()` may still
    /// be awaiting a response -- safe because actor isolation serializes it against
    /// `step()`'s own mutations. `step()` checks this flag before returning a live
    /// result, so a response that lands after teardown is discarded rather than
    /// applied to a screen nobody is looking at anymore.
    func cancel() {
        isCancelled = true
    }

    /// §4 point 3 / §3-c: a resync (gap handling, N4, or the one-per-episode
    /// auto-recovery) throws away whatever the client remembers and starts over
    /// exactly like a first-ever poll -- the empty cursor is the wire protocol's own
    /// "nothing to resume from" sentinel (`PollCursor.empty`'s doc comment), identical
    /// to a brand-new screen's first request.
    func resetForResync() {
        cursor = .empty
        resyncEpoch += 1
    }

    /// The cursor this loop would send on its NEXT request, at the moment this is
    /// called. Used by the manual "再試行" action (`ConversationViewModel`): unlike
    /// "読み直す" (which calls `resetForResync()` -- a full resync), retry restarts
    /// the underlying `Task` without discarding history or cursor position, so it
    /// needs to hand the replacement `PollLoop` the position this one had already
    /// reached.
    func currentCursor() -> PollCursor {
        cursor
    }

    /// One round trip. `nil` means `cancel()` had already been called before this
    /// step started, or was called while the request was in flight -- the caller's
    /// drive loop should stop, not apply anything.
    func step(waitMs: Int) async -> StepResult? {
        guard !isCancelled else { return nil }
        let epochAtStart = resyncEpoch
        let openedAtMs = Self.nowMs()
        let outcome = await client.poll(baseURL: baseURL, apiKey: apiKey, sessionID: sessionID, cursor: cursor, waitMs: waitMs)
        guard !isCancelled else { return nil }

        switch outcome {
        case .success(let response):
            attempt = 0
            // §2-a step 6: cursor advances only on a successful, trusted decode, and
            // only if no resync landed while this request was in flight (see
            // `resyncEpoch`'s doc).
            if resyncEpoch == epochAtStart {
                cursor = response.cursor
            }
            return StepResult(kind: .readable(response), nextWaitMs: response.more ? 0 : 20_000, localBackoffMs: 0)

        case .unreadable:
            // §2-a steps 2-4 / §3-a: cursor untouched, `attempt` untouched -- this is
            // `UnreadableMeter`'s counter, not `Backoff`'s. See the type doc's
            // "deliberate divergence from app.html" note.
            return StepResult(kind: .unreadable, nextWaitMs: 20_000, localBackoffMs: 0)

        case .unauthorized:
            return StepResult(kind: .unauthorized, nextWaitMs: 20_000, localBackoffMs: 0)

        case .sessionNotFound:
            // `attempt` is deliberately NOT advanced. `Backoff`'s ladder exists to pace
            // retries, and there is no retry after this -- climbing it here would leave
            // a stale rung behind for a later loop on this same actor (a resync reuses
            // the instance) to inherit a delay it never earned.
            return StepResult(kind: .sessionNotFound, nextWaitMs: 20_000, localBackoffMs: 0)

        case .cancelled:
            // A deliberate cancellation (teardown, or a resync racing this request)
            // is never a transport failure -- must not climb `Backoff`'s ladder just
            // because the caller chose to stop waiting on it.
            return nil

        case .unreachable:
            attempt = Backoff.nextAttempt(attempt: attempt, openedAtMs: openedAtMs, nowMs: Self.nowMs())
            return StepResult(kind: .unreachable, nextWaitMs: 20_000, localBackoffMs: Backoff.ms(attempt: attempt))
        }
    }

    private static func nowMs() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }
}
