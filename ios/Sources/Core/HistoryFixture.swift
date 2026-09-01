import Foundation

#if DEBUG

/// DEBUG-only fixture data source for the Conversation screen, same pattern as
/// `SessionsListingFixture` (Sprint 2): selected via `RC_UI_FIXTURE`, holds no
/// hostname/URL, never touches the Keychain.
struct HistoryFetchingFixture: HistoryFetching {
    enum State: String {
        /// All 3 wire roles + a "load earlier" button in one screenshot -- brief
        /// §4-b's Simulator screenshot requirement.
        case threeRoles = "conversation-3roles"
        /// Sprint 4 brief §7 DoD item 6: the quiet 1-line staged-degradation banner
        /// (`UnreadableMeter.Stage.degraded`). History content is irrelevant to this
        /// screenshot -- reuses `threeRolesResponse` rather than a second literal --
        /// what makes the banner actually appear is `PollFetchingFixture`, selected
        /// off this same case in `RootView`.
        case degraded = "conversation-degraded"
        /// Sprint 4 brief §7 DoD item 6: the warning + `[再試行]`/`[読み直す]` banner
        /// (`UnreadableMeter.Stage.stalled`). Same reasoning as `.degraded`.
        case stalled = "conversation-stalled"
        /// 2026-08-06: the two screen classifications the composer/interrupt table
        /// actually turns on. Every state above drives `poll()` to `.unreadable`, so
        /// `screen` stays `nil` in all of them and the UI layer had **no** way to
        /// reach the rule Tom's ruling is about (「返答待ちであれ作業中であれいつでも
        /// 見て、干渉できればいい」). History content is irrelevant to both -- what
        /// makes them differ is `PollFetchingFixture`, selected off these same cases.
        case busy = "conversation-busy"
        /// The one classification that legitimately takes the composer away, and the
        /// only place `interruptAllowedOnChoiceScreen` is observable end-to-end.
        ///
        /// Sprint 7 re-pointed this at the **hard-stop** shape: `show: true` with the
        /// menu text intact, `buttons: []`, and `view.mjs`'s own refusal in `reason`.
        /// It previously sent a card with neither a digest nor buttons, which is a
        /// state the server emits only for an unparseable menu -- so the fixture that
        /// existed to prove 「自動化に安全確認を押させない」 was standing on the wrong
        /// screen for it.
        case choice = "conversation-choice"
        /// The other half, and it did not exist before Sprint 7: a benign menu the
        /// server DID hand keys for. Two states rather than a flag on one, because the
        /// pair is the assertion -- the two screens differ only in `buttons`, and any
        /// test that cannot tell them apart is not measuring the allowlist.
        case choiceKeys = "conversation-choice-keys"
        /// ★Sprint 8。上の6つは**どれも4行**しか返さない -- つまり画面から溢れず、
        /// 「開いた時どこに居るか」も「新しい行を追うか」も、UI からは**構造的に
        /// 測れなかった**。溢れる長さを持つ最初の状態。
        ///
        /// もう一つ、上の6つに無い性質を持つ: **2回目の取得で本当に古い行が増える**。
        /// 他の状態は limit を無視して同じ4行を返すので、「以前を読む」を押しても
        /// `advanced == false`(一番古い行が動かない)になり、押した後どこへ寄るかを
        /// 決める道筋そのものが走らない。
        case long = "conversation-long"
        /// ★2026-09-01。**探索の 5 面を UI から全部 出せる**唯一の状態。
        ///
        /// 上の 7 つでは足りない理由が 2 つ在る:
        ///   1. どれも走査の窓(下の `scanWindow` = 120)より短いので、後方読みは
        ///      必ず会話の頭に着く = `coverage` が常に `.wholeConversation`。
        ///      **`emptyBounded` が原理的に出せない** —— 之は依頼文の核心
        ///      (0 件の 2 意味)を UI の扉から測れないという事。
        ///   2. どれも `limit`(100)を超える一致を作れないので、
        ///      `isCapped`(= 「全部は見せていない」)も出せない。
        /// だから 240 行 持つ。窓 120 を跨ぐので走査は頭に着かず、`line` を含む問いは
        /// 120 件 一致して 100 で切られる。
        case search = "conversation-search"
        /// 探索**だけ**が机に届かない状態。転写は普通に読めている。
        ///
        /// 分けたのは、S7(`Couldn't reach the desk.`)を出す為に問いの文字列へ
        /// 合図を仕込む(`q == "!fail"` 等)道を採らない為。合図は fixture の中に
        /// 「実物に無い絞り込み規則」を 1 本 増やす事で、それは此の型が
        /// 自分の doc で禁じている「探した振り」の別形。状態で分ければ、
        /// 絞り込みの実装は 1 本のまま。
        case searchUnreachable = "conversation-search-unreachable"
    }

