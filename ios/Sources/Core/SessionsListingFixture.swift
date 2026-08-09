import Foundation

#if DEBUG

/// `SessionsListingFixture.fetch` が呼ばれた回数。**個体の外に置く必要が在る**:
/// fixture は `struct` で、`SessionsListingFactory.make()` は呼ばれるたびに新しい値を
/// 返すので、数える器を中に持たせると数が毎回 0 に戻り、常に「#1」を表示して
/// 「取り直していない」と見分けが付かなくなる。
///
/// `@MainActor` なのは、数を守るのに鍵を自前で持たない為。`fetch` は nonisolated な
/// async なので MainActor を継承せず、呼ぶ側が `await` を書く事になる —— その
/// `await` が「ここで隔離を跨いだ」と読める形で残るのが、`nonisolated(unsafe)` な
/// static 変数より良い所。DEBUG にしか居ないので Release の実行経路には一切出ない。
@MainActor
enum SessionsListingFixtureFetchCount {
    private static var count = 0

    static func next() -> Int {
        count += 1
        return count
    }
}

/// DEBUG-only fixture data source for `RemoteMiniUITests` (Sprint 2 brief §5-b).
///
/// A new, dedicated protocol conformance -- not `SessionsAuthProbe`, which discards
/// the response body and belongs to Key-entry only (see that type's own comment).
/// Selected via the `RC_UI_FIXTURE` environment variable rather than a network stub
/// or a separate `UI_TESTING` compile condition: the brief's author rejected both
/// alternatives explicitly (§5-b) -- a network-based fixture would need its own ATS
/// exception in a project that deliberately has none (ITSAppUsesNonExemptEncryption
/// comment in `project.yml`), and a narrower compile condition would need its own
/// screenshot-producing configuration on top of the Debug build `build.sh --sim`
/// already produces, for no behavioral difference over gating on `#if DEBUG`, which
/// already disappears from a Release binary (see `ios/tools/` fixture-absence
/// controls).
///
/// Holds no hostname, no URL, and an obviously-fake key (`"ui-fixture-key"`, wired at
/// the call site in `RootView`) -- and never touches the Keychain, unlike the real
/// Key-entry -> `CredentialStore` path.
struct SessionsListingFixture: SessionsListing {
    enum State: String {
        case normal = "list-normal"
        case paneFault = "list-panefault"
        case empty = "list-empty"
        /// Optional per brief §5-b ("optionally list-401"). Wired minimally: the
        /// ViewModel receives `.unauthorized` and invokes its `onUnauthorized`
        /// callback exactly as it would for a real 401, but `RootView`'s fixture
        /// path has no real `AppState` to tear down, so that callback is a no-op
        /// there. Not a required DoD screenshot; not pursued further this sprint.
        case unauthorized = "list-401"
        /// ★2026-08-08(監査 X2-3)。**取得が毎回失敗する**面。名前を `list-unreachable`
        /// にしないのは、どの phase に落ちるかが失敗の**回数**で決まる為 ——
        /// 1回目は `.retryable(priorSessions: nil)`、`unreachableThreshold` を超えて
        /// 初めて `.unreachable` になる。fixture が決めているのは結果ではなく入力なので、
        /// 名前も入力の側で付ける。
        ///
        /// 此処を足した理由: `list.retry` は `.retryable` と `.unreachable` にしか
        /// 出ないのに、既存の状態はどれもそこへ行けなかった —— `list-panefault` は
        /// 「banner を単独で見せる」面で、再試行のボタンを持たない(brief §4)。
        /// 旅程で最も起きる失敗(一覧が出ない)の唯一の的が、一度も測れていなかった。
        case fetchFailure = "list-fetchfail"
    }

    let state: State

