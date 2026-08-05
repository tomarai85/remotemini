import Foundation

/// The List screen's state machine (Sprint 2 brief §4/§4-a/§5-2).
///
/// Owns exactly one thing the spec calls out as List's sole persistence exception
/// (brief §4-2): a memory-only "last successful response" used for stale-while-
/// revalidate display. Nothing here ever touches disk.
@MainActor
final class ListViewModel: ObservableObject {
    enum Phase: Equatable {
        /// No fetch has resolved yet (success or failure) since this ViewModel was
        /// created. Distinct from `.retryable(priorSessions: nil, ...)`, which means
        /// a fetch was *attempted and failed* -- this is "before the first attempt
        /// finished," not a failure state at all.
        case initialLoading
        /// a11y id `list.empty`. Brief §4: only reachable on HTTP 200, `sessions`
        /// empty, AND `paneFault == nil` -- `paneFault` is checked first and this
        /// case must never stack with it (see `phase(for:)`).
        case empty(scanLine: String)
        /// a11y id `list.paneFault`. `sessions` may itself be empty (paneFault only
        /// suppresses `registryOnlySessions`, not the scanned sessions) -- when it
        /// is, this case is shown instead of `.empty`, never both.
        case paneFault(reason: String, detail: String, sessions: [SessionRow], scanLine: String)
        case list(sessions: [SessionRow], scanLine: String)
        /// 1-2 consecutive failures (brief §4-a). `priorSessions == nil` is the third,
        /// distinct "まだ取れていません" state -- not `.empty`, not a bare spinner.
        /// `priorSessions != nil` keeps showing the old list, un-grayed, with a
        /// subtle retry affordance -- no red banner at this tier.
        case retryable(priorSessions: [SessionRow]?)
        /// a11y id `list.unreachable`. 3+ consecutive failures (brief §4-a):
        /// red banner, and the prior list (if any) is grayed out rather than
        /// replaced -- brief: "既存の一覧を空の一覧に差し替えない".
        case unreachable(priorSessions: [SessionRow]?)
    }

    /// Named constant, never a bare literal (brief §4-a): resolves the §5-4 vs §3-6
    /// numeric inconsistency in the spec: the brief author ruled 3 is correct.
    static let unreachableThreshold = 3

    @Published private(set) var phase: Phase = .initialLoading
    @Published private(set) var isRefreshing = false

    private let client: SessionsListing
    private let baseURL: URL
    private let apiKey: String
    private let onUnauthorized: () -> Void
    private let now: () -> Double

    private var consecutiveFailures = 0
    private var lastResponse: SessionsResponse?
    /// epoch ms of the last *successful* fetch; `0` means "never." Read by the View
    /// via `lastFetchedAtMs` and fed to `Freshness.freshness`, re-evaluated at redraw
    /// time rather than on a timer (brief §2-2/§3-c: no poll loop this sprint).
    private(set) var lastFetchedAtMs: Double = 0

    init(
        client: SessionsListing,
        baseURL: URL,
        apiKey: String,
        onUnauthorized: @escaping () -> Void,
        now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 }
    ) {
        self.client = client
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.onUnauthorized = onUnauthorized
        self.now = now
    }

    /// The single entry point for all four refresh triggers (brief §3-d: initial
    /// display / pull-to-refresh / foreground-resume / the retry button -- there is
    /// no fifth trigger, and in particular no "return from Conversation": that screen
    /// does not exist yet).
    func refresh() async {
        isRefreshing = true
        let result = await client.fetch(baseURL: baseURL, apiKey: apiKey)
        let wasCancelled = { if case .failure(.cancelled) = result { return true }; return false }()
        apply(result)
        // A cancelled fetch means a *newer* `refresh()` call cancelled this one and
        // is already in flight -- that call owns `isRefreshing` now. Clearing it here
        // would flip the spinner off while the real, still-running fetch continues,
        // which is exactly the flicker this skip avoids.
        if !wasCancelled { isRefreshing = false }
    }

    /// The state-machine transition itself, isolated from the async/Task plumbing in
    /// `refresh()` above so it can be driven directly and deterministically in tests
    /// (`ListViewModelTests`) with a scripted sequence of results, instead of racing
    /// real `Task` cancellation.
    func apply(_ result: Result<SessionsResponse, SessionsFetchError>) {
        switch result {
        case .success(let response):
            // Brief §4-a: ANY HTTP 200 resets the counter, regardless of paneFault.
            consecutiveFailures = 0
            lastResponse = response
            lastFetchedAtMs = now()
            phase = Self.phase(for: response)

        case .failure(.unauthorized):
            // Brief §4-a/§4-b: not counted at all -- exits to Key-entry instead.
            onUnauthorized()

        case .failure(.cancelled):
            // Brief §4-a/§8: not counted. No state changes at all -- a cancelled
            // fetch carries no information about the backend.
            break

        case .failure(.unreachable), .failure(.malformedBody), .failure(.notFound):
            // `.notFound` is Sprint 3's addition to the shared `SessionsFetchError`
            // taxonomy (brief §3-c) for Conversation's 404 -- `SessionsClient.fetch`
            // above never actually produces it (`/api/sessions` carries no session id
            // to 404 against), but the enum is shared, so this switch must still
            // handle every case to compile. Folded into the same opaque-failure
            // bucket as the other two: if a future server change ever did return 404
            // here, "nothing usable to show, count it" is still the right call.
            consecutiveFailures += 1
            phase = failurePhase()
        }
    }

    private static func phase(for response: SessionsResponse) -> Phase {
        // paneFault is checked FIRST -- brief §4: never stack "no conversations"
        // underneath a paneFault banner, even when `sessions` is also empty.
        if let fault = response.paneFault {
            return .paneFault(reason: fault.reason, detail: fault.detail, sessions: response.sessions, scanLine: response.display.scan)
        }
        if response.sessions.isEmpty {
            return .empty(scanLine: response.display.scan)
        }
        return .list(sessions: response.sessions, scanLine: response.display.scan)
    }

    private func failurePhase() -> Phase {
        let prior = lastResponse?.sessions
        if consecutiveFailures >= Self.unreachableThreshold {
            return .unreachable(priorSessions: prior)
        }
        return .retryable(priorSessions: prior)
    }
}