    let state: State

    func fetch(baseURL: URL, apiKey: String, sessionID: String, limit: Int) async -> Result<HistoryResponse, SessionsFetchError> {
        switch state {
        case .threeRoles, .degraded, .stalled, .busy, .choice, .choiceKeys, .searchUnreachable:
            return .success(Self.threeRolesResponse)
        case .long:
            // `ConversationViewModel.initialLimit` は 50、「以前を読む」は
            // `MergeHistory.nextHistoryLimit(50) == 150` を要求する。境界を 50 に
            // 置くのは、実物の2つの呼び出しがちょうどその両側に落ちる為。
            return .success(limit > Self.initialLimitBoundary ? Self.longWithOlder : Self.longTail)
        case .search:
            let all = Self.searchTranscript
            let shown = Array(all.suffix(limit))
            return .success(HistoryResponse(history: shown, truncated: shown.count < all.count))
        }
    }

    /// ★探索の fixture は**実物と同じ機構**を回す(2026-09-01 に絞り込みだけから拡張)。
    ///
    /// 2026-08-31 版は「返ってきた窓を `contains` で絞る」だけで、`matched` も
    /// `searchedToStart` も持っていなかった(`HistoryResponse` しか無かったので当然)。
    /// 新しい型はその 2 つを運ぶので、**固定値を入れると面が「探した振り」で緑になる**。
    /// 特に `searchedToStart: true` を焼き付けると、画面は毎回
    /// 「この会話のどこにも在りません」と言い切る —— 依頼文が名指しで禁じている嘘。
    ///
    /// だから机の 3 つの止まり方を写す(`sessions.mjs` / `listing.mjs`):
    ///   - 後方へ**チャンク単位**で遡る(`scanChunk`)
    ///   - 遡れる上限が在る(`scanWindow` ↔ 机の `TAIL_MAX` = 1 MiB)
    ///   - 一致が `limit` に届いたらそのチャンクの**末**で止まる(= 少し超過する
    ///     ので `matched > limit` が起きる。机の `all.slice(-limit)` と同じ形)
    /// `reachedStart` は「頭の 1 件まで見た」時だけ真。
    func search(baseURL: URL, apiKey: String, sessionID: String, limit: Int, query: String) async -> Result<TranscriptSearchResponse, SessionsFetchError> {
        if state == .searchUnreachable { return .failure(.unreachable) }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // 机は空の問いを「全件一致」にしない。電話は其れ以前に送らないが、
        // fixture 側でも同じ答え(0 件・頭まで見ていない)を返す。
        guard !needle.isEmpty else {
            return .success(TranscriptSearchResponse(history: [], matched: 0, coverage: .boundedScan))
        }
        return .success(Self.scan(Self.transcript(for: state), needle: needle, limit: limit))
    }

    /// 走査の 1 歩(机の `TAIL_CHUNK` = 64 KiB に当たる)。
    private static let scanChunk = 32
    /// 遡れる上限(机の `TAIL_MAX` = 1 MiB に当たる)。
    /// ★120 なのは、上の 7 状態(最長 90 行)が**全部この内側に収まり**、
    ///   `.search`(240 行)**だけ**が外へ出る為。境界を跨ぐ状態が 1 つ在る事が、
    ///   `.wholeConversation` と `.boundedScan` を UI から撃ち分ける唯一の手段。
    private static let scanWindow = 120

    private static func transcript(for state: State) -> [HistoryEntry] {
        switch state {
        case .threeRoles, .degraded, .stalled, .busy, .choice, .choiceKeys, .searchUnreachable:
            return threeRolesResponse.history
        // 「以前を読む」で全部 出る側が会話の全体。探索は読み込み済みの窓ではなく
        // **会話そのもの**を対象にする(窓の外を探すのが目的なので)。
        case .long: return longWithOlder.history
        case .search: return searchTranscript
        }
    }

