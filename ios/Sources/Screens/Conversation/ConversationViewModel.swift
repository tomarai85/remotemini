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

    // MARK: - どこへ自動で寄せるか (Sprint 8)

    /// ★**末尾が伸びた時だけ**進む札。「件数が変わったら一番下へ」で書けない理由が
    /// この型の存在理由そのもの。
    ///
    /// `applyLoadEarlier(_:…)` は `history` を丸ごと長い配列へ差し替える -- 増えた分は
    /// **先頭**に付く。だから件数で追従させると、「以前を読む」を押した直後に画面が
    /// 一番下へ引き戻され、**押した行為そのものが画面から消える**。伸びた場所を
    /// 区別しない札は、追従ではなく妨害になる。
    ///
    /// 進むのは3箇所だけ: 初回読み込み / poll の live 追記 / 復帰時の取り直し。
    /// `applyLoadEarlier` は**進めない**(あちらは下の `earlierRevealToken` の担当)。
    @Published private(set) var tailToken = 0

    /// 「以前を読む」が**実際に古い行を足せた時だけ**進む札。`advanced == false`
    /// (押したが一番古い行が動かなかった = `.stalledRetry`)では進まない。
    ///
    /// View はこの札が進んだ時、`earlierRevealIndex` の行を画面の**下端**へ置く。
    /// 上端ではなく下端なのは、下端に置くと**新しく出た古い行だけで画面が埋まる**から
    /// -- 上端に置くと、既に読んだ行を見せて「押しても何も出ない」ように見える。
    @Published private(set) var earlierRevealToken = 0

    /// `earlierRevealToken` と対で書かれる。足す前に一番古かった行の、足した後の位置。
    ///
    /// `entries` は `MergeHistory.merge` の性質上つねに `history` を前置きにする
    /// (`history + live.suffix(from: k)`)ので、`history` 内の位置がそのまま
    /// `entries` 内の位置になる。ここで二重に数え直さないのはその為。
    private(set) var earlierRevealIndex: Int?

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
    ///
    /// ★2026-08-08(DESIGN §2.53): 打鍵ごとに `draftStore` へ書き通す。まとめ書きに
    /// しないのは、送信成功で消した事が**書き戻される窓**ができるから —— 送った直後に
    /// 落ちると、次に開いた時に送信済みの本文が composer へ蘇る。消した事も同じ経路で
    /// 書かれるなら、その窓は原理的に無い。
    ///
    /// `didSet` は init 内の代入では発火しない。復元(`init` の `self.draft = …`)が
    /// 書き戻しにならないのはその為で、§2.53 の「同じ本文で時刻を若返らせない」は
    /// store 側にも独立して置いてある(呼ぶ側の作法に正しさを預けない)。
    @Published var draft: String = "" {
        didSet { draftStore.save(draft, sessionID: sessionID) }
    }
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

    // MARK: - Queue (v2, 2026-08-14 — spec §7 の表の1行目を実装)

    /// 送信待ちの数の生値。`nil` = 観測していない(tmux 経路 / 古いサーバ)。
    /// §2-c の null-hold は screen / choice の規約であって此処には適用しない ——
    /// `queued` の null は「据え置き」ではなく**「観測できない」という値**なので、
    /// poll ごとに其のまま上書きする(`src/view.mjs` の `queueView` の註釈が正本)。
    private(set) var queuedCount: Int?
    /// 上の数が**取れた**時刻。面の古さは描画時に `Freshness` で測る(境目は一覧と共有)。
    private(set) var queuedFetchedAtMs: Double = 0
    /// 描画の度に呼ぶ(一覧の `freshnessLine()` と同じ型 —— timer を持たない)。
    func queueView(nowMs: Double) -> QueueViewState {
        QueueViewState.make(queued: queuedCount, fetchedAtMs: queuedFetchedAtMs, nowMs: nowMs)
    }
    /// 取り消しの結果の band。sendBanner / interruptBanner と同じ理由で**専用の枠**
    /// (共有すると答えの主語が混ざる)。数が**変わった** poll で流す —— choiceBanner が
    /// digest の変化で流れるのと同じ「答えの相手が動いたら残さない」規約。
    @Published private(set) var queueBanner: ClearQueueOutcome?
    @Published private(set) var isClearingQueue = false

    /// 取り消しを撃つ。走っている番は止まらない(サーバの route 註釈)。
    func clearQueue() async {
        guard !isClearingQueue else { return }
        isClearingQueue = true
        defer { isClearingQueue = false }
        let outcome = await clearQueueClient.clearQueue(
            baseURL: baseURL, apiKey: apiKey, sessionID: sessionID)
        queueBanner = outcome
    }

    // MARK: - Interrupt (Sprint 6, brief §2-b)

    /// True from the moment the interrupt button is pressed until its response has
    /// been applied.
    @Published private(set) var isInterrupting = false
    /// **Its own band, deliberately not `sendBanner`.** Sharing one slot would let an
    /// interrupt's answer overwrite a send's (and vice versa) with no way for the
    /// reader to tell which operation the surviving sentence belongs to -- and these
    /// two are the operations most likely to be fired seconds apart, since the reason
    /// to interrupt is usually "I just sent the wrong thing."
    @Published private(set) var interruptBanner: SendBanner?

    /// ★★The one gated behaviour in Sprint 6, and the reason it is a named constant
    /// rather than an inline `case .choice: return false`.
    ///
    /// The collision, measured 2026-08-05 (Sprint 6 brief §0-e):
    ///
    /// - The server's interrupt handler does **not** look at `screen`; `inject.mjs`'s
    ///   `#interruptExclusive` runs `send-keys … Escape` unconditionally, with no
    ///   hard-stop or benign-screen check anywhere on that path.
    /// - Permission / trust prompts carry numbered options, so `classifyScreen`
    ///   returns `CHOICE` for them.
    /// - Therefore an interrupt button that is live on a `CHOICE` screen **is** a way
    ///   to send `Escape` to a permission prompt from the phone.
    /// - That exact capability is what `DESIGN.md` §2.29-f and `src/choice.mjs`'s
    ///   header record as **not adopted, pending the owner's ruling**, with Codex's
    ///   2026-08-03 finding that widening D4 「開発側の解釈だけで広げるべきではありません」.
    /// - Spec §5-3's table nevertheless marks interrupt 有効 on `CHOICE` -- but its
    ///   justification column only restates the server's behaviour and cites neither
    ///   D4 nor §2.29-f. A grep of both documents found no reconciliation anywhere. It
    ///   is an inherited line, not a decided one, so it does not get to settle this.
    ///
    /// Default is therefore the forbidden side. Flipping this to `true` is the whole
    /// of the change if Tom re-defines D4 as 「承認は禁止、明示的な拒否は可」 --
    /// `composerDisabledReason` reads the same constant, so the button and the
    /// sentence that points at the button cannot disagree.
    ///
    /// ★★**Sprint 7 note, and read it before concluding this constant is now dead.**
    /// The choice card can put an `escape` button on a `CHOICE` screen, which looks
    /// like the very thing this constant forbids. It is not the same capability, and
    /// the difference is *who decided the screen was safe*:
    ///
    /// - The interrupt button would send `Escape` through `#interruptExclusive`, which
    ///   never classifies the menu. Its reach is every `CHOICE` screen, permission
    ///   prompts included. That is the D4 widening, and it stays forbidden.
    /// - The card's buttons are not composed here at all. They arrive in `buttons`,
    ///   which the server emits only after `classifyChoice` returned `benign` **with a
    ///   matcher** -- an allowlist. A permission or trust prompt yields zero buttons
    ///   and a `reason` instead, so there is no key for the phone to press.
    ///
    /// So the card leaves 「自動化に安全確認を押させない」 intact by construction rather
    /// than by this flag, and the flag still governs the one path that has no
    /// classification behind it. Do not fold the two together.
    static let interruptAllowedOnChoiceScreen = false

    /// Whether the interrupt button is live at all.
    ///
    /// Note what is deliberately NOT here: `BUSY`. Interrupting is allowed at any
    /// time, which is Tom's own ruling on this app -- 「返答待ちであれ作業中であれ
    /// いつでも見て、干渉できればいいんじゃないかな？」. Gating on "we currently observe
    /// generation" would mean the phone refuses to act precisely when its view of the
    /// desk has gone stale, and the server already answers "there was nothing to stop"
    /// truthfully and in its own words (`view.mjs`'s `interruptResult`).
    var interruptEnabled: Bool {
        guard let screen else { return true }
        switch screen.classification {
        case .choice:
            return Self.interruptAllowedOnChoiceScreen
        case .sendable, .busy, .unknown, .unrecognized:
            // `UNKNOWN` stays enabled: unlike the composer (which would be putting new
            // text into a screen nobody can read), interrupting only ever cancels. An
            // unreadable screen is the state in which being unable to stop the desk is
            // worst.
            return true
        }
    }

    /// ★Sprint 7, found by looking at a screenshot rather than by a test.
    ///
    /// This sentence read 「確認待ちの画面では、v1 は電話から中断しません。机で確認して
    /// ください」 -- and the choice card put an escape button roughly 40 points below it.
    /// Both statements were *true* (the interrupt path is blocked; the card's Escape is a
    /// server-allowlisted key), and the screen still read as the app contradicting
    /// itself, which is worse than either being wrong: a user who cannot tell which of
    /// two adjacent sentences to believe stops believing both.
    ///
    /// Every assertion in the suite passed while that was on screen, because each half
    /// was tested against its own rule and nothing tested the pair. The fix is to say
    /// the true thing, which is not 「中断しません」 but 「この button では中断しません」.
    ///
    /// ★2026-08-08 (監査 S8-20) -- a correction to this comment, not to the code. The
    /// screenshot showed that button labelled 「中止(Escape)」, and this comment said so
    /// for a sprint. Production never emitted that string: it came from
    /// `PollFixture.swift`, hand-written prettier than the server, whose escape label was
    /// the bare `Escape`. So the sentence below sent the user to 「下の選択肢」 on a card
    /// where nothing said 中止. The branch was right; the screen it was drawn from was
    /// not real. `view.mjs` now emits `Escape(中止)` and a backend test pins these
    /// fixtures to what the server can actually produce.
    var interruptDisabledReason: String? {
        guard !interruptEnabled else { return nil }
        // `visibleChoice`, not `choiceView`: a card the screen is not drawing cannot be
        // the thing this sentence points at. Pointing 「下の選択肢から選んでください」 at a
        // card that is not below is the same self-contradiction one line up, arrived at
        // from the other direction.
        if visibleChoice?.buttons.contains(where: { $0.key == "escape" }) == true {
            return "This confirmation isn't stopped by interrupting. To cancel, pick from the options below"
        }
        return "On a confirmation screen, v1 does not interrupt from the phone. Handle it on the desk"
    }

    var canInterrupt: Bool { interruptEnabled && !isInterrupting }

    // MARK: - Reachability (Sprint 6, spec §5-4)

    /// Spec §5-4's counter, the same type List uses. Before Sprint 6 this screen had
    /// no equivalent at all: `applyPollStep(.unreachable)` returned `true` and touched
    /// nothing, so a phone that lost the backend mid-conversation kept showing a
    /// perfectly normal, perfectly stale screen indefinitely.
    ///
    /// Fed **only** by transport failures (§5-4: 接続不可・タイムアウト・5xx, all three
    /// of which arrive here as `.unreachable`). An unreadable poll is not counted here
    /// -- that is `unreadableMeter`'s job (§5-5), and the spec forbids substituting one
    /// for the other by name: 「代用した瞬間、200 で返る壊れた配信が『接続は健全』に
    /// 見える」.
    ///
    /// `@Published` because nothing else changes on a poll transport failure -- without
    /// it the banner would not appear until some unrelated state happened to move.
    @Published private(set) var reachability = ReachabilityMeter()

    var isBackendUnreachable: Bool { reachability.isUnreachable }

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
    ///
    /// Sprint 6: the `CHOICE` sentence is now derived from
    /// `interruptAllowedOnChoiceScreen` rather than fixed. Sprint 5 shipped it ending
    /// 「…机で確認するか、割り込みで中断してください」, which is a promise about the
    /// interrupt button -- so the sentence and the button have to move together or one
    /// of them becomes a lie. Two call sites of one constant is the cheapest structure
    /// that makes disagreement impossible.
    ///
    /// Sprint 7 applies that same rule to the choice card, because it broke the same
    /// way. The `CHOICE` sentence read 「v1 では電話から選べません」 -- a claim about a
    /// capability, which the card is. Leaving it would have put 「選べません」 directly
    /// above a row of buttons that select. So the sentence now names whichever of the
    /// three states the card is actually in, and in two of them it points **at the
    /// card** rather than restating its content: the card carries the server's own
    /// `reason`, and a paraphrase up here could only drift away from it.
    var composerDisabledReason: String? {
        guard let screen, !composerEnabled else { return nil }
        switch screen.classification {
        case .choice:
            // 「文字は送れません」 stays in all three: that part is about the composer,
            // which is disabled on `CHOICE` regardless of what the card offers.
            guard let card = visibleChoice else {
                // The screen is a menu but no card arrived (a poll without `display`,
                // or a server too old to send one). Nothing to point at, so this falls
                // back to Sprint 6's sentence -- including its interrupt clause, which
                // is why the constant is still read here.
                return Self.interruptAllowedOnChoiceScreen
                    ? "Waiting on a choice. Text can't be sent. Handle it on the desk, or interrupt"
                    : "Waiting on a choice. Text can't be sent. Handle it on the desk"
            }
            if card.canPress && card.digest != staleChoiceDigest {
                return "Waiting on a choice. Text can't be sent. Pick from the options below"
            }
            return "Waiting on a choice. Text can't be sent. The reason is shown below"
        case .unknown:
            return "The screen state is unreadable"
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
            && !isVerifyingSend
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// ★2026-08-08(DESIGN §2.54): 要求が飛んでいる間、画面に出す一文。
    ///
    /// 体験側監査 #4 は「不通が分かっているなら送信を先に断れ」と言う。断らない —— 理由は
    /// §2.54 に書いた(計器は片側にしか外れず、外れるのは常に「通るのに断る」側)。ただし
    /// 指摘が指している痛みは本物で、それは**この段が無言だった**事。
    ///
    /// 測った所(2026-08-08、`ConversationView` の送信行):`isSending` の間、送信ボタンは
    /// `ProgressView()` に化けて伏せられるが、**文は1つも出ていなかった**。次の段
    /// (`isVerifyingSend`)には §2.52 の `sendUnknownInterim` が在るのに、その手前の
    /// 最大30秒だけが回っているだけの窓だった。iOS で文の無いスピナが30秒続くのは、
    /// 正常な待ちの見え方ではない。
    ///
    /// **新しい `@Published` を持たない**のがここの要点。`isSending` は既に `@Published`
    /// なので computed で足り、`isBackendUnreachable` と同じ形になる —— 状態を増やすと
    /// 「送信中である事」の真実が2箇所になり、食い違える。
    var sendInFlightNotice: String? {
        isSending ? Self.sendInFlightText(timeout: BackendSession.writeTimeout) : nil
    }

    /// ★2026-08-08(DESIGN §2.56): 割り込みと打鍵の、同じ窓。
    ///
    /// §2.54 は送信だけを直した。残る2操作を測ったら **非対称が3段階だった**:
    ///
    /// | 操作 | 飛んでいる間 | 結果不明の取り直しの間 |
    /// |---|---|---|
    /// | 送信 | スピナ + 文(§2.54) | 文 + ボタン伏せ |
    /// | 割り込み | スピナ、**文なし** | 文 (`interruptUnknownInterim`) |
    /// | 打鍵 | **スピナも文も無し**(灰色になるだけ) | 文 (`choiceUnknownInterim`) |
    ///
    /// 直すのは**左の列だけ**。右の列は3操作とも既に文が在る —— この節は一度
    /// 「割り込みと打鍵は取り直しの間も無言」と書き、`applyInterruptOutcome` の先頭と
    /// `.display` 枝しか読まずに結論を出していた。結果不明の枝
    /// (`.unreachable` / `.contractViolation`)を読めば両方とも文を置いている。
    /// **足す物が無い所に足しに行くのは、S8-5 で踏んだばかりの穴。**
    ///
    /// 新しい `@Published` を持たないのは `sendInFlightNotice` と同じ理由。
    var interruptInFlightNotice: String? {
        isInterrupting ? Self.interruptInFlightText(timeout: BackendSession.writeTimeout) : nil
    }

    var choiceInFlightNotice: String? {
        inFlightChoiceKey == nil ? nil : Self.choiceInFlightText(timeout: BackendSession.writeTimeout)
    }

    /// 結果の分からなかった送信について、電話が机の履歴を取り直している間(DESIGN §2.52)。
    ///
    /// `isSending` と分ける理由は意味が違うから —— あちらは要求が飛んでいる間、
    /// こちらは**飛び終わったが届いたか分からない間**。だが `canSend` には同じ様に
    /// 効かせる: この窓の中で2通目を許すと、1通目が実は届いていた時に**二重配達**を
    /// 作る。`POST /messages` に冪等鍵は無い(`server.mjs` 実測)ので、二重は本当に
    /// 二重になる。
    ///
    /// 割り込みと打鍵には同じ錠を掛けていない。打鍵は同じ指紋の再送を
    /// `inject.mjs` が `choice-already-sent` で断るので二重打鍵にならず、割り込みは
    /// 二重に効いても Escape が2回行くだけだから。**錠は害の在る所にだけ掛ける。**
    @Published private(set) var isVerifyingSend = false

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
    private let interruptClient: Interrupting
    private let attachClient: Attaching
    private let choiceClient: ChoiceSending
    private let clearQueueClient: QueueClearing
    /// 打ちかけの置き場(DESIGN §2.53)。**既定値を持たせていない** —— 既定を本物に
    /// すると、`RootView` の UI 検査用の面が黙って実機の `UserDefaults` を触る。
    /// 本番は `ListView` だけが `UserDefaultsDraftStore` を渡す。
    private let draftStore: DraftStoring
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

    /// ★`clients` に既定値が無いのは意図(2026-08-08)。以前は5つの口を別々に受け、
    /// うち4つの既定が**本物の client** だった —— つまり渡し忘れた口が黙って
    /// production の挙動になる形で、実際に2度そうなっている。全文は
    /// `ios/Sources/Core/ConversationClients.swift`。`draftStore` が既定を持たない
    /// 理由(下の註)と同じ判断を、残りの口へ広げただけ。
    init(
        clients: ConversationClients,
        draftStore: DraftStoring,
        baseURL: URL,
        apiKey: String,
        sessionID: String,
        title: String,
        onUnauthorized: @escaping () -> Void,
        initialLimit: Int = ConversationViewModel.initialLimit
    ) {
        self.client = clients.history
        self.pollClient = clients.poll
        self.sendClient = clients.send
        self.interruptClient = clients.interrupt
        self.attachClient = clients.attach
        self.choiceClient = clients.choice
        self.clearQueueClient = clients.clearQueue
        self.draftStore = draftStore
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.sessionID = sessionID
        self.title = title
        self.onUnauthorized = onUnauthorized
        self.currentLimit = initialLimit

        // 打ちかけの復元(DESIGN §2.53)。`didSet` は init 内では発火しないので、
        // ここで書き戻しは起きない —— 開き直すだけで時刻が若返る型を、呼ぶ側でも
        // 踏まない形にしてある。
        self.draft = draftStore.load(sessionID: sessionID) ?? ""
    }

    func load() async {
        let result = await client.fetch(baseURL: baseURL, apiKey: apiKey, sessionID: sessionID, limit: currentLimit)
        applyInitial(result)
    }

    func applyInitial(_ result: Result<HistoryResponse, SessionsFetchError>) {
        switch result {
        case .success(let response):
            reachability.recordSuccess()
            history = response.history
            truncated = response.truncated
            phase = .loaded
            // 初回は無条件に一番下。50件の履歴を一番古い行から見せられても、
            // 「机で今どうなっているか」を知る為に開いた画面としては役に立たない。
            tailToken += 1
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
            // Counted (§5-4) as well as phased. The two are not redundant: `.unreachable`
            // as a PHASE means "the initial load never produced a screen, so there is
            // nothing to show"; the meter is what the banner over an *already-loaded*
            // screen reads, and a load failure is exactly as much evidence about the
            // backend as a poll failure is.
            reachability.recordFailure()
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

        // ★取るのは**送る前**。送信が飛んでいる間に poll が机からの追記を運んで来る
        // 事が在り、後で取ると「送る前から在った行」と「送った結果として出た行」が
        // 混ざる。差分で観測する意味がそこで消える(DESIGN §2.52)。
        let entriesBeforeSend = entries

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
        if applySendOutcome(outcome, sentText: text) {
            await verifySendByRereading(text: text, entriesBefore: entriesBeforeSend)
        }
    }

    /// Split out for the same reason as `applyInitial(_:)`: tests drive the classified
    /// outcomes directly rather than racing a real `Task`.
    ///
    /// ★戻り値 = **結果が分からなかったか**(DESIGN §2.52)。`true` を返した時、この
    /// method が置く帯は途中経過であって答えではない —— 呼んだ側は
    /// `verifySendByRereading` を回して、観測で置き換える義務が在る。文言と戻り値が
    /// 同じ義務を指しているのはわざと: 片方だけ直しても噛み合わなくなる。
    ///
    /// `sentText` に既定値を置かないのは S8-8 の要点(下の `clearSentText(_:)`)。
    /// 「何を送ったか」を知らずに消す口が在ると、消す側は必ず全部消す方へ倒れる ——
    /// 既定を持たせない事で、呼ぶ側は毎回それを言う事になる。
    @discardableResult
    func applySendOutcome(_ outcome: SendOutcome, sentText: String) -> Bool {
        isSending = false

        switch outcome {
        case .cancelled:
            // Whoever cancelled owns the outcome: no banner, and above all no clearing
            // of the draft. Same rule as `SessionsFetchError.cancelled` everywhere else
            // in this app.
            //
            // 取り直しも回さない。取り消したのは呼んだ側で、その側が結果を持っている。
            return false

        case .unauthorized:
            // A ROUTE decision, decided from the status alone (brief §0-c ①). The draft
            // is deliberately left in place: the user is about to be sent to Key-entry
            // and back, and losing what they typed to a credentials round trip would be
            // the worst possible moment for it.
            //
            // 鍵が無い状態で `/history` を取り直しても同じ 401 が返るだけなので回さない。
            onUnauthorized()
            return false

        case .sessionNotFound:
            // The one 404 that means what it says. The whole screen is now invalid, not
            // just this send -- so it becomes the phase, exactly as a 404 on `/history`
            // does.
            //
            // 取り直す先の会話がもう無い。
            phase = .notFound
            return false

        case .contractViolation(let violation):
            // Deliberately NOT `applyContractViolation` -- this one does not become the
            // phase. On the load paths the unreadable response IS the screen's content,
            // so there is nothing left to show. Here the conversation is loaded, the
            // poll loop is live, and the desk may well have received the message: tearing
            // the screen down would destroy the one view the user needs in order to find
            // out. So it is recorded, logged, and shown as a banner over an intact screen.
            recordContractViolation(violation)
            sendBanner = SendBanner(
                locallyWorded: violation.displayText + Self.sendUnknownInterim,
                tone: .error
            )
            return true

        case .unreachable:
            // One of the places the phone words a banner itself, and it is allowed to
            // precisely because no `display` ever arrived. The wording refuses to claim
            // either outcome: a request whose response was lost may well have been
            // delivered, and "送れませんでした" would be a guess stated as a fact.
            sendBanner = SendBanner(locallyWorded: Self.sendUnknownInterim, tone: .warn)
            return true

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
                clearSentText(sentText)
            }
            return false
        }
    }

    /// 消すのは**送った分だけ**(2026-08-08、S8-8)。
    ///
    /// 見付かり方が此の method の存在理由なので残す:S8-7 で初めて「送信が飛んでいる
    /// 最中」の画面を撮り、その1枚に本文 `ping` が composer に残ったまま写っていた。
    /// 残るのは設計通り(`send()` の doc が言う「分類が終わるまで本文に触らない」)。
    /// 問題はその**次**で、`composerEnabled` は `isSending` を見ていないから、
    /// 飛んでいる 30 秒の間ずっと**打ち足せる**。そこで `draft = ""` を実行すると、
    /// 送った物ではなく**まだ送っていない物**まで消える。
    ///
    /// 大きさが違う2つの誤りのうち、`applySendOutcome` 自身が
    /// 「消してはいけない物を消すのは取り返しがつかない」と書いている方に当たる ——
    /// つまり此処は、あの節が既に決めていた規則が1箇所だけ実装されていなかった。
    ///
    /// 前置きが一致しない時(飛んでいる間に**途中**を書き換えた)は何も消さない。
    /// 消し損ねは画面に見えて手で消せるが、消し過ぎは戻せない。同じ非対称。
    private func clearSentText(_ text: String) {
        guard draft.hasPrefix(text) else { return }
        draft.removeFirst(text.count)
    }

    // MARK: - 結果が分からなかった時、電話が自分で取り直す(DESIGN §2.52)

    /// 途中経過の文。**答えではない** —— この後 `verifySendByRereading` が観測で
    /// 置き換える。「机の画面を確認してください」を落としたのがこの節の要点で、
    /// あの一文は「電話しか無い」場面でしか出ないのに机を唯一の回復手段にしていた。
    static let sendUnknownInterim = "Whether it sent is unknown. Your text is kept. Re-reading the desk history now…"
    static let interruptUnknownInterim = "Whether it stopped is unknown. Re-reading the desk history now…"
    static let choiceUnknownInterim = "Whether the key landed is unknown. Re-reading the desk history now…"

    /// ★`sendUnknownInterim` の**一つ手前**の段の文(DESIGN §2.54)。すぐ上に置いてあるのは、
    /// 2つの段が続けて起きるのに意味が正反対だから —— こちらは「まだ飛んでいる」、
    /// あちらは「飛び終わったが届いたか分からない」。同じ文を出すと段が見分けられなくなる。
    ///
    /// ★**秒数を直書きしない。** 実際の timeout を受け取って作る。
    /// `BackendSession.writeTimeout` は `pollTimeout` = `serverPollMaxWait + 10` で、
    /// `serverPollMaxWait` はサーバ側の定数の写し。この鎖のどこかが変わった時に、
    /// **文だけが古くなる**形にしない —— 電話が言った上限と実際の上限が違うのは、
    /// この節が直している当の病気(電話が観測していない事を言う)と同じ型。
    static func sendInFlightText(timeout: TimeInterval) -> String {
        "Sending… (waiting up to \(Int(timeout))s for the desk)"
    }

    /// ★2026-08-08(DESIGN §2.56): 割り込みと打鍵の、同じ段の文。
    ///
    /// **秒数の出所が送信と同じ `writeTimeout` なのは、測って決めた。** この節は当初
    /// 「割り込み/打鍵は `interactiveTimeout` = 8秒だから、文は要らないかもしれない」
    /// という前提で始まった。実測(`InterruptClient` / `ChoiceClient`)では両方とも
    /// `request.timeoutInterval = BackendSession.writeTimeout` で、8秒が使われているのは
    /// **読みだけ**(`healthz` / `history` / `sessions`)。`BackendSession` の doc が
    /// 理由まで書いている ——「Sends and interrupts keep the long timeout, deliberately.」
    ///
    /// この訂正で §2.54 の裁定がそのまま効く: 文の無いスピナが最大30秒続くのは
    /// 正常な待ちの見え方ではない。**判断ではなく、既に出た答えの適用。**
    ///
    /// 3つの文言を分けてあるのは、`sendInFlightText` が `sendUnknownInterim` と分かれて
    /// いるのと同じ理由 —— 同じ画面に3つの操作が在り、生き残った一文がどれの物か
    /// 読み手が判別できなくなる。動詞まで操作ごとに違えてある。
    static func interruptInFlightText(timeout: TimeInterval) -> String {
        "Asking it to stop… (waiting up to \(Int(timeout))s for the desk)"
    }

    static func choiceInFlightText(timeout: TimeInterval) -> String {
        "Sending your choice… (waiting up to \(Int(timeout))s for the desk)"
    }

    static let sendLandedText = "It landed (the re-read desk history contains this text). Your draft is kept — delete it if you don't need it."
    /// ★「届いていません」とは書かない。取り直しに成功して行が無くても、机の側で
    /// まだ処理中の可能性は消えていない。**電話は自分が見た物だけを言う。**
    static let sendNotOnDeskText = "It isn't on the desk right now. Your text is kept. You can send again."
    static let sendStillUnreachableText = "Still unreachable. Whether it sent is unknown. Your text is kept."
    /// ★3つ目の答え。取り直しには成功したが、送る前の記録と1行も重ならなかった時
    /// (机側の圧縮や `/clear` で記録が丸ごと入れ替わると起きる)。
    ///
    /// ここを `sendNotOnDeskText` に潰してはいけない。あの文は「机に無い」と断言した上に
    /// 「もう一度送れます」で再送 = 二重配達を勧める。電話は境目を見失っていて、机に
    /// 在るとも無いとも言えない —— **見ていない事は言わない**が §2.52 の全部。
    ///
    /// ★次の一手の宛先が**電話の画面**である事も要点。この節が落とした一文
    /// (「机の画面を確認してください」)は、電話しか無い場面で机を指していた。
    /// 置き換えた先が同じ性質だったら直した事にならない。
    static let sendCannotTellText =
        "The re-read history shares no lines with what was there before sending, so delivery couldn't be told apart. "
        + "Above is the re-read history. Your text is kept — if it isn't up there, send again."

    /// 送信の結果が分からなかった直後の観測(DESIGN §2.52)。
    ///
    /// ★本文は**どちらに転んでも消さない**。外した時の費用が対称でない: 消して外すと
    /// 本文を失った上に届いたと思い込む(二重の失敗)。残して外すと要らない一文が
    /// composer に残るだけ。`keepText` の非対称と同じ向き。
    private func verifySendByRereading(text: String, entriesBefore: [HistoryEntry]) async {
        isVerifyingSend = true
        defer { isVerifyingSend = false }

        guard await performResync() else {
            sendBanner = SendBanner(locallyWorded: Self.sendStillUnreachableText, tone: .warn)
            return
        }

        // ★3分岐。`nil`(見分けられない)を `false` 側へ寄せない為に `switch` で書く
        // —— `if let` や `?? false` は「分からない」を静かに「無い」に潰す形で、
        //    その潰れ方が二重配達を勧める向きに出る(`sendCannotTellText` 参照)。
        switch MergeHistory.landed(text: text, before: entriesBefore, after: entries) {
        case .some(true):
            sendBanner = SendBanner(locallyWorded: Self.sendLandedText, tone: .ok)
        case .some(false):
            sendBanner = SendBanner(locallyWorded: Self.sendNotOnDeskText, tone: .warn)
        case .none:
            sendBanner = SendBanner(locallyWorded: Self.sendCannotTellText, tone: .warn)
        }
    }

    /// 割り込み・打鍵の側。**送信と違って「効いたか」は主張しない。**
    ///
    /// 観測できる物が、別の理由で同じ値を取るから —— 机の面が `BUSY` を離れるのは
    /// 机の人が止めた時も同じで、設問の指紋が変わるのは机が次の設問へ進んだ時も同じ。
    /// だから此処で言えるのは「取り直した」という事実と、取り直した後の記録だけ。
    /// **弱いが嘘でない答え**であって、強い嘘ではない。
    private func verifyByRereading(
        interrupted: Bool
    ) async -> String {
        let resynced = await performResync()
        if !resynced {
            return interrupted
                ? "Still unreachable. Whether it stopped is unknown."
                : "Still unreachable. Whether the key landed is unknown."
        }
        return interrupted
            ? "Whether it stopped is unknown. The desk history was re-read — what's above is the re-read record."
            : "Whether the key landed is unknown. The desk history was re-read — what's above is the re-read record."
    }

    // MARK: - Interrupt (Sprint 6, brief §2-b)

    /// One interrupt attempt. Nothing is sent in the body and nothing local is
    /// staked on the outcome, so this is much simpler than `send()` -- there is no
    /// draft to protect and no `keepText` rule.
    /// 写真を机へ渡す。2026-08-26。
    ///
    /// ★結果の**言い換えをここでしない**。`AttachWording` が1箇所で持つ。
    ///   置けたが入力欄に載らなかった状態が実在するので、それを「送れました」に
    ///   丸める場所を1つも作らない。
    ///
    /// ★履歴の再読み込みもしない。パスは入力欄に**載っただけ**で、まだ送っていない
    ///   = 転写には何も増えていない。読み直すと「何も変わっていない」を
    ///   「効かなかった」と読ませる余地を作る。
    func attach(image: Data) async -> AttachOutcome {
        await attachClient.attach(baseURL: baseURL, apiKey: apiKey, sessionID: sessionID, image: image)
    }

    func interrupt() async {
        guard canInterrupt else { return }

        isInterrupting = true
        // Same reason `send()` clears `sendBanner` on entry: leaving the previous
        // attempt's sentence visible under an in-flight one lets a stale
        // 「止めました」 be read as this attempt's answer.
        interruptBanner = nil

        let outcome = await interruptClient.interrupt(baseURL: baseURL, apiKey: apiKey, sessionID: sessionID)
        if applyInterruptOutcome(outcome) {
            interruptBanner = SendBanner(
                locallyWorded: await verifyByRereading(interrupted: true),
                tone: .warn
            )
        }
    }

    /// Split out for the same reason as every other `apply…` on this type.
    ///
    /// ★The `.display` arm is one line, and that is the design. Whether the generation
    /// actually stopped is a distinction the server makes along two axes -- the outcome
    /// (`verified` / `already-done` / `unverified` / `null`, plus `refused`) and, since
    /// 2026-08-08, the *route*, because the two routes press different things: tmux
    /// presses Escape, the worker sends a stop signal to a child process. The server
    /// renders every combination into its own sentence -- covered branch by branch in
    /// `test/view.test.mjs`. The phone re-deriving any of it would rebuild the bug the
    /// server fixed on 2026-08-03 (tmux route) and again on 2026-08-08 (worker route),
    /// when "Escape was pressed" was being reported as 「止めました」 -- on the worker
    /// route, where Escape is never pressed at all.
    /// 戻り値は `applySendOutcome` と同じ意味 —— `true` = 結果が分からなかったので、
    /// 呼んだ側が取り直しを回して帯を置き換える(DESIGN §2.52)。
    @discardableResult
    func applyInterruptOutcome(_ outcome: SendOutcome) -> Bool {
        isInterrupting = false

        switch outcome {
        case .cancelled:
            return false

        case .unauthorized:
            onUnauthorized()
            return false

        case .sessionNotFound:
            phase = .notFound
            return false

        case .contractViolation(let violation):
            // Same call as the send path's, and for the same reason: the conversation
            // is loaded and the desk may well have received the Escape, so tearing the
            // screen down would destroy the one view that could show it.
            recordContractViolation(violation)
            interruptBanner = SendBanner(
                locallyWorded: violation.displayText + Self.interruptUnknownInterim,
                tone: .error
            )
            return true

        case .unreachable:
            // Worded locally, permissibly, because no `display` arrived. It refuses to
            // claim either outcome for the same reason the send path's does: a request
            // whose response was lost may well have been delivered.
            interruptBanner = SendBanner(locallyWorded: Self.interruptUnknownInterim, tone: .warn)
            return true

        case .display(let display):
            interruptBanner = SendBanner(display: display)
            return false
        }
    }

    // MARK: - Choice (answering the desk's menu from the phone)

    /// One keystroke in flight, **and which key it is**. Its own state, not `isSending`:
    /// the composer and the menu are never both live (the composer is disabled on
    /// `CHOICE`), but sharing a flag would still mean a future screen that enabled both
    /// could disable the wrong control.
    ///
    /// ★2026-08-08(§2.56): `Bool` から `String?` に**置き換えた**(足したのではない)。
    /// 画面が「押した鍵だけを回す」為に鍵が要るが、`Bool` と鍵を両方持つと
    /// 「飛んでいる事」の真実が2箇所になり、片方だけ倒れる版が書ける。
    /// `isChoosing` は下の computed として残してあるので、読む側の意味は変わらない。
    @Published private(set) var inFlightChoiceKey: String?

    /// 「今どれかの鍵が飛んでいる」だけを聞きたい側の口。**保持しない** ——
    /// 唯一の真実は `inFlightChoiceKey` で、これはその読み方の一つでしかない。
    var isChoosing: Bool { inFlightChoiceKey != nil }

    /// Its own band, for `interruptBanner`'s reason: three operations, three answers,
    /// and no way for the reader to tell whose sentence survived if they share a slot.
    @Published private(set) var choiceBanner: SendBanner?

    /// The fingerprint of a card we KNOW the desk has moved past, because the server
    /// answered a keystroke aimed at it by naming a different one.
    ///
    /// Stored as the digest rather than a `Bool` so that it expires by itself: the card
    /// is stale exactly while `choiceView?.digest` still equals this, and the next poll
    /// carrying any other fingerprint makes the comparison false with no bookkeeping.
    /// A `Bool` would need a second site to clear it, and the site that forgets to
    /// clear a safety flag is the one that leaves the phone permanently mute.
    @Published private(set) var staleChoiceDigest: String?

    /// The card the screen is allowed to draw. **The single place that decides whether a
    /// menu card exists**, so the view, the composer sentence and the interrupt sentence
    /// cannot each answer that question differently.
    ///
    /// Two terminators, not one. `show: false` is the server's, and on the healthy
    /// protocol it always arrives: `server.mjs` emits `screen` and `display.choice`
    /// under the *same* `screenChanged` condition, so a revision that leaves `CHOICE`
    /// carries a `choiceView` of the empty screen with it. The second is this phone's
    /// own: **a card is a lie the moment the last screen we observed says the desk is
    /// not on a menu**, whatever the card itself claims.
    ///
    /// ★Asked for by Codex (2026-08-08, question (a)) as contract fragility rather than a
    /// live bug, and worth taking for exactly that reason -- it costs one comparison and
    /// removes the phone's dependence on a server invariant it cannot verify. A card
    /// stranded visible after an outage is the failure it prevents: buttons over a desk
    /// that has long since moved on.
    ///
    /// **Absence is not contradiction.** `screen == nil` (nothing observed yet) leaves the
    /// card alone: the card came FROM the server, so hiding it on no evidence would be
    /// the phone inventing a state, and hiding the desk's own question from the person
    /// being asked to go read it is the one thing the hard-stop path must never do.
    var visibleChoice: ChoiceView? {
        guard let card = choiceView, card.show else { return nil }
        if let screen, screen.classification != .choice { return nil }
        return card
    }

    /// Whether the menu's buttons do anything.
    ///
    /// Four independent gates, and none of them decides WHICH keys are offered -- that
    /// is `buttons`, computed server-side. These only decide whether the offered set is
    /// live right now.
    var choiceEnabled: Bool {
        guard let card = visibleChoice, card.canPress else { return false }
        return card.digest != staleChoiceDigest && !isChoosing
    }

    /// Shown in place of the buttons when the card is stale. Locally worded, which is
    /// permitted here for `composerDisabledReason`'s reason: this describes the phone's
    /// own UI state, not a server response, so no `display.text` exists to render.
    var staleChoiceReason: String? {
        guard let card = visibleChoice, card.canPress,
              card.digest == staleChoiceDigest else { return nil }
        return "The desk screen changed. Keys are disabled until the new options arrive"
    }

    /// One keystroke.
    ///
    /// ★`key` and `digest` are both echoed from what the server itself handed us -- the
    /// key from a `ChoiceButton` in `buttons`, the digest from the same `ChoiceView`
    /// that carried it. Nothing on this path composes either. That is what carries the
    /// server's guarantee 見た物と押す物が同じ across the wire: the fingerprint travels
    /// with the button it was drawn beside, so a menu that changed between the draw and
    /// the tap is refused rather than answered.
    /// 危険な承認で「構えた」状態。★**指紋ごと**持つ —— 画面が変われば構えは無効で、
    /// 別の画面のボタンを押した時に古い構えが効いてしまう事を防ぐ。
    @Published private(set) var armedDangerDigest: String?

    /// 構え直しを促す1文。サーバが返した理由をそのまま使い、電話で作文しない。
    @Published private(set) var dangerNotice: String?

    /// 今この鍵は「押せば実行」か「押せば構えるだけ」か。★画面に出す文がこれで決まる。
    func isArmed(for digest: String) -> Bool { armedDangerDigest == digest }

    func disarmDanger() { armedDangerDigest = nil; dangerNotice = nil }

    func choose(key: String) async {
        guard choiceEnabled, let card = visibleChoice else { return }
        // The key must be one the server offered. A tap can only originate from a
        // drawn button, so this is unreachable through the UI -- it exists because the
        // day something else calls this method, the failure it prevents is sending an
        // unoffered keystroke to a permission prompt.
        guard card.buttons.contains(where: { $0.key == key }) else { return }

        let sentDigest = card.digest
        inFlightChoiceKey = key
        choiceBanner = nil

        // ★危険な画面は1タップで通さない(2026-08-26)。構えていなければ、
        //   この tap は**構えるだけ**でサーバへは行かない。指紋に束ねてあるので、
        //   構えた後に画面が変われば次の tap も通らない(サーバ側の指紋検査が断る)。
        let currentDigest = visibleChoice?.digest ?? ""
        let isDanger = visibleChoice?.risk.isDanger == true
        if isDanger && !isArmed(for: currentDigest) {
            armedDangerDigest = currentDigest
            dangerNotice = visibleChoice?.risk.notice ?? "This action is hard to undo."
            return
        }
        let confirmValue = isDanger ? currentDigest : nil
        defer { disarmDanger() }

        let attempt = await choiceClient.choose(
            baseURL: baseURL,
            apiKey: apiKey,
            sessionID: sessionID,
            key: key,
            digest: sentDigest,
            confirm: confirmValue
        )
        if applyChoiceAttempt(attempt, sentDigest: sentDigest) {
            choiceBanner = SendBanner(
                locallyWorded: await verifyByRereading(interrupted: false),
                tone: .warn
            )
        }
    }

    /// Split out for the same reason as every other `apply…` on this type.
    ///
    /// ★★**No auto-retry, ever.** The server attaches the live fingerprint to a refusal
    /// precisely so a client can recover without re-capturing the screen, and the
    /// obvious use of it -- resend the same key with the fresh digest -- is the one
    /// thing this method must not do. It would mean the phone answering a menu Tom has
    /// not seen, which is 「自動化に安全確認を押させない」 read at its actual meaning:
    /// the rule is about who did the deciding, not about which process typed. Recovery
    /// is therefore: mark the card stale, let the poll deliver the new one, and wait for
    /// a second deliberate tap.
    ///
    /// 戻り値は `applySendOutcome` と同じ意味 —— `true` = 結果が分からなかったので、
    /// 呼んだ側が取り直しを回す(DESIGN §2.52)。★取り直しは**読むだけ**なので、
    /// 上の「再送しない」規則とは衝突しない。同じ鍵をもう一度打つのは自動化が
    /// 安全確認に答える事だが、履歴を読み直すのは机に何も起こさない。
    @discardableResult
    func applyChoiceAttempt(_ attempt: ChoiceAttempt, sentDigest: String) -> Bool {
        // ★飛んでいる文が消えるのはここ。残せば「答えの顔をした待ち」になる ——
        // この行を消す変異が §2.56 の対照で一番要る錨。
        inFlightChoiceKey = nil

        // Behaviour binds to the fingerprint, never to the refusal vocabulary -- see
        // `ChoiceAttempt`'s ★. A server that says nothing about the current screen
        // (`serverDigest == nil`) has given no information, and silence is not
        // confirmation that the card still stands.
        if let served = attempt.serverDigest, served != sentDigest {
            staleChoiceDigest = sentDigest
        }

        switch attempt.outcome {
        case .cancelled:
            return false

        case .unauthorized:
            onUnauthorized()
            return false

        case .sessionNotFound:
            phase = .notFound
            return false

        case .contractViolation(let violation):
            // Same call and same reasoning as the send and interrupt paths: the
            // conversation is loaded and the desk may well have received the keystroke,
            // so this becomes a banner over an intact screen, not the phase.
            recordContractViolation(violation)
            choiceBanner = SendBanner(
                locallyWorded: violation.displayText + Self.choiceUnknownInterim,
                tone: .error
            )
            return true

        case .unreachable:
            // The third and last locally-worded site, permitted because no `display`
            // arrived. It refuses to claim either outcome for the reason the other two
            // give: a request whose response was lost may well have been delivered.
            //
            // The card is deliberately NOT marked stale here -- we learned nothing
            // about the desk. Pressing again is safe by construction: the second
            // request carries the same fingerprint, and `inject.mjs` refuses a repeat
            // on a fingerprint it has already answered (`choice-already-sent`), so a
            // double press cannot become a double keystroke.
            choiceBanner = SendBanner(locallyWorded: Self.choiceUnknownInterim, tone: .warn)
            return true

        case .display(let display):
            // Verbatim. `view.mjs`'s `choiceResult` already splits the four values of
            // `applied` (`verified` / `unverified` / `moved-to-hard-stop` / null) into
            // four sentences, and got that split wrong once by writing `=== false`
            // against a string. Re-deriving any of it here would rebuild that bug on
            // this side of the wire.
            choiceBanner = SendBanner(display: display)
            return false
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
            // ★ここで `tailToken` は進めない。進めると「以前を読む」を押した直後に
            // 一番下へ引き戻される。代わりに、足す前に一番古かった行の新しい位置を
            // 出して、そこを画面の下端に置いてもらう。
            //
            // 位置は `MergeHistory.sameRoleAndText` で引く -- `advanced` の判定
            // (`sameOldest`)と同じ比較器を使う為。ここだけ別の「同じ行」の定義を
            // 作ると、片方が進んだと言い、片方が見つからないと言う状態が作れる。
            if advanced, let oldestBefore {
                earlierRevealIndex = history.firstIndex {
                    MergeHistory.sameRoleAndText($0, oldestBefore)
                }
                // 見つからない事は在り得る(同じ本文が複数在れば最初に当たるし、
                // 併走する会話で古い端が削れていれば消えている)。その時は札を
                // 進めない = 画面は動かない。誤った場所へ飛ばすより動かない方が良い。
                if earlierRevealIndex != nil { earlierRevealToken += 1 }
            }
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
            // ★An unreadable poll is a **reachability SUCCESS**, not "no evidence" and
            // certainly not a failure. `PollClient` only reaches `.unreadable` after a
            // 200 has already arrived and been read off the wire, which is direct proof
            // of the one thing §5-4 measures (接続不可・タイムアウト・5xx -- none of
            // which happened). The backend is reachable; it is talking nonsense, which
            // is §5-5's meter's job on the next line.
            //
            // Counting it as a failure here would be exactly the substitution the spec
            // forbids by name -- 「片方をもう片方で代用しない —— 代用した瞬間、200 で
            // 返る壊れた配信が『接続は健全』に見える」 -- run in the other direction: a
            // shape regression on the server would be reported to the user as a network
            // problem, sending them to check their signal instead of the deploy.
            reachability.recordSuccess()
            unreadableMeter?.markUnreadable()
            publishUnreadableState()
            maybeAutoResync()
            return true
        case .unauthorized:
            onUnauthorized()
            return false
        case .sessionNotFound:
            // The conversation ended (or was deleted) while this screen was watching
            // it. Same destination as a 404 on the initial load and on "load earlier"
            // -- one phase for one fact, reached from all three doors.
            //
            // Returning `false` is the substance of the fix, not `phase` alone: with
            // `true`, the screen would say 「この会話は見つかりません」 while a loop
            // underneath it kept asking a dead session for updates, with `Backoff`
            // stretching the interval forever. A phase that says "gone" over a loop
            // that behaves like "maybe not" is the same class of contradiction the
            // `.unreadable` arm above refuses.
            phase = .notFound
            return false
        case .unreachable:
            // `Backoff.attempt` already advanced inside `PollLoop`; §3-a: a transport
            // failure must not touch `UnreadableMeter` in either direction.
            //
            // §5-4 (Sprint 6): it does touch `reachability`. This is the arm that used
            // to return `true` and change nothing at all, which is how a phone that
            // had lost the backend went on showing a stale conversation in silence.
            reachability.recordFailure()
            return true
        }
    }

    private func applyReadablePoll(_ response: PollResponse) {
        // §5-4: 「1回でも HTTP 成功」 clears the reachability banner immediately. Note
        // the asymmetry with the line below -- reachability resets on any 200 that got
        // this far, whereas §5-5's meter resets only on a successful MERGE. They are
        // measuring different things and their reset conditions differ accordingly.
        reachability.recordSuccess()

        // §2-a step 5: this -- a successful merge, not merely "got a 200" -- is the
        // only place the meter resets.
        unreadableMeter?.markReadable(now: Date())
        publishUnreadableState()
        resyncEpisodeUsed = false // streak back to 0 ends the episode (§3-c)

        // Queue(v2): `queued` は null-hold の**対象外** —— null は「据え置き」ではなく
        // 「観測できない」という値なので、poll ごとに其のまま上書きする(§2-c の規約が
        // screen / choice に限る理由ごと `QueueViewState` の頭に書いてある)。
        // band は数が**変わった**時に流す(choiceBanner が digest の変化で流れるのと
        // 同じ「答えの相手が動いたら残さない」)。
        if response.queued != queuedCount {
            queueBanner = nil
        }
        queuedCount = response.queued
        queuedFetchedAtMs = Date().timeIntervalSince1970 * 1000

        // §2-c: null = hold the previous value, for `screen` and `display.choice`
        // alike, applied here in the one shared spot the brief asks for.
        if let newScreen = response.screen {
            screen = newScreen
        }
        if let newChoice = response.display?.choice {
            // The banner is the answer to a keystroke aimed at ONE fingerprint; once the
            // desk has moved to a different one, leaving 「押しました」 under a freshly-drawn
            // menu invites the reader to attribute an old answer to a new question. So it
            // expires on a CHANGED fingerprint, and only then -- an identical menu coming
            // back is still the question that press was about.
            if newChoice.digest != choiceView?.digest {
                choiceBanner = nil
            }

            // ★The stale mark expires on a DIFFERENT signal: the mere arrival of a payload,
            // whatever fingerprint it carries. The two questions are not the same one --
            // banner = 「私の直前の打鍵に何が起きたか」, stale = 「今この瞬間、机に出ているのは
            // この面か」-- and the second is answered in full by any fresh observation.
            //
            // It used to expire on a changed fingerprint too, which **deadlocks on A→B→A**
            // (Codex, 2026-08-08): the desk leaves menu A and returns to a byte-identical A
            // between two polls, the phone never observes B, so the digest that arrives
            // equals the one it marked stale and the card stays dead permanently -- under a
            // sentence (「机の画面が変わりました」) that is false by then. The monotonic screen
            // revision that would tell A-then-A apart from A-still lives inside the cursor,
            // which this client is contractually forbidden to parse (see `PollCursor`), and
            // it does not need it: **arrival is itself the new observation**, because
            // `server.mjs` gates `screen` and `display.choice` on the same `screenChanged`.
            //
            // Nothing safety-bearing is given up. All a 409 ever taught the phone is that
            // the live screen was not the one on display -- that refusal's own wording is
            // 「何も送っていません」, so the menu, when it comes back, is genuinely unanswered.
            // And what stops a revived button from re-answering a menu that WAS answered is
            // not this flag and never was: `inject.mjs` refuses a second keystroke to a
            // spent fingerprint (`choice-already-sent`) and the phone renders that refusal
            // verbatim. A client-side copy of a server-side rule only buys a second place
            // to drift.
            //
            // Still a digest rather than a `Bool`: it names WHICH card it condemns, so the
            // stale sentence cannot appear under a card it does not refer to even if some
            // future path assigns `choiceView` without passing through here.
            staleChoiceDigest = nil

            choiceView = newChoice
        }

        var needsHistoryRefetch = false
        for item in response.items {
            switch item {
            case .message(let message):
                if let entries = message.entries, !entries.isEmpty {
                    live.append(contentsOf: entries)
                    // 末尾が伸びた。空配列で進めないのは、進んだ札が
                    // 「見る物が増えた」以外の意味を持たない為。
                    tailToken += 1
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
    ///
    /// ★4つ目の呼び出し元が 2026-08-08 に足された(DESIGN §2.52): 送信 / 割り込み /
    /// 打鍵の**結果が分からなかった直後**。その経路だけが戻り値を読む —— 取り直し
    /// 自体が失敗した時に「今の机には出ていません」と言うと、見ていない物を言う事に
    /// なるから。既存の3経路は `@discardableResult` で今まで通り。
    @discardableResult
    private func performResync() async -> Bool {
        let result = await client.fetch(baseURL: baseURL, apiKey: apiKey, sessionID: sessionID, limit: currentLimit)
        guard case .success(let response) = result else {
            // No distinct UI state is specified for "the resync's own /history call
            // itself failed" (brief doesn't name one) -- fail soft: keep whatever
            // `history` currently holds, and the still-running poll loop's next
            // successful response keeps merging against it. Noted as a judgment call
            // in progress.md.
            return false
        }
        history = response.history
        truncated = response.truncated
        live = []
        // 復帰は初回と同じ扱い。背面に居た間に机が進んでいるのが普通なので、
        // 戻って来た人が最初に見るべきは一番下。
        tailToken += 1
        await pollLoop?.resetForResync()
        return true
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
