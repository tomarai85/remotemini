import Foundation

/// The Conversation screen's state machine (Sprint 3 brief §3). Same split as
/// `ListViewModel`: `apply(_:)` is separated from the async fetch call so tests can
/// drive it directly without racing a real `Task` (see `ConversationViewModelTests`).
@MainActor
final class ConversationViewModel: ObservableObject {
    /// Brief §2-a: `50` is `nextHistoryLimit`'s own fallback for "no current value
    /// yet" (`MergeHistory.nextHistoryLimit`'s `base`, seeded from `nil`) -- the first
    /// fetch on screen entry asks for exactly that, so `nextHistoryLimit(initialLimit)`
    /// on the very next "load earlier" tap produces the same `150` a `nil`-seeded call
    /// would.
    static let initialLimit = 50

    enum Phase: Equatable {
        case initialLoading
        case loaded
        case unreachable
        case malformedBody
        /// HTTP 404 -- brief §3-c's per-case table: distinct from `.unreachable`
        /// because the two prompt opposite user actions. `.unreachable` means "try
        /// again might work"; `.notFound` means the conversation is gone and retrying
        /// the same request will 404 again forever -- so the View must never offer a
        /// retry button for this case, only a way back to the list.
        case notFound
    }

    /// Brief §3-b-2's table, one case per row. `.loading` covers the in-flight tap
    /// (button disabled, progress shown, brief §3-b-3); it is not one of the table's
    /// 4 rows, it is what's shown *between* an attempt's start and its own re-entry
    /// into one of those 4.
    enum LoadEarlierState: Equatable {
        /// `truncated == false`: nothing older exists. No button, no line.
        case hidden
        /// `truncated == true`, not yet at the ceiling: "以前を読む".
        case available
        /// `truncated == true` AND `nextHistoryLimit(current) == current`: the only
        /// PERMANENT state in the table (brief §3-b-3) -- retract the button, show
        /// the ceiling line. Never reached by `.stalledRetry` alone; only by actually
        /// exhausting the 500-entry cap.
        case atCeiling
        /// A load-earlier attempt completed (successfully or not) without the oldest
        /// entry actually changing -- brief §3-b-1/§3-b-4: measured by comparing the
        /// oldest entry before/after via `MergeHistory.sameRoleAndText`, NOT by
        /// comparing counts (a concurrently-growing conversation can gain entries at
        /// the *live* end while the oldest end never moves, which the original,
        /// Codex-caught version of this rule read as success). One failed attempt is
        /// never permanent -- button stays, relabeled "もう一度試す".
        case stalledRetry
        case loading
    }

    @Published private(set) var phase: Phase = .initialLoading
    @Published private(set) var history: [HistoryEntry] = []
    /// Always empty this sprint -- brief §2-d: no poll loop until Sprint 4. Held (not
    /// omitted) so `entries` already routes through `MergeHistory.merge` today; only
    /// *populating* `live` is Sprint 4's job, not restructuring this pipeline.
    @Published private(set) var live: [HistoryEntry] = []
    @Published private(set) var truncated = false
    @Published private(set) var loadEarlierState: LoadEarlierState = .hidden

    /// The render array every screen actually shows. Recomputed on every access
    /// rather than cached -- brief §2-d, this is the one call site `mergeHistory`
    /// needs this sprint.
    var entries: [HistoryEntry] { MergeHistory.merge(history, live) }

    /// From the List row that navigated here (brief §3-c: the title survives a
    /// failed fetch -- it is never re-derived from a `/history` response, which
    /// carries no title at all).
    let title: String

    private let client: HistoryFetching
    private let baseURL: URL
    private let apiKey: String
    private let sessionID: String
    private let onUnauthorized: () -> Void

    private var currentLimit: Int
    private var isFetchingEarlier = false

    init(
        client: HistoryFetching,
        baseURL: URL,
        apiKey: String,
        sessionID: String,
        title: String,
        onUnauthorized: @escaping () -> Void,
        initialLimit: Int = ConversationViewModel.initialLimit
    ) {
        self.client = client
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.sessionID = sessionID
        self.title = title
        self.onUnauthorized = onUnauthorized
        self.currentLimit = initialLimit
    }

    func load() async {
        let result = await client.fetch(baseURL: baseURL, apiKey: apiKey, sessionID: sessionID, limit: currentLimit)
        applyInitial(result)
    }