    private static func scan(_ all: [HistoryEntry], needle: String, limit: Int) -> TranscriptSearchResponse {
        var matches: [HistoryEntry] = []   // 机と同じく**古い順**を保つ
        var scanned = 0
        var cursor = all.count             // 之より後ろは見た
        var reachedStart = all.isEmpty     // 空の転写は「頭まで見た」で正しい
        while scanned < scanWindow {
            let step = min(scanChunk, min(cursor, scanWindow - scanned))
            if step <= 0 { break }
            let lower = cursor - step
            matches = all[lower..<cursor].filter { $0.text.lowercased().contains(needle) } + matches
            cursor = lower
            scanned += step
            if cursor == 0 { reachedStart = true; break }
            // ★止まるのは**チャンクを読み切った後**。机の `done(lines)` が
            //   チャンク境界でしか評価されないのと同じで、之が `matched > limit` を生む。
            if matches.count >= limit { break }
        }
        return TranscriptSearchResponse(
            history: Array(matches.suffix(limit)),
            matched: matches.count,
            coverage: reachedStart ? .wholeConversation : .boundedScan
        )
    }

    // MARK: - conversation-long

    private static let initialLimitBoundary = 50

    /// 行番号を本文に持たせているのは、UI 検査が「どの行が画面に居るか」を
    /// 掴める唯一の手掛かりだから -- `EntryBubble` は行ごとの識別子を振らない
    /// (振ると `.accessibilityIdentifier` が子へ伝播して本文が読めなくなる)。
    private static func line(_ n: Int) -> HistoryEntry {
        // 役割を交互にするのは見た目の為ではなく、`MergeHistory.sameRoleAndText`
        // が role も見る比較器だから -- 全部同じ役割だと、比較器の片側だけが
        // 効いていても気付けない。
        let role: EntryRole = n.isMultiple(of: 2) ? .assistant : .user
        return HistoryEntry(
            role: role,
            text: String(format: "line %03d", n),
            display: .init(who: role == .user ? "Tom" : "Claude")
        )
    }

    /// 最初の取得。60行 -- どの iPhone でも1画面には入らない。
    private static let longTail = HistoryResponse(
        history: (31...90).map(line),
        truncated: true
    )

    /// 「以前を読む」の後。古い30行が**先頭に**足された同じ会話。
    /// 足す前に一番古かった行(`行 031`)はこの配列の index 30 に居る。
    private static let longWithOlder = HistoryResponse(
        history: (1...90).map(line),
        truncated: false
    )

    // MARK: - conversation-search

    /// 240 行。**窓(120)の 2 倍**在る事が此の状態の全部で、其れが
    /// `.boundedScan` と `isCapped` を UI から出せる唯一の性質。
    ///
    /// 本文は `line(_:)` を使い回す(新しい `who` の書き方を増やさない ——
    /// `rc-backend/test/fixture-labels-producible.test.mjs` が此の file の
    /// 発言者名を「サーバが作れる名前か」で数えている)。
    /// 問いごとの当たり方:
    ///   `line`     → 窓の中の 120 件 全部に当たる。100 で切られるので `isCapped`
    ///   `line 23`  → `line 230`…`line 239` の 10 件。切られない
    ///   何にも当たらない語 → 0 件・**頭までは見ていない**(= `emptyBounded`)
    private static let searchTranscript: [HistoryEntry] = (1...240).map(line)

    private static let threeRolesResponse = HistoryResponse(
        history: [
            HistoryEntry(role: .user, text: "Check the booking status", display: .init(who: "Tom")),
            HistoryEntry(role: .assistant, text: "Checking now — one moment.", display: .init(who: "Claude")),
            HistoryEntry(role: .tool, text: "⚙ Bash", display: .init(who: "Tool")),
            HistoryEntry(role: .assistant, text: "Found 2 bookings. Sending details.", display: .init(who: "Claude")),
        ],
        // truncated: true so the DoD screenshot also shows the "以前を読む" button
        // alongside all 3 role types in the same frame.
        truncated: true
    )
}

#endif

/// Exists in every configuration; the `RC_UI_FIXTURE` check itself is `#if
/// DEBUG`-gated below -- same shape as `SessionsListingFactory`. `RootView` uses this
/// to decide whether to bypass List/Key-entry/`AppState` entirely and show
/// `ConversationView` directly against canned data.
enum ConversationHistoryFactory {
    #if DEBUG
    static var fixtureState: HistoryFetchingFixture.State? {
        ProcessInfo.processInfo.environment["RC_UI_FIXTURE"].flatMap(HistoryFetchingFixture.State.init(rawValue:))
    }
    #endif
}
