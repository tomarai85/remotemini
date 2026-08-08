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
    }

    let state: State

    func fetch(baseURL: URL, apiKey: String) async -> Result<SessionsResponse, SessionsFetchError> {
        // 数えるのは分岐の**手前**。`.unauthorized` も取得の一回で、失敗した回だけ
        // 数え落とすと「何回撃ったか」ではなく「何回成功したか」を数える器になる。
        let n = await SessionsListingFixtureFetchCount.next()
        switch state {
        case .unauthorized:
            return .failure(.unauthorized)
        case .normal:
            return .success(Self.response(sessions: Self.sampleRows, paneFault: nil, fetchCount: n))
        case .paneFault:
            return .success(Self.response(
                sessions: [Self.sampleRows[0]],
                paneFault: .init(reason: "pane-scan-timeout", detail: "tmux ペインの走査がタイムアウトしました。"),
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
    private static let sampleRows: [SessionRow] = [
        row(id: "fixture-choice-001", title: "承認待ちの一件", kind: .choice, short: "★選択待ち",
            text: "机で開いている・★選択待ち(Enter が承認や課金になります)", screen: "CHOICE"),
        row(id: "fixture-tmux-002", title: "作業中のセッション", kind: .tmux, short: "机・作業中",
            text: "机で開いている・作業中", screen: "MAIN"),
        row(id: "fixture-worker-003", title: "バックグラウンド処理", kind: .worker, short: "ワーカー・実行中",
            text: "ワーカーが実行中", screen: ""),
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
