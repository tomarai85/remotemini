import Foundation
import os

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
        ///
        /// ★`reason` / `detail` は**載せない**(2026-08-08 / 監査 S8-22)。以前は其の2つを
        /// 載せていて、`ListView` が見出しに `panes-unreadable`、本文に生の JS エラー文を
        /// そのまま描いていた。直しを「View で描く物を替える」で済ませなかったのは、
        /// 生の値が相に載っている限り**次に描く人が同じ事を書ける**から。相が読める文しか
        /// 持たなければ、View に選択肢が無い。落とし所(サーバが説明を送らない古い版)は
        /// `SessionsResponse.PaneFault.bannerDisplay` の1箇所だけに在る。
        case paneFault(headline: String, body: String, sessions: [SessionRow], scanLine: String)
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

        /// 机側が返した走査の行。持っていない相(まだ一度も成功していない / 取得に失敗した)
        /// では `nil`。
        ///
        /// ★此処に置いた理由(2026-08-08 / 監査 X2-7)。`ListView` は帯を各 case の中で
        /// 個別に貼っていて、6つのうち3つ(`.empty` / `.paneFault` / `.list`)にしか
        /// 付いていなかった —— **失敗している時だけ帯が消える**形になっていた。
        /// 帯は版の名乗りも載せるので、「古いビルドで動いていないか」を最も疑う場面で
        /// 版が見えない、が起きる。
        ///
        /// 直しを「残り3つにも貼る」で済ませなかったのは、それが**次に case を足す人が
        /// 憶えていなければ再発する**形だから。相の側に走査行を持たせて `ListView` が
        /// 帯を一度だけ貼れば、新しい case は「走査行が在るか」を答える以外に選択肢が無い。
        /// `default` を書かない事がその強制で、書いた瞬間に強制が消える。
        var scanLine: String? {
            switch self {
            case .initialLoading: return nil
            case .empty(let scanLine): return scanLine
            case .paneFault(_, _, _, let scanLine): return scanLine
            case .list(_, let scanLine): return scanLine
            case .retryable: return nil
            case .unreachable: return nil
            }
        }
    }

    /// Named constant, never a bare literal (brief §4-a): resolves the §5-4 vs §3-6
    /// numeric inconsistency in the spec: the brief author ruled 3 is correct.
    ///
    /// Sprint 6: the number and the counting now live in `ReachabilityMeter`, shared
    /// with Conversation per spec §5-4. This stays as a forwarding alias so the
    /// existing call sites and tests keep naming the threshold rather than the
    /// literal -- the thing the constant existed for in the first place.
    static var unreachableThreshold: Int { ReachabilityMeter.unreachableThreshold }

    @Published private(set) var phase: Phase = .initialLoading
    @Published private(set) var isRefreshing = false

    private let client: SessionsListing
    private let baseURL: URL
    private let apiKey: String
    private let onUnauthorized: () -> Void
    private let now: () -> Double

    /// Same subsystem/category as `ConversationViewModel`'s, on purpose: "how many
    /// response-contract violations did this app see today" must be one query, not two.
    private static let log = Logger(subsystem: "com.tomtim.mobilework", category: "contract")

    /// Spec §5-4's counter, shared with `ConversationViewModel` (Sprint 6). Readable
    /// so the View can print the live count in the banner -- the banner outlives the
    /// threshold, so "3回" frozen into the text would state a stale measurement as the
    /// current one. Redraw is not a problem: `phase` is `@Published` and is assigned
    /// on every failure, and `@Published` notifies on assignment regardless of whether
    /// the new value compares equal to the old.
    ///
    /// What List feeds it is a superset of §5-4's definition -- see `ReachabilityMeter`'s
    /// doc for why that is deliberate and what it costs.
    private(set) var reachability = ReachabilityMeter()
    private var lastResponse: SessionsResponse?
    /// ★既定を持たせるのは、既存の呼び出し 5 箇所を書き換えない為ではない ——
    ///   **本物の面が既定で本物の記憶を使う**事を型で保証する為。検査だけが差し替える。
    private let snoozeStore: UpdateSnoozeStoring

    /// 「机は新しい版を配っている」の一行。**文面はサーバが決める**(`wire.mjs` の
    /// `updateNotice`)ので、此処は運ぶだけ —— 加工すると、電話と机で別の事を言い出す。
    ///
    /// ★出す物が無ければ `nil`。**空文字にしない**(帯に空の警告が出る)。
    /// ★なぜ此の経路が要るか: CF-11 で私は「修正は反映済み」と報告したが、其の修正は
    ///   Tom が持っているどの版にも入っていなかった。CF-17 の実測では配布口に
    ///   `client=app` が1本も来ておらず、栞は一度も叩かれていない。
    ///   「新しい版が在る」を伝える経路が**私が思い出して言う**しか無かった。
    var updateNotice: String? {
        UpdateNoticeRule.visibleNotice(
            notice: lastResponse?.display.update,
            build: lastResponse?.display.updateBuild,
            snoozed: snoozeStore.snoozedBuild()
        )
    }

    /// 「此の版は後で」。★番号が判らない時は**憶えない** —— 鍵の無い記憶は、
    ///   何を黙らせたのか誰も判らないまま警報だけを消す。
    func snoozeUpdateNotice() {
        guard let build = lastResponse?.display.updateBuild, !build.isEmpty else { return }
        snoozeStore.snooze(build: build)
        objectWillChange.send()
    }
    /// epoch ms of the last *successful* fetch; `0` means "never." Read by the View
    /// via `lastFetchedAtMs` and fed to `Freshness.freshness`, re-evaluated at redraw
    /// time rather than on a timer (brief §2-2/§3-c: no poll loop this sprint).
    private(set) var lastFetchedAtMs: Double = 0

    init(
        client: SessionsListing,
        baseURL: URL,
        apiKey: String,
        onUnauthorized: @escaping () -> Void,
        now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 },
        snoozeStore: UpdateSnoozeStoring = UserDefaultsUpdateSnooze()
    ) {
        self.client = client
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.onUnauthorized = onUnauthorized
        self.now = now
        self.snoozeStore = snoozeStore
    }

    /// The single entry point for all **five** refresh triggers. Four are the brief's
    /// (§3-d): initial display / pull-to-refresh / foreground-resume / the retry
    /// button. The fifth is returning from a pushed `ConversationView` -- and it is
    /// the one that is **not written anywhere in `ListView`** (DESIGN §2.55, S8-5).
    ///
    /// ★5つ目の仕組み(2026-08-08 実測、推測ではない): SwiftUI は `NavigationStack` が
    ///   会話画面を push している間、覆われた `ListView` の `.task` を**中断**し、
    ///   pop した時に**もう一度走らせる**。だから取り直しは `.onDisappear` の様な
    ///   明示の1行ではなく、`.task { await viewModel.refresh() }` の生存期間その物から
    ///   出ている。つまり Sprint 3 で会話画面を足した日から既に在った ——
    ///   名前が無く、doc に無く、一度も測られていない引き金として。
    ///
    ///   測り方(単一検査を3通りで走らせて消去法):
    ///   | 配線                          | 戻った時の取得 |
    ///   |-------------------------------|---------------|
    ///   | `.task` + `.onDisappear` 追加 | **+2**(二重発火)|
    ///   | `.task` のみ(= 現状)        | **+1**        |
    ///   | どちらも無し                  | **+0**        |
    ///   S8-5 が最初に足そうとした `.onDisappear` の1行は、直しではなく二重発火だった。
    ///   それを掴めたのは UI 検査の主張が「番号が変わった」ではなく
    ///   **ちょうど +1** だったから —— `!=` で書いていたら緑で通って、机側には
    ///   戻るたびに2倍の走査が飛び続けていた。
    ///
    /// ★暗黙なので壊れ方も静か: `navigationDestination` への書き換え、初回取得を
    ///   `.task` から `.onAppear` や `init` へ動かす整理、`ListView` を
    ///   `NavigationStack` の外へ出す変更 —— どれも「取り直しを消した」と気付かずに
    ///   5つ目を殺せる。画面上は何も変わらない(古い一覧が古いまま出るだけ)。
    ///   だから配線ではなく**振る舞い**の側に錨を打った:
    ///   `ios/tools/list-return-refresh-control.sh` が、`.task` を外すと検査が赤に
    ///   なる事を実測で示す。
    ///
    /// 5つ目だけ性質が違う: 1-4 は「古いかもしれない」= 時間由来、5 は「変わったと
    /// 分かっている」= 因果由来。だから鮮度(`Freshness`)で門番させてはいけない ——
    /// Tom が机側で何かした直後こそ `stale` は false なので、門番は必ず一番要る瞬間に
    /// 黙る。
    ///
    /// ★引き金 #3(背面から戻る)も同じ日に測って、**両側とも壊れていた**事が判った。
    ///   数え上げの doc を信じて配線を見なかったら、5つ目を足して終わっていた:
    ///   - 一覧側は `oldPhase` を捨てて `.active` に着いた事だけを見ていたので、
    ///     iOS が起動を `.inactive -> .active` で通す分と `.task` の初回取得が重なり、
    ///     **起動のたびに2回**机側へ走査を飛ばしていた(通知バナーや Control Center の
    ///     上下でも同じ = 電話では1日に何度も)。
    ///   - 会話側は Sprint 4 で `oldPhase == .background && newPhase == .active` を
    ///     置いていたが、iOS はその辺を**一度も配らない**(復帰は `background ->
    ///     inactive -> active` の2段)。つまり会話画面の N4 は Sprint 4 から
    ///     一度も発火していなかった —— 単体2本と変異2本が緑を出したまま。
    ///   直しは条件の借用ではなく `ForegroundResume`(履歴を憶える器)の共有。
    ///   実測列と「なぜ4本の緑が素通りしたか」はその型の doc に全文。
    ///
    /// ★この doc は 2026-08-08 まで「there is no fifth trigger, and in particular no
    ///   "return from Conversation": that screen does not exist yet」と書いてあった。
    ///   会話画面は Sprint 3 で出来ている。書いた当時は正しかった事実が、5 sprint
    ///   そのまま残って嘘になった —— **引き金を数え上げる doc は、画面が増えた日に
    ///   嘘になる形をしている**。数を維持する責任を人からも外す為に、上の錨を置いた。
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
    /// 「保存された宛先へ届かなかった」を**1回だけ**外へ知らせる口(2026-08-27)。
    /// 机が別の機体へ引っ越した時、電話が古い宛先を握ったまま詰むのを外側が解く為。
    /// ★1回だけなのは、乗り換えても駄目な時に無限に蒔き直す輪を作らない為。
    var onUnreachable: (() async -> Void)?
    private var toldUnreachable = false

    func apply(_ result: Result<SessionsResponse, SessionsFetchError>) {
        switch result {
        case .success(let response):
            // Brief §4-a: ANY HTTP 200 resets the counter, regardless of paneFault.
            reachability.recordSuccess()
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

        case .failure(.contractViolation(let violation)):
            // `SessionsClient` really does produce this one (every 404 on `/api/sessions`
            // is a path the server does not serve), so unlike `.notFound` below this is
            // not a compile-only arm.
            //
            // It still counts as an ordinary failure HERE, because the List screen has
            // no per-error display vocabulary -- it shows one failure surface, tracked
            // by a counter, and inventing a second one is Sprint 5's §1-b "何も足さない".
            // What it does NOT do is stay silent: the log line is the countable half of
            // brief §0-c ③, and it is the only reason a wrong-path bug on this route is
            // distinguishable from the backend being down. Recorded in progress.md as
            // the one place a contract violation is currently visible only in the log.
            Self.log.error(
                "response contract violation: status=\(violation.status, privacy: .public) code=\(violation.code ?? "-", privacy: .public)"
            )
            reachability.recordFailure()
            phase = failurePhase()

        // ★`.anchorGone` は錨の窓(`HistoryClient.around`)だけが作る値で、一覧の口は 409 を返さない。
        //   到達しない分岐だが、網羅を崩さない為に置く —— `default` に逃がすと、次に生えた case が
        //   黙って「届かない」の顔で一覧に出る(此の file が `.notFound` で既に踏んだ形)。
        case .failure(.unreachable), .failure(.malformedBody), .failure(.notFound), .failure(.anchorGone):
            if !toldUnreachable, let tell = onUnreachable {
                toldUnreachable = true
                Task { await tell() }
            }
            // `.notFound` is Sprint 3's addition to the shared `SessionsFetchError`
            // taxonomy (brief §3-c) for Conversation's 404 -- `SessionsClient.fetch`
            // above never actually produces it (`/api/sessions` carries no session id
            // to 404 against), but the enum is shared, so this switch must still
            // handle every case to compile. Folded into the same opaque-failure
            // bucket as the other two: if a future server change ever did return 404
            // here, "nothing usable to show, count it" is still the right call.
            reachability.recordFailure()
            phase = failurePhase()
        }
    }

    private static func phase(for response: SessionsResponse) -> Phase {
        // paneFault is checked FIRST -- brief §4: never stack "no conversations"
        // underneath a paneFault banner, even when `sessions` is also empty.
        if let fault = response.paneFault {
            // ★`bannerDisplay` を通す(2026-08-08 / 監査 S8-22)。サーバが説明を送ってくる
            //   のが常だが、電話がサーバより新しい事は実際に起きている(edith が HEAD より
            //   古い版で走っていたのを観測済み)。落とし所を1箇所に置いてあるので、此処は
            //   在るか無いかを見ない。
            return .paneFault(headline: fault.bannerDisplay.headline, body: fault.bannerDisplay.body,
                              sessions: response.sessions, scanLine: response.display.scan)
        }
        if response.sessions.isEmpty {
            return .empty(scanLine: response.display.scan)
        }
        return .list(sessions: response.sessions, scanLine: response.display.scan)
    }

    private func failurePhase() -> Phase {
        let prior = lastResponse?.sessions
        if reachability.isUnreachable {
            return .unreachable(priorSessions: prior)
        }
        return .retryable(priorSessions: prior)
    }
}