    func fetch(baseURL: URL, apiKey: String) async -> Result<SessionsResponse, SessionsFetchError> {
        // 数えるのは分岐の**手前**。`.unauthorized` も取得の一回で、失敗した回だけ
        // 数え落とすと「何回撃ったか」ではなく「何回成功したか」を数える器になる。
        let n = await SessionsListingFixtureFetchCount.next()
        switch state {
        case .unauthorized:
            return .failure(.unauthorized)
        case .fetchFailure:
            return .failure(.unreachable)
        case .normal:
            return .success(Self.response(sessions: Self.sampleRows, paneFault: nil, fetchCount: n))
        case .paneFault:
            return .success(Self.response(
                sessions: [Self.sampleRows[0]],
                // ★此処の3つは**私が読みやすく書き直してよい所ではない**(上の sampleRows と同じ)。
                //   起票時は `pane-scan-timeout` +「tmux ペインの走査がタイムアウトしました。」で、
                //   前者は `paneFaultReason` が作れない語、後者は本番が絶対に出さない綺麗な日本語だった。
                //   `reason` / `display` は `test/fixture-labels-producible.test.mjs` が縛る。
                //   `detail` だけは縛れない —— 本番は `e.message` = 自由記述で、作れる集合が無い。
                //   画面には出ないので、一目で合成と分かる形にしてある。
                paneFault: .init(
                    reason: "panes-unreadable",
                    detail: "fixture-detail: production puts a raw JS error message here; the banner never draws it",
                    display: .init(
                        headline: "tmux の画面一覧を読めていません",
                        body: "tmux からの返事は来ていますが、中身が壊れていて読めません。復旧するまで、どの会話にも送れません。この故障は電話からは直せないので、机で確認してください。"
                    )
                ),
                fetchCount: n
            ))
        case .empty:
            return .success(Self.response(sessions: [], paneFault: nil, fetchCount: n))
        }
    }

    /// scan 行に取得の通し番号を載せる。**これが UI から取得回数を読む唯一の口**。
    ///
    /// なぜ画面に出す必要が在るか: `ListView` の引き金は5つ在るが(`ListViewModel.refresh()`
    /// の doc)、どれも `refresh()` を呼ぶだけで、呼ばれた事は ViewModel の中に痕跡を残さない
    /// —— `phase` は同じ応答なら同じ値に落ち着くので、「取り直した」と「取り直していない」が
    /// 画面上で**同じ**になる。番号を載せて初めて、UI 検査が引き金の配線そのものを見られる。
    ///
    /// 「違う番号になった」ではなく「**ちょうど +1**」を主張できる形にしてあるのが要点で、
    /// 戻るたびに2回撃つ実装(引き金を二重に配線した等)を緑で通さない。
    private static func response(sessions: [SessionRow], paneFault: SessionsResponse.PaneFault?, fetchCount: Int) -> SessionsResponse {
        SessionsResponse(
            sessions: sessions,
            display: .init(scan: "scan: fixture data, no real scan ran (取得 #\(fetchCount))"),
            paneFault: paneFault
        )
    }

