import Foundation
import os

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
        ///
        /// Sprint 5 narrowed what reaches here: only a 404 whose body says
        /// `SESSION_NOT_FOUND` (see `HistoryClient`). A 404 that means "no such path"
        /// now lands in `.contractViolation` below instead, which is the whole of
        /// DoD row 6 -- this screen must NOT offer "一覧に戻る" for a bug in its own
        /// URL construction.
        case notFound
        /// Sprint 5 brief §0-c ③: the server broke the response contract. Its own
        /// phase rather than a variant of `.malformedBody`, because the two prompt
        /// different actions from whoever is debugging: `.malformedBody` means the
        /// payload of an otherwise-correct response did not parse, this means the
        /// response was not one the phone is permitted to interpret at all.
        case contractViolation(ResponseContractViolation)
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
    /// Populated by the poll loop as of Sprint 4 (brief §1-a items 1-3) -- previously
    /// always empty (Sprint 3 brief §2-d: no poll loop existed yet). Still never
    /// mutated directly by the View; only `applyReadablePoll(_:)` appends to it.
    @Published private(set) var live: [HistoryEntry] = []
    @Published private(set) var truncated = false
    @Published private(set) var loadEarlierState: LoadEarlierState = .hidden

    /// §2-c: `nil` means "server held this over, unchanged" -- these two are always
    /// written together, at the one shared apply site (`applyReadablePoll(_:)`),
    /// never independently, per the brief's own "両者を同じ1箇所で扱う事."
    @Published private(set) var screen: ScreenBody?
    @Published private(set) var choiceView: ChoiceView?
    /// Brief §4: the most recent non-null gap notice. Brief §1-a item 4 only asks to
    /// "draw the notice when non-null" -- no dismiss affordance is specified, so this
    /// simply holds the latest one until superseded by a newer gap (judgment call,
    /// noted in progress.md).
    @Published private(set) var latestGapNotice: String?

    @Published private(set) var unreadableStage: UnreadableMeter.Stage = .normal
    /// `nil` only before polling has ever started. Seeded to "now" the moment
    /// `startPolling()` runs (brief §3-b's banner always shows a clock time, never a
    /// blank) -- same "never display nothing, fail toward a stated unknown" instinct
    /// as `Freshness`.
    @Published private(set) var lastReadableAt: Date?

    // MARK: - Composer (Sprint 5)

    /// What the user has typed. The one `@Published` property on this type with a
    /// public setter -- SwiftUI's `TextField` needs a two-way binding, and routing
    /// every keystroke through a method would buy nothing. Everything that *clears*
    /// it goes through `applySendOutcome(_:)`, which is where the `keepText` rule
    /// lives.
    @Published var draft: String = ""
    /// True from the moment the send button is pressed until the response has been
    /// applied. The composer text is deliberately NOT cleared on entry to this state
    /// (brief §2 steps 2 and 5, and the star between them): clearing before the
    /// branch means a refusal makes the user retype what they wrote.
    @Published private(set) var isSending = false
    /// The band under the composer. `nil` until a send has completed at least once.
    @Published private(set) var sendBanner: SendBanner?
    /// Retained for tests and for anyone reading the screen's state in a debugger --
    /// the durable record is the log line written in `applySendOutcome(_:)`. Brief
    /// §0-c ③ asks for both: a fixed display AND a log, because a violation that only
    /// shows up as one user-visible sentence is one nobody can count.
    @Published private(set) var lastContractViolation: ResponseContractViolation?

    /// Brief §0-c ⑤, exactly its table. Only `CHOICE` and `UNKNOWN` disable the
    /// composer.
    ///
    /// Two spots where the obvious reading is wrong, both load-bearing:
    ///
    /// 1. **An unreadable poll leaves this `true`.** Nothing here consults
    ///    `unreadableStage`. The temptation is to fail closed -- "we can't see the
    ///    desk, so don't let them send" -- but fail-closed already exists on the side
    ///    that can actually observe the screen: `inject.mjs` returns `sent:false` for
    ///    `CHOICE`/`UNKNOWN` and aborts on a modal detected immediately before
    ///    injection. Blocking here would add nothing except a phone that goes mute
    ///    exactly when the user most wants to reach the desk.
    /// 2. **`BUSY` stays enabled**, which contradicts a literal reading of the Sprint
    ///    5 brief's own §2 step 1 ("not `SENDABLE` -> the button can't be pressed").
    ///    §2 step 1 is a loose restatement; §0-c ⑤ is the table with sources, and
    ///    `server.mjs`'s injector comment settles it outright: "生成中でも composer は
    ///    あるので送れる(Claude Code 自身が次ターンとして扱う)". Disabling on `BUSY`
    ///    would make the app unusable during exactly the state it exists to watch.
    ///
    /// `.unrecognized` (a future 5th classification) also stays enabled, same reasoning
    /// as `ResultDisplay.kind` not being a strict enum: an unknown value must not
    /// silently take a capability away.
    var composerEnabled: Bool {
        guard let screen else {
            // No screen observed yet (the first poll has not landed, or the route
            // holds `screen` over as null). Same rule as an unreadable poll.
            return true
        }
        switch screen.classification {
        case .choice, .unknown:
            return false
        case .sendable, .busy, .unrecognized:
            return true
        }
    }

    /// The fixed line shown in place of the composer while it is disabled. Both
    /// strings are the spec's own (§5-3 and its §2-3 reference), not newly invented
    /// here -- and neither describes a *response*, so the "never word things
    /// yourself" rule (which governs rendering `display`) does not apply: this is the
    /// phone reporting its own UI state, which no server response covers.
    var composerDisabledReason: String? {
        guard let screen, !composerEnabled else { return nil }
        switch screen.classification {
        case .choice:
            return "v1 では電話から選べません。机で確認するか、割り込みで中断してください"
        case .unknown:
            return "画面の状態を読めていません"
        case .sendable, .busy, .unrecognized:
            return nil
        }
    }

    /// Whether the send button does anything. Empty (or whitespace-only) input is
    /// blocked here rather than sent for the server to reject: the server's own 400
    /// path exists and is tested, but making the user round-trip to be told "text
    /// required" is not a use of it.
    ///
    /// The trim is only for THIS decision. `send()` transmits `draft` unmodified --
    /// the server trims, and a phone that also trimmed would be a second place
    /// deciding what the user's message is.
    var canSend: Bool {
        composerEnabled
            && !isSending
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The render array every screen actually shows. Recomputed on every access
    /// rather than cached -- brief §2-d, this is the one call site `mergeHistory`
    /// needs this sprint.
    var entries: [HistoryEntry] { MergeHistory.merge(history, live) }

    /// From the List row that navigated here (brief §3-c: the title survives a
    /// failed fetch -- it is never re-derived from a `/history` response, which
    /// carries no title at all).
    let title: String

    private let client: HistoryFetching
    private let pollClient: PollFetching
    private let sendClient: MessageSending
    private let baseURL: URL
    private let apiKey: String
    private let sessionID: String
    private let onUnauthorized: () -> Void

    private var currentLimit: Int
    private var isFetchingEarlier = false

    private var unreadableMeter: UnreadableMeter?
    /// Brief §3-c: "2回目以降は「読み直す」を人が押した時のみ" -- the automatic,
    /// one-shot resync fires once per stalled *episode*; this flag is what makes it
    /// one-shot, and `applyReadablePoll(_:)` clearing it on the next readable response
    /// (streak back to 0) is what ends an episode and re-arms it for the next one.
    private var resyncEpisodeUsed = false
    private var pollLoop: PollLoop?
    private var pollTask: Task<Void, Never>?

    /// One `os.Logger` for the whole screen, used only for response-contract
    /// violations. Deliberately not a general-purpose logger: everything else this
    /// type does has a visible on-screen consequence, and a log line nobody reads is
    /// worse than no log line -- it makes the file look instrumented while measuring
    /// nothing. Nothing user-typed and nothing key-shaped is ever passed to it; only
    /// the status and the server's own `code` vocabulary word.
    private static let log = Logger(subsystem: "com.tomtim.mobilework", category: "contract")

    init(
        client: HistoryFetching,
        pollClient: PollFetching = PollClient(),
        sendClient: MessageSending = SendClient(),
        baseURL: URL,
        apiKey: String,
        sessionID: String,
        title: String,
        onUnauthorized: @escaping () -> Void,
        initialLimit: Int = ConversationViewModel.initialLimit
    ) {
        self.client = client
        self.pollClient = pollClient
        self.sendClient = sendClient
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
            // Brief §1-a items 1-3: the poll loop starts once there is a history
            // screen to attach it to, not before -- a poll loop with nothing loaded
            // yet has nowhere to merge its `live` items against.
            startPolling()
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
        case .failure(.contractViolation(let violation)):
            applyContractViolation(violation)
        }
    }

    /// The one place a contract violation becomes screen state, so that "was it
    /// logged?" has a single answer. Brief §0-c ③ asks for both halves -- the fixed
    /// sentence AND a log line -- because a violation that exists only as one Japanese
    /// sentence on a phone is one nobody can ever count.
    private func applyContractViolation(_ violation: ResponseContractViolation) {
        recordContractViolation(violation)
        phase = .contractViolation(violation)
    }

    /// Records without deciding what the screen becomes -- the load paths make it the
    /// whole screen, the send path makes it one banner (see `applySendOutcome(_:)` for
    /// why those differ).
    ///
    /// The two logged values are the only two this type holds: an HTTP status and the
    /// server's own `code` vocabulary word. Neither can contain the user's typed text
    /// or the API key, which is why `ResponseContractViolation` never retains the
    /// response body in the first place.
    private func recordContractViolation(_ violation: ResponseContractViolation) {
        lastContractViolation = violation
        Self.log.error(
            "response contract violation: status=\(violation.status, privacy: .public) code=\(violation.code ?? "-", privacy: .public)"
        )
    }

    // MARK: - Send (Sprint 5, brief §2)

    /// One send attempt. The ordering here is the brief's §2, and the one thing it
    /// stars is the one thing this method is careful about: **the composer text is not
    /// touched until the response has been classified.** Clearing on tap reads as
    /// snappier UI and is wrong -- 409 (refused) and every transport failure would
    /// then cost the user everything they wrote.
    func send() async {
        guard canSend else { return }
        let text = draft

        isSending = true
        // The previous attempt's banner goes away as this one starts; leaving "送った"
        // visible under an in-flight send would let the user read a stale success as
        // this send's result.
        sendBanner = nil

        let outcome = await sendClient.send(
            baseURL: baseURL,
            apiKey: apiKey,
            sessionID: sessionID,
            text: text
        )
        applySendOutcome(outcome)
    }

    /// Split out for the same reason as `applyInitial(_:)`: tests drive the classified
    /// outcomes directly rather than racing a real `Task`.
    func applySendOutcome(_ outcome: SendOutcome) {
        isSending = false

        switch outcome {
        case .cancelled:
            // Whoever cancelled owns the outcome: no banner, and above all no clearing
            // of the draft. Same rule as `SessionsFetchError.cancelled` everywhere else
            // in this app.
            return

        case .unauthorized:
            // A ROUTE decision, decided from the status alone (brief §0-c ①). The draft
            // is deliberately left in place: the user is about to be sent to Key-entry
            // and back, and losing what they typed to a credentials round trip would be
            // the worst possible moment for it.
            onUnauthorized()

        case .sessionNotFound:
            // The one 404 that means what it says. The whole screen is now invalid, not
            // just this send -- so it becomes the phase, exactly as a 404 on `/history`
            // does.
            phase = .notFound

        case .contractViolation(let violation):
            // Deliberately NOT `applyContractViolation` -- this one does not become the
            // phase. On the load paths the unreadable response IS the screen's content,
            // so there is nothing left to show. Here the conversation is loaded, the
            // poll loop is live, and the desk may well have received the message: tearing
            // the screen down would destroy the one view the user needs in order to find
            // out. So it is recorded, logged, and shown as a banner over an intact screen.
            recordContractViolation(violation)
            sendBanner = SendBanner(locallyWorded: violation.displayText, tone: .error)

        case .unreachable:
            // One of the only three places the phone words a banner itself, and it is
            // allowed to precisely because no `display` ever arrived. The wording refuses
            // to claim either outcome: a request whose response was lost may well have
            // been delivered, and "送れませんでした" would be a guess stated as a fact.
            sendBanner = SendBanner(
                locallyWorded: "送れたかどうか確認できませんでした。本文は残してあります。机の画面を確認してください。",
                tone: .warn
            )

        case .display(let display):
            // The verbatim path. `display.text` is shown as the server wrote it -- no
            // suffix, no rewording, nothing appended. In particular the "本文は残して
            // あります" sentence is NOT added here: `view.mjs` already writes it into the
            // one branch that needs it (202 + `delivered:"unverified"`), and adding a
            // second copy on the phone would mean two files deciding one sentence.
            sendBanner = SendBanner(display: display)

            // Brief §2 step 5, read as a FIELD and never inferred from `kind`.
            //
            // Deliberate deviation, recorded rather than applied silently: the brief
            // says "偽/不在なら消す" -- absent should clear. This clears only on an
            // explicit `false`. The asymmetry is that the two mistakes are not the same
            // size. Keeping text that should have been cleared leaves a duplicate the
            // user can see and delete; clearing text that should have been kept destroys
            // something unrecoverable. It is the same reasoning §0-c ⑥ uses for an
            // unknown `kind` (degrade appearance, never capability) and the same
            // `view.mjs` states as "読めない事は値ではない".
            if display.keepText == false {
                draft = ""
            }
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
        case .failure(.contractViolation(let violation)):
            // Same teardown as `.notFound`, and for the same structural reason rather
            // than the same cause. The tempting alternative -- keep the (perfectly
            // good) history on screen and just show `.stalledRetry` -- fails on one
            // property: a contract violation does not heal by retrying. It would leave
            // the user tapping "もう一度試す" against a response the phone is not
            // permitted to interpret, forever, with the retry label quietly asserting
            // that another attempt might work.
            //
            // That is exactly the shape brief §0-c ② measured and DoD row 6 exists to
            // prevent: the app's own most likely bug (a wrong path) wearing the most
            // ordinary-looking explanation available.
            applyContractViolation(violation)
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

    // MARK: - Poll loop (Sprint 4, brief §1-a items 1-6)

    /// Brief §2-b: one `PollLoop` per displayed Conversation screen. Idempotent --
    /// called again from a later successful `load()` (the "再試行" button on a
    /// failure phase) while a loop from an earlier successful load is still running
    /// is a no-op, not a second concurrent loop.
    func startPolling() {
        guard pollTask == nil else { return }
        let now = Date()
        unreadableMeter = UnreadableMeter(lastReadableAt: now)
        lastReadableAt = now
        unreadableStage = .normal
        resyncEpisodeUsed = false

        let loop = PollLoop(client: pollClient, baseURL: baseURL, apiKey: apiKey, sessionID: sessionID)
        pollLoop = loop
        pollTask = Task { [weak self] in
            await self?.drivePolling(loop: loop)
        }
    }

    /// Brief §2-b: called from the View's `.onDisappear` -- cancels the driving
    /// `Task` (which, via structured-concurrency cancellation propagation through
    /// `URLSession`'s async API, also unblocks any in-flight long-poll `await`) and
    /// the underlying actor's own flag, belt-and-suspenders.
    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        if let loop = pollLoop {
            Task { await loop.cancel() }
        }
        pollLoop = nil
    }

    /// The real drive loop: repeatedly steps, applies, sleeps for whatever `step()`
    /// reported, and steps again. Kept separate from `step()` itself, and from
    /// `applyPollStep(_:)`, so tests exercise those two directly with no real
    /// sleeping or looping involved -- same reasoning as `load()`/`applyInitial(_:)`.
    private func drivePolling(loop: PollLoop) async {
        var waitMs = 0
        while !Task.isCancelled {
            guard let result = await loop.step(waitMs: waitMs) else { return }
            let shouldContinue = applyPollStep(result)
            guard shouldContinue else { return }
            if result.localBackoffMs > 0 {
                try? await Task.sleep(nanoseconds: UInt64(result.localBackoffMs) * 1_000_000)
            }
            waitMs = result.nextWaitMs
        }
    }

    /// One poll round trip's result, applied synchronously -- mirrors
    /// `applyInitial(_:)`/`applyLoadEarlier(...)`. Returns `false` when the drive
    /// loop should stop (brief §5-b: 401 stops polling and exits to Key-entry, same
    /// as every other authenticated request in this app).
    @discardableResult
    func applyPollStep(_ result: PollLoop.StepResult) -> Bool {
        switch result.kind {
        case .readable(let response):
            applyReadablePoll(response)
            return true
        case .unreadable:
            unreadableMeter?.markUnreadable()
            publishUnreadableState()
            maybeAutoResync()
            return true
        case .unauthorized:
            onUnauthorized()
            return false
        case .unreachable:
            // `Backoff.attempt` already advanced inside `PollLoop`; §3-a: a transport
            // failure must not touch `UnreadableMeter` in either direction.
            return true
        }
    }

    private func applyReadablePoll(_ response: PollResponse) {
        // §2-a step 5: this -- a successful merge, not merely "got a 200" -- is the
        // only place the meter resets.
        unreadableMeter?.markReadable(now: Date())
        publishUnreadableState()
        resyncEpisodeUsed = false // streak back to 0 ends the episode (§3-c)

        // §2-c: null = hold the previous value, for `screen` and `display.choice`
        // alike, applied here in the one shared spot the brief asks for.
        if let newScreen = response.screen {
            screen = newScreen
        }
        if let newChoice = response.display?.choice {
            choiceView = newChoice
        }

        var needsHistoryRefetch = false
        for item in response.items {
            switch item {
            case .message(let message):
                if let entries = message.entries {
                    live.append(contentsOf: entries)
                }
                // Worker-route `event` payloads decode but are not rendered this
                // sprint (brief §1-b) -- nothing to apply.
            case .gap(let gap):
                // Brief §4: whether a notice is DRAWN and whether `/history` is
                // REFETCHED are two separate decisions -- refetch regardless of
                // whether `notice` happened to be null for this particular gap.
                if let notice = gap.notice {
                    latestGapNotice = notice
                }
                needsHistoryRefetch = true
            case .unrecognized:
                break
            }
        }

        if needsHistoryRefetch {
            Task { await performResync() }
        }
    }

    /// Brief §3-c: fires exactly once per stalled episode, at the moment the stage
    /// FIRST becomes `.stalled` -- not on every subsequent unreadable response while
    /// already stalled (`resyncEpisodeUsed` is what prevents that).
    private func maybeAutoResync() {
        guard let meter = unreadableMeter, meter.stage(now: Date()) == .stalled, !resyncEpisodeUsed else { return }
        resyncEpisodeUsed = true
        Task { await performResync() }
    }

    private func publishUnreadableState() {
        guard let meter = unreadableMeter else { return }
        unreadableStage = meter.stage(now: Date())
        lastReadableAt = meter.lastReadableAt
    }

    /// Shared by gap-driven refetch (§4 point 3), N4 (background -> foreground), and
    /// the one-per-episode auto-recovery (§3-c) -- all three are explicitly "the same
    /// procedure" (brief §1-a item 5 / §3-c). Refetches `/history` at the current
    /// limit, clears `live` (the fresh history now supersedes whatever the poll loop
    /// had accumulated), and resets the poll loop's cursor to empty.
    private func performResync() async {
        let result = await client.fetch(baseURL: baseURL, apiKey: apiKey, sessionID: sessionID, limit: currentLimit)
        guard case .success(let response) = result else {
            // No distinct UI state is specified for "the resync's own /history call
            // itself failed" (brief doesn't name one) -- fail soft: keep whatever
            // `history` currently holds, and the still-running poll loop's next
            // successful response keeps merging against it. Noted as a judgment call
            // in progress.md.
            return
        }
        history = response.history
        truncated = response.truncated
        live = []
        await pollLoop?.resetForResync()
    }

    /// N4: background -> foreground. Same procedure as any other resync (see
    /// `performResync()`'s doc) -- time spent backgrounded is exactly the situation
    /// brief §4/§3-c already has a name for ("assume a gap happened, don't try to
    /// prove one did").
    func handleForegroundResume() {
        Task { await performResync() }
    }

    /// Manual "再試行": unlike "読み直す" (`rereadNow()`, a full resync), this does
    /// NOT touch `history`/`live` -- it restarts the driving `Task` from the SAME
    /// cursor position the old loop had already reached, which is only useful to
    /// distinguish from a resync if the old loop's `Task` was itself stuck (e.g. deep
    /// in a local backoff sleep) rather than just slow. Exact semantic split between
    /// the two buttons is a judgment call, not fully specified by the brief -- see
    /// progress.md.
    func retryPollingNow() {
        guard let oldLoop = pollLoop else {
            startPolling()
            return
        }
        pollTask?.cancel()
        Task { [weak self] in
            guard let self else { return }
            let resumeCursor = await oldLoop.currentCursor()
            await oldLoop.cancel()
            // No `await` here: `Task { [weak self] in ... }` created directly inside
            // an already-`@MainActor` method inherits that isolation, so this call
            // never actually hops actors -- confirmed by the build itself (`await
            // self.restartPolling(...)` compiled but the compiler warned "no 'async'
            // operations occur within 'await' expression"). Removed rather than left
            // in place: this one is not one of the pre-existing Sprint 3
            // `initialLimit` warnings, it's new to this sprint's own code.
            self.restartPolling(from: resumeCursor)
        }
    }

    private func restartPolling(from cursor: PollCursor) {
        let loop = PollLoop(client: pollClient, baseURL: baseURL, apiKey: apiKey, sessionID: sessionID, initialCursor: cursor)
        pollLoop = loop
        pollTask = Task { [weak self] in
            await self?.drivePolling(loop: loop)
        }
    }

    /// Manual "読み直す": the full resync procedure, on demand -- brief §3-c names
    /// this explicitly as the ONLY resync trigger from the second stalled episode
    /// onward (the automatic one is one-shot per episode; this button has no such
    /// limit).
    func rereadNow() {
        Task { await performResync() }
    }
}
