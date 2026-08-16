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
    }

    let state: State

    func fetch(baseURL: URL, apiKey: String, sessionID: String, limit: Int) async -> Result<HistoryResponse, SessionsFetchError> {
        switch state {
        case .threeRoles, .degraded, .stalled, .busy, .choice, .choiceKeys:
            return .success(Self.threeRolesResponse)
        case .long:
            // `ConversationViewModel.initialLimit` は 50、「以前を読む」は
            // `MergeHistory.nextHistoryLimit(50) == 150` を要求する。境界を 50 に
            // 置くのは、実物の2つの呼び出しがちょうどその両側に落ちる為。
            return .success(limit > Self.initialLimitBoundary ? Self.longWithOlder : Self.longTail)
        }
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