    /// One row per `RouteLabel.Kind` the brief requires distinct visual treatment
    /// for (§1-b), so a screenshot of `list-normal` alone demonstrates all five.
    ///
    /// ★ここの文字列は**私が読みやすく書き直してよい所ではない**。サーバの `routeLabel`
    ///   (`rc-backend/src/view.mjs`)が実際に出す物と1バイト違えば、この fixture で撮った
    ///   画面は本番の画面ではなくなる。
    ///
    ///   2026-08-08 の実測で、5行中2行(tmux / worker)が production に作れない文字列
    ///   だった。worker 行は `ワーカー・実行中` と綺麗な日本語で、本番は `ワーカー・busy` と
    ///   内部トークンを生で出していた —— **fixture の方が本番より良く見えていたので、その
    ///   欠陥は画面を何度見ても原理的に見つからなかった**。「答えを書き込んだ fixture は
    ///   何も証明しない」の、緑ではなく見た目で騙す方の形。
    ///
    ///   以後は `rc-backend/test/fixture-labels-producible.test.mjs` が、この5行を
    ///   `routeLabel` が**出しうる集合**と突き合わせる(1つの代表とのバイト一致ではない ——
    ///   同日、その形にしたら正しい blocked 行を誤って赤にした)。文言を変える時は先に
    ///   サーバを変える事。この表を先に書き換えると、検査が「本番に作れない札」として止める。
    private static let sampleRows: [SessionRow] = [
        row(id: "fixture-choice-001", title: "承認待ちの一件", kind: .choice, short: "★選択待ち",
            text: "机で開いている・★選択待ち(Enter が承認や課金になります)", screen: "CHOICE"),
        // ★`screen` は `"MAIN"` だった(2026-08-09 に訂正)。サーバの `routeLabel` が tmux の枝で
        //   入れるのは `v.screen || ""` = `classifyScreen` の `SENDABLE` / `CHOICE` / `UNKNOWN` だけで、
        //   `MAIN` は**どの枝からも出ない**。出所は `test/fixture-labels-producible.test.mjs` の
        //   入力表で、其処では `routeLabel` が `=== "CHOICE"` しか見ない為に値が効かず、
        //   置き場所の無い placeholder が此処へ写った時にだけ「線に出る値」の顔をした。
        //   `SENDABLE` を選んだのは実測に依る —— `view.mjs` に、生成中の実画面
        //   (`generating-spinner-visible.txt`)が `{state:"SENDABLE", activity:"observed"}` に
        //   なると記録が在る。「動いている」は `activity` 側の話で、`screen` とは別の軸。
        row(id: "fixture-tmux-002", title: "作業中のセッション", kind: .tmux, short: "机・動いている",
            text: "机で開いている・動いている", screen: "SENDABLE"),
        row(id: "fixture-worker-003", title: "バックグラウンド処理", kind: .worker, short: "ワーカー・答え待ち",
            text: "ワーカー・答え待ち", screen: ""),
        row(id: "fixture-blocked-004", title: "宛先不明のセッション", kind: .blocked, short: "送れない",
            text: "宛先を確定できません。", screen: ""),
        row(id: "fixture-unknown-005", title: "未知の経路", kind: .unknown, short: "状態不明",
            text: "状態不明", screen: ""),
    ]

    private static func row(id: String, title: String, kind: RouteLabel.Kind, short: String, text: String, screen: String) -> SessionRow {
        SessionRow(
            id: id,
            title: title,
            updatedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-90)),
            fromRegistryOnly: nil,
            display: .init(
                route: RouteLabel(kind: kind, short: short, text: text, screen: screen),
                subtitle: "fixture subtitle"
            )
        )
    }
}

#endif

/// The factory `RootView` uses to pick a data source. Exists in every configuration,
/// but the `RC_UI_FIXTURE` check itself is `#if DEBUG`-gated below, so a Release
/// build's `make()` unconditionally returns `SessionsClient()` and the string
/// `RC_UI_FIXTURE` does not appear in the Release binary at all -- see
/// `ios/tools/ui-fixture-absence-control.sh` and `ios/tools/ui-fixture-behavior-control.sh`.
enum SessionsListingFactory {
    static func make() -> SessionsListing {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["RC_UI_FIXTURE"],
           let state = SessionsListingFixture.State(rawValue: raw) {
            return SessionsListingFixture(state: state)
        }
        #endif
        return SessionsClient()
    }

    #if DEBUG
    /// `nil` outside of a UI-test launch, or when `RC_UI_FIXTURE` names an unknown
    /// state. `RootView` uses this (not `make()`) to decide whether to bypass
    /// Key-entry/`AppState` entirely -- the fixture never needs a stored credential.
    static var fixtureState: SessionsListingFixture.State? {
        ProcessInfo.processInfo.environment["RC_UI_FIXTURE"].flatMap(SessionsListingFixture.State.init(rawValue:))
    }
    #endif
}