    func applyInitial(_ result: Result<HistoryResponse, SessionsFetchError>) {
        switch result {
        case .success(let response):
            history = response.history
            truncated = response.truncated
            phase = .loaded
            // No "before" to compare against on the very first load -- `advanced`
            // is vacuously true, so the only question is `hidden`/`available`/`atCeiling`.
            loadEarlierState = Self.resolveLoadEarlierState(
                truncated: truncated,
                currentLimit: currentLimit,
                advanced: true
            )
        case .failure(.unauthorized):
            onUnauthorized()
        case .failure(.cancelled):
            break // a newer request owns the outcome
        case .failure(.unreachable):
            phase = .unreachable
        case .failure(.malformedBody):
            phase = .malformedBody
        case .failure(.notFound):
            phase = .notFound
        }
    }

    /// Brief §3-b-3: pressing while a fetch is already in flight must not launch a
    /// second one. `isFetchingEarlier` is set synchronously before the first `await`
    /// inside this (`@MainActor`) method, so a second call arriving before the first
    /// suspends sees it and returns immediately -- same guard shape as
    /// `ListViewModel.isRefreshing`.
    func loadEarlier() async {
        guard !isFetchingEarlier else { return }
        guard loadEarlierState == .available || loadEarlierState == .stalledRetry else { return }

        isFetchingEarlier = true
        let stateBeforeAttempt = loadEarlierState
        loadEarlierState = .loading

        let oldestBefore = history.first
        let requestedLimit = MergeHistory.nextHistoryLimit(currentLimit)
        let result = await client.fetch(baseURL: baseURL, apiKey: apiKey, sessionID: sessionID, limit: requestedLimit)
        applyLoadEarlier(result, requestedLimit: requestedLimit, oldestBefore: oldestBefore, stateBeforeAttempt: stateBeforeAttempt)

        isFetchingEarlier = false
    }

    func applyLoadEarlier(
        _ result: Result<HistoryResponse, SessionsFetchError>,
        requestedLimit: Int,
        oldestBefore: HistoryEntry?,
        stateBeforeAttempt: LoadEarlierState
    ) {
        switch result {
        case .success(let response):
            currentLimit = requestedLimit
            history = response.history
            truncated = response.truncated
            let advanced = !Self.sameOldest(oldestBefore, history.first)
            loadEarlierState = Self.resolveLoadEarlierState(
                truncated: truncated,
                currentLimit: currentLimit,
                advanced: advanced
            )
        case .failure(.unauthorized):
            onUnauthorized()
        case .failure(.cancelled):
            // Superseded by a newer request (e.g. the view disappearing mid-flight,
            // not a double-tap -- that's already blocked by `isFetchingEarlier`).
            // Restore whatever was showing before this attempt; the newer request
            // owns the real outcome.
            loadEarlierState = stateBeforeAttempt
        case .failure(.unreachable), .failure(.malformedBody):
            // Brief §3-b-3: a one-time failure to advance is never treated as the
            // permanent ceiling -- a network hiccup on "load earlier" reads exactly
            // like "fetched, but the oldest entry didn't move": button stays
            // (relabeled), "今回は読み込めませんでした" shown. The ceiling case is
            // ONLY reached by `nextHistoryLimit(current) == current` actually being
            // true, which a failed fetch (currentLimit left unchanged) cannot cause.
            loadEarlierState = .stalledRetry
        case .failure(.notFound):
            // Brief §3-c: a load-earlier request can 404 too (the conversation was
            // deleted between the initial open and this tap) -- treated the same as
            // a 404 on the initial load, not as a stalled retry: continuing to show
            // the history fetched before the file disappeared, with a working "read
            // more" loop underneath it, would be showing a stale, misleading screen.
            // `phase != .loaded` once this fires, so `loadEarlierFooter` (which only
            // renders inside the `.loaded` branch) disappears along with the history.
            phase = .notFound
        }
    }

    /// Brief §3-b-1: reuses `MergeHistory.sameRoleAndText`, not a new equality
    /// notion -- and inherits its known weakness (case 6, `mergeHistory`) that two
    /// genuinely-identical leading messages read as "unchanged" even when the older
    /// one really is a distinct message.
    private static func sameOldest(_ a: HistoryEntry?, _ b: HistoryEntry?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let a?, let b?): return MergeHistory.sameRoleAndText(a, b)
        default: return false
        }
    }

    /// Brief §3-b-2's table, evaluated in the table's own order: ceiling beats
    /// "advanced" beats "not advanced" -- e.g. an attempt that both hit the ceiling
    /// AND failed to advance must show the ceiling line, not the retry line, because
    /// only the ceiling condition is permanent.
    private static func resolveLoadEarlierState(truncated: Bool, currentLimit: Int, advanced: Bool) -> LoadEarlierState {
        guard truncated else { return .hidden }
        if MergeHistory.nextHistoryLimit(currentLimit) == currentLimit { return .atCeiling }
        return advanced ? .available : .stalledRetry
    }
}
